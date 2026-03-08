import Foundation
import Synchronization

public actor Supervisor: Sendable, CancellableType {
  public func cancel() async {
    _ = await cancelInternal()?.result
  }

  public var isCancelled: Bool {
    cancelled
  }

  public var trackedCount: Int {
    monitored.count
  }

  @discardableResult
  public func run(
    priority: TaskPriority? = nil,
    work: sending @escaping () async -> Void
  ) async -> AnyWork {
    if cancelled {
      return AnyWork(Work(task: Task<Void, Never> {}))
    }

    let task = Task<Void, Never>(priority: priority) {
      await work()
    }
    let monitoredWork = Work(task: task)
    await add(monitoredWork)
    return AnyWork(monitoredWork)
  }

  public func supervise(work: some CancellableType) async {
    await track(work)
  }

  public func track(_ work: some CancellableType) async {
    await add(work)
  }

  public func supervise(priority: TaskPriority? = nil, work: sending @escaping () async -> Void)
    async
  {
    _ = await run(priority: priority, work: work)
  }

  public init() {}
  private var cancelled: Bool = false
  private var monitored: [any CancellableType] = []

  func add(_ cancellableType: some CancellableType) async {
    if cancelled {
      await Task.detached {
        await cancellableType.cancel()
      }.value
    } else {
      monitored.append(cancellableType)
    }
  }

  func cancelInternal() -> AnyAwaitable? {
    guard !cancelled else { return nil }
    cancelled = true
    let old = monitored
    monitored = []
    return AnyAwaitable(
      erasing: Task.detached {
        await withTaskGroup { g in
          for c in old {
            g.addTask(operation: { await c.cancel() })
          }
          await g.waitForAll()
        }
      })
  }

  isolated deinit {
    _ = cancelInternal()
  }

  public func delegate() async -> Supervisor {
    let child = Supervisor()
    await add(child)
    return child
  }
}
