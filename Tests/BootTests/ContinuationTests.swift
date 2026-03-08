import Testing

@testable import Boot

@Suite
struct ContinuationTests {
  @Test
  func yieldsToAwaitersRegisteredBeforeYield() async throws {
    let continuation = Continuation<Int>()

    async let first: Int = continuation()
    async let second: Int = continuation()
    await Task.yield()
    await Task.yield()

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
  func resultWrapsValueInSuccess() async throws {
    let continuation = Continuation<String>()
    try continuation.yield("ok")

    #expect(await continuation.result == .success("ok"))
  }

  @Test
  func voidConvenienceYieldResumesWaiters() async throws {
    let continuation = Continuation<Void>()

    async let waiter: Void = continuation()
    await Task.yield()
    try continuation.yield()

    await waiter
  }
}
