import Synchronization

/// A runtime value whose lifetime can be ended explicitly.
///
/// `Scope`, `Resource`, and `Child` all conform to this protocol so they can
/// be adopted into other scopes uniformly.
public protocol LifetimeHandle: Sendable {
  func cancel() async
}

protocol NamedLifetimeHandle: LifetimeHandle {
  var name: String? { get }
}

struct Cancelling: ~Copyable, Sendable {
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

  init(performCancel: @escaping @Sendable () async -> Void) {
    self.lock = .init(.unstarted(.async(performCancel)))
  }

  init(performCancel: @escaping @Sendable () -> Void) {
    self.lock = .init(.unstarted(.sync(performCancel)))
  }

  private static func progress(state: inout State) -> Action? {
    switch state {
    case .unstarted(let action):
      switch action {
      case .sync(let syncAction):
        state = .finished
        return .sync(syncAction)
      case .async(let asyncAction):
        let continuation = Continuation<Void>()
        let completion = { @Sendable in
          await asyncAction()
          try? continuation.yield()
        }
        state = .pending {
          await continuation()
        }
        return .async(completion)
      }
    case .pending(let awaitable):
      return .async(awaitable)
    case .finished:
      return nil
    }
  }

  func cancel() async {
    let action = lock.withLock { state in
      Self.progress(state: &state)
    }

    guard let action else { return }

    switch action {
    case .sync(let syncAction):
      syncAction()
    case .async(let asyncAction):
      await asyncAction()
    }
  }

  @discardableResult
  nonisolated func triggerCancellation() -> Task<Void, Never>? {
    let action = lock.withLock { state in
      Self.progress(state: &state)
    }

    guard let action else { return nil }

    switch action {
    case .sync(let syncAction):
      syncAction()
      return nil
    case .async(let asyncAction):
      return Task.detached {
        await asyncAction()
      }
    }
  }

  deinit {
    triggerCancellation()
  }
}
