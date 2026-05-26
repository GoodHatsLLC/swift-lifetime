// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimePolicies

struct TimeoutPolicyTests {
  @Test
  func waitForTimeoutDelegatesToInjectedSleeper() async throws {
    let sleeper = ManualTimeoutSleeper()
    let policy = TimeoutPolicy(.seconds(5), sleeper: sleeper)

    async let wait: Void = policy.waitForTimeout()

    let duration = await sleeper.nextDuration()
    #expect(duration == .seconds(5))

    await sleeper.release()
    try await wait
  }

  @Test
  func zeroTimeoutDoesNotSleep() async throws {
    let sleeper = ManualTimeoutSleeper()
    let policy = TimeoutPolicy(.zero, sleeper: sleeper)

    try await policy.waitForTimeout()

    #expect(await sleeper.requestedDurations.isEmpty)
  }
}

private actor ManualTimeoutSleeper: AsyncSleeper {
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
