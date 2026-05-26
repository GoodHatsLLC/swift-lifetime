// © GoodHatsLLC

public import Foundation
import Synchronization

/// A throwing one-shot async value for callback bridges.
///
/// Wraps `withUnsafeThrowingContinuation` but throws ``AlreadyResolved`` on
/// repeated completion attempts rather than trapping. The internal state
/// machine guarantees every appended waiter is resumed exactly once,
/// replacing the `CheckedContinuation` runtime safety net with a
/// compile-time-checked invariant. Use it at framework callback boundaries
/// where success, failure, and fallback completion paths can race.
public final class AsyncThrowingContinuation<Value: Sendable>: Sendable {
  public init() {}

  public struct AlreadyResolved: Error, Hashable {
    public let id: UUID
    public let resolvedValueDescription: String

    public var description: String {
      "AsyncThrowingContinuation<\(Value.self)> already resolved '\(resolvedValueDescription)'"
    }
  }

  public let id: UUID = .init()

  @discardableResult
  public func callAsFunction() async throws -> Value {
    try await unsafe withUnsafeThrowingContinuation { continuation in
      let immediateResult = continuations.withLock { state -> Result<Value, any Error>? in
        switch state {
        case .resolved(let result):
          return result
        case .awaiting(var waiters):
          unsafe waiters.append(continuation)
          state = unsafe .awaiting(waiters)
          return nil
        }
      }
      if let immediateResult {
        unsafe continuation.resume(with: immediateResult)
      }
    }
  }

  public nonisolated func yield(_ value: Value) throws(AlreadyResolved) {
    try resolve(.success(value))
  }

  public nonisolated func fail(_ error: any Error) throws(AlreadyResolved) {
    try resolve(.failure(error))
  }

  private func resolve(_ result: Result<Value, any Error>) throws(AlreadyResolved) {
    let waiters = try unsafe continuations.withLock { state throws(AlreadyResolved) in
      switch state {
      case .resolved(let previous):
        throw AlreadyResolved(id: id, resolvedValueDescription: String(describing: previous))
      case .awaiting(let waiters):
        state = .resolved(result)
        return unsafe waiters
      }
    }
    // swift-format-ignore
    for unsafe continuation in unsafe waiters {
      unsafe continuation.resume(with: result)
    }
  }

  @safe
  private enum State {
    case resolved(Result<Value, any Error>)
    case awaiting([UnsafeContinuation<Value, any Error>])
  }

  private let continuations: Mutex<State> = unsafe .init(.awaiting([]))
}

extension AsyncThrowingContinuation where Value == Void {
  public func yield() throws(AlreadyResolved) {
    try yield(())
  }
}
