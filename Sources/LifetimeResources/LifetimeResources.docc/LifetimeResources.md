# ``LifetimeResources``

Lazy resources and scope-shaped invalidation.

## Overview

Higher-level helpers built on ``Lifetime`` for two specific patterns:

- A runtime value whose construction is deferred until first access, with cached storage and explicit reset semantics — see ``LazyValue`` and ``LazyResource``.
- A scope whose cancellation is scheduled against a policy (background pressure, timeout, manual trigger) — see ``ScopeInvalidator``.

## Topics

### Articles

- <doc:LazyValuesAndInvalidation>

### Lazy Resources

- ``LazyValue``
- ``LazyResource``
- ``ResourceObserver``
- ``ResourceIsolation``
- ``ResourceState``

### Scope Invalidation

- ``ScopeInvalidator``
