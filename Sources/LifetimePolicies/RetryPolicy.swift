// © GoodHatsLLC

import Foundation

/// The wait schedule between retry attempts.
///
/// Used by ``RetryPolicy`` to compute the duration of each retry's
/// inter-attempt sleep — either a constant duration or capped exponential
/// backoff.
public enum RetryDelay: Sendable, Equatable {
  case constant(Duration)
  case exponential(base: Duration, maximum: Duration, maximumExponent: Int)

  public func duration(afterFailureCount failureCount: Int) -> Duration {
    let failureCount = max(0, failureCount)
    switch self {
    case .constant(let duration):
      return duration

    case .exponential(let base, let maximum, let maximumExponent):
      guard failureCount > 0 else { return .zero }
      let exponent = min(
        failureCount - 1,
        max(0, min(maximumExponent, Int.bitWidth - 2)),
      )
      let multiplier = 1 << exponent
      let scaled = base * multiplier
      return scaled > maximum ? maximum : scaled
    }
  }
}

/// A named retry/backoff boundary backed by an injectable sleeper.
///
/// Production code should use this instead of scattering raw `Task.sleep`
/// calls through command, readiness, and background-worker retry loops.
public struct RetryPolicy: Sendable {
  public let maxAttempts: Int
  public let delay: RetryDelay
  private let sleeper: any AsyncSleeper

  public init(
    maxAttempts: Int,
    delay: RetryDelay,
    sleeper: any AsyncSleeper = TaskSleeper()
  ) {
    self.maxAttempts = max(1, maxAttempts)
    self.delay = delay
    self.sleeper = sleeper
  }

  public var attempts: ClosedRange<Int> {
    1...maxAttempts
  }

  public func shouldRetry(afterAttempt attempt: Int) -> Bool {
    attempt < maxAttempts
  }

  public func retryDelay(afterFailureCount failureCount: Int) -> Duration {
    delay.duration(afterFailureCount: failureCount)
  }

  public func waitBeforeRetry(afterAttempt attempt: Int) async throws {
    guard shouldRetry(afterAttempt: attempt) else { return }
    try await wait(afterFailureCount: attempt)
  }

  public func wait(afterFailureCount failureCount: Int) async throws {
    let duration = retryDelay(afterFailureCount: failureCount)
    guard duration > .zero else { return }
    try await sleeper.sleep(for: duration)
  }
}
