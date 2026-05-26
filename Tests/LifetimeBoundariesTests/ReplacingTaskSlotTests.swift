// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimeBoundaries

struct ReplacingTaskSlotTests {
  @Test
  func cancelDrainsOperationCleanup() async {
    let slot = ReplacingTaskSlot()
    let started = Continuation<Void>()
    let cleaned = Continuation<Void>()
    let cancellation = CancellationGate()

    await slot.replace {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await slot.cancel()

    await cleaned()
    #expect(await slot.isActive == false)
  }

  @Test
  func replaceDrainsPreviousTaskBeforeStartingNextTask() async {
    let slot = ReplacingTaskSlot()
    let events = EventLog()
    let firstStarted = Continuation<Void>()
    let firstCleaned = Continuation<Void>()
    let secondStarted = Continuation<Void>()
    let cancellation = CancellationGate()

    await slot.replace {
      await events.append("first-started")
      try? firstStarted.yield()
      await cancellation.wait()
      await events.append("first-cleaned")
      try? firstCleaned.yield()
    }

    await firstStarted()

    async let replacement: Void = slot.replace {
      await events.append("second-started")
      try? secondStarted.yield()
    }

    await firstCleaned()
    await replacement
    await secondStarted()

    #expect(await events.values == ["first-started", "first-cleaned", "second-started"])
  }

  @Test
  func completedTaskClearsActiveState() async {
    let slot = ReplacingTaskSlot()
    let finished = Continuation<Void>()

    await slot.replace {
      try? finished.yield()
    }

    await finished()
    await slot.waitForCurrentTask()

    #expect(await slot.isActive == false)
  }

  @Test
  func cancelIsIdempotentWhenSlotIsEmpty() async {
    let slot = ReplacingTaskSlot()

    await slot.cancel()
    await slot.cancel()

    #expect(await slot.isActive == false)
  }
}

private actor EventLog {
  private var storage: [String] = []

  var values: [String] {
    storage
  }

  func append(_ value: String) {
    storage.append(value)
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
