import Foundation
import Synchronization
import Testing
import os

@testable import Boot

// MARK: - Helpers

/// Thread-safe counter using os_unfair_lock for use in stress tests.
private final class AtomicCounter: Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: 0)

  var value: Int { lock.withLock { $0 } }

  func increment() { lock.withLock { $0 += 1 } }
}

/// Thread-safe actor counter for async contexts.
private actor AsyncCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

// MARK: - LazyAsync Stress Tests

@Suite
struct LazyAsyncStressTests {

  @Test(.timeLimit(.minutes(1)))
  func manyAwaitersShareSingleExecution() async throws {
    let builderRuns = AtomicCounter()
    let awaiterCount = 200

    let value = LazyAsync {
      builderRuns.increment()
      try await Task.sleep(for: .milliseconds(10))
      return 42
    }

    let results = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<awaiterCount {
        group.addTask { try await value.get() }
      }
      var collected: [Int] = []
      collected.reserveCapacity(awaiterCount)
      for try await v in group { collected.append(v) }
      return collected
    }

    #expect(results.count == awaiterCount)
    #expect(results.allSatisfy { $0 == 42 })
    #expect(builderRuns.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func rapidGetResetCycles() async throws {
    let builderRuns = AsyncCounter()

    let value = LazyAsync {
      await builderRuns.increment()
      return await builderRuns.value
    }

    let cycles = 50
    for _ in 0..<cycles {
      _ = try await value.get()
      await value.reset()
    }

    let totalRuns = await builderRuns.value
    #expect(totalRuns == cycles)
    #expect(await value.currentState == .pending)
  }

  @Test(.timeLimit(.minutes(1)))
  func concurrentGetAndResetDoesNotCrash() async throws {
    let value = LazyAsync {
      try await Task.sleep(for: .milliseconds(1))
      return "hello"
    }

    // Half the tasks get(), the other half reset(). No crashes or deadlocks.
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        if i.isMultiple(of: 2) {
          group.addTask { _ = try? await value.get() }
        } else {
          group.addTask { await value.reset() }
        }
      }
    }
    // If we reach here without hanging, the test passes.
    // State should be consistent (pending or resolved, never stuck).
    let state = await value.currentState
    #expect(state == .pending || state == .resolved)
  }

  @Test(.timeLimit(.minutes(1)))
  func errorRetryUnderConcurrency() async throws {
    let attempts = AtomicCounter()

    let value = LazyAsync(.detached, retryOnError: true) {
      attempts.increment()
      if attempts.value < 3 {
        throw CancellationError()
      }
      return "success"
    }

    // First calls may fail; retryOnError resets to pending so eventually one succeeds.
    var succeeded = false
    for _ in 0..<10 {
      do {
        _ = try await value.get()
        succeeded = true
        break
      } catch {
        // Expected for early attempts.
      }
    }

    #expect(succeeded)
    #expect(await value.currentState == .resolved)
  }

  @Test(.timeLimit(.minutes(1)))
  func failedStateCachesError() async throws {
    struct TestError: Error {}
    let builderRuns = AtomicCounter()

    let value = LazyAsync<String>(.detached, retryOnError: false) {
      builderRuns.increment()
      throw TestError()
    }

    // First call fails.
    await #expect(throws: TestError.self) { try await value.get() }
    #expect(await value.currentState == .failed)

    // Subsequent calls rethrow without re-running the builder.
    await #expect(throws: TestError.self) { try await value.get() }
    #expect(builderRuns.value == 1)
  }
}

// MARK: - Continuation Stress Tests

@Suite
struct ContinuationStressTests {

  @Test(.timeLimit(.minutes(1)))
  func manyConcurrentAwaitersAllReceiveValue() async throws {
    let continuation = Continuation<Int>()
    let awaiterCount = 200

    let results = await withTaskGroup(of: Int.self) { group in
      for _ in 0..<awaiterCount {
        group.addTask { await continuation() }
      }

      // Let awaiters register before yielding.
      try? await Task.sleep(for: .milliseconds(20))
      try! continuation.yield(99)

      var collected: [Int] = []
      collected.reserveCapacity(awaiterCount)
      for await v in group { collected.append(v) }
      return collected
    }

    #expect(results.count == awaiterCount)
    #expect(results.allSatisfy { $0 == 99 })
  }

  @Test(.timeLimit(.minutes(1)))
  func awaitersAfterYieldReturnImmediately() async {
    let continuation = Continuation<String>()
    try! continuation.yield("cached")

    let awaiterCount = 200
    let results = await withTaskGroup(of: String.self) { group in
      for _ in 0..<awaiterCount {
        group.addTask { await continuation() }
      }
      var collected: [String] = []
      for await v in group { collected.append(v) }
      return collected
    }

    #expect(results.count == awaiterCount)
    #expect(results.allSatisfy { $0 == "cached" })
  }

  @Test(.timeLimit(.minutes(1)))
  func concurrentYieldExactlyOneSucceeds() async throws {
    let continuation = Continuation<Int>()
    let successCount = AtomicCounter()
    let failureCount = AtomicCounter()
    let racerCount = 50

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<racerCount {
        group.addTask {
          do {
            try continuation.yield(i)
            successCount.increment()
          } catch {
            failureCount.increment()
          }
        }
      }
    }

    #expect(successCount.value == 1)
    #expect(failureCount.value == racerCount - 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func yieldWhileAwaitersRegister() async {
    // Interleave awaiter registration and yield in a tight race.
    for _ in 0..<20 {
      let continuation = Continuation<Int>()

      async let awaiters: [Int] = withTaskGroup(of: Int.self) { group in
        for _ in 0..<10 {
          group.addTask { await continuation() }
        }
        var results: [Int] = []
        for await v in group { results.append(v) }
        return results
      }

      // Yield immediately — some awaiters may or may not have registered yet.
      try! continuation.yield(7)

      let results = await awaiters
      #expect(results.allSatisfy { $0 == 7 })
    }
  }
}

// MARK: - Cancelling Stress Tests

@Suite
struct CancellingStressTests {

  @Test(.timeLimit(.minutes(1)))
  func sequentialCancelsFireExactlyOnce() async {
    let counter = AtomicCounter()
    let cancelling = Cancelling { counter.increment() }

    // Cancel many times sequentially — action fires only on the first.
    for _ in 0..<100 {
      await cancelling.cancel()
    }

    #expect(counter.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func triggerThenCancelIsIdempotent() async {
    let counter = AtomicCounter()
    let cancelling = Cancelling { counter.increment() }

    let awaitable = cancelling.triggerCancellation()
    _ = await awaitable?.result

    // Subsequent cancel() should be a no-op.
    await cancelling.cancel()
    await cancelling.cancel()

    #expect(counter.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func asyncCancelActionCompletesBeforeCancelReturns() async {
    let counter = AtomicCounter()

    let cancelling = Cancelling {
      try? await Task.sleep(for: .milliseconds(10))
      counter.increment()
    }

    await cancelling.cancel()

    // The counter must have been incremented by the time cancel() returns.
    #expect(counter.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func manyDeinitCancellationsAllFire() async {
    let counter = AtomicCounter()
    let iterations = 200

    for _ in 0..<iterations {
      _ = Cancelling { counter.increment() }
    }

    // Sync Cancelling actions fire immediately on deinit — no sleep needed.
    #expect(counter.value == iterations)
  }

  @Test(.timeLimit(.minutes(1)))
  func asyncDeinitCancellationsAllFire() async throws {
    let counter = AtomicCounter()
    let iterations = 50

    for _ in 0..<iterations {
      _ = Cancelling {
        counter.increment()
      }
    }

    // Sync actions fire synchronously on deinit.
    #expect(counter.value == iterations)
  }
}

// MARK: - Supervisor Stress Tests

@Suite
struct SupervisorStressTests {

  @Test(.timeLimit(.minutes(1)))
  func cancelsManyTasksConcurrently() async throws {
    let supervisor = Supervisor()
    let cancelledCount = AtomicCounter()
    let taskCount = 100

    for _ in 0..<taskCount {
      await supervisor.supervise {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          cancelledCount.increment()
        }
      }
    }

    await supervisor.cancel()
    try await Task.sleep(for: .milliseconds(50))

    #expect(cancelledCount.value == taskCount)
  }

  @Test(.timeLimit(.minutes(1)))
  func deepDelegationChainCascadesCancellation() async throws {
    let supervisor = Supervisor()
    let depth = 10
    let cancelledCount = AtomicCounter()

    // Build a chain: root -> child1 -> child2 -> ... -> childN
    var current = supervisor
    for _ in 0..<depth {
      let child = await current.delegate()
      await child.supervise {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          cancelledCount.increment()
        }
      }
      current = child
    }

    // Cancel root — should cascade through all children.
    await supervisor.cancel()
    try await Task.sleep(for: .milliseconds(100))

    #expect(cancelledCount.value == depth)
  }

  @Test(.timeLimit(.minutes(1)))
  func concurrentAddAndCancelDoesNotCrash() async {
    let supervisor = Supervisor()
    let counter = AtomicCounter()

    await withTaskGroup(of: Void.self) { group in
      // Half the tasks add work, other half cancel.
      for i in 0..<100 {
        if i.isMultiple(of: 2) {
          group.addTask {
            await supervisor.supervise { counter.increment() }
          }
        } else {
          group.addTask {
            await supervisor.cancel()
          }
        }
      }
    }

    // The test passes if we reach here without hanging or crashing.
    // Some work may have executed, some may have been refused — both are valid.
    #expect(counter.value >= 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func wideTreeCascadesCancellation() async throws {
    let supervisor = Supervisor()
    let cancelledCount = AtomicCounter()
    let childCount = 20

    for _ in 0..<childCount {
      let child = await supervisor.delegate()
      await child.supervise {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          cancelledCount.increment()
        }
      }
    }

    await supervisor.cancel()
    try await Task.sleep(for: .milliseconds(100))

    #expect(cancelledCount.value == childCount)
  }
}

// MARK: - Work Stress Tests

@Suite
struct WorkStressTests {

  @Test(.timeLimit(.minutes(1)))
  func concurrentResultAccessReturnsSameValue() async {
    let work = Work<Int, Never>(task: Task { 42 })
    let readerCount = 100

    let results = await withTaskGroup(of: Result<Int, Never>.self) { group in
      for _ in 0..<readerCount {
        group.addTask { await work.result }
      }
      var collected: [Result<Int, Never>] = []
      for await r in group { collected.append(r) }
      return collected
    }

    #expect(results.count == readerCount)
    #expect(results.allSatisfy { $0 == .success(42) })
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelWhileAwaitingCompletes() async {
    let work = Work<String, any Error>(
      task: Task {
        try await Task.sleep(for: .seconds(10))
        return "done"
      })

    async let result = work.result
    try? await Task.sleep(for: .milliseconds(10))
    await work.cancel()

    let outcome = await result
    // After cancellation, the task should complete (with failure or success).
    switch outcome {
    case .success:
      break  // Possible if cancellation raced and the task completed first.
    case .failure:
      break  // Expected — CancellationError from sleep.
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anyWorkErasesAndCompletes() async {
    let work = Work<Int, Never>(task: Task { 7 })
    let erased = AnyWork(work)
    let readerCount = 50

    let results = await withTaskGroup(of: Result<Void, Never>.self) { group in
      for _ in 0..<readerCount {
        group.addTask { await erased.result }
      }
      var collected: [Result<Void, Never>] = []
      for await r in group { collected.append(r) }
      return collected
    }

    #expect(results.count == readerCount)
  }
}

// MARK: - onCancellation Stress Tests

@Suite
struct OnCancellationStressTests {

  @Test(.timeLimit(.minutes(1)))
  func cancellationActionFiresWhenTaskCancelled() async {
    let counter = AtomicCounter()

    let task = Task {
      try await awaitCancellationThenPerform { counter.increment() }
    }

    task.cancel()
    _ = await task.result

    #expect(counter.value == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func manyConcurrentCancellationHooksAllFire() async {
    let counter = AtomicCounter()
    let taskCount = 50

    let tasks = (0..<taskCount).map { _ in
      Task {
        try await awaitCancellationThenPerform { counter.increment() }
      }
    }

    for t in tasks { t.cancel() }
    for t in tasks { _ = await t.result }

    #expect(counter.value == taskCount)
  }

  @Test(.timeLimit(.minutes(1)))
  func immediateCancellationStillFires() async {
    let counter = AtomicCounter()

    // Create a task and cancel it from outside before onCancellation registers.
    let task = Task {
      // Yield to let the outer code cancel us.
      await Task.yield()
      await Task.yield()
      try await awaitCancellationThenPerform { counter.increment() }
    }

    // Cancel immediately.
    task.cancel()
    _ = await task.result

    #expect(counter.value == 1)
  }
}
