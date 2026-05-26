# Building a serialized executor

Walk through ``IntentReducerExecutor`` with one concrete example: a save queue that coalesces edits.

## Overview

A "save queue" is a recurring shape in real apps: many synchronous
events arrive (keystrokes, autosave triggers, explicit `Cmd+S`), each
needs to be folded into a single pending state, and at most one save
should be in flight at a time. When the save finishes — successfully
or after teardown — the queue should consider the next pending event.

``IntentReducerExecutor`` is built for exactly this shape. The three
pieces you provide:

- A **`PendingState`** type representing the queue's coalesced state
  between runs.
- A **`Reducer`** that folds an `IntentEvent` into `PendingState` and
  decides whether to cancel the active run.
- A **`NextExecutable`** that drains one runnable unit out of the
  pending state and returns it as an `Executable`
  (a scope-bound `ResourceFactory<Void, Void>`).

The executor's pump owns the actual work loop: it asks for one
executable, runs its `make()` to do the work, then runs `cancel()` on
the returned resource to drain its `destroy` closure before asking
for the next.

## The save-queue example

### Pending state and events

```swift
struct PendingSave: Sendable {
  var dirty: Document?
}

enum SaveEvent: Sendable {
  case edited(Document)
  case forceFlush
}
```

`dirty` is the load-bearing field: every editor change overwrites it,
so by the time the pump asks for the next save it sees only the most
recent document.

### Reducer

```swift
import LifetimeIntent

let reduce: IntentReducerExecutor<SaveEvent, PendingSave>.Reducer = {
  state, event in
  switch event {
  case .edited(let document):
    state.dirty = document
    return .keepRunning
  case .forceFlush:
    state.dirty = state.dirty
    return .cancelActive
  }
}
```

`.keepRunning` lets any in-flight save finish before the pump picks
up the newer document. `.cancelActive` tells the executor to
cooperatively cancel the running save before consuming the next
event — the right call when the user explicitly forces a flush.

### Producing executables from a scope

This is where ``IntentReducerExecutor/Executable`` being a
``Lifetime/ResourceFactory`` earns its keep. You build executables
from a real ``Lifetime/Scope`` so the work — and any resource it
spawns — is part of the scope's teardown contract:

```swift
import Lifetime
import LifetimeIntent

let scope = Scope.root()
let api = DocumentAPI()

let nextExecutable: IntentReducerExecutor<SaveEvent, PendingSave>.NextExecutable = {
  state in
  guard let document = state.dirty else { return nil }
  state.dirty = nil
  return try? scope.resourceFactory(name: "Save") { @Sendable in
    try await api.save(document)
  } destroy: { _ in
    await api.releaseConnection()
  }
}
```

`scope.resourceFactory(...)` is the only public way to construct a
`ResourceFactory.init` because that initializer is package-internal.
That's deliberate: every executable submitted to an
``IntentReducerExecutor`` is bound to a live scope by construction,
which means scope cancellation tears in-flight work down through the
standard scope path instead of leaking it into an orphan task.

### Wiring the executor

```swift
let saveQueue = IntentReducerExecutor(
  initialState: PendingSave(),
  reduce: reduce,
  nextExecutable: nextExecutable,
  onError: { error in
    // surface to the UI; the pump continues with the next event
  }
)

// Adopt into a scope so saveQueue is part of the scope's teardown.
try scope.adopt(saveQueue)

// Producers call send synchronously — never blocking the caller:
saveQueue.send(event: .edited(document))
```

### Shutdown shapes

Two terminal paths, depending on what shutdown means for your app:

- ``IntentReducerExecutor/finish()`` — close intake and **drain
  pending executables**. Producers can no longer submit new events,
  but the pump keeps running until `nextExecutable` returns `nil`.
  Use when the app shuts down cleanly and you want the last
  in-memory edit to land.
- ``IntentReducerExecutor/cancel()`` — close intake, **cooperatively
  cancel** the active executable, and wait for the pump task to
  finish. Use when you're tearing the scope down on an error path
  and the last in-flight save is no longer welcome.

`saveQueue` is a ``Lifetime/LifetimeHandle``, so adopting it into a
scope is the usual one-liner — when the scope ends, the handle's
`cancel()` runs as part of the deterministic teardown.

### Idle waits

``IntentReducerExecutor/waitUntilIdle()`` blocks until both
`pendingExecutable` returns `nil` *and* no executable is currently
running. Useful in tests as a "settle" point and at app suspend time
to commit before the OS pulls the plug.

## What this is, and is not

`IntentReducerExecutor` is **not** a general-purpose actor queue. It
is a one-at-a-time executor with bounded pending state and
deterministic teardown — the right shape for save queues, sync
queues, importer pipelines, document migration loops, single-flight
fetch coalescers. If your work needs concurrent execution, you want
a ``Lifetime/Scope`` with multiple supervised handles instead.

It is **also not** a place for unbounded queues. Your reducer is the
only thing standing between "many incoming events" and "many pending
executables", so design `PendingState` and `nextExecutable` together
to keep that pressure bounded. A `PendingSave { var dirty: Document? }`
is bounded by construction; `PendingState { var queue: [Document] }`
needs an explicit drop or coalesce policy.

## See also

- ``Lifetime/ResourceFactory`` — the underlying type
  `Executable` is an alias for.
- ``Lifetime/Scope/resourceFactory(_:name:create:destroy:)-…`` — the
  only public way to construct an `Executable`.
- The `Lifetime` article "Testing with Lifetime" covers the
  `await handle.cancel()` shape that lets `IntentReducerExecutor`'s
  cancel path be asserted on.
