// © GoodHatsLLC

public import Foundation
import Lifetime
import LifetimePrimitives
import Synchronization

/// Owns unstructured async callback work behind a drainable boundary.
///
/// Use this at synchronous platform callback boundaries that need to enter an
/// async domain but cannot expose raw `Task` handles to application code.
public final class AsyncTaskRunner: Sendable {
  private let tasks: Mutex<[UUID: DetachedOwnedWork<Void>]> = .init([:])

  public init() {}

  deinit {
    cancelAllNow()
  }

  public var activeCount: Int {
    tasks.withLock(\.count)
  }

  @discardableResult
  public func run(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void,
  ) -> UUID {
    let id = UUID()
    let startGate = Continuation<Void>()

    tasks.withLock { tasks in
      tasks[id] = DetachedOwnedWork(priority: priority) { [weak self] in
        await startGate()
        guard !Task.isCancelled else {
          self?.finish(id)
          return
        }

        await operation()
        self?.finish(id)
      }
    }

    try? startGate.yield()
    return id
  }

  public func drain() async {
    let currentTasks = tasks.withLock { $0 }
    for (id, task) in currentTasks {
      await task.value
      tasks.withLock { $0[id] = nil }
    }
  }

  public func cancel(_ id: UUID) async {
    guard let task = tasks.withLock({ $0.removeValue(forKey: id) }) else {
      return
    }
    await task.cancel()
  }

  public func cancelAll() async {
    let currentTasks = tasks.withLock { tasks in
      let currentTasks = Array(tasks.values)
      tasks.removeAll()
      return currentTasks
    }

    for task in currentTasks {
      await task.cancel()
    }
  }

  public func cancelAllNow() {
    let currentTasks = tasks.withLock { tasks in
      let currentTasks = Array(tasks.values)
      tasks.removeAll()
      return currentTasks
    }

    for task in currentTasks {
      task.cancelNow()
    }
  }

  private func finish(_ id: UUID) {
    tasks.withLock { $0[id] = nil }
  }
}
