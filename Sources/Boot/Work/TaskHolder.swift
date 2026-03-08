/// A lightweight wrapper which holds, and on deinit cancells, a Task.
///
/// - Note: Useful in cases like view-logic debouncing, where a ``Supervisor``
/// is heavier than necessary.
@propertyWrapper public struct TaskHolder<Success: Sendable, Failure: Error>: ~Copyable {
  public init(
    _ success: Success.Type = Success.self,
    _ failure: Failure.Type = Failure.self,
    wrappedValue: Task<Success, Failure>? = nil
  ) {
    self.wrappedValue = wrappedValue
  }

  public init(
    _ success: Success.Type = Success.self,
    wrappedValue: Task<Success, Failure>? = nil
  ) where Failure == Never {
    self.wrappedValue = wrappedValue
  }

  @_disfavoredOverload
  public init(
    _ success: Success.Type = Success.self,
    wrappedValue: Task<Success, Failure>? = nil
  ) where Failure == any Error {
    self.wrappedValue = wrappedValue
  }

  deinit {
    wrappedValue?.cancel()
  }

  public var wrappedValue: Task<Success, Failure>? = nil {
    willSet {
      wrappedValue?.cancel()
    }
  }
}
