import Synchronization
import Testing

@testable import Lifetime

@Suite
struct ContinuationTests {
  @Test
  func continuationIsHashableByID() {
    let first = Continuation<Int>()
    let alias = first
    let second = Continuation<Int>()

    #expect(first == alias)
    #expect(first != second)

    let set: Set<Continuation<Int>> = [first, second]
    #expect(set.contains(first))
    #expect(set.contains(second))
    #expect(set.count == 2)
  }

  @Test
  func yieldsToAwaitersRegisteredBeforeYield() async throws {
    let continuation = Continuation<Int>()

    async let first: Int = continuation()
    async let second: Int = continuation()

    #expect(
      await waitUntil(timeout: .seconds(1)) {
        waiterCount(for: continuation) == 2
      }
    )

    try continuation.yield(42)

    #expect(await first == 42)
    #expect(await second == 42)
  }

  @Test
  func returnsYieldedValueForFutureWaiters() async throws {
    let continuation = Continuation<Int>()
    try continuation.yield(7)

    #expect(await continuation() == 7)
    #expect(await continuation() == 7)
  }

  @Test
  func throwsAlreadyYieldedWithOriginalValueMetadata() throws {
    let continuation = Continuation<Int>()
    try continuation.yield(1)

    do {
      try continuation.yield(2)
      Issue.record("Expected the second yield to throw.")
    } catch let error {
      #expect(error.id == continuation.id)
      #expect(error.yieldedValueDescription == "1")
      #expect(error.description.contains("already yielded"))
    }
  }

  @Test
  func alreadyYieldedUsesCustomStringConvertibleDescription() throws {
    let continuation = Continuation<Int>()
    try continuation.yield(1)

    do {
      try continuation.yield(2)
      Issue.record("Expected the second yield to throw.")
    } catch let error {
      #expect(String(describing: error) == error.description)
    }
  }

  @Test
  func resultWrapsValueInSuccess() async throws {
    let continuation = Continuation<String>()
    try continuation.yield("ok")

    #expect(await continuation.result == .success("ok"))
  }

  @Test
  func voidConvenienceYieldResumesWaiters() async throws {
    let continuation = Continuation<Void>()

    async let waiter: Void = continuation()
    #expect(
      await waitUntil(timeout: .seconds(1)) {
        waiterCount(for: continuation) == 1
      }
    )

    try continuation.yield()

    await waiter
  }

  private func waiterCount<Value: Sendable>(for continuation: Continuation<Value>) -> Int {
    continuation.continuations.withLock { state in
      switch state {
      case .awaiting(let waiters):
        unsafe waiters.count
      case .yielded:
        0
      }
    }
  }
}
