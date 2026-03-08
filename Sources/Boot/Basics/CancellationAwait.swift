import Synchronization


/// A result replacing cancellation propagation in ``awaitCancellationThenReturn(isolation:from:)``.
public enum CancellationResult<T> {
  case cancelled(T)
}

/// Blocks the current async context until it is cancelled — then runs the action
/// and returns its result.
///
/// - Important: The function blocks forwards progress until cancellation occurs.
/// Unlike ``withCancellationHandler(handler:operation:)`` this function is dangerous.
public func awaitCancellationThenReturn<T>(
  isolation: (any Actor)? = #isolation,
  from action: () async -> T
) async -> CancellationResult<T> {
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

/// Blocks the current async context until it is cancelled — then runs the action
/// before throwing a `CancellationError`.
///
/// - Important: The function blocks forwards progress until cancellation occurs.
/// Unlike ``withCancellationHandler(handler:operation:)`` this function is dangerous.
public func awaitCancellationThenPerform(
  isolation: (any Actor)? = #isolation,
  action: () async -> Void
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
