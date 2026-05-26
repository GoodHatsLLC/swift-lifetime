import Foundation
public import Lifetime
public import Observation

/// Controls where a lazy resource builder executes.
public enum ResourceIsolation: Sendable {
  case detached
  case inherited
  case mainActor
}

/// The current state of a lazy resource.
public enum ResourceState: Sendable, Equatable {
  case pending
  case resolving
  case resolved
  case failed
}

/// An async value whose construction is deferred until first access.
///
/// The builder runs at most once per generation; concurrent accesses share
/// the in-flight task. ``reset()`` invalidates the cached value and waits
/// for any superseded build to finish before allowing a new one to begin.
/// Use ``ResourceIsolation`` to control where the builder executes.
public actor LazyValue<Value: Sendable> {
  private struct RunningTask: Sendable {
    let generation: UInt64
    let task: Task<Value, any Error>
  }

  private let builder: @Sendable () async throws -> Value
  private let isolation: ResourceIsolation
  private let retryOnError: Bool

  private var state: ResourceState = .pending
  private var generation: UInt64 = 0
  private var task: RunningTask?
  private var cachedValue: Value?
  private var cachedError: (any Error)?

  public init(
    _ isolation: ResourceIsolation = .detached,
    retryOnError: Bool = false,
    _ builder: @Sendable @escaping () async throws -> Value
  ) {
    self.builder = builder
    self.isolation = isolation
    self.retryOnError = retryOnError
  }

  public var currentState: ResourceState {
    state
  }

  public var isResolved: Bool {
    state == .resolved
  }

  public func get() async throws -> Value {
    if let cachedValue {
      return cachedValue
    }

    if let cachedError, !retryOnError {
      throw cachedError
    }

    if let task {
      return try await resolve(task)
    }

    state = .resolving
    let task = RunningTask(generation: generation, task: makeTask())
    self.task = task

    return try await resolve(task)
  }

  /// Cancels any in-flight build and invalidates all previously cached results.
  ///
  /// Values produced by a superseded build are discarded, even if that build
  /// completes after the reset. Returns after the superseded build task has
  /// finished.
  public func reset() async {
    await invalidateCurrentTask(clearCache: true)
  }

  /// Cancels the current in-flight build, if any, without clearing a resolved value.
  ///
  /// Returns after the in-flight build task has finished.
  public func cancel() async {
    await invalidateCurrentTask(clearCache: false)
  }

  private nonisolated func makeTask() -> Task<Value, any Error> {
    switch isolation {
    case .detached:
      Task.detached { [builder] in
        try await builder()
      }
    case .inherited:
      Task { [builder] in
        try await builder()
      }
    case .mainActor:
      Task { @MainActor [builder] in
        try await builder()
      }
    }
  }

  private func resolve(_ runningTask: RunningTask) async throws -> Value {
    do {
      let value = try await runningTask.task.value

      guard generation == runningTask.generation else {
        throw CancellationError()
      }

      if task?.generation == runningTask.generation {
        cachedValue = value
        cachedError = nil
        task = nil
        state = .resolved
      }

      return value
    } catch {
      guard generation == runningTask.generation else {
        throw CancellationError()
      }

      if task?.generation == runningTask.generation {
        task = nil
        if retryOnError || error is CancellationError {
          state = .pending
          cachedError = nil
        } else {
          cachedError = error
          state = .failed
        }
      }

      throw error
    }
  }

  private func invalidateCurrentTask(clearCache: Bool) async {
    if clearCache {
      cachedValue = nil
      cachedError = nil
      state = .pending
    }

    guard let task else {
      if clearCache {
        generation &+= 1
      }
      return
    }

    generation &+= 1
    self.task = nil
    task.task.cancel()

    if !clearCache, cachedValue == nil, cachedError == nil {
      state = .pending
    }

    _ = await task.task.result
  }
}

/// A `Sendable` value-type wrapper around ``LazyValue``.
///
/// Use this when application code wants to pass a lazy resource by value
/// rather than as an actor reference, and is happy with the actor's
/// queueing behavior on each call.
public struct LazyResource<Value: Sendable>: Sendable {
  private let value: LazyValue<Value>

  public static func mainActor(
    retryOnError: Bool = false,
    _ builder: @MainActor @Sendable @escaping () async throws -> Value
  ) -> LazyResource<Value> {
    LazyResource(.mainActor, retryOnError: retryOnError) {
      try await builder()
    }
  }

  public init(
    _ isolation: ResourceIsolation = .detached,
    retryOnError: Bool = false,
    _ builder: @Sendable @escaping () async throws -> Value
  ) {
    value = LazyValue(isolation, retryOnError: retryOnError, builder)
  }

  public func get() async throws -> Value {
    try await value.get()
  }

  public func reset() async {
    await value.reset()
  }

  public func cancel() async {
    await value.cancel()
  }

  public func currentState() async -> ResourceState {
    await value.currentState
  }

  public func isResolved() async -> Bool {
    await value.isResolved
  }
}

/// A `@MainActor`, `@Observable` view-side wrapper that publishes the
/// current ``ResourceObserver/State`` of a ``LazyResource``.
///
/// Call ``start()`` to begin observing; the returned ``LifetimeHandle``
/// owns the observation task and must be cancelled to stop updates. Use
/// this when a SwiftUI view needs to render loading / ready / failed
/// states for a lazy resource without subscribing to a stream manually.
@MainActor
@Observable
public final class ResourceObserver<Value: Sendable>: Sendable {
  public enum State: Sendable {
    case loading
    case ready(Value)
    case failed(String)
  }

  public private(set) var state: State = .loading
  private let resource: LazyResource<Value>

  public init(_ resource: LazyResource<Value>) {
    self.resource = resource
  }

  public func start() -> some LifetimeHandle {
    TaskHandle {
      do {
        if await self.resource.isResolved() {
          let value = try await self.resource.get()
          await MainActor.run {
            self.state = .ready(value)
          }
          return
        }

        await MainActor.run {
          self.state = .loading
        }

        let value = try await self.resource.get()
        guard !Task.isCancelled else { return }

        await MainActor.run {
          self.state = .ready(value)
        }
      } catch {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        await MainActor.run {
          self.state = .failed(error.localizedDescription)
        }
      }
    }
  }
}
