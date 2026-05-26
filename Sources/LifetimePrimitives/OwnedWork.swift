// © GoodHatsLLC

import Foundation

/// A detached task handle with both drained and best-effort cancellation APIs.
///
/// Use this for boundary work that must not inherit caller actor isolation, but
/// still needs an explicit owner that can await termination during shutdown.
public struct DetachedOwnedWork<Success: Sendable>: Sendable {
  private let task: Task<Success, Never>

  public init(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  ) {
    task = Task.detached(priority: priority) {
      await operation()
    }
  }

  /// Starts work that inherits the caller's actor isolation instead of
  /// detaching. Use when the operation captures actor-confined framework values
  /// that are not compiler-verifiable as `Sendable`.
  public init(
    priority: TaskPriority? = nil,
    inheriting isolation: isolated (any Actor)? = #isolation,
    operation: @escaping () async -> Success
  ) {
    task = Task(priority: priority) {
      _ = isolation
      return await operation()
    }
  }

  public var isCancelled: Bool {
    task.isCancelled
  }

  public var value: Success {
    get async {
      await task.value
    }
  }

  public func cancelNow() {
    task.cancel()
  }

  public func cancel() async {
    task.cancel()
    _ = await task.value
  }
}

/// An alias for ``DetachedOwnedWork`` used when constructing it via the
/// actor-inheriting initializer.
///
/// Functionally identical to ``DetachedOwnedWork``; the alternate spelling
/// signals intent at call sites that lean on the inheriting init's actor
/// isolation behavior.
public typealias ActorOwnedWork<Success: Sendable> = DetachedOwnedWork<Success>

/// A main-actor task handle with both drained and best-effort cancellation APIs.
///
/// Use this for UI-owned work kicked off from synchronous view hooks when the
/// operation must remain main-actor isolated but still needs explicit ownership.
public struct MainActorOwnedWork: Sendable {
  private let task: Task<Void, Never>

  @MainActor
  public init(
    priority: TaskPriority? = nil,
    operation: @MainActor @Sendable @escaping () async -> Void
  ) {
    task = Task(priority: priority) {
      await operation()
    }
  }

  public var isCancelled: Bool {
    task.isCancelled
  }

  public var value: Void {
    get async {
      await task.value
    }
  }

  public func cancelNow() {
    task.cancel()
  }

  public func cancel() async {
    task.cancel()
    await task.value
  }
}
