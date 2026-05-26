import Synchronization

/// A single-yield async value that replays to all current and future
/// awaiters.
///
/// Use this at coordination boundaries where a single resolution event needs
/// to be observed by multiple awaiters — a "ready" signal, a computed result
/// that should be shared. Wraps `withUnsafeContinuation` but throws
/// ``Continuation/AlreadyYielded`` on repeated yield rather than trapping
/// the process. The internal state machine guarantees every appended waiter
/// is resumed exactly once, replacing the `CheckedContinuation` runtime
/// safety net with a compile-time-checked invariant.
public final class Continuation<Value: Sendable>: Sendable, Hashable {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public
  /// Metadata describing an attempt to yield more than once.
  public struct AlreadyYielded: Error, Hashable, CustomStringConvertible {
    public let id: LifetimeID
    public let yieldedValueDescription: String

    public var description: String {
      "Continuation<\(Value.self)> already yielded '\(yieldedValueDescription)'"
    }
  }

  public let id: LifetimeID = .init()

  public static func == (lhs: borrowing Continuation, rhs: borrowing Continuation) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  @discardableResult
  /// Suspends until the continuation has been yielded, then returns that value.
  public func callAsFunction() async -> Value {
    await unsafe withUnsafeContinuation { continuation in
      let immediateValue = continuations.withLock { state -> Value? in
        switch state {
        case .yielded(let yielded):
          return yielded
        case .awaiting(var waiters):
          unsafe waiters.append(continuation)
          state = unsafe .awaiting(waiters)
          return nil
        }
      }
      if let immediateValue {
        unsafe continuation.resume(returning: immediateValue)
      }
    }
  }

  /// Yield a value for the continuation to return when awaited.
  ///
  /// - parameter value: The value that will be returned when the continuation called and awaited.
  /// - throws: The continuation's value can only be yielded once. Subsequent attempts will throw.
  public nonisolated func yield(_ value: Value) throws(AlreadyYielded) {
    let continuations = try unsafe continuations.withLock { state throws(AlreadyYielded) in
      switch state {
      case .yielded(let value):
        throw AlreadyYielded(id: id, yieldedValueDescription: String(describing: value))
      case .awaiting(let array):
        state = .yielded(value)
        return unsafe array
      }
    }
    // swift-format-ignore
    for unsafe continuation in unsafe continuations {
      unsafe continuation.resume(returning: value)
    }
  }

  // MARK: Internal

  @safe
  enum State {
    case yielded(Value)
    case awaiting([UnsafeContinuation<Value, Never>])
  }

  let continuations: Mutex<State> = unsafe .init(.awaiting([]))
}

extension Continuation where Value == Void {
  /// Convenience overload for yielding `Void`.
  public func yield() throws(AlreadyYielded) { try yield(()) }
}

extension Continuation {
  /// Awaits the continuation and wraps the value in `Result.success`.
  public var result: Result<Value, Never> {
    get async {
      await .success(self())
    }
  }
}
