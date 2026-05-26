# ``Lifetime``

Resource trees for Swift Concurrency.

## Overview

Swift's structured concurrency gives you task trees. ``Lifetime`` gives you resource trees: a way to create, own, nest, and tear down runtime values with the same clarity.

A ``Scope`` is a lifecycle boundary that owns children and teardown actions. A ``Resource`` is a caller-owned runtime value with deterministic async teardown via ``Resource/cancel()``. A ``Child`` is a nested scope plus typed exports. Each one supports idempotent cancellation and cascading teardown.

`await cancel()` is the contract. `deinit` is a **fallback only**: when the last reference is dropped without an explicit cancel, teardown runs on a detached task as a backstop against leaks. The trigger site does not block and completion is not observable. Do not rely on `deinit` for ordering, sequencing, or any teardown a test or shutdown sequence must wait on.

Factories (``ResourceFactory``, ``ChildFactory``) build transient handles on demand without keeping their originating ``Scope`` alive. Creating from a cancelled scope throws ``ScopeError/cancelled``.

## Reference vs value types

The rule is consistent across the module: a type is a `final class` when it carries its own lifecycle identity — mutable state behind a lock, or a `deinit` safety net that fires teardown when the last reference is dropped. A type is a `struct` when it is a pure value-typed wrapper over one of those classes and adds no independent identity.

- ``Scope`` and ``Resource`` are classes because each carries the cancellation state machine that drives `deinit`-triggered teardown.
- ``Child`` is a struct because it adds typed exports around a ``Scope``; cancelling a `Child` simply forwards to the underlying scope, which provides the identity and the safety net.
- ``ResourceFactory`` and ``ChildFactory`` are structs because they hold a closure and a `name` — neither requires identity, and a factory's lifetime is independent of any handle it produces.

## Supervision and delegation

``Scope`` ships supervision and delegation helpers directly:
``Scope/supervise(work:)`` adopts an existing handle into the scope,
``Scope/supervise(priority:work:)`` lifts a `Sendable` async closure
into a managed ``TaskHandle``, and ``Scope/delegate()`` returns a child
scope whose lifetime is tied to its parent. Pair these with
``LifetimeBoundaries`` when bridging sync platform callbacks into
scope-owned async work.

## Topics

### Articles

- <doc:MigratingOffATaskGraveyard>
- <doc:TestingWithLifetime>
- <doc:Glossary>

### Scope

- ``Scope``
- ``ScopeCancellationPolicy``
- ``LaunchPolicy``
- ``ScopeContext``
- ``ScopeError``
- ``ScopeSnapshot``

### Owned Runtime Values

- ``Resource``
- ``ResourceFactory``
- ``Child``
- ``ChildFactory``

### Coordination

- ``Continuation``
- ``LifetimeHandle``
- ``NamedLifetimeHandle``
- ``LifetimeID``
- ``TaskHandle``
