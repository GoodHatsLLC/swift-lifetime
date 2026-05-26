import Synchronization

/// Diagnostic context attached to a ``ScopeError``.
///
/// Context is informational — it does not affect equality comparisons
/// on ``ScopeError``.
public struct ScopeContext: Sendable, CustomStringConvertible {
  /// The scope that rejected the operation, if known.
  public let scopeID: LifetimeID?
  /// The operation that was attempted (e.g. `"start"`, `"adopt"`, `"child"`).
  public let operation: String?

  public init(scopeID: LifetimeID? = nil, operation: String? = nil) {
    self.scopeID = scopeID
    self.operation = operation
  }

  public var description: String {
    switch (scopeID, operation) {
    case (let id?, let op?):
      return "scope \(id), operation: \(op)"
    case (let id?, nil):
      return "scope \(id)"
    case (nil, let op?):
      return "operation: \(op)"
    case (nil, nil):
      return ""
    }
  }
}

/// Errors produced by Lifetime while creating or cancelling runtime lifetimes.
public enum ScopeError: Error, Sendable, CustomStringConvertible {
  /// The requested operation could not complete because the scope is already
  /// cancelling or fully cancelled.
  case cancelled(ScopeContext = .init())

  /// The diagnostic context for this error.
  public var context: ScopeContext {
    switch self {
    case .cancelled(let context):
      return context
    }
  }

  public var description: String {
    let detail = context.description
    if detail.isEmpty {
      return "Scope has already been cancelled."
    }
    return "Scope has already been cancelled (\(detail))."
  }
}

extension ScopeError: Equatable {
  public static func == (lhs: ScopeError, rhs: ScopeError) -> Bool {
    switch (lhs, rhs) {
    case (.cancelled, .cancelled):
      return true
    }
  }
}

/// A lifecycle boundary that owns child scopes, teardown work, and runtime resources.
///
/// ``cancel()`` is the contract: it is idempotent, cascades through every
/// child and registered cancellation action, and does not return until
/// in-flight `start` and `withResource` teardown has finished.
///
/// `deinit` is a **fallback only**. When the last strong reference to a
/// scope is dropped without an explicit cancel, teardown fires on a
/// detached task as a backstop against leaks — the trigger site does not
/// block and completion is not observable. Do not rely on `deinit` for
/// ordering, sequencing, or any teardown a test or shutdown sequence must
/// wait on.
public final class Scope: Sendable, LifetimeHandle, CustomStringConvertible,
  CustomDebugStringConvertible
{
  nonisolated let id: LifetimeID = .init()

  private let parent: Scope?
  private let cancellationPolicy: ScopeCancellationPolicy

  /// One slot in the unified registration log.
  ///
  /// `.tombstone` marks a slot that has been logically removed without
  /// touching the surrounding array layout. Walks, snapshots, and
  /// description counts must skip tombstones. The entries array is only
  /// freed when the scope transitions to `.cancelled`, so the tombstone
  /// memory cost is bounded by a single scope's lifetime.
  fileprivate enum Entry: Sendable {
    case child(id: LifetimeID, name: String?, reference: WeakScopeRef)
    case action(id: LifetimeID, name: String?, run: @Sendable () async -> Void)
    case tombstone

    fileprivate var id: LifetimeID? {
      switch self {
      case .child(let id, _, _), .action(let id, _, _):
        return id
      case .tombstone:
        return nil
      }
    }

    fileprivate var name: String? {
      switch self {
      case .child(_, let name, _), .action(_, let name, _):
        return name
      case .tombstone:
        return nil
      }
    }

    fileprivate var isChild: Bool {
      if case .child = self { return true }
      return false
    }

    fileprivate var isLive: Bool {
      if case .tombstone = self { return false }
      return true
    }
  }

  /// Lifecycle phase of a scope. The runtime `entries` log lives alongside
  /// the phase in ``ScopeStorage`` so that entry mutations don't have to
  /// rewrite an enum payload — which would defeat Swift's in-place array
  /// CoW for the registration log.
  enum Phase: Sendable {
    case running
    case cancelling(CancellationRun, DescriptionSnapshot)
    case cancelled(DescriptionSnapshot)
  }

  struct DescriptionSnapshot: Sendable {
    let phase: String
    let childCount: Int
    let cancellationCount: Int
    let names: [String]
  }

  /// Single mutable storage cell for a scope's runtime state.
  ///
  /// Hoisting `phase` and `entries` into one struct (instead of nesting
  /// `entries` inside a `.running` enum payload) lets the entries array
  /// mutate in place without triggering the enum-payload rewrite that
  /// previously broke `Array`'s copy-on-write fast path on every
  /// `register` / `removeEntry` / append. See git history for the
  /// per-`start()` cost this avoids.
  ///
  /// Children and cancellation actions share a single registration log
  /// so ``ScopeCancellationPolicy/serialLIFO`` can walk it in strict
  /// reverse registration order across both kinds of entry. The
  /// ``ScopeCancellationPolicy/parallelUnordered`` path still partitions
  /// the log into a children-then-actions sequence at cancellation time.
  struct ScopeStorage: Sendable {
    var phase: Phase = .running
    fileprivate var entries: [Entry] = []

    /// Runs `body` against the entries log if the scope is still running.
    /// Returns `.cancelled(context)` once the scope has moved past
    /// `.running`.
    fileprivate mutating func withRunningEntries<T>(
      context: ScopeContext = .init(),
      _ body: (inout [Entry]) -> T
    ) -> Result<T, ScopeError> {
      switch phase {
      case .running:
        return .success(body(&entries))
      case .cancelling, .cancelled:
        return .failure(.cancelled(context))
      }
    }
  }

  private let state: Mutex<ScopeStorage> = .init(.init())

  package init(
    parent: Scope? = nil,
    cancellationPolicy: ScopeCancellationPolicy = .serialLIFO
  ) {
    self.parent = parent
    self.cancellationPolicy = cancellationPolicy
  }

  /// Creates a root scope with no parent.
  ///
  /// `cancellationPolicy` defaults to `.serialLIFO`.
  public static func root(cancellationPolicy: ScopeCancellationPolicy = .serialLIFO) -> Scope {
    Scope(parent: nil, cancellationPolicy: cancellationPolicy)
  }

  /// Creates a root scope, runs `operation`, and always cancels the scope
  /// before returning or rethrowing.
  ///
  /// `cancellationPolicy` defaults to `.serialLIFO`.
  public static func withRoot<Result>(
    cancellationPolicy: ScopeCancellationPolicy = .serialLIFO,
    _ operation: @Sendable @escaping (Scope) async throws -> Result
  ) async throws -> Result {
    let scope = Scope.root(cancellationPolicy: cancellationPolicy)
    do {
      let result = try await operation(scope)
      await scope.cancel()
      return result
    } catch {
      await scope.cancel()
      throw error
    }
  }

  /// Registers custom async teardown work for this scope.
  ///
  /// The action runs as part of scope cancellation and is only invoked once.
  public func onCancel(_ action: @Sendable @escaping () async -> Void) throws {
    _ = try registerCancelAction(name: nil, operation: "onCancel", action)
  }

  /// Adopts an existing lifetime handle into this scope.
  ///
  /// The scope retains the handle through its cancellation closure and will
  /// cancel it when the scope ends.
  public func adopt(_ handle: some LifetimeHandle) throws {
    let name = (handle as? any NamedLifetimeHandle)?.name
    _ = try registerCancelAction(name: name, operation: "adopt") {
      await handle.cancel()
    }
  }

  public var description: String {
    let snapshot = state.withLock { storage in
      switch storage.phase {
      case .running:
        return Scope.describe(storage.entries, phase: "running")
      case .cancelling(_, let snapshot), .cancelled(let snapshot):
        return snapshot
      }
    }
    return Scope.format(snapshot)
  }

  public var debugDescription: String { description }

  /// Returns a structural snapshot of the scope's ownership tree.
  ///
  /// Snapshots preserve the registration order of children and
  /// cancellation actions, unlike the summary string from
  /// ``description``. Use this for debugging, observability, and test
  /// assertions on teardown ordering.
  ///
  /// A snapshot of a running scope recurses into each child, so the
  /// returned ``ScopeSnapshot`` contains the entire subtree rooted at
  /// this scope. Snapshots of scopes in
  /// ``ScopeSnapshot/Phase/cancelling`` or
  /// ``ScopeSnapshot/Phase/cancelled`` expose only the phase: the
  /// underlying runtime state has already been released.
  public func snapshot() -> ScopeSnapshot {
    let (phase, children, cancellations) = state.withLock {
      storage -> (
        ScopeSnapshot.Phase, [ScopeSnapshot.ChildEntry], [ScopeSnapshot.CancellationEntry]
      )
      in
      switch storage.phase {
      case .running:
        var children: [ScopeSnapshot.ChildEntry] = []
        var cancellations: [ScopeSnapshot.CancellationEntry] = []
        for entry in storage.entries {
          switch entry {
          case .child(let id, let name, let reference):
            children.append(
              ScopeSnapshot.ChildEntry(
                id: id,
                name: name,
                snapshot: reference.value?.snapshot()
              )
            )
          case .action(let id, let name, _):
            cancellations.append(
              ScopeSnapshot.CancellationEntry(id: id, name: name)
            )
          case .tombstone:
            continue
          }
        }
        return (.running, children, cancellations)
      case .cancelling:
        return (.cancelling, [], [])
      case .cancelled:
        return (.cancelled, [], [])
      }
    }
    return ScopeSnapshot(
      id: id,
      phase: phase,
      children: children,
      cancellationActions: cancellations
    )
  }

  /// Creates a lifetime handle, runs `operation`, and guarantees the handle
  /// is cancelled exactly once when `operation` completes or throws.
  public func withLifetime<Handle: LifetimeHandle, Result>(
    make: @Sendable @escaping () async throws -> Handle,
    _ operation: @Sendable @escaping (Handle) async throws -> Result
  ) async throws -> Result {
    let handle = try await make()
    do {
      let result = try await operation(handle)
      await handle.cancel()
      return result
    } catch {
      await handle.cancel()
      throw error
    }
  }

  /// Starts a scope-owned runtime resource immediately.
  ///
  /// Lifetime creates a ``Resource``, adopts it into the scope, then returns the
  /// unwrapped value.
  ///
  /// Prefer ``LaunchPolicy/inline`` (the default). Use
  /// ``LaunchPolicy/detached`` only when creation must not inherit the
  /// caller's isolation, priority, or task-local values; caller
  /// cancellation propagates into the detached task in either case.
  public func start<Value: Sendable>(
    _ name: String? = nil,
    launchPolicy: LaunchPolicy = .inline,
    create: @Sendable @escaping () async throws -> Value,
    destroy: @Sendable @escaping (_ value: Value) async -> Void = { _ in }
  ) async throws -> Value {
    try await startOwnedResource(name: name, operation: "start") { [self] in
      let value = try await executeFactory(launchPolicy: launchPolicy) {
        try await create()
      }
      return Resource(value: value, name: name, destroy: destroy)
    }
  }

  /// Starts a scope-owned runtime resource from an existing factory.
  ///
  /// The created resource is immediately adopted into the scope and the plain
  /// value is returned.
  public func start<Input: Sendable, Value: Sendable>(
    _ factory: ResourceFactory<Input, Value>,
    input: Input
  ) async throws -> Value {
    try await startOwnedResource(name: factory.name, operation: "start") {
      try await factory.make(input)
    }
  }

  private func startOwnedResource<Value: Sendable>(
    name: String?,
    operation: String,
    make: @Sendable @escaping () async throws -> Resource<Value>
  ) async throws -> Value {
    // `registerCancelAction` already throws `.cancelled` if the scope is
    // not running, so the upfront `ensureRunning` check would only acquire
    // the state lock a second time without adding any guarantees.
    let pendingResource = PendingOwnedHandle<Resource<Value>>()
    let cancellationID = try registerCancelAction(name: name, operation: operation) {
      await pendingResource.cancel()
    }
    let resource: Resource<Value>

    do {
      resource = try await make()
    } catch {
      pendingResource.resolve(nil)
      removeCancelAction(id: cancellationID)
      throw error
    }

    let ownerStillRunning = pendingResource.resolve(resource)
    guard ownerStillRunning else {
      throw ScopeError.cancelled(.init(scopeID: id, operation: operation))
    }

    do {
      try ensureRunning(for: operation)
      return resource.value
    } catch {
      await pendingResource.cancel()
      throw error
    }
  }

  /// Creates a scoped resource, runs `operation`, and cancels the resource on
  /// completion or error.
  ///
  /// The resource is owned by an ephemeral child scope so parent-scope
  /// cancellation also waits for this resource teardown.
  ///
  /// - Note: The ephemeral child scope is the source of `withResource`'s
  ///   strongest guarantee — `await scope.cancel()` on the parent will
  ///   block on this resource's `destroy` — but it does cost a child
  ///   scope allocation and an extra cancellation hop. In current
  ///   benchmarks `withResource` is roughly 40% slower than ``start``
  ///   for the same create/destroy work. If the resource should belong
  ///   directly to the current scope rather than to a transient
  ///   sub-scope, use ``start(_:launchPolicy:create:destroy:)`` and call
  ///   ``Resource/cancel()`` (or rely on scope cancellation) yourself.
  public func withResource<Value: Sendable, Result>(
    _ name: String? = nil,
    launchPolicy: LaunchPolicy = .inline,
    create: @Sendable @escaping () async throws -> Value,
    destroy: @Sendable @escaping (_ value: Value) async -> Void = { _ in },
    _ operation: @Sendable @escaping (Value) async throws -> Result
  ) async throws -> Result {
    try await withChildScope(name: name) { childScope in
      let value = try await childScope.start(
        name,
        launchPolicy: launchPolicy,
        create: create,
        destroy: destroy
      )
      return try await operation(value)
    }
  }

  /// Creates a resource from an existing factory, runs `operation`, and
  /// cancels the created resource on completion or error.
  ///
  /// The resource is owned by an ephemeral child scope so parent-scope
  /// cancellation also waits for this resource teardown. See the note on
  /// the inline-create overload for the perf trade-off vs ``start(_:input:)``.
  public func withResource<Input: Sendable, Value: Sendable, Result>(
    _ factory: ResourceFactory<Input, Value>,
    input: Input,
    _ operation: @Sendable @escaping (Value) async throws -> Result
  ) async throws -> Result {
    try await withChildScope(name: factory.name) { childScope in
      let value = try await childScope.start(factory, input: input)
      return try await operation(value)
    }
  }

  /// Creates a caller-owned resource factory for transient runtime values.
  ///
  /// Each call to the returned factory produces a distinct ``Resource`` handle
  /// that the caller owns until cancellation or adoption.
  public func resourceFactory<Value: Sendable>(
    _ launchPolicy: LaunchPolicy = .inline,
    name: String? = nil,
    create: @Sendable @escaping () async throws -> Value,
    destroy: @Sendable @escaping (_ value: Value) async -> Void = { _ in }
  ) throws -> ResourceFactory<Void, Value> {
    try resourceFactory(
      launchPolicy,
      name: name,
      create: { (_: Void) in
        try await create()
      },
      destroy: destroy
    )
  }

  /// Creates a caller-owned resource factory for transient runtime values.
  ///
  /// Each call to the returned factory produces a distinct ``Resource`` handle
  /// that the caller owns until cancellation or adoption.
  public func resourceFactory<Input: Sendable, Value: Sendable>(
    _ launchPolicy: LaunchPolicy = .inline,
    name: String? = nil,
    create: @Sendable @escaping (Input) async throws -> Value,
    destroy: @Sendable @escaping (_ value: Value) async -> Void = { _ in }
  ) throws -> ResourceFactory<Input, Value> {
    try ensureRunning(for: "resourceFactory")
    let owner = WeakScopeRef(self)
    let ownerID = id

    return ResourceFactory(name: name) { [owner, ownerID] input in
      guard let scope = owner.value else {
        throw ScopeError.cancelled(.init(scopeID: ownerID, operation: "resourceFactory.make"))
      }
      try scope.ensureRunning(for: "resourceFactory.make")
      let value = try await scope.executeFactory(launchPolicy: launchPolicy) {
        try await create(input)
      }

      do {
        try scope.ensureRunning(for: "resourceFactory.make")
        return Resource(value: value, name: name, destroy: destroy)
      } catch {
        await destroy(value)
        throw error
      }
    }
  }

  /// Builds a child lifetime immediately.
  ///
  /// The returned ``Child`` owns a new nested scope plus its exported values.
  public func child<Exports: Sendable>(
    _ build: @Sendable @escaping (Scope) async throws -> Exports
  ) async throws -> Child<Exports> {
    try await child(input: (), name: nil) { _, child in
      try await build(child)
    }
  }

  /// Builds a child lifetime immediately with runtime input.
  ///
  /// The returned ``Child`` owns a new nested scope plus its exported values.
  public func child<Input: Sendable, Exports: Sendable>(
    input: Input,
    _ build: @Sendable @escaping (Input, Scope) async throws -> Exports
  ) async throws -> Child<Exports> {
    try await child(input: input, name: nil, build)
  }

  /// Creates a child lifetime, runs `operation`, and always cancels the child
  /// scope before returning or rethrowing.
  public func withChild<Exports: Sendable, Result>(
    name: String? = nil,
    build: @Sendable @escaping (Scope) async throws -> Exports,
    _ operation: @Sendable @escaping (Child<Exports>) async throws -> Result
  ) async throws -> Result {
    try await withChild(
      name: name,
      input: (),
      build: { _, child in
        try await build(child)
      },
      operation
    )
  }

  /// Creates a child lifetime from runtime input, runs `operation`, and always
  /// cancels the child scope before returning or rethrowing.
  public func withChild<Input: Sendable, Exports: Sendable, Result>(
    name: String? = nil,
    input: Input,
    build: @Sendable @escaping (Input, Scope) async throws -> Exports,
    _ operation: @Sendable @escaping (Child<Exports>) async throws -> Result
  ) async throws -> Result {
    try await withLifetime(
      make: { [self] in
        try await child(input: input, name: name, build)
      },
      operation
    )
  }

  /// Creates a child from an existing factory, runs `operation`, and always
  /// cancels the child scope before returning or rethrowing.
  public func withChild<Input: Sendable, Exports: Sendable, Result>(
    _ factory: ChildFactory<Input, Exports>,
    input: Input,
    _ operation: @Sendable @escaping (Child<Exports>) async throws -> Result
  ) async throws -> Result {
    try await withLifetime(
      make: {
        try await factory.make(input)
      },
      operation
    )
  }

  /// Creates an ephemeral child scope, runs `operation`, and guarantees the
  /// child scope is cancelled when `operation` completes or throws.
  public func withChildScope<Result>(
    name: String? = nil,
    _ operation: @Sendable @escaping (Scope) async throws -> Result
  ) async throws -> Result {
    try await withLifetime(
      make: { [self] in
        try await child(input: (), name: name) { _, child in
          child
        }
      },
      { child in
        try await operation(child.scope)
      }
    )
  }

  private func child<Input: Sendable, Exports: Sendable>(
    input: Input,
    name: String?,
    _ build: @Sendable @escaping (Input, Scope) async throws -> Exports
  ) async throws -> Child<Exports> {
    try ensureRunning(for: "child")
    let child = try makeChildScope(name: name)

    do {
      let exports = try await build(input, child)
      try ensureRunning(for: "child")
      return Child(name: name, scope: child, exports: exports)
    } catch {
      await child.cancel()
      throw error
    }
  }

  /// Creates a caller-owned child factory.
  ///
  /// Each call to the returned factory produces a distinct child scope.
  public func childFactory<Exports: Sendable>(
    name: String? = nil,
    _ build: @Sendable @escaping (Scope) async throws -> Exports
  ) throws -> ChildFactory<Void, Exports> {
    try childFactory(name: name) { (_: Void, child: Scope) in
      try await build(child)
    }
  }

  /// Creates a caller-owned child factory with runtime input.
  ///
  /// Each call to the returned factory produces a distinct child scope.
  public func childFactory<Input: Sendable, Exports: Sendable>(
    name: String? = nil,
    _ build: @Sendable @escaping (Input, Scope) async throws -> Exports
  ) throws -> ChildFactory<Input, Exports> {
    try ensureRunning(for: "childFactory")
    let owner = WeakScopeRef(self)
    let ownerID = id

    return ChildFactory(name: name) { [owner, ownerID, name] input in
      guard let scope = owner.value else {
        throw ScopeError.cancelled(.init(scopeID: ownerID, operation: "childFactory.make"))
      }
      return try await scope.child(input: input, name: name, build)
    }
  }

  /// Shuts down this scope, cascading through child scopes and registered teardown.
  ///
  /// Cancellation is idempotent.
  public func cancel() async {
    guard let pending = beginCancellation() else { return }
    // Originator drives the walk inline on the caller's task; concurrent
    // callers receive `work == nil` and just await the shared run.
    if let work = pending.work {
      // `work()` calls `run.complete()` before returning, so the run is
      // already signalled — the originator does not need to await itself.
      // Concurrent callers awaiting `run.wait()` are unblocked by that same
      // completion.
      await work()
      return
    }
    await pending.run.wait()
  }

  deinit {
    guard let pending = beginCancellation() else { return }
    // `deinit` cannot await, so the originator hands the walk to a detached
    // task. Concurrent callers already awaiting `cancel()` continue to wait
    // on the same run and unblock when the detached walk completes.
    if let work = pending.work {
      Task.detached {
        await work()
      }
    }
  }

  func ensureRunning(for operation: String? = nil) throws(ScopeError) {
    let isRunning = state.withLock { storage in
      switch storage.phase {
      case .running:
        return true
      case .cancelling, .cancelled:
        return false
      }
    }

    guard isRunning else {
      throw .cancelled(.init(scopeID: id, operation: operation))
    }
  }

  private func makeChildScope() throws(ScopeError) -> Scope {
    try makeChildScope(name: nil)
  }

  private func makeChildScope(name: String?) throws(ScopeError) -> Scope {
    // No upfront prune: `walkCancellation` already tolerates nil weak refs,
    // and the entries log is freed wholesale at `.cancelled`. Skipping the
    // prune is one fewer lock acquisition per child registration and avoids
    // an O(n) scan on the hot path.
    let child = Scope(parent: self, cancellationPolicy: cancellationPolicy)
    let entry = Entry.child(
      id: child.id,
      name: name,
      reference: WeakScopeRef(child)
    )

    return try state.withLock { storage in
      storage.withRunningEntries(context: .init(scopeID: self.id, operation: "child")) { entries in
        entries.append(entry)
        return child
      }
    }.get()
  }

  /// Output of `beginCancellation` — `work` is non-nil only for the caller
  /// that transitioned the scope from `.running` to `.cancelling`. That
  /// caller is responsible for driving the walk (inline for `cancel()`,
  /// detached for `deinit`). All callers must `await run.wait()` so they
  /// unblock together when the originator signals completion.
  private struct PendingCancellation {
    let work: (@Sendable () async -> Void)?
    let run: CancellationRun
  }

  private static func walkCancellation(
    cancellationPolicy: ScopeCancellationPolicy,
    entries: [Entry]
  ) async {
    switch cancellationPolicy {
    case .serialLIFO:
      // Strict LIFO across both kinds of entry: walk the unified
      // registration log in reverse, dispatching each entry by kind.
      // Tombstones are skipped without affecting the order of remaining
      // live entries.
      for entry in entries.reversed() {
        switch entry {
        case .child(_, _, let reference):
          if let child = reference.value {
            await child.cancel()
          }
        case .action(_, _, let action):
          await action()
        case .tombstone:
          continue
        }
      }
    case .parallelUnordered:
      // Two-phase: all child scopes concurrently, then all cancellation
      // actions concurrently. The phases stay sequenced so that destroy
      // hooks (registered as actions) outlive the child scopes that may
      // have referenced them. Tombstones never reach either phase.
      var childScopes: [Scope] = []
      var actions: [@Sendable () async -> Void] = []
      for entry in entries {
        switch entry {
        case .child(_, _, let reference):
          if let child = reference.value {
            childScopes.append(child)
          }
        case .action(_, _, let action):
          actions.append(action)
        case .tombstone:
          continue
        }
      }

      await withTaskGroup(of: Void.self) { group in
        for child in childScopes {
          group.addTask { await child.cancel() }
        }
        await group.waitForAll()
      }

      await withTaskGroup(of: Void.self) { group in
        for action in actions {
          group.addTask { await action() }
        }
        await group.waitForAll()
      }
    }
  }

  private func beginCancellation() -> PendingCancellation? {
    state.withLock { storage in
      switch storage.phase {
      case .running:
        let snapshot = Self.describe(storage.entries, phase: "cancelling")
        let run = CancellationRun()
        let parent = self.parent
        let childID = self.id
        let policy = self.cancellationPolicy
        // Capture the entries by value; the work closure walks this
        // immutable snapshot while the scope's storage holds the new
        // `.cancelling` phase with an empty entries log.
        let entries = storage.entries
        let work: @Sendable () async -> Void = { [weak self] in
          await Self.walkCancellation(cancellationPolicy: policy, entries: entries)
          parent?.detachChild(id: childID)
          self?.completeCancellation()
          run.complete()
        }
        storage.phase = .cancelling(run, snapshot)
        storage.entries = []
        return PendingCancellation(work: work, run: run)
      case .cancelling(let run, _):
        return PendingCancellation(work: nil, run: run)
      case .cancelled:
        return nil
      }
    }
  }

  private func executeFactory<Value: Sendable>(
    launchPolicy: LaunchPolicy,
    builder: @Sendable @escaping () async throws -> Value
  ) async throws -> Value {
    switch launchPolicy {
    case .detached:
      let result = Continuation<Result<Value, any Error>>()

      let task = Task.detached {
        let resolved: Result<Value, any Error>
        do {
          resolved = .success(try await builder())
        } catch {
          resolved = .failure(error)
        }
        try? result.yield(resolved)
      }

      return try await withTaskCancellationHandler {
        try await result().get()
      } onCancel: {
        task.cancel()
      }
    case .inline:
      return try await builder()
    }
  }

  private func detachChild(id: LifetimeID) {
    removeEntry(id: id)
  }

  private func registerCancelAction(
    name: String?,
    operation: String,
    _ action: @Sendable @escaping () async -> Void
  ) throws -> LifetimeID {
    let actionID = LifetimeID()
    try state.withLock { storage in
      storage.withRunningEntries(context: .init(scopeID: id, operation: operation)) { entries in
        entries.append(.action(id: actionID, name: name, run: action))
      }
    }.get()
    return actionID
  }

  private func removeCancelAction(id: LifetimeID) {
    removeEntry(id: id)
  }

  /// Marks the entry with the given id as a tombstone instead of removing
  /// it from the array. This preserves O(1) amortized append behaviour on
  /// the registration log without paying the array element shift cost of
  /// `removeAll`, and — combined with the flat ``ScopeStorage`` layout —
  /// keeps the `entries` CoW fast path intact (no enum-payload rewrite).
  ///
  /// Walks, snapshots, and description counts all skip tombstones.
  /// Storage is freed wholesale when the scope transitions to
  /// `.cancelled`. Used by both `detachChild` and `removeCancelAction`;
  /// the entry kind doesn't matter because each id is unique.
  private func removeEntry(id: LifetimeID) {
    state.withLock { storage in
      // Recently-registered ids are statistically more likely targets
      // (e.g. a `start` calling `removeCancelAction` on its own action
      // after creation), so scan from the end.
      guard case .running = storage.phase else { return }
      for index in storage.entries.indices.reversed() {
        if storage.entries[index].id == id {
          storage.entries[index] = .tombstone
          return
        }
      }
    }
  }

  private static func describe(
    _ entries: [Entry],
    phase: String
  ) -> DescriptionSnapshot {
    var childCount = 0
    var cancellationCount = 0
    var names: Set<String> = []
    for entry in entries {
      if case .tombstone = entry {
        continue
      }
      if let name = entry.name {
        names.insert(name)
      }
      if entry.isChild {
        childCount += 1
      } else {
        cancellationCount += 1
      }
    }

    return DescriptionSnapshot(
      phase: phase,
      childCount: childCount,
      cancellationCount: cancellationCount,
      names: Array(names).sorted()
    )
  }

  private static func format(_ snapshot: DescriptionSnapshot) -> String {
    let namesDescription = snapshot.names.isEmpty ? "" : ", names: \(snapshot.names)"
    return
      "Scope(state: \(snapshot.phase), children: \(snapshot.childCount), cancellations: \(snapshot.cancellationCount)\(namesDescription))"
  }

  private func completeCancellation() {
    state.withLock { storage in
      guard case .cancelling = storage.phase else { return }
      storage.phase = .cancelled(
        .init(
          phase: "cancelled",
          childCount: 0,
          cancellationCount: 0,
          names: []
        )
      )
      // Entries were already cleared at the .cancelling transition, but
      // re-assert here so the cancelled state never retains references.
      storage.entries = []
    }
  }
}

private final class WeakScopeRef: Sendable {
  weak let value: Scope?

  init(_ value: Scope) {
    self.value = value
  }
}

struct CancellationRun: Sendable {
  private let completion = Continuation<Void>()

  func wait() async {
    await completion()
  }

  func complete() {
    try? completion.yield()
  }
}

// Allows `start(...)` to register ownership before async creation completes.
//
// Mediates the race between `resolve(handle)` (called once when make()
// finishes) and `cancel()` (called from the scope's cancel-action when the
// scope is cancelled while make() is in flight or after). `resolve` is
// synchronous so the happy path takes no actor hop; `cancel` may suspend
// waiting for the in-flight make() to finish so it can tear down the
// resource make() produced.
private final class PendingOwnedHandle<Handle: LifetimeHandle & Sendable>: Sendable {
  private struct PendingState {
    var isResolved = false
    var resolvedHandle: Handle? = nil
    var cancellationRequested = false
    var waiters: [CheckedContinuation<Handle?, Never>] = []
  }

  private let state: Mutex<PendingState> = .init(.init())

  /// Publishes the result of `make()` to any pending `cancel()` and reports
  /// whether the scope is still alive (so the caller can hand back the value).
  ///
  /// - Returns: `true` if no `cancel()` has been observed yet — the caller
  ///   may treat the resource as owned by the scope. `false` if a cancellation
  ///   was already requested; the awaiting `cancel()` (if any) will take
  ///   responsibility for tearing the resource down.
  @discardableResult
  func resolve(_ handle: Handle?) -> Bool {
    let (waiters, ownerStillRunning): ([CheckedContinuation<Handle?, Never>], Bool) =
      state.withLock { state in
        guard !state.isResolved else {
          // resolve should only ever be called once per pending handle; if it
          // isn't, preserve the first resolution and report current status.
          return ([], !state.cancellationRequested)
        }
        state.isResolved = true
        state.resolvedHandle = handle
        let drained = state.waiters
        state.waiters = []
        return (drained, !state.cancellationRequested)
      }
    for waiter in waiters {
      waiter.resume(returning: handle)
    }
    return ownerStillRunning
  }

  /// Marks the handle as cancelled and tears down the resolved resource (if
  /// any). If make() is still in flight, suspends until resolve(_:) runs.
  func cancel() async {
    let immediate: Handle?? = state.withLock { state in
      state.cancellationRequested = true
      if state.isResolved {
        return .some(state.resolvedHandle)
      }
      return nil
    }

    if let immediate {
      if let handle = immediate {
        await handle.cancel()
      }
      return
    }

    let handle: Handle? = await withCheckedContinuation { continuation in
      let resolved: Handle?? = state.withLock { state in
        if state.isResolved {
          return .some(state.resolvedHandle)
        }
        state.waiters.append(continuation)
        return nil
      }
      if let resolved {
        continuation.resume(returning: resolved)
      }
    }

    if let handle {
      await handle.cancel()
    }
  }
}
