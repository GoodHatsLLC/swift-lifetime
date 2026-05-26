// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimePolicies

struct RetryPolicyTests {
  @Test
  func constantDelayDelegatesToInjectedSleeper() async throws {
    let sleeper = ManualRetrySleeper()
    let policy = RetryPolicy(
      maxAttempts: 3,
      delay: .constant(.milliseconds(500)),
      sleeper: sleeper,
    )

    async let wait: Void = policy.waitBeforeRetry(afterAttempt: 1)

    let duration = await sleeper.nextDuration()
    #expect(duration == .milliseconds(500))

    await sleeper.release()
    try await wait
  }

  @Test
  func waitBeforeRetryDoesNotSleepAfterFinalAttempt() async throws {
    let sleeper = ManualRetrySleeper()
    let policy = RetryPolicy(
      maxAttempts: 2,
      delay: .constant(.milliseconds(500)),
      sleeper: sleeper,
    )

    try await policy.waitBeforeRetry(afterAttempt: 2)

    #expect(await sleeper.requestedDurations.isEmpty)
  }

  @Test
  func exponentialDelayClampsToMaximum() {
    let policy = RetryPolicy(
      maxAttempts: 5,
      delay: .exponential(
        base: .milliseconds(250),
        maximum: .seconds(1),
        maximumExponent: 16,
      ),
    )

    #expect(policy.retryDelay(afterFailureCount: 0) == .zero)
    #expect(policy.retryDelay(afterFailureCount: 1) == .milliseconds(250))
    #expect(policy.retryDelay(afterFailureCount: 2) == .milliseconds(500))
    #expect(policy.retryDelay(afterFailureCount: 3) == .seconds(1))
    #expect(policy.retryDelay(afterFailureCount: 4) == .seconds(1))
  }
}

private actor ManualRetrySleeper: AsyncSleeper {
  private var durations: [Duration] = []
  private let requestedDuration = Continuation<Duration>()
  private let releaseSleep = Continuation<Void>()

  var requestedDurations: [Duration] {
    durations
  }

  func sleep(for duration: Duration) async throws {
    durations.append(duration)
    try requestedDuration.yield(duration)
    await releaseSleep()
  }

  func nextDuration() async -> Duration {
    await requestedDuration()
  }

  func release() {
    try? releaseSleep.yield()
  }
}
