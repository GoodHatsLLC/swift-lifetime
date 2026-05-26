// © GoodHatsLLC

import Lifetime
import LifetimePolicies
import Testing

@testable import LifetimePrimitives

struct TokenBucketTests {
  @Test
  func limitsConcurrentWorkUntilTokenReturned() async {
    let bucket = TokenBucket(tokens: 1)
    let firstStarted = Continuation<Void>()
    let firstRelease = Continuation<Void>()
    let secondStarted = Continuation<Void>()

    async let first: Void = bucket.withToken {
      try? firstStarted.yield()
      await firstRelease()
    }
    async let second: Void = bucket.withToken {
      try? secondStarted.yield()
    }

    await firstStarted()
    #expect(await bucket.availableTokens == 0)

    try? firstRelease.yield()
    _ = await (first, second)

    await secondStarted()
    #expect(await bucket.availableTokens == 1)
  }

  @Test
  func cancelledAcquireDoesNotConsumeReturnedToken() async {
    let bucket = TokenBucket(tokens: 1)
    try? await bucket.acquire()

    let acquireStarted = Continuation<Void>()
    let waiter = ActorOwnedWork {
      try? acquireStarted.yield()
      do {
        try await bucket.acquire()
        return true
      } catch {
        return false
      }
    }

    await acquireStarted()
    while await bucket.pendingWaiterCount == 0 {
      await CooperativeYieldPolicy().wait()
    }

    await waiter.cancel()
    #expect(await waiter.value == false)
    #expect(await bucket.pendingWaiterCount == 0)

    await bucket.returnToken()
    #expect(await bucket.availableTokens == 1)
  }

  @Test
  func withAcquiredTokenReleasesAfterThrow() async {
    enum TestError: Error {
      case failed
    }

    let bucket = TokenBucket(tokens: 1)

    do {
      try await bucket.withAcquiredToken {
        throw TestError.failed
      }
      Issue.record("Expected operation failure")
    } catch TestError.failed {
      #expect(await bucket.availableTokens == 1)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
