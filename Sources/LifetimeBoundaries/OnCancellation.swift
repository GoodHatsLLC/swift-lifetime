// © GoodHatsLLC

import Synchronization

/// The result of an ``awaitCancellation(isolation:then:)`` call that returned
/// a value from its action closure.
public enum CancellationAwaitResult<T> {
  case cancelled(T)
}

/// Suspends until the surrounding task is cancelled, then runs `action` and
/// returns its result wrapped in ``CancellationAwaitResult/cancelled(_:)``.
///
/// Use this where a sync→async boundary needs a deterministic place to run
/// cleanup work in response to cancellation, while still surfacing a value
/// to the caller.
public func awaitCancellation<T>(
  isolation _: (any Actor)? = #isolation,
  then action: () async -> T,
) async -> CancellationAwaitResult<T> {
  let mutex: Mutex<CheckedContinuation<Void, Never>?> = .init(nil)
  await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      mutex.withLock {
        if Task.isCancelled {
          continuation.resume()
          return
        }
        $0 = continuation
      }
    }
  } onCancel: {
    let continuation = mutex.withLock { $0.take() }
    continuation?.resume()
  }
  return await .cancelled(action())
}

/// Suspends until the surrounding task is cancelled, runs `action`, then
/// throws `CancellationError`.
///
/// Use this in code that must surface cancellation as a thrown error after
/// running cleanup, rather than as a returned value.
public func awaitCancellation(
  isolation _: (any Actor)? = #isolation,
  then action: () async -> Void,
) async throws(CancellationError) {
  let mutex: Mutex<CheckedContinuation<Void, Never>?> = .init(nil)

  await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      mutex.withLock {
        if Task.isCancelled {
          continuation.resume()
        } else {
          $0 = continuation
        }
      }
    }
  } onCancel: {
    mutex.withLock { $0.take() }?.resume()
  }

  await action()
  throw CancellationError()
}

/// Runs `operation` and invokes `action` if the surrounding task is
/// cancelled while it's in flight, without altering `operation`'s return
/// value or thrown error.
///
/// Thin wrapper over `withTaskCancellationHandler` that keeps cancellation
/// side effects grep-able from the call site.
public func withCancellationSideEffect<T>(
  isolation _: (any Actor)? = #isolation,
  _ operation: () async throws -> T,
  onCancel action: @Sendable () -> Void,
) async rethrows -> T {
  try await withTaskCancellationHandler {
    try await operation()
  } onCancel: {
    action()
  }
}
