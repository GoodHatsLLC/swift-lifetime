// © GoodHatsLLC

import Lifetime
import LifetimePrimitives
import Testing

@testable import LifetimeIntent

struct IntentReducerExecutorTests {
  @Test
  func runsAllExecutablesSelectedFromOneReducedEvent() async {
    let scope = Scope.root()
    let events = EventLog()
    let executor = makeAppendExecutor(scope: scope, events: events)

    executor.send(event: .append([1, 2, 3]))
    await executor.waitUntilIdle()

    #expect(
      await events.values == [
        "run-1", "destroy-1",
        "run-2", "destroy-2",
        "run-3", "destroy-3",
      ])
    await executor.cancel()
  }

  @Test
  func coalescesPendingIntentsWhileActiveExecutableRuns() async {
    let scope = Scope.root()
    let events = EventLog()
    let firstStarted = Continuation<Void>()
    let releaseFirst = Continuation<Void>()

    let executor = IntentReducerExecutor<LatestEvent, LatestState>(
      initialState: .init(),
      reduce: { state, event in
        switch event {
        case .set(let value):
          state.pending = value
          return .keepRunning
        }
      },
      nextExecutable: { state in
        guard let value = state.pending else { return nil }
        state.pending = nil
        return try! scope.resourceFactory(name: "latest-\(value)") {
          await events.append("run-\(value)")
          if value == 1 {
            try? firstStarted.yield()
            await releaseFirst()
          }
          await events.append("finish-\(value)")
        } destroy: { _ in
          await events.append("destroy-\(value)")
        }
      },
    )

    executor.send(event: .set(1))
    await firstStarted()
    executor.send(event: .set(2))
    executor.send(event: .set(3))
    try? releaseFirst.yield()

    await executor.waitUntilIdle()

    #expect(
      await events.values == [
        "run-1", "finish-1", "destroy-1",
        "run-3", "finish-3", "destroy-3",
      ])
    await executor.cancel()
  }

  @Test
  func reducerCanCancelActiveExecutableBeforeRunningLatestPendingExecutable() async {
    let scope = Scope.root()
    let events = EventLog()
    let firstStarted = Continuation<Void>()
    let firstCleaned = Continuation<Void>()
    let cancellation = CancellationGate()

    let executor = IntentReducerExecutor<LatestEvent, LatestState>(
      initialState: .init(),
      reduce: { state, event in
        switch event {
        case .set(let value):
          state.pending = value
          return .cancelActive
        }
      },
      nextExecutable: { state in
        guard let value = state.pending else { return nil }
        state.pending = nil
        return try! scope.resourceFactory(name: "active-cancel-\(value)") {
          await events.append("run-\(value)")
          if value == 1 {
            try? firstStarted.yield()
            await cancellation.wait()
            await events.append("cleanup-\(value)")
            try? firstCleaned.yield()
          } else {
            await events.append("finish-\(value)")
          }
        } destroy: { _ in
          await events.append("destroy-\(value)")
        }
      },
    )

    executor.send(event: .set(1))
    await firstStarted()
    executor.send(event: .set(2))
    executor.send(event: .set(3))

    await firstCleaned()
    await executor.waitUntilIdle()

    #expect(
      await events.values == [
        "run-1", "cleanup-1", "destroy-1",
        "run-3", "finish-3", "destroy-3",
      ])
    await executor.cancel()
  }

  @Test
  func cancelClosesIntakeAndDrainsActiveExecutableCancellation() async {
    let scope = Scope.root()
    let events = EventLog()
    let activeStarted = Continuation<Void>()
    let activeCleaned = Continuation<Void>()
    let cancellation = CancellationGate()

    let executor = IntentReducerExecutor<AppendEvent, AppendState>(
      initialState: .init(),
      reduce: appendReducer,
      nextExecutable: { state in
        guard !state.pending.isEmpty else { return nil }
        let value = state.pending.removeFirst()
        return try! scope.resourceFactory(name: "cancellable-\(value)") {
          await events.append("run-\(value)")
          if value == 1 {
            try? activeStarted.yield()
            await cancellation.wait()
            await events.append("cleanup-\(value)")
            try? activeCleaned.yield()
          }
        } destroy: { _ in
          await events.append("destroy-\(value)")
        }
      },
    )

    executor.send(event: .append([1]))
    await activeStarted()
    executor.send(event: .append([2]))

    async let cancelled: Void = executor.cancel()
    await activeCleaned()
    await cancelled

    #expect(await events.values == ["run-1", "cleanup-1", "destroy-1"])
    #expect(executor.send(event: .append([3])) == false)
  }

  @Test
  func finishClosesIntakeAndDrainsPendingExecutables() async {
    let scope = Scope.root()
    let events = EventLog()
    let firstStarted = Continuation<Void>()
    let releaseFirst = Continuation<Void>()

    let executor = IntentReducerExecutor<AppendEvent, AppendState>(
      initialState: .init(),
      reduce: appendReducer,
      nextExecutable: { state in
        guard !state.pending.isEmpty else { return nil }
        let value = state.pending.removeFirst()
        return try! scope.resourceFactory(name: "finish-\(value)") {
          await events.append("run-\(value)")
          if value == 1 {
            try? firstStarted.yield()
            await releaseFirst()
          }
          await events.append("finish-\(value)")
        } destroy: { _ in
          await events.append("destroy-\(value)")
        }
      },
    )

    executor.send(event: .append([1, 2]))
    await firstStarted()

    async let finished: Void = executor.finish()
    try? releaseFirst.yield()
    await finished

    #expect(executor.send(event: .append([3])) == false)
    #expect(
      await events.values == [
        "run-1", "finish-1", "destroy-1",
        "run-2", "finish-2", "destroy-2",
      ])
  }

  @Test
  func reportsExecutableErrorsThroughSideChannelAndContinuesDraining() async {
    let scope = Scope.root()
    let events = EventLog()
    let errors = ErrorLog()

    let executor = IntentReducerExecutor<AppendEvent, AppendState>(
      initialState: .init(),
      reduce: appendReducer,
      nextExecutable: { state in
        guard !state.pending.isEmpty else { return nil }
        let value = state.pending.removeFirst()
        if value == 1 {
          return try! scope.resourceFactory(name: "failing-\(value)") {
            throw TestFailure()
          }
        }
        return try! scope.resourceFactory(name: "succeeding-\(value)") {
          await events.append("run-\(value)")
        } destroy: { _ in
          await events.append("destroy-\(value)")
        }
      },
      onError: { error in
        await errors.append(String(describing: error))
      },
    )

    executor.send(event: .append([1, 2]))
    await executor.waitUntilIdle()

    #expect(await errors.values == ["TestFailure()"])
    #expect(await events.values == ["run-2", "destroy-2"])
    await executor.cancel()
  }
}

private enum AppendEvent: Sendable {
  case append([Int])
}

private struct AppendState: Sendable {
  var pending: [Int] = []
}

private let appendReducer: IntentReducerExecutor<AppendEvent, AppendState>.Reducer =
  { state, event in
    switch event {
    case .append(let values):
      state.pending.append(contentsOf: values)
      return .keepRunning
    }
  }

private enum LatestEvent: Sendable {
  case set(Int)
}

private struct LatestState: Sendable {
  var pending: Int?
}

private struct TestFailure: Error, Sendable {}

private func makeAppendExecutor(
  scope: Scope,
  events: EventLog,
) -> IntentReducerExecutor<AppendEvent, AppendState> {
  IntentReducerExecutor(
    initialState: .init(),
    reduce: appendReducer,
    nextExecutable: { state in
      guard !state.pending.isEmpty else { return nil }
      let value = state.pending.removeFirst()
      return try! scope.resourceFactory(name: "append-\(value)") {
        await events.append("run-\(value)")
      } destroy: { _ in
        await events.append("destroy-\(value)")
      }
    },
  )
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

private actor ErrorLog {
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
