# Lifetime

[![ci](https://github.com/GoodHatsLLC/swift-lifetime/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/GoodHatsLLC/swift-lifetime/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FGoodHatsLLC%2Fswift-lifetime%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/GoodHatsLLC/swift-lifetime)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FGoodHatsLLC%2Fswift-lifetime%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/GoodHatsLLC/swift-lifetime)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

**Make ownership and boundaries explicit, so they can be tested and torn down.**

📚 [API documentation on Swift Package Index](https://swiftpackageindex.com/GoodHatsLLC/swift-lifetime/documentation)

> **Requires Swift 6.2 + iOS 18 / macOS 15 / tvOS 18 / watchOS 11.** The
> floor is driven by `Synchronization.Mutex`; projects still targeting
> iOS 17 or earlier cannot adopt this package. See
> [Requirements](#requirements) for the full list.

Swift's structured concurrency makes task ownership implicit. `swift-lifetime`
gives you explicit names for the rest: the runtime values your tasks own, the
synchronous callback boundaries they cross, and the scheduler decisions they
depend on.

Open a resource, use it, close it deterministically — even on errors:

```swift
let user = try await Scope.withRoot { scope in
  try await scope.withResource(
    "APIClient",
    create: { APIClient() },
    destroy: { client in await client.shutdown() }
  ) { client in
    try await client.fetchUser(id: "avery")
  }
}
// `client.shutdown()` has fully awaited by the time this line runs,
// whether `fetchUser` returned or threw.
```

Composition is the same shape repeated: see [Structured Helpers](#structured-helpers) for resources nested inside child scopes.

## Requirements

- Swift 6.2+ in Swift 6 language mode
- macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+

## Why not `TaskGroup` + `defer`?

Structured concurrency already covers most cases. Reach for `Lifetime` when
`TaskGroup` and `defer` start running out:

- **Lifetimes must outlive a single function.** `TaskGroup` is a great
  resource owner *for the duration of the function it's declared in* — when
  that function returns, the group is gone. A long-lived `APIClient`, a
  Combine subscription that needs to drain on logout, a database pool: those
  outlive any single call. `Scope` is a first-class owner you can hand
  around, adopt into another scope, and cancel from a different module.
- **Teardown must be async and awaited.** `defer` blocks run synchronously
  on the way out — fine for closing a file handle, useless for awaiting
  `client.shutdown()`. `Scope.cancel()` is an `async` operation that
  cascades through children and waits for in-flight `start` / `withResource`
  teardown before returning.
- **Synchronous platform callbacks need a drainable owner.** A UIKit
  delegate method, a Combine subscriber, a C callback: each is a sync
  entry point that needs to spawn async work. A raw `Task { … }` from such
  a callback has no owner, no shutdown sequence, no way for a test to
  await it. `LifetimeBoundaries` wraps that work in a handle you can
  drain or cancel deterministically.
- **Resources need names you can debug and tests can assert on.** Scopes,
  resources, and children carry optional names that surface in
  `description` output and in `ScopeError` context. Nothing in stdlib
  gives you that.

If a `TaskGroup` plus a couple of `defer` blocks covers your case, use
them. This package earns its keep at the boundaries where they don't.

## Modules

The package is a small stack. Most users only need `Lifetime`. Add the higher
layers when their tagline matches the problem you're holding.

| Module | Tagline |
|---|---|
| `Lifetime` | Resource trees for Swift Concurrency. |
| `LifetimePrimitives` | Async-aware coordination primitives. |
| `LifetimeBoundaries` | Own async work at sync and callback boundaries. |
| `LifetimePolicies` | Named, injectable scheduler boundaries. |
| `LifetimeIntent` | Reducer-driven executor for repeatable intents. |
| `LifetimeResources` | Lazy resources and scope-shaped invalidation. |
| `LifetimeSwiftUI` | Mount scoped components into SwiftUI. |

Each module's types are `Sendable`. Each carries the same contract: explicit
ownership, idempotent cancellation, and deterministic teardown via
`await cancel()`.

`await cancel()` is the contract. `deinit` is a **fallback only** — when
the last reference is dropped without an explicit cancel, teardown fires
on a detached task as a backstop against leaks. The trigger site does not
block and completion is not observable. Do not rely on `deinit` for
ordering, sequencing, or any teardown a test or shutdown sequence needs
to wait on.

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/GoodHatsLLC/swift-lifetime.git", from: "1.0.0")
]
```

```swift
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "Lifetime", package: "swift-lifetime")
    ]
  )
]
```

Add other modules as you need them, e.g. `"LifetimeBoundaries"` for sync→async
callback owners, or `"LifetimePolicies"` for injectable sleepers/retries.

## Scope Model

`Lifetime` gives you a small, composable runtime surface:

| Type | Role |
|------|------|
| `Scope` | A lifecycle boundary that owns children and teardown actions. |
| `Resource<Value>` | A caller-owned runtime value with async teardown. |
| `ResourceFactory<Input, Value>` | Builds transient `Resource` handles on demand. |
| `Child<Exports>` | A child `Scope` plus typed exported values. |
| `ChildFactory<Input, Exports>` | Builds transient child lifetimes on demand. |
| `Continuation<Value>` | A single-yield async coordination primitive. |

Every type is `Sendable`. Cancellation is idempotent. Dropping the last strong
reference triggers cleanup from `deinit` as a safety net.
Factories do not keep their originating `Scope` alive, and `make(...)` throws
`ScopeError.cancelled` once that scope has ended.

## Core Concepts

### Scoped Ownership

```swift
let root = Scope.root()
let sessionID = try await root.start("Session") {
  UUID().uuidString
}
await root.cancel()
```

### Structured Helpers

```swift
let result = try await Scope.withRoot { root in
  try await root.withResource("Client", create: { APIClient() }, destroy: { c in
    await c.shutdown()
  }) { client in
    try await root.withChild(name: "Session", build: { child in
      SessionExports(token: try await child.start("Token") { "tok-123" })
    }) { session in
      try await client.fetch(token: session.exports.token)
    }
  }
}
```

Also available: `withChildScope` and `withLifetime`.

### Caller-Owned Factories

Use a factory when the same shape of child or resource is produced many
times and the caller — not a structured `with…` block — decides when each
instance ends. Each call to `make(...)` produces a fresh, independently
cancellable handle.

```swift
let makeSession = try root.childFactory(name: "Session") { (userID: String, child: Scope) in
  let token = try await child.start("Token") { "tok-\(userID)" }
  return SessionExports(userID: userID, token: token)
}

func handle(userID: String) async throws {
  let session = try await makeSession.make(userID)
  do {
    try await doWork(with: session.exports)
    await session.cancel()
  } catch {
    await session.cancel()
    throw error
  }
}
```

Prefer this awaited-`cancel()` shape over fire-and-forget tear-down. A
factory-produced handle is also adoptable into another scope via
``Scope/adopt(_:)`` or ``Scope/supervise(work:)`` — handing it off to a
parent that already has a teardown sequence is usually a better answer
than spinning up an unstructured `Task` just to cancel it.

### Teardown Policy

`Scope.root()` defaults to `.serialLIFO`. Children and cancellation actions
(resources, adopted handles, `onCancel` work) share a single registration
log inside the scope; the policy controls how that log is walked at
cancellation time.

- `.serialLIFO`: walks the unified log in strict reverse registration
  order, one entry at a time. A child registered after a resource is
  torn down before that resource, and vice versa. Default.
- `.parallelUnordered`: cancels all children concurrently, then runs all
  cancellation actions concurrently. The two phases stay sequenced so
  destroy hooks outlive child teardown. Use when teardown throughput
  matters more than strict ordering.

### Launch Policy

Builder work runs inline by default. Use `.detached` when creation should not
inherit the caller's task context.

## Cancellation Guarantees

- `Scope.cancel()`, `Resource.cancel()`, and `Child.cancel()` are idempotent.
- Cancelling a scope cascades through all children and registered teardown work.
- `Scope.cancel()` waits for in-flight `start` and `withResource` teardown before returning.
- Creating from a cancelled scope throws `ScopeError.cancelled`.
- Dropping the last reference to a `Scope`, `Resource`, or `Child` fires
  `deinit` as a **fallback only**: teardown runs on a detached task, the
  trigger site does not block, and completion is not observable. Always
  prefer `await cancel()`; treat `deinit` purely as a leak backstop.

## Benchmarks

The root package includes `LifetimeBenchmarks`:

```bash
swift run -c release LifetimeBenchmarks
```

Current baseline targets (release build, Apple Silicon M-series Mac;
release mode is required — debug numbers will be roughly 5–10× higher
and are not meaningful for regression checks):

| Benchmark | Baseline | Observed (median) |
|-----------|---------:|------------------:|
| `start.inline.createCancelScope` | 2,800 ns/op | ~2,400 ns/op |
| `withResource.inline.createCancelScope` | 4,200 ns/op | ~3,600 ns/op |
| `childFactory.makeCancelScope` | 3,900 ns/op | ~3,400 ns/op |
| `withChild.input.createCancelScope` | 3,700 ns/op | ~3,000 ns/op |
| `scope.cancel.adopt100Resources` | 68,500 ns/op | ~59,400 ns/op |

Four of the five benchmarks carry roughly 15% headroom above their
observed medians. `withChild` is set at 20% headroom because its
observed tail extends further (35% above median vs ≤22% for the
others); at these sub-microsecond ops, absolute jitter becomes a
larger relative share. Combined with the ±20% detection band, the
"slower" trigger sits at median × 1.38–1.44 — tight enough to flag
real drift without false positives on ordinary machine noise. The
`adopt100Resources` benchmark runs 2000 iterations rather than the
500 used elsewhere; the cancel walk it exercises is sensitive to
cooperative-pool latency spikes that only average out across enough
samples. Numbers will vary across hardware; treat the relative
magnitudes as the contract, not the absolutes.

### Complexity and memory

- **Cancel walk is O(n)** in the number of live + tombstoned entries
  registered on the scope. `.serialLIFO` walks the array once in reverse;
  `.parallelUnordered` partitions it into children and actions in a
  single pass and then dispatches each set concurrently.
- **Tombstones are not compacted during a scope's life.** Each
  cancelled child, completed resource, or detached supervised handle
  leaves a tombstone in the unified registration log; the array is only
  freed when the scope itself transitions to `.cancelled`. Long-lived
  scopes with high registration churn (e.g. one per HTTP request) hold
  memory proportional to *total ever-registered* entries, not currently-
  live ones. For workloads with that shape, prefer a fresh child scope
  per logical unit so the parent can reclaim the whole log at once.
- **Cancel is bounded by the slowest child or action.** Under
  `.serialLIFO` every step is awaited serially, so a single slow
  `destroy` closure dictates total teardown time. Under
  `.parallelUnordered` the phase times reduce to the slowest child
  followed by the slowest action.
- **Per-scope overhead** is a `Mutex`-protected storage struct plus the
  registration array. Sendable closures captured by `start`,
  `withResource`, and `onCancel` are the dominant retained payload —
  size your captures accordingly when registering thousands of entries
  on one scope.

## Tests

The Swift Testing suite covers:

- structured helper lifecycle guarantees
- cancellation policy behavior and teardown ordering
- idempotent cancellation under concurrent calls
- deinit-triggered cleanup for dropped handles
- factory-after-cancel failure behavior
- detached launch semantics and shutdown races
- `Continuation` replay and double-yield errors
- per-module suites for `LifetimePrimitives`, `LifetimeBoundaries`,
  `LifetimePolicies`, and `LifetimeIntent`

## License

MIT
