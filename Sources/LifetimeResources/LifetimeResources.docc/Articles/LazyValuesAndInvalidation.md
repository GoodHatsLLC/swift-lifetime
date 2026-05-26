# Lazy values and scope-shaped invalidation

When to reach for ``LazyValue``, ``LazyResource``, and ``ScopeInvalidator`` — and how they differ.

## Overview

`LifetimeResources` is a small module of three load-bearing types. New
adopters routinely confuse them because the names look similar but
the shapes are distinct. This article walks through what each one
does and when to pick it.

| Type | Holds | Coordination | Use when |
|---|---|---|---|
| ``LazyValue`` | a single deferred value | an `actor` | you need direct access to the deferred value behind an actor barrier |
| ``LazyResource`` | a wrapper over a ``LazyValue`` | a `Sendable` struct | you want the same lazy value but value-typed for ergonomic capture and ``ResourceObserver`` integration |
| ``ScopeInvalidator`` | a scheduled cancellation | an `actor` | you need to *cancel* a scope after a delay tied to a reason (background pressure, timeout, manual) |

## LazyValue — deferred construction with shared in-flight access

``LazyValue`` is the underlying primitive. The builder runs **at most
once per generation**: concurrent `get()` calls share the same
in-flight `Task`, and once it completes every caller sees the same
result.

```swift
import LifetimeResources

let userCache = LazyValue<UserProfile> {
  try await api.profile(id: "avery")
}

// Many call sites can race here; only one network call is made.
async let a = userCache.get()
async let b = userCache.get()
async let c = userCache.get()
let (x, y, z) = try await (a, b, c)
assert(x == y && y == z)
```

Three knobs:

- **Isolation.** ``ResourceIsolation`` controls where the builder
  runs: `.detached` (default), `.inherited` (caller's isolation), or
  `.mainActor`. Pick `.mainActor` when the build path touches UIKit /
  AppKit; pick `.inherited` when the builder must run on the
  caller's actor.
- **`retryOnError`.** Off by default: a failed build is *cached*, so
  later `get()` calls re-throw the same error without rebuilding.
  Turn this on when you want transient failures to be retried on the
  next `get()` — at the cost of "I touched this once and now it
  retries forever" surprise.
- **`reset()` / `cancel()`.** `reset()` invalidates the cached value
  and waits for any superseded build to finish before letting a new
  one begin. `cancel()` is terminal: it tears down the in-flight
  build and any state.

## LazyResource — the same value, value-typed

``LazyResource`` is a `Sendable` `struct` wrapping a ``LazyValue``.
Functionally it forwards every operation to the underlying actor;
the difference is **how it captures**:

```swift
struct ProfileScreen {
  let userCache: LazyResource<UserProfile>

  func load() async throws -> UserProfile {
    try await userCache.get()
  }
}

let resource = LazyResource {
  try await api.profile(id: "avery")
}

let screen = ProfileScreen(userCache: resource)
```

You can hold a `LazyResource` in a `Sendable` struct or pass it
across actor boundaries without paying an `actor` indirection at the
*holding* site. The actual coordination still happens inside the
wrapped `LazyValue`.

Pick `LazyResource` when:

- The holder is a `struct` or another `Sendable` type.
- You need ``ResourceObserver`` to render the value's loading /
  ready / failed state in SwiftUI.
- The factory method `LazyResource.mainActor { … }` matches your
  needs — it returns a `LazyResource` whose builder is `@MainActor`
  isolated, with no extra ceremony.

Pick `LazyValue` directly when you already own the actor surface and
want to skip the wrapping layer.

## ResourceObserver — SwiftUI bridge

When a SwiftUI view needs to display "loading / ready / failed" for a
``LazyResource``, ``ResourceObserver`` is the supported shape:

```swift
import LifetimeResources
import SwiftUI

@MainActor
struct ProfileView: View {
  @State private var observer: ResourceObserver<UserProfile>
  @State private var observationHandle: (any LifetimeHandle)?

  init(resource: LazyResource<UserProfile>) {
    _observer = State(initialValue: ResourceObserver(resource))
  }

  var body: some View {
    Group {
      switch observer.state {
      case .loading: ProgressView()
      case .ready(let profile): Text(profile.displayName)
      case .failed(let message): Text("Failed: \(message)").foregroundStyle(.red)
      }
    }
    .task {
      let handle = observer.start()
      observationHandle = handle
      await withTaskCancellationHandler {
        try? await Task.never()
      } onCancel: {
        Task { await handle.cancel() }
      }
    }
  }
}
```

`observer.start()` returns a ``Lifetime/LifetimeHandle`` — adopt it
into a scope when you have one to extend the observation's lifetime;
cancel it explicitly when the view goes away.

## ScopeInvalidator — scheduled cancellation

``ScopeInvalidator`` is the odd one out: it isn't about lazy
*construction*, it's about scheduled *cancellation*. Use it when an
outer scope should end after a delay tied to a specific reason.

```swift
import LifetimeResources

let invalidator = ScopeInvalidator()

// On entering background:
await invalidator.schedule(trigger: .background,
                           delay: .seconds(30)) {
  await session.endIfStillIdle()
}

// On returning to foreground, before the timer fires:
await invalidator.cancelAll()
```

Scheduling a new invalidation replaces any previous pending one —
useful when "background entry" and "foreground return" arrive in
quick succession. ``ScopeInvalidator/cancelAll()`` makes the
invalidator reusable: it cancels the internal work scope and starts
fresh.

Three triggers come built in: `.background`, `.timeout`, `.manual`.
They are purely informational labels right now — the trigger value is
not yet used to vary behavior — but they exist so observability code
can tell why an invalidation fired.

## When *not* to use these

- For a value that's *cheap* to construct on every access, skip
  `LazyValue` entirely. The coordination overhead is not worth it.
- For "one-shot construction with no caching", use a normal `async`
  initializer. `LazyValue`'s job is dedup + caching.
- For cancelling work *immediately*, use ``Lifetime/Scope/cancel()``
  directly. `ScopeInvalidator` is specifically for *delayed*
  cancellation tied to a reason.

## See also

- ``Lifetime/Resource`` — the lower-level resource handle that
  ``LazyResource`` is logically a deferred wrapper over.
- The `LifetimeSwiftUI` documentation covers further SwiftUI
  integration patterns built on `LifetimeResources`.
