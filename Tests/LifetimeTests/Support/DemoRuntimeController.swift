// © GoodHatsLLC

public import Foundation
import Lifetime
import LifetimePolicies
public import Observation

public enum DemoLifetimePolicy: String, CaseIterable, Identifiable, Sendable {
  case serialLIFO
  case parallelUnordered

  public var id: Self {
    self
  }

  public var label: String {
    switch self {
    case .serialLIFO:
      "serialLIFO"
    case .parallelUnordered:
      "parallelUnordered"
    }
  }

  var scopePolicy: ScopeCancellationPolicy {
    switch self {
    case .serialLIFO:
      .serialLIFO
    case .parallelUnordered:
      .parallelUnordered
    }
  }
}

public struct DemoTraceEntry: Identifiable, Sendable, Hashable {
  public let id: UUID
  public let timestamp: Date
  public let message: String

  public var timestampLabel: String {
    timestamp.formatted(date: .omitted, time: .standard)
  }
}

public enum DemoImportJobState: String, CaseIterable, Sendable {
  case running
  case completed
  case cancelled
  case failed
}

public struct DemoImportJobSnapshot: Identifiable, Sendable, Hashable {
  public let id: Int
  public let tenantID: String
  public let dataset: String
  public let totalRows: Int
  public let importedRows: Int
  public let state: DemoImportJobState

  public var progressLabel: String {
    "\(importedRows)/\(totalRows)"
  }

  public var progressFraction: Double {
    guard totalRows > 0 else { return 0 }
    return Double(importedRows) / Double(totalRows)
  }
}

public struct DemoPaymentMetrics: Sendable, Equatable {
  public let charges: Int
  public let refunds: Int

  public init(charges: Int = 0, refunds: Int = 0) {
    self.charges = charges
    self.refunds = refunds
  }
}

public struct DemoInventoryMetrics: Sendable, Equatable {
  public let committedItems: Int
  public let openReservations: Int

  public init(committedItems: Int = 0, openReservations: Int = 0) {
    self.committedItems = committedItems
    self.openReservations = openReservations
  }
}

public enum DemoControllerError: Error, CustomStringConvertible {
  case offline
  case invalidAmount(Double)
  case invalidItemCount(Int)
  case unauthorized
  case fraudHold(Double)
  case unknownJob(Int)
  case runtimeAlreadyStarted

  public var description: String {
    switch self {
    case .offline:
      "runtime is offline"
    case .invalidAmount(let amount):
      "amount must be positive: \(amount)"
    case .invalidItemCount(let count):
      "item count must be positive: \(count)"
    case .unauthorized:
      "session auth token is invalid"
    case .fraudHold(let amount):
      "payment held for manual review: \(amount)"
    case .unknownJob(let id):
      "no tracked job for id \(id)"
    case .runtimeAlreadyStarted:
      "runtime already started"
    }
  }
}

@MainActor
@Observable
public final class DemoRuntimeController {
  public private(set) var isLifetimeed = false
  public private(set) var activePolicy: DemoLifetimePolicy = .serialLIFO
  public private(set) var rootDescription = "Scope(state: offline)"
  public private(set) var jobs: [DemoImportJobSnapshot] = []
  public private(set) var traceEntries: [DemoTraceEntry] = []
  public private(set) var paymentMetrics = DemoPaymentMetrics()
  public private(set) var inventoryMetrics = DemoInventoryMetrics()
  public private(set) var lastMessage: String?

  @ObservationIgnored private let traceStore = DemoTraceStore()
  @ObservationIgnored private let jobStore = ImportJobStatusStore()
  @ObservationIgnored private var runtimeState: RuntimeState?
  @ObservationIgnored private var activeImportJobs: [Int: ManagedImportJob] = [:]
  @ObservationIgnored private var nextJobID = 1
  @ObservationIgnored private var pollingTask: DemoOwnedTask?

  public init() {}

  public var activeImportJobCount: Int {
    jobs.count(where: { $0.state == .running })
  }

  public func boot(policy: DemoLifetimePolicy) async throws -> String {
    guard runtimeState == nil else {
      throw DemoControllerError.runtimeAlreadyStarted
    }

    await pollingTask?.cancel()
    pollingTask = nil
    await traceStore.clear()
    await jobStore.reset()
    activeImportJobs.removeAll()
    nextJobID = 1

    let root = Scope.root(cancellationPolicy: policy.scopePolicy)
    let trace = traceStore

    let payments = try await root.start("PaymentGateway") {
      PaymentGateway(trace: trace)
    } destroy: { gateway in
      await gateway.shutdown()
    }

    let inventory = try await root.start("InventorySystem") {
      InventorySystem(trace: trace)
    } destroy: { inventory in
      await inventory.shutdown()
    }

    try root.onCancel {
      await trace.record("root scope cancellation finished")
    }

    let makeSession = try root.childFactory(name: "TenantSession") {
      (
        tenantID: String,
        sessionScope: Scope,
      ) in
      try sessionScope.onCancel {
        await trace.record("tenant session cancelled tenant=\(tenantID)")
      }

      let authToken = try await sessionScope.start("TenantAuthToken") {
        "tok-\(tenantID)-\(UUID().uuidString.prefix(8))"
      } destroy: { _ in
        await trace.record("tenant auth token revoked tenant=\(tenantID)")
      }

      return SessionExports(
        tenantID: tenantID,
        authToken: authToken,
      )
    }

    let makeRequestContext = try root.resourceFactory(name: "HTTPRequestContext") {
      (route: String) in
      RequestContext(
        id: UUID().uuidString,
        route: route,
        startedAt: ContinuousClock().now,
      )
    } destroy: { context in
      let elapsed = ContinuousClock().now - context.startedAt
      await trace.record(
        "request context destroyed route=\(context.route) id=\(context.id) latencyMs=\(durationMilliseconds(elapsed))",
      )
    }

    let makeImportJob = try root.childFactory(name: "ImportJob") {
      (
        input: ImportJobInput,
        jobScope: Scope,
      ) in
      let cancellationFlag = CancellationFlag()

      try jobScope.onCancel {
        await cancellationFlag.markCancelled()
        await trace.record(
          "import job scope cancelled tenant=\(input.tenantID) dataset=\(input.dataset)",
        )
      }

      let cursor = try await jobScope.start("ImportCursor") {
        "cursor-\(UUID().uuidString.prefix(8))"
      } destroy: { _ in
        await trace.record(
          "import cursor destroyed tenant=\(input.tenantID) dataset=\(input.dataset)",
        )
      }

      return ImportJobExports(
        tenantID: input.tenantID,
        dataset: input.dataset,
        totalRows: input.totalRows,
        cursor: cursor,
        cancellationFlag: cancellationFlag,
      )
    }

    runtimeState = RuntimeState(
      root: root,
      policy: policy,
      payments: payments,
      inventory: inventory,
      makeSession: makeSession,
      makeRequestContext: makeRequestContext,
      makeImportJob: makeImportJob,
    )

    isLifetimeed = true
    activePolicy = policy
    await traceStore.record("runtime booted policy=\(policy.label)")
    await startPolling()
    await refresh()

    let message = "runtime booted with policy: \(policy.label)"
    lastMessage = message
    return message
  }

  public func shutdown() async -> String {
    guard let runtimeState else {
      let message = "runtime is already offline"
      lastMessage = message
      return message
    }

    await pollingTask?.cancel()
    pollingTask = nil

    await runtimeState.root.cancel()

    for job in activeImportJobs.values {
      await job.task.value
    }
    activeImportJobs.removeAll()

    self.runtimeState = nil
    isLifetimeed = false
    rootDescription = "Scope(state: offline)"

    await traceStore.record("runtime shutdown complete")
    await refresh()

    let message = "runtime is offline"
    lastMessage = message
    return message
  }

  public func checkout(
    tenantID: String,
    itemCount: Int,
    amount: Double,
  ) async throws -> String {
    guard let runtimeState else {
      throw DemoControllerError.offline
    }
    guard itemCount > 0 else {
      throw DemoControllerError.invalidItemCount(itemCount)
    }
    guard amount > 0 else {
      throw DemoControllerError.invalidAmount(amount)
    }

    let trace = traceStore

    let result = try await runtimeState.root.withChild(
      runtimeState.makeSession,
      input: tenantID,
    ) { session in
      try await runtimeState.root.withResource(
        runtimeState.makeRequestContext,
        input: "/checkout",
      ) { request in
        await trace.record(
          "checkout start tenant=\(tenantID) request=\(request.id) items=\(itemCount) amount=\(amount)",
        )

        let reservation = try await runtimeState.inventory.reserve(
          items: itemCount,
          tenantID: tenantID,
          requestID: request.id,
        )

        do {
          let receiptID = try await runtimeState.payments.charge(
            tenantID: session.exports.tenantID,
            amount: amount,
            authToken: session.exports.authToken,
            requestID: request.id,
          )
          await runtimeState.inventory.commit(reservation: reservation, tenantID: tenantID)

          await trace.record(
            "checkout success tenant=\(tenantID) request=\(request.id) receipt=\(receiptID)",
          )
          return "receipt=\(receiptID), reservedItems=\(reservation.items)"
        } catch {
          await runtimeState.inventory.release(
            reservation: reservation,
            tenantID: tenantID,
            reason: "payment_failed",
          )
          await trace.record(
            "checkout failed tenant=\(tenantID) request=\(request.id) error=\(error)",
          )
          throw error
        }
      }
    }

    let message = "checkout completed: \(result)"
    lastMessage = message
    await refresh()
    return message
  }

  public func refund(
    tenantID: String,
    amount: Double,
  ) async throws -> String {
    guard let runtimeState else {
      throw DemoControllerError.offline
    }
    guard amount > 0 else {
      throw DemoControllerError.invalidAmount(amount)
    }

    let trace = traceStore

    let result = try await runtimeState.root.withChild(
      runtimeState.makeSession,
      input: tenantID,
    ) { session in
      try await runtimeState.root.withResource(
        runtimeState.makeRequestContext,
        input: "/refund",
      ) { request in
        await trace.record(
          "refund start tenant=\(tenantID) request=\(request.id) amount=\(amount)",
        )

        let refundID = try await runtimeState.payments.refund(
          tenantID: session.exports.tenantID,
          amount: amount,
          authToken: session.exports.authToken,
          requestID: request.id,
        )

        await trace.record(
          "refund success tenant=\(tenantID) request=\(request.id) refund=\(refundID)",
        )
        return "refund=\(refundID)"
      }
    }

    let message = "refund completed: \(result)"
    lastMessage = message
    await refresh()
    return message
  }

  public func startImport(
    tenantID: String,
    dataset: String,
    rows: Int,
  ) async throws -> Int {
    await pruneFinishedJobs()

    guard let runtimeState else {
      throw DemoControllerError.offline
    }
    guard rows > 0 else {
      throw DemoControllerError.invalidItemCount(rows)
    }

    let jobID = nextJobID
    nextJobID += 1

    let input = ImportJobInput(
      tenantID: tenantID,
      dataset: dataset,
      totalRows: rows,
    )
    let child = try await runtimeState.makeImportJob.make(input)

    await jobStore.start(
      id: jobID,
      tenantID: tenantID,
      dataset: dataset,
      totalRows: rows,
    )

    let trace = traceStore
    let jobStore = jobStore
    let task = DemoOwnedTask { [child] in
      await trace.record(
        "import job started id=\(jobID) tenant=\(tenantID) dataset=\(dataset) rows=\(rows)",
      )

      let step = max(1, rows / 12)
      var imported = 0

      while imported < rows {
        if await child.exports.cancellationFlag.isCancelled() {
          await jobStore.markCancelled(id: jobID)
          await trace.record("import job cancelled id=\(jobID)")
          await child.cancel()
          return
        }

        await DemoPacing.wait(for: .milliseconds(200))

        if await child.exports.cancellationFlag.isCancelled() {
          await jobStore.markCancelled(id: jobID)
          await trace.record("import job cancelled id=\(jobID)")
          await child.cancel()
          return
        }

        imported = min(rows, imported + step)
        await jobStore.updateProgress(id: jobID, importedRows: imported)
      }

      await jobStore.markCompleted(id: jobID)
      await trace.record("import job completed id=\(jobID) rows=\(rows)")
      await child.cancel()
    }

    activeImportJobs[jobID] = ManagedImportJob(
      id: jobID,
      tenantID: tenantID,
      dataset: dataset,
      totalRows: rows,
      child: child,
      task: task,
    )

    let message = "import job started: \(jobID)"
    lastMessage = message
    await refresh()
    return jobID
  }

  public func cancelImportJob(id: Int) async throws -> String {
    await pruneFinishedJobs()

    let snapshot = await jobStore.snapshot(id: id)
    if let snapshot, snapshot.state != .running {
      activeImportJobs[id] = nil
      let message = "job \(id) is already \(snapshot.state.rawValue)"
      lastMessage = message
      await refresh()
      return message
    }

    guard let job = activeImportJobs[id] else {
      throw DemoControllerError.unknownJob(id)
    }

    await job.child.cancel()
    await job.task.value
    activeImportJobs[id] = nil

    await jobStore.markCancelled(id: id)
    await traceStore.record(
      "import job cancel requested id=\(id) tenant=\(job.tenantID) dataset=\(job.dataset)",
    )

    let message = "job \(id) cancelled"
    lastMessage = message
    await refresh()
    return message
  }

  public func clearTrace() async {
    await traceStore.clear()
    traceEntries = []
    let message = "trace cleared"
    lastMessage = message
  }

  public func refresh() async {
    await pruneFinishedJobs()
    await refreshSnapshots()
  }

  public func recentTrace(limit: Int) -> [DemoTraceEntry] {
    Array(traceEntries.suffix(limit))
  }

  private func startPolling() async {
    await pollingTask?.cancel()
    pollingTask = DemoOwnedTask { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        await DemoPacing.wait(for: .milliseconds(250))
      }
    }
  }

  private func pruneFinishedJobs() async {
    let snapshots = await jobStore.list()
    let runningIDs = Set(
      snapshots.lazy
        .filter { $0.state == .running }
        .map(\.id),
    )
    activeImportJobs = activeImportJobs.filter { runningIDs.contains($0.key) }
  }

  private func refreshSnapshots() async {
    let snapshots = await jobStore.list()
    jobs = snapshots.map { snapshot in
      DemoImportJobSnapshot(
        id: snapshot.id,
        tenantID: snapshot.tenantID,
        dataset: snapshot.dataset,
        totalRows: snapshot.totalRows,
        importedRows: snapshot.importedRows,
        state: snapshot.state,
      )
    }

    traceEntries = await traceStore.snapshot()

    if let runtimeState {
      isLifetimeed = true
      activePolicy = runtimeState.policy
      rootDescription = String(describing: runtimeState.root)
      paymentMetrics = await runtimeState.payments.snapshot()
      inventoryMetrics = await runtimeState.inventory.snapshot()
    } else {
      isLifetimeed = false
      rootDescription = "Scope(state: offline)"
      paymentMetrics = DemoPaymentMetrics()
      inventoryMetrics = DemoInventoryMetrics()
    }
  }
}

private struct RuntimeState {
  let root: Scope
  let policy: DemoLifetimePolicy
  let payments: PaymentGateway
  let inventory: InventorySystem
  let makeSession: ChildFactory<String, SessionExports>
  let makeRequestContext: ResourceFactory<String, RequestContext>
  let makeImportJob: ChildFactory<ImportJobInput, ImportJobExports>
}

private struct ManagedImportJob {
  let id: Int
  let tenantID: String
  let dataset: String
  let totalRows: Int
  let child: Child<ImportJobExports>
  let task: DemoOwnedTask
}

private struct DemoOwnedTask {
  private let task: Task<Void, Never>

  @MainActor
  init(
    priority: TaskPriority? = nil,
    operation: @MainActor @escaping () async -> Void
  ) {
    task = Task(priority: priority) {
      await operation()
    }
  }

  func cancel() async {
    task.cancel()
    await task.value
  }

  var value: Void {
    get async {
      await task.value
    }
  }
}

private enum DemoPacing {
  static func wait(for duration: Duration) async {
    try? await DelayPolicy(duration).wait()
  }
}

private struct SessionExports {
  let tenantID: String
  let authToken: String
}

private struct RequestContext {
  let id: String
  let route: String
  let startedAt: ContinuousClock.Instant
}

private struct ImportJobInput {
  let tenantID: String
  let dataset: String
  let totalRows: Int
}

private struct ImportJobExports {
  let tenantID: String
  let dataset: String
  let totalRows: Int
  let cursor: String
  let cancellationFlag: CancellationFlag
}

private actor CancellationFlag {
  private var cancelled = false

  func markCancelled() {
    cancelled = true
  }

  func isCancelled() -> Bool {
    cancelled
  }
}

private actor ImportJobStatusStore {
  struct Snapshot {
    let id: Int
    let tenantID: String
    let dataset: String
    let totalRows: Int
    var importedRows: Int
    var state: DemoImportJobState
  }

  private var snapshots: [Int: Snapshot] = [:]

  func start(id: Int, tenantID: String, dataset: String, totalRows: Int) {
    snapshots[id] = Snapshot(
      id: id,
      tenantID: tenantID,
      dataset: dataset,
      totalRows: totalRows,
      importedRows: 0,
      state: .running,
    )
  }

  func updateProgress(id: Int, importedRows: Int) {
    guard var snapshot = snapshots[id] else { return }
    guard snapshot.state == .running else { return }
    snapshot.importedRows = min(snapshot.totalRows, importedRows)
    snapshots[id] = snapshot
  }

  func markCompleted(id: Int) {
    guard var snapshot = snapshots[id] else { return }
    snapshot.importedRows = snapshot.totalRows
    snapshot.state = .completed
    snapshots[id] = snapshot
  }

  func markCancelled(id: Int) {
    guard var snapshot = snapshots[id] else { return }
    if snapshot.state == .completed || snapshot.state == .failed {
      return
    }
    snapshot.state = .cancelled
    snapshots[id] = snapshot
  }

  func list() -> [Snapshot] {
    snapshots.values.sorted(by: { $0.id < $1.id })
  }

  func snapshot(id: Int) -> Snapshot? {
    snapshots[id]
  }

  func reset() {
    snapshots.removeAll()
  }
}

private actor DemoTraceStore {
  private var entries: [DemoTraceEntry] = []

  func record(_ message: String) {
    entries.append(
      DemoTraceEntry(
        id: UUID(),
        timestamp: .now,
        message: message,
      ),
    )
  }

  func snapshot() -> [DemoTraceEntry] {
    entries
  }

  func clear() {
    entries.removeAll()
  }
}

private actor PaymentGateway {
  private let trace: DemoTraceStore
  private var charges = 0
  private var refunds = 0

  init(trace: DemoTraceStore) {
    self.trace = trace
  }

  func charge(
    tenantID: String,
    amount: Double,
    authToken: String,
    requestID: String,
  ) async throws -> String {
    guard amount > 0 else { throw DemoControllerError.invalidAmount(amount) }
    guard amount < 5000 else { throw DemoControllerError.fraudHold(amount) }
    guard authToken.hasPrefix("tok-") else { throw DemoControllerError.unauthorized }

    await DemoPacing.wait(for: .milliseconds(120))
    charges += 1

    let receiptID = "pay-\(charges)-\(UUID().uuidString.prefix(6))"
    await trace.record(
      "payment charge request=\(requestID) tenant=\(tenantID) amount=\(amount) receipt=\(receiptID)",
    )
    return receiptID
  }

  func refund(
    tenantID: String,
    amount: Double,
    authToken: String,
    requestID: String,
  ) async throws -> String {
    guard amount > 0 else { throw DemoControllerError.invalidAmount(amount) }
    guard authToken.hasPrefix("tok-") else { throw DemoControllerError.unauthorized }

    await DemoPacing.wait(for: .milliseconds(90))
    refunds += 1

    let refundID = "refund-\(refunds)-\(UUID().uuidString.prefix(6))"
    await trace.record(
      "payment refund request=\(requestID) tenant=\(tenantID) amount=\(amount) refund=\(refundID)",
    )
    return refundID
  }

  func snapshot() -> DemoPaymentMetrics {
    DemoPaymentMetrics(charges: charges, refunds: refunds)
  }

  func shutdown() async {
    await trace.record("payment gateway shutdown charges=\(charges) refunds=\(refunds)")
  }
}

private struct InventoryReservation {
  let id: String
  let items: Int
}

private actor InventorySystem {
  private let trace: DemoTraceStore
  private var reservations: [String: Int] = [:]
  private var committedItems = 0

  init(trace: DemoTraceStore) {
    self.trace = trace
  }

  func reserve(
    items: Int,
    tenantID: String,
    requestID: String,
  ) async throws -> InventoryReservation {
    guard items > 0 else { throw DemoControllerError.invalidItemCount(items) }

    await DemoPacing.wait(for: .milliseconds(80))

    let reservation = InventoryReservation(
      id: "res-\(UUID().uuidString.prefix(6))",
      items: items,
    )
    reservations[reservation.id] = items

    await trace.record(
      "inventory reserve request=\(requestID) tenant=\(tenantID) reservation=\(reservation.id) items=\(items)",
    )
    return reservation
  }

  func commit(reservation: InventoryReservation, tenantID: String) async {
    committedItems += reservation.items
    reservations[reservation.id] = nil
    await trace.record(
      "inventory commit tenant=\(tenantID) reservation=\(reservation.id) items=\(reservation.items)",
    )
  }

  func release(
    reservation: InventoryReservation,
    tenantID: String,
    reason: String,
  ) async {
    reservations[reservation.id] = nil
    await trace.record(
      "inventory release tenant=\(tenantID) reservation=\(reservation.id) reason=\(reason)",
    )
  }

  func snapshot() -> DemoInventoryMetrics {
    DemoInventoryMetrics(
      committedItems: committedItems,
      openReservations: reservations.count,
    )
  }

  func shutdown() async {
    await trace.record(
      "inventory shutdown committedItems=\(committedItems) openReservations=\(reservations.count)",
    )
  }
}

private func durationMilliseconds(_ duration: Duration) -> Int {
  let seconds = Double(duration.components.seconds) * 1000
  let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000
  return Int((seconds + attoseconds).rounded())
}
