import Testing

@testable import Boot

@Suite
struct SupervisorTests {

  @Test func SupervisorCancelsTasks() async throws {
    let supervisor = Supervisor()
    let counter = Counter()

    _ = await supervisor.supervise {
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        await counter.increment()
      } catch {
        await counter.markCancelled()
      }
    }
    await supervisor.cancel()

    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(await counter.value == 0)
    #expect(await counter.cancelled == true)
  }

  @Test func SupervisorCancelsNestedChild() async throws {
    let supervisor = Supervisor()
    let child = await supervisor.delegate()
    let counter = Counter()

    _ = await child.supervise {
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
        await counter.increment()
      } catch {
        await counter.markCancelled()
      }
    }
    await supervisor.cancel()

    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(await counter.value == 0)
    #expect(await counter.cancelled == true)
  }

  @Test func SupervisorRefusesInactiveWorkAfterCancel() async {
    let supervisor = Supervisor()
    let counter = Counter()
    await supervisor.cancel()
    await supervisor.supervise {
      await counter.increment()
    }
    for _ in 0..<100 {
      // We're attempting to prove a negative,
      // So we wait generously.
      await Task.yield()
    }
    let v = await counter.value
    #expect(v == 0)
  }

  @Test func SupervisorCancelsAlreadyActiveWorkAfterCancel() async {
    let supervisor = Supervisor()
    let counter = Counter()
    await supervisor.cancel()
    let cont = Continuation<Void>()
    let task = Task {
      try await awaitCancellationThenPerform {
        try! cont.yield()
        await counter.increment()
      }
    }
    let work = Work(task: task)
    await supervisor.add(work)
    await cont()
    let v = await counter.value
    #expect(v == 1)
  }

  @Test func runReturnsHandleAndExposesSupervisorState() async {
    let supervisor = Supervisor()
    let completion = Continuation<Void>()

    #expect(await supervisor.trackedCount == 0)
    #expect(await supervisor.isCancelled == false)

    let handle = await supervisor.run {
      await completion()
    }

    #expect(await supervisor.trackedCount == 1)

    try! completion.yield()
    _ = await handle.result

    await supervisor.cancel()
    #expect(await supervisor.isCancelled == true)
  }

  private actor Counter {
    private(set) var value: Int = 0
    private(set) var cancelled: Bool = false

    func increment() {
      value += 1
    }

    func markCancelled() {
      cancelled = true
    }
  }
}
