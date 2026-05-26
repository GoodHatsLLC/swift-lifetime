# Internals

> This document is for **contributors and reviewers**. Adopters should
> read the [README](../README.md) and the per-module DocC catalogs;
> nothing in here is a public contract.

The package is small enough that one document can cover everything
load-bearing. The sections below are ordered from most-frequently-needed
(state machine, registration log) to least (`deinit` plumbing, weak
references).

---

## The `Scope` state machine

A `Scope` lives in one of three phases, defined inline in `Scope.Phase`:

```
.running
   │
   │  cancel() is called for the first time
   ▼
.cancelling(run, snapshot)
   │
   │  every entry's teardown closure has returned
   ▼
.cancelled(snapshot)
```

Once the scope leaves `.running`, no new entries can be registered.
Every public registration path (`start`, `withResource`, `child`,
`onCancel`, `adopt`, `supervise`, `delegate`) funnels through
`ScopeStorage.withRunningEntries`, which returns `.cancelled` if the
phase has advanced. Factories check the same gate in `make(...)`;
that's the only way they can throw `ScopeError.cancelled` after the
originating scope ends.

### `.cancelling` carries a `CancellationRun`

`CancellationRun` is an `AsyncSignal` that all concurrent callers of
`cancel()` await. The first caller transitions `.running →
.cancelling(run, snapshot)`, captures the entries log into a closure
by value, and drives the walk; subsequent callers see `.cancelling`
and await the same `run`. This is what makes `cancel()` idempotent
and gives every caller the same "teardown actually finished" signal.

The `snapshot` in `.cancelling` is a frozen description (phase string,
counts, sorted names) so `description` keeps returning meaningful
output mid-teardown without re-walking the now-empty entries array.

### `.cancelled` is terminal and empty

Transitioning to `.cancelled` clears the entries array. The
`DescriptionSnapshot` is preserved so the type still describes itself
after teardown, but no closures, weak references, or task handles are
retained. A `.cancelled` scope is small enough that holding one through
a deinit-only fallback is cheap.

---

## The registration log

Children and cancellation actions share **one array** per scope,
`ScopeStorage.entries: [Entry]`. The `Entry` enum has three cases:

- `.child(id, name, reference: WeakScopeRef)` — registered by
  `child`, `withChild`, `delegate`, etc.
- `.action(id, name, run: @Sendable () async -> Void)` — registered by
  `onCancel`, `adopt`, `start`'s `destroy` closure,
  `withResource`'s `destroy` closure, supervised handles.
- `.tombstone` — a logically removed entry.

### Why one log, not two

`ScopeCancellationPolicy.serialLIFO` is the default and the load-
bearing case. It walks the log in *strict reverse registration order*
across both children and actions: a child registered after a
resource's `destroy` action is torn down *before* that action, and
vice versa. The two-array alternative requires reconstructing an
interleaved order from timestamps, which is both more code and
allocates per-entry.

`.parallelUnordered` repartitions the log into a children-then-actions
sequence at cancellation time so destroy hooks outlive the child
scopes that may reference them. Doing this repartition lazily (only
on cancel, on a captured-by-value snapshot) means the hot path stays
identical to `.serialLIFO`.

### Why tombstones, not `remove(at:)`

`Resource.cancel()`, `Child.cancel()`, and detached children all need
to remove themselves from their parent's log *before* the parent
walks teardown. The naive shape — `entries.remove(at: foundIndex)` —
is `O(n)` per removal and, more importantly, breaks Swift's array
copy-on-write fast path because the removal site mutates the array's
buffer header. Hot scopes (per-request, per-event) churn enough
registrations that this showed up as a real allocation regression in
the benchmark suite.

Tombstones are constant-time:

```swift
storage.entries[index] = .tombstone
```

Walks, snapshots, and the `description` counter all skip
`.tombstone`. The entries array is freed wholesale at the
`.running → .cancelling` transition, so tombstone memory is bounded
by a single scope's lifetime — *not* by the lifetime of the program.

There is no compaction step. Adopters who register and detach
thousands of entries on one long-lived scope will hold tombstone
memory until that scope cancels. The README's "Complexity and memory"
section calls this out for users; in practice it pushes toward the
"fresh child scope per logical unit" pattern, which is what we want.

### `ScopeStorage` is a struct, not an enum

The flat `ScopeStorage { phase, entries }` layout intentionally hoists
`entries` *out* of the `.running` enum payload. Nesting `entries`
inside `.running` would force the whole enum payload to be rewritten
on every append (because the discriminant + payload have to be
overwritten atomically under the lock), which defeats Array CoW. The
flat layout lets `entries` mutate in place inside the lock-held
critical section.

---

## Locking

Every `Scope` owns a single `Synchronization.Mutex<ScopeStorage>`.
This is the entire concurrency story for the type:

- Every registration path takes the lock once, mutates `entries`, and
  releases.
- The cancellation walk **never holds the lock**. The first `cancel()`
  caller flips the phase, captures `entries` by value, sets
  `storage.entries = []`, and releases the lock. The walk then runs
  against the captured snapshot.
- Re-entrant scope cancellation works because the walk runs without
  the parent's lock held; a child's `detachChild(id:)` can take the
  parent's lock during teardown without deadlock.

`Synchronization.Mutex` is why the platform floor is iOS 18 / macOS
15. Lowering this floor would require swapping in `os_unfair_lock`
on Apple platforms and a `pthread_mutex_t`-backed equivalent on
Linux. We don't.

---

## Parent / child wiring

A child scope holds a strong reference to its parent (
`private let parent: Scope?`). The parent only holds a *weak*
reference to each child, via `WeakScopeRef`:

```swift
private final class WeakScopeRef: Sendable {
    weak var value: Scope?
    ...
}
```

This asymmetry matters:

- The parent surviving outlives all its children's documented lifetimes.
- A child whose only retainers are its parent's registration entry
  *and* its own caller can be released as soon as the caller drops it.
  `deinit` then triggers the leak-fallback teardown without the parent
  preventing it.
- The parent's cancellation walk re-derefs each `WeakScopeRef`; a
  child that's already gone resolves to `nil` and is skipped.

When a child cancels — whether through `Child.cancel()`, its own
`deinit`, or its parent's cascading walk — it calls
`parent?.detachChild(id:)`, which marks the parent's entry as a
tombstone. That keeps `description` and `snapshot()` accurate while
the parent is still running.

---

## Resource and Child are *handles*, not owners

The reference-vs-value-type rule in the [`Lifetime` DocC overview](../Sources/Lifetime/Lifetime.docc/Lifetime.md):

- `Scope` and `Resource` are `final class` — each owns the
  cancellation state machine that drives `deinit`-triggered teardown.
- `Child` is a `struct` — it wraps a `Scope` plus typed exports; the
  scope provides identity and the safety net.
- `ResourceFactory` and `ChildFactory` are `struct`s holding a closure
  plus a `name`; they neither carry state nor pin their originating
  `Scope` alive.

The factory-doesn't-pin-scope property is what makes
`ScopeError.cancelled` from `make(...)` meaningful: a factory whose
originating scope has cancelled can still be called, but it observes
the cancellation through `withRunningEntries` and throws.

---

## The `deinit` fallback

The README and DocC documents repeat that `deinit` is a backstop, not
a contract. The implementation reflects that:

- When a `Scope` deinits while still `.running`, it fires `cancel()`
  on a detached task and returns immediately. The trigger site does
  *not* block and cannot observe completion.
- The detached task captures the scope's lock and entries list the
  same way an explicit `cancel()` would. Once it transitions through
  `.cancelling → .cancelled`, the snapshot string updates so any
  surviving `description` consumer sees a coherent terminal state.
- `Resource` and `Child` have the same structure: their `deinit` fires
  the cancellation closure on a detached task.

This is deliberately not awaitable. The whole point is that
"production forgot to cancel" should leak no work, but it should not
let test code paper over the bug either — tests that rely on
`await cancel()` won't accidentally pass against a `deinit`-only
shutdown.

---

## Cancellation policies in one paragraph each

- `ScopeCancellationPolicy.serialLIFO` — walks the captured entries
  snapshot in reverse, awaiting each child / action serially. Strict
  reverse registration order across both kinds. Default. Use when
  ordering matters more than throughput.
- `ScopeCancellationPolicy.parallelUnordered` — partitions the
  snapshot into children and actions, awaits all children
  concurrently in a `TaskGroup`, then all actions concurrently in a
  second `TaskGroup`. The two phases stay sequenced so a
  resource's `destroy` (an action) runs after the child that may
  reference it.

Both policies cancel exactly once. Both reject new registrations as
soon as the phase moves off `.running`. Both update the description
snapshot at the same transition.

---

## When to extend vs. when not to

A few rules of thumb for contributors thinking about new APIs:

- If the new type needs a `cancel()` and a `deinit` fallback, it
  should be a `final class` with the same shape as `Scope` /
  `Resource`: phase enum, registration log if it owns sub-work,
  `Synchronization.Mutex` for the storage cell, idempotent `cancel()`.
- If the new type is a *wrapper* over an existing owner (typed
  exports, factory closure), it should be a `struct`. Don't introduce
  a second class identity for what is really a value-type adapter.
- New scheduler decisions belong in `LifetimePolicies` and must
  depend on `AsyncSleeper` rather than `Task.sleep` directly. That
  is the entire reason the protocol exists.
- New sync-to-async boundary owners belong in `LifetimeBoundaries`.
  They should accept a `Scope` (not a `LifetimeHandle`) so the
  adopter can choose whether the work is scope-bound or supervised.

If something doesn't fit any of those slots, open an issue. The
package's reputation rests on a small, coherent surface.
