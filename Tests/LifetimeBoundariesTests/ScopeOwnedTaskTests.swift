// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimeBoundaries

struct ScopeOwnedTaskTests {
  @Test
  func scopeCancellationDrainsOwnedTaskCleanup() async throws {
    let started = Continuation<Void>()
    let cleaned = Continuation<Void>()
    let gate = CancellationGate()

    try await Scope.withRoot { scope in
      scope.startOwnedTask {
        try? started.yield()
        await gate.wait()
        try? cleaned.yield()
      }

      await started()
      await scope.cancel()
    }

    await cleaned()
  }

  @Test
  func throwingTaskReturnsValue() async throws {
    let task = ScopeOwnedThrowingTask<Int> {
      42
    }

    #expect(try await task.value == 42)
  }

  @Test
  func throwingTaskDrainsAfterCancellation() async {
    let started = Continuation<Void>()
    let cleaned = Continuation<Void>()
    let gate = CancellationGate()
    let task = ScopeOwnedThrowingTask<Int> {
      try? started.yield()
      await gate.wait()
      try? cleaned.yield()
      return 1
    }

    await started()
    await task.cancel()
    await cleaned()
  }
}

private final class CancellationGate: Sendable {
  private let continuation = Continuation<Void>()

  func wait() async {
    await withTaskCancellationHandler {
      await continuation()
    } onCancel: {
      try? continuation.yield()
    }
  }
}
