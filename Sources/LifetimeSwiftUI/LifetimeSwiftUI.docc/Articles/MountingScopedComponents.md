# Mounting scope-owned components

How ``ComponentMount`` and ``MountedComponentView`` cooperate to rebuild a SwiftUI subtree without leaking scoped work.

## Overview

A scope-owned component is a `Sendable` value (often a controller or
view-model) whose lifetime is tied to a ``Lifetime/Scope``. SwiftUI
expects views to rebuild when their inputs change, but a scope-owned
component does not change identity in the SwiftUI sense — it just
gets *replaced* when navigation happens or when a state machine
transitions to a new screen.

``ComponentMount`` is the bridge. It is a `@MainActor`, `@Observable`
slot that:

- Holds the currently-mounted component (or `nil`).
- Tracks a monotonically increasing `epoch` that `MountedComponentView`
  observes via SwiftUI's `id(_:)` modifier to rebuild the subtree.
- Provides ``ComponentMount/invalidate(shutdown:)`` so the *outgoing*
  component runs its async teardown before the new one mounts.

## The shape that's wrong

```swift
struct SessionScreen: View {
  @State private var session: SessionController?

  var body: some View {
    if let session {
      SessionContent(session: session)
    } else {
      ProgressView()
        .task { session = await SessionController.boot() }
    }
  }
}
```

Three things go wrong:

- **No shutdown story.** When the screen pops, `session` deinits, but
  the controller's `Scope` only tears down on the `deinit` fallback
  — fire-and-forget, no observer, racing with any later test.
- **No "swap" semantics.** Logging out and logging back in just
  replaces the `@State` value; SwiftUI keeps the same view identity
  and the old subtree never tears down cleanly.
- **No loading state survives a swap.** Going from session-A to
  session-B does not re-show `ProgressView`; the user sees stale
  A-state while B is still booting.

## The shape that's right

```swift
import LifetimeSwiftUI
import Lifetime

struct SessionScreen: View {
  @State private var mount = ComponentMount<SessionController>()

  var body: some View {
    MountedComponentView(mount: mount) { session in
      SessionContent(session: session)
    } placeholder: {
      ProgressView()
    }
    .task(id: userID) {
      // Tear down whatever was previously mounted, awaited.
      await mount.invalidate { previous in
        await previous.scope.cancel()
      }

      // Build the new component and mount it.
      let session = await SessionController.boot(userID: userID)
      mount.mount(session)
    }
  }
}
```

Three things this gets right:

- **Invalidation is awaited.** `mount.invalidate { ... }` runs the
  shutdown closure on the outgoing component and *does not return*
  until it has finished. Whatever boots next sees a clean teardown.
- **The placeholder is re-shown automatically.** `invalidate(_:)`
  detaches the component (bumping `epoch`); `MountedComponentView`
  observes the nil component and renders the placeholder until
  `mount(_:)` is called with the new one.
- **The subtree fully rebuilds.** `MountedComponentView` keys its
  content on `mount.epoch` via `id(_:)`. SwiftUI tears down the old
  subtree and rebuilds against the new component — no stale state
  bleeds through.

## Bridging to ``MountInvalidatableComponent``

If your component has a single canonical shutdown entry point, declare
it via the ``MountInvalidatableComponent`` protocol so callers don't
have to remember which method to call:

```swift
final class SessionController: MountInvalidatableComponent {
  let scope: Scope
  // ...

  func shutdown() async {
    await scope.cancel()
  }
}
```

The call site then collapses to the overload that knows about
`shutdown()`:

```swift
.task(id: userID) {
  await mount.invalidate()      // calls previous.shutdown() if a component was mounted
  let session = await SessionController.boot(userID: userID)
  mount.mount(session)
}
```

This is the recommended shape: it makes the mount/dismount loop
symmetrical and removes the trailing closure each invalidation site
would otherwise have to repeat.

## How epoch and `id(_:)` cooperate

``ComponentMount/epoch`` is a `UInt64` that increments on every
*detach*. Mounting a value does **not** bump it; detaching one — via
``ComponentMount/detach()``, ``ComponentMount/invalidate(shutdown:)``,
or the `MountInvalidatableComponent` overload — does. Three call
sequences worth understanding:

| Sequence | Epoch behavior |
|---|---|
| `mount(c1)` only | Epoch stays at 0; subtree renders against `c1`. |
| `mount(c1)`, `mount(c2)` | Epoch stays the same; SwiftUI sees the *same* keyed subtree with a new component value. State inside the content view may persist across the swap. |
| `mount(c1)`, `invalidate { … }`, `mount(c2)` | Epoch bumps on `invalidate`; the placeholder renders, then the new content is keyed on the new epoch and rebuilt from scratch. |

For most navigation cases you want the third sequence — that is what
`invalidate(...)` + `mount(...)` gives you. If you specifically want
to swap components *without* tearing down state, call `mount(_:)` a
second time; this is rare and load-bearing only when you know you're
preserving identity (e.g., live-editing a value-typed configuration
that the content view inspects directly).

## Testing

`ComponentMount` is `@MainActor` and `@Observable`. A test that
drives the mount looks like:

```swift
import Testing
import LifetimeSwiftUI

@Test @MainActor
func invalidationDetachesAndShutsDown() async throws {
  let mount = ComponentMount<FakeComponent>()
  let first = FakeComponent()
  mount.mount(first)
  #expect(mount.component != nil)

  await mount.invalidate { component in
    await component.shutdown()
  }

  #expect(mount.component == nil)
  #expect(first.didShutDown)
}
```

The `await mount.invalidate { … }` lands the assertion deterministically
— there is no race between the shutdown and the `expect`, because
`invalidate` does not return until the shutdown closure has.

## See also

- ``Lifetime/Scope`` — the lifetime story your component should
  delegate `shutdown()` to.
- The `Lifetime` article "Testing with Lifetime" covers the broader
  test patterns that pair with these mount tests.
