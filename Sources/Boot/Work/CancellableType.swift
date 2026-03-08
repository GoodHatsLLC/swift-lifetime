import Foundation
import Synchronization

/// A type representing a cancellation action.
public protocol CancellableType: Sendable, ~Copyable {
  func cancel() async
}

/// A cancellation action which auto-triggers if it is dereferenced.
public struct Cancelling: ~Copyable, Sendable, CancellableType {
  typealias AsyncAction = @Sendable () async -> Void
  typealias SyncAction = @Sendable () -> Void
  enum Action {
    case sync(SyncAction)
    case async(AsyncAction)
  }

  enum State {
    case unstarted(Action)
    case pending(AsyncAction)
    case finished
  }
  private let lock: Mutex<State>

  public init(performCancel: @escaping @Sendable () async -> Void) {
    self.lock = .init(.unstarted(.async(performCancel)))
  }
  public init(performCancel: @escaping @Sendable () -> Void) {
    self.lock = .init(.unstarted(.sync(performCancel)))
  }

  static func progress(state: inout State) -> Action? {
    switch state {
    case .unstarted(let action):
      switch action {
      case .sync(let syncAction):
        state = .finished
        return .sync(syncAction)
      case .async(let asyncAction):
        let continuation: Continuation<Void> = .init()
        let action = { @Sendable in
          await asyncAction()
          try! continuation.yield()
        }
        state = .pending({
          await continuation()
        })
        return .async(action)
      }
    case .pending(let awaitable):
      return .async(awaitable)
    case .finished:
      return nil
    }
  }

  /// Trigger cancellation if needed, and await any cancellation still pending.
  public func cancel() async {
    let maybeAction: Action? = lock.withLock { state in
      Self.progress(state: &state)
    }
    if let action = maybeAction {
      switch action {
      case .sync(let syncAction):
        syncAction()
      case .async(let asyncAction):
        await asyncAction()
      }
    }
  }

  /// Immediately trigger cancellation.
  /// - Returns: An ``Awaitable`` if cancellation is still pending completion.
  @discardableResult
  public nonisolated func triggerCancellation() -> AnyAwaitable? {
    let maybeAction: Action? = lock.withLock { state in
      Self.progress(state: &state)
    }
    if let action = maybeAction {
      switch action {
      case .sync(let syncAction):
        syncAction()
      case .async(let asyncAction):
        let task = Task<Void, Never>.detached { await asyncAction() }
        return AnyAwaitable(erasing: task)
      }
    }
    return nil
  }

  deinit {
    triggerCancellation()
  }
}
