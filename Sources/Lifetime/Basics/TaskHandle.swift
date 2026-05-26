/// A ``LifetimeHandle`` wrapping a single non-detached `Task<Void, Never>`.
///
/// Use this when sync code (a UIKit delegate, a Combine subscriber, a C
/// callback, a view-model initializer) needs to spawn async work that
/// must remain owned and cancellable but should inherit the caller's
/// isolation, priority, and task-local values rather than detaching.
///
/// `cancel()` first asks the underlying task to cancel, then awaits the
/// task's completion before returning — so callers can rely on the work
/// having drained by the time the call returns. The task itself returns
/// `Void` and never throws; lift errors into the closure's own
/// reporting if you need them.
///
/// For detached work, isolation-inheriting work, or work that must be
/// pinned to the main actor, prefer the `OwnedWork` family in
/// `LifetimePrimitives` (``DetachedOwnedWork``, ``MainActorOwnedWork``).
public struct TaskHandle: LifetimeHandle {
  private let task: Task<Void, Never>

  public init(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void
  ) {
    task = Task(priority: priority) {
      await operation()
    }
  }

  public func cancel() async {
    task.cancel()
    _ = await task.result
  }
}
