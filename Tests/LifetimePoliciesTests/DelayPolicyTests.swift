// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimePolicies

struct DelayPolicyTests {
  @Test
  func waitDelegatesToInjectedSleeper() async throws {
    let sleeper = ManualDelaySleeper()
    let policy = DelayPolicy(.milliseconds(125), sleeper: sleeper)

    async let wait: Void = policy.wait()

    #expect(await sleeper.nextDuration() == .milliseconds(125))
    await sleeper.release()
    try await wait
  }

  @Test
  func zeroDelayDoesNotSleep() async throws {
    let sleeper = ManualDelaySleeper()
    let policy = DelayPolicy(.zero, sleeper: sleeper)

    try await policy.wait()

    #expect(await sleeper.requestCount == 0)
  }

  @Test
  func cooperativeYieldPolicyAcceptsZeroCycles() async {
    await CooperativeYieldPolicy(cycles: 0).wait()
  }
}

private actor ManualDelaySleeper: AsyncSleeper {
  private let requestedDuration = Continuation<Duration>()
  private let releaseSleep = Continuation<Void>()
  private(set) var requestCount = 0

  func sleep(for duration: Duration) async throws {
    requestCount += 1
    try? requestedDuration.yield(duration)
    await releaseSleep()
  }

  func nextDuration() async -> Duration {
    await requestedDuration()
  }

  func release() async {
    try? releaseSleep.yield()
  }
}
