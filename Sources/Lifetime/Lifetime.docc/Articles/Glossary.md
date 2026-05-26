# Glossary

Canonical vocabulary used across the `Lifetime` package and its module documentation.

## Overview

`Lifetime` and its sibling modules share a small dictionary of terms.
Each definition below names the term, points to the type that owns
the contract, and notes the most common confusion. Cross-references
go to the precise symbol or document.

## Core terms

- term **Scope**:
    A ``Scope`` is a lifecycle boundary that owns a unified registration
    log of children, cancellation actions, and adopted handles. The
    only way to drive teardown deterministically is through
    ``Scope/cancel()``; `deinit` is a fallback (see *deinit fallback*
    below). Roots come from ``Scope/root(cancellationPolicy:)``;
    children come from ``Scope/child(name:input:launchPolicy:build:)``
    or ``Scope/delegate()``.

- term **Resource**:
    A ``Resource`` is a caller-owned runtime value paired with an
    async `destroy` closure. Created by ``Scope/start(_:launchPolicy:create:destroy:)``
    or ``Scope/withResource(_:input:launchPolicy:create:destroy:operation:)``.
    `Resource.cancel()` runs the destroy closure exactly once.
    Distinct from *handle* in that a `Resource` *holds a value* — you
    keep using `resource.value` until you cancel.

- term **Child**:
    A ``Child`` is a struct wrapping a nested ``Scope`` plus typed
    *exports*. `Child.cancel()` forwards to the underlying scope; the
    scope provides identity and the safety net. Use a child when the
    work needs its own cancellation point and exports a small set of
    derived values for the parent to use.

- term **Exports**:
    The typed values a ``Child`` makes available to its caller. The
    child's `build` closure constructs them inside the child scope;
    the parent reads them via `child.exports`. Exports are arbitrary
    `Sendable` values — they are not themselves owners, just typed
    pointers into work the child already owns.

- term **Factory**:
    Either ``ResourceFactory`` or ``ChildFactory``. Factories are
    small `Sendable` structs that build transient handles on demand
    via `make(...)`. A factory does **not** retain its originating
    scope; calling `make(...)` after that scope has cancelled throws
    ``ScopeError/cancelled``.

- term **LifetimeHandle**:
    The minimal protocol — ``LifetimeHandle`` — that any cancellable,
    `Sendable` async owner implements: a single
    `cancel() async` requirement. ``Scope``, ``Resource``, ``Child``,
    and ``TaskHandle`` all conform. Functions that accept a
    `some LifetimeHandle` work with any of them.

- term **NamedLifetimeHandle**:
    A ``LifetimeHandle`` that also carries a `String` `name`. Adopted
    by a scope, the name surfaces in `description` and in
    ``ScopeSnapshot`` entries.

- term **TaskHandle**:
    A ``LifetimeHandle`` over an `async` closure, used internally by
    ``Scope/supervise(priority:work:)``. Wraps the closure in a
    `Task` whose cancellation is observable and awaitable through
    `cancel()`.

- term **Continuation**:
    A ``Continuation`` is a single-yield async coordination primitive.
    Exactly one caller awaits the value; exactly one writer fulfils
    it. Double-yield is an error, not silent overwrite. Distinct from
    ``LifetimePrimitives/AsyncThrowingContinuation``, which is a
    one-shot bridge for completion-handler APIs.

## Ownership verbs

- term **adopt**:
    ``Scope/adopt(_:)`` registers an external ``LifetimeHandle`` into
    the scope's teardown sequence. The handle is cancelled when the
    scope cancels. Adoption *binds an existing handle* to a scope.

- term **supervise**:
    ``Scope/supervise(work:)`` and
    ``Scope/supervise(priority:work:)`` are convenience wrappers over
    *adopt*. The handle-taking form is identical to `adopt`; the
    closure-taking form wraps an async closure in a ``TaskHandle``
    first, then adopts it. Use `supervise` when the source is a
    closure; use `adopt` when you already have a handle. If adoption
    fails because the scope has begun shutdown, `supervise` cancels
    the supplied handle immediately rather than leaking it.

- term **delegate**:
    ``Scope/delegate()`` returns a child scope tied to the receiver's
    lifetime. Use it when you need a sub-scope but have no exports
    to declare. Equivalent to ``Scope/child(name:input:launchPolicy:build:)``
    with an empty build closure, but more explicit at the call site.

- term **start**:
    ``Scope/start(_:launchPolicy:create:destroy:)`` registers a
    caller-owned value with paired `create` / `destroy` closures and
    returns the wrapped value. Distinct from `adopt` in that `start`
    *creates* the value; distinct from `withResource` in that `start`
    leaves the resource alive until the scope ends (or the caller
    explicitly cancels it).

- term **withResource / withChild / withChildScope / withLifetime**:
    Structured helpers. Each runs a block with a freshly-created
    owner, cancels that owner when the block returns or throws, and
    returns the block's result. Use these when the work is bounded
    by a single function call.

## Cancellation vocabulary

- term **cancel**:
    `await cancel()` is the contract for every owner in this package.
    It is **idempotent**, **cascading** (parent cancellation drives
    every registered child and action), and **awaited** (does not
    return until every registered teardown has finished).

- term **idempotent cancellation**:
    Calling `cancel()` more than once is safe. Subsequent calls
    short-circuit to await the in-flight cancellation rather than
    starting a new one.

- term **cancellation policy**:
    ``ScopeCancellationPolicy`` controls how a scope walks its
    registration log at teardown. `.serialLIFO` (default) is strict
    reverse order across children and actions; `.parallelUnordered`
    runs children concurrently, then actions concurrently.

- term **launch policy**:
    ``LaunchPolicy`` controls how a scope creates a new owner.
    `.inline` (default) runs the builder on the caller's task;
    `.detached` runs it on a detached task. Use `.detached` when the
    caller's isolation should not be inherited by the builder.

- term **deinit fallback**:
    When the last strong reference to a ``Scope``, ``Resource``, or
    ``Child`` is dropped without an explicit cancel, teardown fires on
    a detached task as a backstop against leaks. The trigger site
    **does not block** and completion **is not observable**. Tests
    and shutdown sequences must use `await cancel()` instead.

## Scheduler / boundary vocabulary

- term **AsyncSleeper**:
    The `LifetimePolicies.AsyncSleeper` protocol abstracts
    `Task.sleep` so production code and tests share the same retry,
    debounce, polling, delay, and timeout machinery while tests
    inject deterministic timing. Production uses
    `LifetimePolicies.TaskSleeper`; tests inject a manual sleeper.

- term **policy** (in `LifetimePolicies`):
    A named, injectable scheduler decision built on
    `LifetimePolicies.AsyncSleeper`. `LifetimePolicies.DelayPolicy`,
    `LifetimePolicies.RetryPolicy`,
    `LifetimePolicies.DebouncePolicy`,
    `LifetimePolicies.PollingPolicy`,
    `LifetimePolicies.TimeoutPolicy`, and
    `LifetimePolicies.CooperativeYieldPolicy` are the named units.

- term **boundary** (in `LifetimeBoundaries`):
    A type that wraps async work spawned from a *synchronous* entry
    point (UIKit delegate, Combine subscriber, C callback) so the
    work is owned, drainable, and cancellable. The headline
    boundaries are `LifetimeBoundaries.AsyncTaskRunner`,
    `LifetimeBoundaries.MainActorTaskRunner`,
    `LifetimeBoundaries.ReplacingTaskSlot`, and
    `LifetimeBoundaries.ScopeOwnedTask`.

## `LifetimeSwiftUI` vocabulary

- term **mount**:
    A `LifetimeSwiftUI.ComponentMount` is a `@MainActor`,
    `@Observable` slot that holds the currently-mounted component for
    a subtree. `mount(_:)` swaps the value;
    `invalidate(shutdown:)` clears it and runs the shutdown
    closure on the outgoing component.

- term **epoch**:
    A monotonically increasing counter on
    `LifetimeSwiftUI.ComponentMount` that
    `LifetimeSwiftUI.MountedComponentView` observes to drive view
    rebuilds. Detaching or invalidating bumps the epoch; mounting a
    new component does not, unless the previous one was detached
    first.

## `LifetimeIntent` vocabulary

- term **executable** (in `LifetimeIntent`):
    A `LifetimeIntent.IntentReducerExecutor.Executable` is a
    ``ResourceFactory``. The executor's pump calls
    `make()` to run the executable's work, then `cancel()` on the
    returned resource to drain its teardown before consuming the
    next executable. Because `ResourceFactory.init` is package-
    internal, every executable is scope-bound by construction.

- term **pump**:
    The single serialized worker inside an
    `LifetimeIntent.IntentReducerExecutor` that consumes one
    executable at a time. Submitting events is non-blocking; the
    pump folds them through the reducer and drives the next
    executable when the previous one's teardown has finished.
