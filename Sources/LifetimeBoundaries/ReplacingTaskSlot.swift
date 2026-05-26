// © GoodHatsLLC

import Foundation

/// Owns a single replaceable unstructured task behind an awaitable lifetime API.
///
/// Use this at platform boundaries where a synchronous caller needs to kick off
/// async work, but the surrounding type still needs deterministic replacement
/// and shutdown. Replacing a task cancels and drains the previous task before
/// starting the next one.
public actor ReplacingTaskSlot {
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0

  public init() {}

  public var isActive: Bool {
    task != nil
  }

  public func replace(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void,
  ) async {
    let previous = removeCurrentTask()
    previous?.cancel()
    await previous?.value

    generation &+= 1
    let taskGeneration = generation
    task = Self.makeTask(
      priority: priority,
      owner: self,
      generation: taskGeneration,
      operation: operation,
    )
  }

  public func cancel() async {
    let previous = removeCurrentTask()
    previous?.cancel()
    await previous?.value
  }

  public func waitForCurrentTask() async {
    let current = task
    await current?.value
  }

  private func removeCurrentTask() -> Task<Void, Never>? {
    generation &+= 1
    let previous = task
    task = nil
    return previous
  }

  private func finish(generation completedGeneration: UInt64) {
    guard generation == completedGeneration else { return }
    task = nil
  }

  private nonisolated static func makeTask(
    priority: TaskPriority?,
    owner: ReplacingTaskSlot,
    generation: UInt64,
    operation: @Sendable @escaping () async -> Void,
  ) -> Task<Void, Never> {
    Task(priority: priority) {
      await operation()
      await owner.finish(generation: generation)
    }
  }
}
