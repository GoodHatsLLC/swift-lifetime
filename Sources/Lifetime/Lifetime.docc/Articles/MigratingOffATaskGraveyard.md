# Migrating off a Task graveyard

A worked example: refactor a class that spawns unstructured `Task { … }` work into one that owns its lifetimes through ``Scope``.

## Overview

The single most common Swift Concurrency anti-pattern is the *Task graveyard*: a class that kicks off `Task { … }` from various entry points, holds no handles, and has no shutdown sequence. The compiler is happy. The runtime mostly works. Then a test flakes, or two callbacks race during teardown, or a logout flow leaves an in-flight request scribbling to a deinit'd object.

This article walks through a small refactor that takes one of these classes and gives it the three things it was missing: an explicit owner, a deterministic teardown sequence, and tests that can assert on either.

## The starting point

Here is a `SessionController` written the obvious way. It boots an analytics flusher, opens a websocket subscription, kicks off a periodic ping, and runs a one-shot bootstrap fetch. None of these are owned — each is fired off as an unstructured `Task`.

```swift
final class SessionController {
  private let api: APIClient
  private let analytics: AnalyticsClient

  init(api: APIClient, analytics: AnalyticsClient) {
    self.api = api
    self.analytics = analytics
  }

  func start(userID: String) {
    Task { await self.analytics.startFlushLoop() }
    Task { await self.api.subscribe(to: userID) }
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        await self.api.ping()
      }
    }
    Task {
      let profile = try await self.api.bootstrap(userID: userID)
      await MainActor.run { /* update UI */ }
    }
  }

  func logout() async {
    await api.signOut()
    // No way to wait for the four tasks above to settle.
  }
}
```

A quick audit of what's wrong:

- **There is no way to await `logout()` cleanly.** The analytics flusher, the subscription, and the ping loop are all still running after `signOut()` returns. The bootstrap task might still be in-flight.
- **Tests cannot assert teardown.** A test that calls `start` and then `logout` has no signal for when the spawned work has actually stopped — it has to insert sleeps and hope.
- **Errors get swallowed silently.** Each `Task { … }` either throws and disappears or returns and disappears. Nothing surfaces.
- **`deinit` is not a shutdown.** When the controller is released its tasks keep running with stale `self` references, mutating actors that no longer have meaning.

## Step 1: give the controller a scope

Hand the controller a ``Scope`` and use ``Scope/start(_:launchPolicy:create:destroy:)`` to make each piece of work explicitly owned. Each ``Scope/start(_:launchPolicy:create:destroy:)`` call returns the wrapped value, registers a teardown closure, and ties the lifetime to the scope.

```swift
import Lifetime

final class SessionController {
  private let api: APIClient
  private let analytics: AnalyticsClient
  private let scope: Scope

  init(api: APIClient, analytics: AnalyticsClient) {
    self.api = api
    self.analytics = analytics
    self.scope = Scope.root()
  }

  func start(userID: String) async throws {
    _ = try await scope.start("AnalyticsFlush") {
      AnalyticsFlushHandle(client: analytics)
    } destroy: { handle in
      await handle.stop()
    }

    _ = try await scope.start("Subscription") {
      try await api.subscribe(to: userID)
    } destroy: { subscription in
      await subscription.cancel()
    }

    let profile = try await scope.start("Bootstrap") {
      try await api.bootstrap(userID: userID)
    }
    await MainActor.run { /* update UI with profile */ }
  }

  func logout() async {
    await api.signOut()
    await scope.cancel()
  }
}
```

Three things changed:

- Each piece of long-lived work is created through ``Scope/start(_:launchPolicy:create:destroy:)`` with a paired `destroy` closure that knows how to shut it down. Errors during creation propagate to the caller instead of disappearing.
- `logout()` ends with `await scope.cancel()`, which cascades teardown through every registered piece of work and does not return until each `destroy` closure has finished. See <doc:Lifetime#Reference-vs-value-types> for why ``Scope/cancel()`` blocks while ``deinit`` does not.
- Tests can now `await controller.logout()` and trust that nothing is still running when the call returns.

## Step 2: nest a child scope for the ping loop

The ping loop was the trickiest piece in the original: a recurring `Task.sleep` loop that needed cooperative cancellation. ``Scope`` plus the ``LifetimePolicies`` module gives this a name and an injectable sleeper.

```swift
import Lifetime
import LifetimePolicies

extension SessionController {
  func start(userID: String, sleeper: any AsyncSleeper = TaskSleeper()) async throws {
    // ... earlier work ...

    let pingScope = try await scope.delegate()
    _ = try await pingScope.start("PingLoop") {
      try await pingScope.start("PingLoopWorker", launchPolicy: .inline) {
        let delay = DelayPolicy(.seconds(15), sleeper: sleeper)
        while !Task.isCancelled {
          try await delay.wait()
          await api.ping()
        }
      }
    }
  }
}
```

The ping loop now lives in a child scope (`pingScope`) returned by ``Scope/delegate()``. Cancelling the parent cancels the child, which cancels the loop. In tests, swap `sleeper` for a manual one to drive the loop deterministically without real sleeps.

## Step 3: write the test that proves it works

```swift
import Testing
@testable import MyApp

@Test
func logoutDrainsAllSessionWork() async throws {
  let api = FakeAPIClient()
  let analytics = FakeAnalyticsClient()
  let controller = SessionController(api: api, analytics: analytics)

  try await controller.start(userID: "avery")
  #expect(analytics.flushLoopRunning)
  #expect(api.subscriptionActive)

  await controller.logout()
  #expect(analytics.flushLoopRunning == false)
  #expect(api.subscriptionActive == false)
}
```

The graveyard version of this test was impossible — there was no signal for "drain finished." The scope version is trivial.

## What you gained

- **Named, debuggable work.** Each piece of background work has a string name attached. ``Scope/snapshot()`` returns a structural view of the tree for assertions and logs.
- **Deterministic teardown.** ``Scope/cancel()`` cascades through children and registered cancellation actions and does not return until every `destroy` closure has finished. See ``ScopeCancellationPolicy`` for ordering details.
- **Cancellation-aware sleeps.** ``LifetimePolicies/DelayPolicy`` and ``LifetimePolicies/PollingPolicy`` make timing dependencies testable by accepting an injected sleeper.
- **No orphan tasks.** Dropping a strong reference to the controller still triggers the `deinit` fallback on the scope, so even forgotten controllers stop their own work eventually — though, as ``Scope`` documents, that fallback is not awaitable and should not be relied upon for ordering.

## When you do *not* need this

If the work is genuinely scoped to a single function, `withTaskGroup` and `defer` are simpler and ship in stdlib. Reach for ``Scope`` when ownership has to outlive a function, teardown has to be async, or a sync platform callback needs an async-aware owner.
