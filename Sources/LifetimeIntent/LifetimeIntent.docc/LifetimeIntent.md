# ``LifetimeIntent``

Reducer-driven executor for repeatable intents.

## Overview

Use ``IntentReducerExecutor`` when you have a stream of synchronously submitted events that need to be folded into bounded pending state and consumed one at a time, with each consumption ending in deterministic teardown before the next begins.

The executor owns a single serialized pump. Callers submit events without blocking; the reducer folds them into pending state; the pump consumes one executable at a time, drains its resource teardown, then asks for the next. `finish()` closes intake and drains pending executables; `cancel()` cooperatively cancels the active executable and waits for the pump to finish.

An ``IntentReducerExecutor/Executable`` is a `ResourceFactory<Void, Void>` constructed via `scope.resourceFactory { /* work */ }`. The pump drives each executable in two phases — `make()` runs the factory's `create` closure (the work); the pump then calls `cancel()` on the returned resource to run its `destroy` closure (the cleanup). The factory alias is load-bearing: because `ResourceFactory.init` is package-internal, every executable is scope-bound by construction, which means in-flight work cancels along with the owning scope.

## Topics

### Articles

- <doc:BuildingASerializedExecutor>

### Types

- ``IntentReducerExecutor``
