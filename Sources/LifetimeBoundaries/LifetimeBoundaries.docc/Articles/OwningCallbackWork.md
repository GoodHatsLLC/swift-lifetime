# Owning callback work

Give synchronous platform callbacks an async owner you can drain, replace, and cancel deterministically.

## Overview

UIKit delegates, Combine subscribers, KVO observers, C callbacks, and
ad-hoc completion handlers are all **synchronous entry points** that
sometimes need to enter async territory. Doing that with a raw
`Task { … }` loses ownership: there's nothing to cancel, nothing to
drain at shutdown, no way for a test to wait for in-flight work.

`LifetimeBoundaries` gives you three shapes that own that work
explicitly. Pick the one that matches the callback's semantics:

| Use case | Type |
|----------|------|
| One-shot work that should live until the surrounding scope ends | ``ScopeOwnedTask`` / ``ScopeOwnedThrowingTask`` |
| Each new callback replaces the previous in-flight work | ``ReplacingTaskSlot`` |
| Async stream / AsyncSequence consumer that needs a teardown hook | ``installTerminationHandler(for:_:)`` |

## A worked example: search-as-you-type

A `UITextField` calls its delegate every keystroke. We want each
keystroke to start an async search; if the user types faster than the
network can respond, the *new* search should pre-empt the old one.

### The naive shape

```swift
final class SearchController: NSObject, UITextFieldDelegate {
  let api: SearchAPI

  init(api: SearchAPI) { self.api = api }

  func textField(_ field: UITextField,
                 shouldChangeCharactersIn range: NSRange,
                 replacementString string: String) -> Bool {
    let query = (field.text ?? "") + string
    Task { [api] in
      let results = try? await api.search(query)
      // results displayed somewhere
    }
    return true
  }
}
```

What's wrong:

- **No ownership.** Every keystroke leaks a `Task` whose result may
  arrive after a newer one and clobber the UI.
- **No shutdown.** When the screen pops, in-flight searches keep
  running against an actor with no listeners.
- **Untestable.** The test cannot await "all spawned tasks settled".

### Step 1 — replaceable work via `ReplacingTaskSlot`

The right shape here is "each new search replaces the previous one,
which gets cancelled and drained before the next starts." That is
exactly ``ReplacingTaskSlot``:

```swift
import LifetimeBoundaries

final class SearchController: NSObject, UITextFieldDelegate {
  let api: SearchAPI
  let slot = ReplacingTaskSlot()
  @MainActor var renderResults: ([Result]) -> Void = { _ in }

  init(api: SearchAPI) { self.api = api }

  func textField(_ field: UITextField,
                 shouldChangeCharactersIn range: NSRange,
                 replacementString string: String) -> Bool {
    let query = (field.text ?? "") + string
    Task { [slot, api, renderResults] in
      await slot.replace { [api, renderResults] in
        do {
          let results = try await api.search(query)
          await MainActor.run { renderResults(results) }
        } catch is CancellationError {
          // expected when a newer keystroke replaced us
        } catch {
          // log
        }
      }
    }
    return true
  }
}
```

`slot.replace { … }` cancels and *drains* the previous task before
starting the next, so two requests can never race for the same
rendering slot.

### Step 2 — give the controller a `Scope`

The controller still has no shutdown sequence. Give it a ``Scope``
and have the view's `deinit` cancel it:

```swift
import Lifetime

final class SearchController: NSObject, UITextFieldDelegate {
  let api: SearchAPI
  let scope: Scope
  let slot = ReplacingTaskSlot()
  @MainActor var renderResults: ([Result]) -> Void = { _ in }

  init(api: SearchAPI, parent: Scope) {
    self.api = api
    self.scope = parent
    super.init()
    Task { [scope, slot] in
      try? scope.onCancel { await slot.cancel() }
    }
  }
  // ...delegate method unchanged from Step 1...
}

// Somewhere on screen teardown:
await screen.scope.cancel()
// At this point the in-flight search has been cancelled AND drained.
```

The `scope.onCancel` registration is the load-bearing part: when the
parent scope ends, the slot's `cancel()` runs as part of the
deterministic teardown.

### Step 3 — the test that proves it works

```swift
import Testing
import Lifetime
import LifetimeBoundaries

@Test
func newerSearchReplacesOlder() async throws {
  let api = ScriptedSearchAPI()
  let controller = await SearchController(api: api, parent: .root())

  await controller.feed("a")
  await controller.feed("ab")
  await controller.feed("abc")

  // The slot has drained two stale searches and is now running "abc".
  let observed = await api.observedQueries
  #expect(observed == ["a", "ab", "abc"])

  // Pop the screen.
  await controller.scope.cancel()

  // The in-flight "abc" search has been cancelled and drained.
  let cancelled = await api.cancelledQueries
  #expect(cancelled.contains("abc"))
}
```

Two assertions the original `Task { … }` shape could not make: a) all
intermediate keystrokes were observed in order, and b) by the time
`scope.cancel()` returns, the in-flight work has actually stopped.

## When to reach for which boundary

- **``ScopeOwnedTask``** — when async work spawned from a sync entry
  point should live for the duration of a scope and be adopted into
  it via ``Lifetime/Scope/supervise(work:)``. Use the throwing variant
  when callers need to observe a result.
- **``ReplacingTaskSlot``** — when each new triggering event should
  cancel and drain the previous in-flight task. Search-as-you-type,
  preview rendering, debounced auto-save.
- **``AsyncTaskRunner`` / ``MainActorTaskRunner``** — when you need a
  long-lived "spawn this async closure for me" surface inside an
  actor or `@MainActor` type, with its own internal ownership and
  shutdown.
- **``awaitCancellation(isolation:then:)``** — when an async function
  needs a structured hook that runs *exactly once* on cancellation,
  awaited, with no `defer { Task { … } }` workaround.
- **``installTerminationHandler(for:_:)``** — when you consume an
  `AsyncSequence` and need to run a teardown hook once it finishes
  (cleanly or via cancellation) without wrapping the consumer in an
  ad-hoc owner.

## See also

- The `Lifetime` article "Migrating off a Task graveyard" shows the
  scope-level transformation that pairs with this article.
- `LifetimePrimitives.ActorOwnedWork` is what ``ScopeOwnedTask`` is
  built on; reach for it directly only when you need
  isolation-inheriting ownership without `LifetimeHandle` semantics.
