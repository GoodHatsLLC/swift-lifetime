// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimeBoundaries

struct AsyncTaskRunnerTests {
  @Test
  func drainWaitsForCompletionAndClearsFinishedTasks() async {
    let runner = AsyncTaskRunner()
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
  func cancelAllDrainsCancellationCleanup() async {
    let runner = AsyncTaskRunner()
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
  func cancelSpecificTaskLeavesOtherTasksRunning() async {
    let runner = AsyncTaskRunner()
    let firstStarted = Continuation<Void>()
    let secondStarted = Continuation<Void>()
    let firstCleaned = Continuation<Void>()
    let firstCancellation = CancellationGate()
    let secondFinish = Continuation<Void>()

    let firstID = runner.run {
      try? firstStarted.yield()
      await firstCancellation.wait()
      try? firstCleaned.yield()
    }

    runner.run {
      try? secondStarted.yield()
      await secondFinish()
    }

    await firstStarted()
    await secondStarted()

    await runner.cancel(firstID)
    await firstCleaned()
    #expect(runner.activeCount == 1)

    try? secondFinish.yield()
    await runner.drain()
    #expect(runner.activeCount == 0)
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
