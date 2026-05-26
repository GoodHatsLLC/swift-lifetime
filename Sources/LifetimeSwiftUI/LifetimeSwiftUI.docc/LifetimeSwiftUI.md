# ``LifetimeSwiftUI``

Mount scoped components into SwiftUI.

## Overview

Bridge between scope-owned components and SwiftUI's view tree. ``ComponentMount`` owns the lifetime of a mounted component subtree and tracks a mount epoch that drives view rebuilds; ``MountedComponentView`` renders content for that mounted component and rebuilds when the epoch changes. Components conforming to ``MountInvalidatableComponent`` get a `shutdown()` callback when the mount is invalidated.

## Topics

### Articles

- <doc:MountingScopedComponents>

### Types

- ``ComponentMount``
- ``MountedComponentView``
- ``MountInvalidatableComponent``
