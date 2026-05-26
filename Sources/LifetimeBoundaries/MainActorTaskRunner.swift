// © GoodHatsLLC

public import Foundation
import LifetimePrimitives

/// Owns main-actor task bridges opened from synchronous callbacks.
///
/// Use this at UI and platform callback boundaries when the caller cannot be
/// made async, but the work still needs explicit ownership and test-visible
/// draining.
@MainActor
public final class MainActorTaskRunner {
  private var tasks: [UUID: MainActorOwnedWork] = [:]

  public nonisolated init() {}

  deinit {
    for task in tasks.values {
      task.cancelNow()
    }
  }

  public var activeCount: Int {
    tasks.count
  }

  @discardableResult
  public func run(
    priority: TaskPriority? = nil,
    operation: @MainActor @Sendable @escaping () async -> Void,
  ) -> UUID {
    let id = UUID()
    tasks[id] = MainActorOwnedWork(priority: priority) { [weak self] in
      await operation()
      self?.tasks[id] = nil
    }
    return id
  }

  @discardableResult
  public func runCatching(
    priority: TaskPriority? = nil,
    operation: @MainActor @Sendable @escaping () async throws -> Void,
    onError: @MainActor @Sendable @escaping (any Error) async -> Void,
  ) -> UUID {
    run(priority: priority) {
      do {
        try await operation()
      } catch {
        guard !Task.isCancelled else { return }
        await onError(error)
      }
    }
  }

  public func drain() async {
    let currentTasks = tasks
    for (id, task) in currentTasks {
      await task.value
      tasks[id] = nil
    }
  }

  public func cancel(_ id: UUID) async {
    guard let task = tasks.removeValue(forKey: id) else {
      return
    }
    await task.cancel()
  }

  public func cancelAll() async {
    let currentTasks = tasks.values
    tasks.removeAll()
    for task in currentTasks {
      await task.cancel()
    }
  }

  public func cancelAllNow() {
    let currentTasks = tasks.values
    tasks.removeAll()
    for task in currentTasks {
      task.cancelNow()
    }
  }
}
