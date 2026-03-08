import Foundation


// MARK: - LazyAsync

/// Lazy async value with actor-based synchronization.
///
/// Builders run only when `resolve()` is first awaited. Concurrent awaiters
/// share a single task. Results are cached for subsequent access.
///
/// ```swift
/// let config = LazyAsync(.mainActor) { await Config.load() }
/// let value = try await config.resolve()
///
/// await config.reset()
/// ```
public actor LazyAsync<Value: Sendable> {

  public enum ResolutionState: Sendable, Equatable {
    /// Builder has not been invoked yet.
    case pending
    /// Builder is currently executing.
    case resolving
    /// Value has been successfully resolved and cached.
    case resolved
    /// Builder threw an error.
    case failed
  }

  private let builder: @Sendable () async throws -> Value
  private let isolation: IsolationClass
  private let retryOnError: Bool

  private var lifecycleState: ResolutionState = .pending
  private var task: Task<Value, any Error>?
  private var cachedValue: Value?
  private var cachedError: (any Error)?

  /// Creates an LazyAsync with specified isolation.
  public init(
    _ isolation: IsolationClass = .detached,
    retryOnError: Bool = false,
    _ builder: @Sendable @escaping () async throws -> Value
  ) {
    self.builder = builder
    self.isolation = isolation
    self.retryOnError = retryOnError
  }

  /// The current state.
  public var state: ResolutionState { lifecycleState }

  /// Whether resolved successfully.
  public var hasResolvedValue: Bool { lifecycleState == .resolved }

  /// Gets the value, resolving if needed.
  public func resolve() async throws -> Value {
    if let value = cachedValue {
      return value
    }

    if let error = cachedError, !retryOnError {
      throw error
    }

    if let task = task {
      return try await task.value
    }

    lifecycleState = .resolving
    let newTask = makeTask()
    task = newTask

    do {
      let value = try await newTask.value
      cachedValue = value
      cachedError = nil
      task = nil
      lifecycleState = .resolved
      return value
    } catch {
      task = nil
      if retryOnError || error is CancellationError {
        lifecycleState = .pending
        cachedError = nil
      } else {
        cachedError = error
        lifecycleState = .failed
      }
      throw error
    }
  }

  /// Gets the value, resolving if needed.
  public func get() async throws -> Value {
    try await resolve()
  }

  public func callAsFunction() async throws -> Value {
    try await resolve()
  }

  /// The current state.
  public var currentState: ResolutionState { lifecycleState }

  /// Whether resolved successfully.
  public var isResolved: Bool { lifecycleState == .resolved }

  /// Resets to pending state, cancelling any in-progress work.
  public func reset() {
    task?.cancel()
    task = nil
    cachedValue = nil
    cachedError = nil
    lifecycleState = .pending
  }

  /// Cancels any in-progress work.
  public func cancel() async {
    guard let task else { return }
    task.cancel()
    _ = await task.result
  }

  private nonisolated func makeTask() -> Task<Value, any Error> {
    switch isolation {
    case .detached:
      return Task.detached { [builder] in
        try await builder()
      }

    case .inherited:
      return Task { [builder] in
        try await builder()
      }

    case .mainActor:
      return Task { @MainActor [builder] in
        try await builder()
      }
    }
  }
}
