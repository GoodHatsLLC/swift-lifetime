# ``LifetimeBoundaries``

Own async work at sync and callback boundaries.

## Overview

Synchronous platform APIs — UIKit delegates, Combine subscribers, C callbacks, KVO observers — frequently need to enter async territory. Doing that with a raw `Task { ... }` loses ownership: there's nothing to cancel, nothing to drain at shutdown, no way for a test to wait for in-flight work.

The types in this module make the boundary explicit. Each one owns its async work, supports idempotent cancellation, and provides a way to await completion or drained teardown.

## Topics

### Articles

- <doc:OwningCallbackWork>

### Task Runners

- ``AsyncTaskRunner``
- ``MainActorTaskRunner``
- ``deferToMainActor(_:)``

### Replaceable and Scope-Adopted Work

- ``ReplacingTaskSlot``
- ``ScopeOwnedTask``
- ``ScopeOwnedThrowingTask``

### Cancellation and Termination

- ``CancellationAwaitResult``
- ``awaitCancellation(isolation:then:)``
- ``installTerminationHandler(for:_:)``
