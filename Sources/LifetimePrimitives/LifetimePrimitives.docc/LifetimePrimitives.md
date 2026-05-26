# ``LifetimePrimitives``

Async-aware coordination primitives.

## Overview

Building blocks for `Sendable` coordination that participate in the package's ownership story but don't depend on ``Lifetime/Scope`` itself. Reach for these when you need a primitive that's safe under Swift 6 strict concurrency and composes with the rest of the package.

The boundary types in ``LifetimeBoundaries`` and the named scheduler decisions in ``LifetimePolicies`` are built on top of these.

## Topics

### Coordination

- ``TokenBucket``
- ``AsyncSignal``
- ``AsyncBroadcaster``
- ``Subject``

### Task Ownership

- ``DetachedOwnedWork``
- ``MainActorOwnedWork``
- ``ActorOwnedWork``

### One-shot Bridges

- ``AsyncThrowingContinuation``
