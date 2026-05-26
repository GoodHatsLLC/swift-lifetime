// © GoodHatsLLC

import Foundation
public import Lifetime
import LifetimePrimitives

/// A scope-adoptable task handle with awaitable drained cancellation.
///
/// Use this when a synchronous boundary must start async work that should be
/// owned by a `Scope`. The underlying `Task` remains private; callers interact
/// with a `LifetimeHandle` and can wait for completion or cancellation.
public struct ScopeOwnedTask: LifetimeHandle {
  private let work: ActorOwnedWork<Void>

  public init(
    _ isolation: isolated (any Actor)? = #isolation,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void
  ) {
    work = ActorOwnedWork(priority: priority, inheriting: isolation) {
      await operation()
    }
  }

  public var isCancelled: Bool {
    work.isCancelled
  }

  public var value: Void {
    get async {
      await work.value
    }
  }

  public func cancelNow() {
    work.cancelNow()
  }

  public func cancel() async {
    await work.cancel()
  }
}

/// A scope-adoptable throwing task handle with awaitable drained cancellation.
///
/// Same role as ``ScopeOwnedTask`` but for operations that can throw. Use
/// this when a synchronous boundary must start async work that should be
/// owned by a ``Scope`` and may surface an error to its waiter.
public struct ScopeOwnedThrowingTask<Success: Sendable>: LifetimeHandle {
  private let work: ActorOwnedWork<Result<Success, any Error>>

  public init(
    _ isolation: isolated (any Actor)? = #isolation,
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  ) {
    work = ActorOwnedWork(priority: priority, inheriting: isolation) {
      do {
        return .success(try await operation())
      } catch {
        return .failure(error)
      }
    }
  }

  public var value: Success {
    get async throws {
      try await work.value.get()
    }
  }

  public func cancelNow() {
    work.cancelNow()
  }

  public func cancel() async {
    await work.cancel()
  }
}

extension Scope {
  @discardableResult
  public func startOwnedTask(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void
  ) -> ScopeOwnedTask {
    let task = ScopeOwnedTask(priority: priority, operation: operation)
    _ = ActorOwnedWork { [task] in
      do {
        try self.adopt(task)
      } catch {
        await task.cancel()
      }
    }
    return task
  }

  @discardableResult
  public func startMainActorOwnedTask(
    priority: TaskPriority? = nil,
    operation: @Sendable @MainActor @escaping () async -> Void
  ) -> ScopeOwnedTask {
    startOwnedTask(priority: priority) {
      await operation()
    }
  }

  @discardableResult
  public func startOwnedThrowingTask<Success: Sendable>(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async throws -> Success
  ) -> ScopeOwnedThrowingTask<Success> {
    let task = ScopeOwnedThrowingTask(priority: priority, operation: operation)
    _ = ActorOwnedWork { [task] in
      do {
        try self.adopt(task)
      } catch {
        await task.cancel()
      }
    }
    return task
  }
}
