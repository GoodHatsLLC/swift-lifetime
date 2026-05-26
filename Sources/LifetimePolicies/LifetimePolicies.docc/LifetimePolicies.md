# ``LifetimePolicies``

Named, injectable scheduler boundaries.

## Overview

When code needs to make a scheduler decision — wait for a duration, retry with backoff, debounce a stream of events, time out a slow operation — these types make that decision explicit and testable.

Every policy depends on the ``AsyncSleeper`` protocol rather than calling `Task.sleep` directly. Production code uses the default ``TaskSleeper``; tests inject a manual sleeper to make timing deterministic.

## Topics

### Articles

- <doc:DeterministicRetryAndTimeout>

### Sleeper Protocol

- ``AsyncSleeper``
- ``TaskSleeper``

### Named Policies

- ``DelayPolicy``
- ``DebouncePolicy``
- ``PollingPolicy``
- ``RetryPolicy``
- ``RetryDelay``
- ``TimeoutPolicy``
- ``CooperativeYieldPolicy``

### Timeout Helpers

- ``withTimeout(of:operation:)``
- ``Timeout``
- ``WithTimeoutError``
- ``TimeoutOnlyError``
- ``SourceLocation``
