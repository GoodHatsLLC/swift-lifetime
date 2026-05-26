// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimeBoundaries

struct MainActorTaskRunnerTests {
  @Test
  @MainActor
  func drainWaitsForCompletionAndClearsFinishedTasks() async {
    let runner = MainActorTaskRunner()
    let started = Continuation<Void>()
    let finish = Continuation<Void>()

    runner.run {
      try? started.yield()
      await finish()
    }

    await started()
    #expect(runner.activeCount == 1)

    try? finish.yield()
    await runner.drain()

    #expect(runner.activeCount == 0)
  }

  @Test
  @MainActor
  func cancelAllDrainsCancellationCleanup() async {
    let runner = MainActorTaskRunner()
    let started = Continuation<Void>()
    let cleaned = Continuation<Void>()
    let cancellation = CancellationGate()

    runner.run {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await runner.cancelAll()

    await cleaned()
    #expect(runner.activeCount == 0)
  }

  @Test
  @MainActor
  func runCatchingReportsNonCancellationErrors() async {
    let runner = MainActorTaskRunner()
    let receivedError = Continuation<String>()

    runner.runCatching {
      throw SampleError.expected
    } onError: { error in
      try? receivedError.yield(String(describing: error))
    }

    #expect(await receivedError() == String(describing: SampleError.expected))
    await runner.drain()
    #expect(runner.activeCount == 0)
  }
}

private enum SampleError: Error, CustomStringConvertible {
  case expected

  var description: String {
    "expected"
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
