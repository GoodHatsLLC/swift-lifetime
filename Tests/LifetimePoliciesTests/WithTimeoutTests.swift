// © GoodHatsLLC

import LifetimeBoundaries
import Testing

@testable import LifetimePolicies

struct WithTimeoutTests {
  @Test
  func returnsOperationValueBeforeTimeout() async throws {
    let value = try await withTimeout(of: .seconds(5)) {
      7
    }

    #expect(value == 7)
  }

  @Test
  func throwsOperationFailure() async {
    await #expect(throws: WithTimeoutError<SampleFailure>.self) {
      try await withTimeout(of: .seconds(5)) { () async throws(SampleFailure) -> Int in
        throw .sample
      }
    }
  }

  @Test
  func throwsTimeoutWhenOperationDoesNotComplete() async {
    await #expect(throws: TimeoutOnlyError.self) {
      try await withTimeout(of: .milliseconds(1)) {
        let _: CancellationAwaitResult<Void> = await awaitCancellation(then: {})
      }
    }
  }
}

private enum SampleFailure: Error, Sendable, Equatable {
  case sample
}
