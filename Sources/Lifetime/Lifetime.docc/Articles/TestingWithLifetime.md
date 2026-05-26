# Testing with Lifetime

How to write tests that prove your code owns its async work — drained, deterministic, and free of `Task.sleep`.

## Overview

The pitch for ``Lifetime`` is testability: every owner cancels exactly
once, ``Scope/cancel()`` does not return until teardown has finished,
and every timing dependency goes through `LifetimePolicies.AsyncSleeper`
so tests can drive the clock. This article walks through the three
patterns that come up over and over.

## Pattern 1 — await the drain, then assert

The most common testability mistake is asserting *after the cancel
call* but *not awaiting it*. ``Scope/cancel()`` is async for a reason:
it blocks the caller until every registered destroy closure has
finished. A test that calls `cancel()` synchronously and immediately
asserts on a fake's "is shut down" flag is racing with that drain.

The shape that works:

```swift
import Testing
import Lifetime

@Test
func cancelDrainsRegisteredResources() async throws {
  let scope = Scope.root()
  let api = FakeAPIClient()

  _ = try await scope.start("APIClient") {
    api
  } destroy: { client in
    await client.shutdown()
  }

  #expect(api.isRunning == true)

  await scope.cancel()

  // Every `destroy` closure registered on `scope` has finished by
  // the time this line runs.
  #expect(api.isRunning == false)
}
```

The same shape works for ``Resource``, ``Child``, and any
``LifetimeHandle``: `await handle.cancel()`, then assert.

### Use `withRoot` to avoid forgetting

For tests that don't need the scope after the body, prefer
``Scope/withRoot(cancellationPolicy:_:)``. It cancels the scope on
the way out — even if the test throws — so you cannot accidentally
leak work between cases:

```swift
@Test
func checkoutPaysOnceAndReleases() async throws {
  let api = FakeAPIClient()

  try await Scope.withRoot { scope in
    _ = try await scope.start("APIClient") { api } destroy: { c in
      await c.shutdown()
    }
    try await runCheckout(api: api)
  }

  #expect(api.charges.count == 1)
  #expect(api.isRunning == false)
}
```

## Pattern 2 — inject a `ManualSleeper`

Time-sensitive code should never call `Task.sleep` directly. Both
``LifetimePolicies/DelayPolicy`` and the other named policies in
`LifetimePolicies` accept a `LifetimePolicies.AsyncSleeper`
parameter so production code uses
`LifetimePolicies.TaskSleeper()` and tests drive the clock
deterministically.

Write your code so the sleeper is injectable:

```swift
import LifetimePolicies

struct PingLoop {
  let api: APIClient
  let delay: DelayPolicy

  init(api: APIClient, sleeper: any AsyncSleeper = TaskSleeper()) {
    self.api = api
    self.delay = DelayPolicy(.seconds(15), sleeper: sleeper)
  }

  func run() async throws {
    while !Task.isCancelled {
      try await delay.wait()
      await api.ping()
    }
  }
}
```

The test drives the loop one tick at a time:

```swift
import Testing

final class ManualSleeper: AsyncSleeper, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [CheckedContinuation<Void, Error>] = []

  func sleep(for duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { pending.append(continuation) }
    }
  }

  func advance() {
    let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    next?.resume()
  }
}

@Test
func pingLoopFiresOncePerTick() async throws {
  let api = FakeAPIClient()
  let sleeper = ManualSleeper()
  let loop = PingLoop(api: api, sleeper: sleeper)

  try await Scope.withRoot { scope in
    _ = try await scope.start("PingLoop", launchPolicy: .detached) {
      try await loop.run()
    }

    #expect(api.pings.count == 0)

    sleeper.advance()
    try await Task.sleep(for: .milliseconds(10))   // yield the loop
    #expect(api.pings.count == 1)

    sleeper.advance()
    try await Task.sleep(for: .milliseconds(10))
    #expect(api.pings.count == 2)
  }
}
```

The `Task.sleep` inside the test exists only to let the loop's
`await delay.wait()` resume after `sleeper.advance()`. It is not
controlling timing — it is yielding cooperatively. Production code
never has this shape.

## Pattern 3 — assert on `ScopeSnapshot`

For tests that care about *what is registered on a scope right now*,
``Scope/snapshot()`` returns a structural view of the entire subtree
in registration order. It is the supported way to make ownership
assertions; do not parse `description`.

```swift
@Test
func sessionRegistersExpectedChildren() async throws {
  try await Scope.withRoot { scope in
    let session = try await scope.withChild(
      name: "Session",
      build: { child in
        let token = try await child.start("Token") { "tok-1" }
        let socket = try await child.start("Socket") { FakeSocket() } destroy: { s in
          await s.close()
        }
        return SessionExports(token: token, socket: socket)
      }
    ) { session in
      session
    }

    let snapshot = scope.snapshot()
    let names = snapshot.children.first?.snapshot?.cancellations.map(\.name) ?? []
    #expect(names.contains("Token"))
    #expect(names.contains("Socket"))

    _ = session
  }
}
```

Snapshots preserve registration order — both for children and for
cancellation actions — so they double as the supported assertion
surface for teardown-ordering tests. A scope that has begun
cancellation surfaces phase only, since the underlying entries log
has already been released; take the snapshot *before* you cancel.

## What to avoid

- **`Task.sleep` in tests.** If the production code under test does
  not accept an `AsyncSleeper`, change it to. The package's whole
  testability story assumes injection.
- **`try? await scope.cancel()`.** `cancel()` is non-throwing; the
  `try?` is a red flag that the caller is treating teardown as
  failable. If you meant "best effort", use `await scope.cancel()`
  unconditionally and rely on cancellation being idempotent.
- **Relying on `deinit` to drain.** The `deinit` fallback runs on a
  detached task. Tests that drop a strong reference and immediately
  assert are racing the detached teardown. Always
  `await handle.cancel()` from the test.
- **`@MainActor` tests that forget to yield.** When `LaunchPolicy`
  defaults to `.inline` on a `@MainActor` test, in-flight async work
  that suspends on the main actor can deadlock with the test body.
  Either mark the test `async` and let the test runtime hop actors,
  or use `launchPolicy: .detached` for work that should not inherit
  the test's main-actor isolation.

## See also

- <doc:MigratingOffATaskGraveyard> — refactoring an existing class so
  it gains the testability described here.
- <doc:Glossary> — the canonical vocabulary used in this article.
