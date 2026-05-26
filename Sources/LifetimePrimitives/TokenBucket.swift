// © GoodHatsLLC

import Foundation

/// A concurrency-aware semaphore for bounding parallel async work.
///
/// ``acquire()`` suspends until a token is available; ``releaseToken()``
/// returns one. Tokens are owned by the bucket — cancelling a waiter
/// releases its reservation without consuming a token, so partial drain
/// at shutdown stays deterministic. Use this when you need to cap
/// concurrency across async operations and want to compose with `await`
/// rather than dispatching to a queue.
public actor TokenBucket {
  public enum AcquireFailure: Error, Sendable {
    case cancelled
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var tokens: Int
  private var waiters: [Waiter]
  private var pendingWaiterIDs: Set<UUID> = []
  private var cancelledWaiters: Set<UUID> = []

  public init(tokens: Int) {
    self.tokens = tokens
    waiters = []
  }

  public var availableTokens: Int {
    tokens
  }

  public var pendingWaiterCount: Int {
    waiters.count
  }

  /// Executes an `async` closure immediately when a token is available.
  /// Only the same number of closures will be executed concurrently as the number
  /// of `tokens` passed to ``TokenBucket/init(tokens:)``, all subsequent
  /// invocations of `withToken` will suspend until a "free" token is available.
  /// - Parameter body: The closure to invoke when a token is available.
  /// - Returns: Resulting value returned by `body`.
  public func withToken<ReturnType: Sendable>(
    _ body: @Sendable () async -> ReturnType,
  ) async -> ReturnType {
    await getToken()
    defer {
      self.returnToken()
    }

    return await body()
  }

  public func withToken<ReturnType: Sendable, Failure: Error & Sendable>(
    _ body: @Sendable () async throws(Failure) -> ReturnType,
  ) async throws(Failure) -> ReturnType {
    await getToken()
    defer {
      self.returnToken()
    }

    return try await body()
  }

  public func getToken() async {
    if tokens > 0 {
      tokens -= 1
      return
    }

    _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.waiters.append(Waiter(id: UUID(), continuation: continuation))
    }
  }

  /// Suspends until a token is available or the waiting task is cancelled.
  ///
  /// If cancellation wins before a token is assigned, the waiter is removed and
  /// no token is consumed.
  public func acquire() async throws(AcquireFailure) {
    if Task.isCancelled {
      throw .cancelled
    }

    if tokens > 0 {
      tokens -= 1
      return
    }

    let id = UUID()
    pendingWaiterIDs.insert(id)
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.pendingWaiterIDs.remove(id)
        if Task.isCancelled || self.cancelledWaiters.remove(id) != nil {
          continuation.resume(returning: false)
        } else {
          self.waiters.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: id)
      }
    }
    pendingWaiterIDs.remove(id)
    cancelledWaiters.remove(id)

    if !acquired {
      throw .cancelled
    }
  }

  public func returnToken() {
    if waiters.isEmpty {
      tokens += 1
    } else {
      let nextWaiter = waiters.removeFirst()
      nextWaiter.continuation.resume(returning: true)
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      if pendingWaiterIDs.contains(id) {
        cancelledWaiters.insert(id)
      }
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  public func releaseToken() {
    returnToken()
  }

  public func withAcquiredToken<ReturnType: Sendable>(
    _ body: @Sendable () async throws -> ReturnType,
  ) async throws -> ReturnType {
    try await acquire()
    defer {
      self.returnToken()
    }

    return try await body()
  }
}
