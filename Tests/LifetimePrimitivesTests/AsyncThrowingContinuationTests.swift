// © GoodHatsLLC

import Testing

@testable import LifetimePrimitives

struct AsyncThrowingContinuationTests {
  @Test
  func returnsYieldedValue() async throws {
    let continuation = AsyncThrowingContinuation<Int>()

    try continuation.yield(42)

    let value = try await continuation()
    #expect(value == 42)
  }

  @Test
  func throwsYieldedFailure() async {
    let continuation = AsyncThrowingContinuation<Int>()

    try? continuation.fail(TestError())

    await #expect(throws: TestError.self) {
      _ = try await continuation()
    }
  }

  @Test
  func rejectsSecondResolution() throws {
    let continuation = AsyncThrowingContinuation<Int>()

    try continuation.yield(1)

    #expect(throws: AsyncThrowingContinuation<Int>.AlreadyResolved.self) {
      try continuation.yield(2)
    }
  }
}

private struct TestError: Error, Equatable {}
