# Changelog

All notable changes to `swift-lifetime` are documented in this file.

The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This package
becomes stable at `1.0.0`: future public API changes are intended to be
source-compatible. Minor releases add functionality, and patch releases
are reserved for fixes. See [README — Installation](./README.md#installation)
for pinning guidance.

## 1.0.0 Initial open-source release.

### Added

- `CONTRIBUTING.md`, `SECURITY.md`, and this `CHANGELOG.md`.
- Seven library targets:
  - `Lifetime` — resource trees for Swift Concurrency: `Scope`,
    `Resource`, `Child`, factories, `Continuation`, `LifetimeHandle`,
    `TaskHandle`.
  - `LifetimePrimitives` — async-aware coordination primitives:
    `TokenBucket`, `AsyncSignal`, `AsyncBroadcaster`, `Subject`,
    `AsyncThrowingContinuation`, `DetachedOwnedWork`,
    `MainActorOwnedWork`, `ActorOwnedWork`.
  - `LifetimeBoundaries` — sync-to-async ownership at platform
    callback boundaries: `AsyncTaskRunner`, `MainActorTaskRunner`,
    `ReplacingTaskSlot`, `ScopeOwnedTask`,
    `ScopeOwnedThrowingTask`, `installTerminationHandler`,
    `awaitCancellation`, `deferToMainActor`.
  - `LifetimePolicies` — named, injectable scheduler boundaries:
    `AsyncSleeper`, `TaskSleeper`, `DelayPolicy`, `DebouncePolicy`,
    `PollingPolicy`, `RetryPolicy`, `RetryDelay`, `TimeoutPolicy`,
    `CooperativeYieldPolicy`, `withTimeout`.
  - `LifetimeIntent` — reducer-driven serialized executor:
    `IntentReducerExecutor`.
  - `LifetimeResources` — lazy resources and scope-shaped
    invalidation: `LazyValue`, `LazyResource`, `ResourceObserver`,
    `ResourceIsolation`, `ResourceState`, `ScopeInvalidator`.
  - `LifetimeSwiftUI` — `ComponentMount`, `MountedComponentView`,
    `MountInvalidatableComponent`.
- `LifetimeBenchmarks` executable with regression thresholds for
  five core operations.
- `.spi.yml` declaring all seven library targets for Swift Package
  Index documentation hosting.

### Requirements

- Swift 6.2+ in Swift 6 language mode.
- macOS 15+, iOS 18+, tvOS 18+, watchOS 11+.

[Unreleased]: https://github.com/GoodHatsLLC/swift-lifetime/compare/1.0.0...HEAD
[1.0.0]: https://github.com/GoodHatsLLC/swift-lifetime/releases/tag/1.0.0
