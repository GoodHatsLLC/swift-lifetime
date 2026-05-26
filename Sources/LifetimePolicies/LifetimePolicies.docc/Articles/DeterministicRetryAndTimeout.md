# Deterministic retry and timeout

Drive retries, debounces, polls, and timeouts from your tests instead of `Task.sleep`.

## Overview

Every named policy in this module — ``DelayPolicy``, ``RetryPolicy``,
``DebouncePolicy``, ``PollingPolicy``, ``TimeoutPolicy`` — takes its
"wait" through the ``AsyncSleeper`` protocol rather than calling
`Task.sleep` directly. Production code uses ``TaskSleeper``; tests
inject a manual sleeper and drive the clock one tick at a time.

This article walks through the shape of a `ManualSleeper`, then uses
it to write a deterministic test for a retry loop and for a polling
loop. The same pattern works for every policy in the module.

## Step 1 — a `ManualSleeper`

A test sleeper just records each in-flight sleep and lets the test
resume them on demand. The minimal shape:

```swift
import LifetimePolicies

actor ManualSleeper: AsyncSleeper {
  struct PendingSleep {
    let duration: Duration
    let continuation: CheckedContinuation<Void, Error>
  }

  private var pending: [PendingSleep] = []

  func sleep(for duration: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      pending.append(PendingSleep(duration: duration, continuation: continuation))
    }
  }

  /// Resumes the oldest pending sleep. Returns the duration the
  /// caller asked for, so tests can assert on it.
  func advance() -> Duration? {
    guard !pending.isEmpty else { return nil }
    let next = pending.removeFirst()
    next.continuation.resume()
    return next.duration
  }

  /// Resumes the oldest pending sleep with a cancellation error.
  func cancel() {
    guard !pending.isEmpty else { return }
    let next = pending.removeFirst()
    next.continuation.resume(throwing: CancellationError())
  }

  var pendingCount: Int { pending.count }
}
```

That's the entire contract. Each policy in the module ultimately
calls `sleeper.sleep(for:)`; `advance()` lets the test resume the
loop with full control over ordering.

## Step 2 — deterministic retry

Production code reaches for ``RetryPolicy`` instead of writing its
own retry loop:

```swift
import LifetimePolicies

func fetchProfile(id: String,
                  api: ProfileAPI,
                  policy: RetryPolicy) async throws -> Profile {
  for attempt in policy.attempts {
    do {
      return try await api.profile(id: id)
    } catch is TransientError where policy.shouldRetry(afterAttempt: attempt) {
      try await policy.wait(afterFailureCount: attempt)
      continue
    }
  }
  throw FetchError.exhausted
}
```

The test:

```swift
import Testing
import LifetimePolicies

@Test
func retriesWithExponentialBackoff() async throws {
  let api = ScriptedAPI(failures: 2, then: .ok)
  let sleeper = ManualSleeper()
  let policy = RetryPolicy(
    maxAttempts: 5,
    delay: .exponential(base: .milliseconds(50),
                        maximum: .seconds(1),
                        maximumExponent: 4),
    sleeper: sleeper
  )

  async let result = fetchProfile(id: "avery", api: api, policy: policy)

  // First failure -> wait 50ms (base * 1)
  let firstDelay = await sleeper.advance()
  #expect(firstDelay == .milliseconds(50))

  // Second failure -> wait 100ms (base * 2)
  let secondDelay = await sleeper.advance()
  #expect(secondDelay == .milliseconds(100))

  let profile = try await result
  #expect(profile.id == "avery")
  #expect(api.callCount == 3)   // 2 failures + 1 success
  #expect(await sleeper.pendingCount == 0)
}
```

Three assertions production code would otherwise have to fake:

1. The retry schedule matches the policy.
2. The third call is the one that succeeded.
3. Nothing else is sleeping when the loop returns.

No `Task.sleep`, no race, no time-based flake.

## Step 3 — deterministic polling

``PollingPolicy`` solves the "ask repeatedly until something is true"
shape — readiness checks, async migrations, eventual-consistency
queries:

```swift
import LifetimePolicies

func waitForJob(id: JobID,
                store: JobStore,
                polling: PollingPolicy) async throws -> JobResult {
  try await polling.poll {
    guard let result = await store.poll(id: id) else { return nil }
    return result
  }
}
```

Driving it from a test:

```swift
@Test
func pollReturnsFirstNonNil() async throws {
  let store = ScriptedJobStore(
    yields: [nil, nil, .completed(id: "j-1")]
  )
  let sleeper = ManualSleeper()
  let polling = PollingPolicy(
    interval: .milliseconds(250),
    sleeper: sleeper
  )

  async let result = waitForJob(id: "j-1", store: store, polling: polling)

  // The loop ran the body once, got nil, then asked to sleep.
  _ = await sleeper.advance()
  _ = await sleeper.advance()

  let value = try await result
  #expect(value == .completed(id: "j-1"))
}
```

## Step 4 — timeout without races

``TimeoutPolicy`` and the free-standing ``withTimeout(of:operation:)``
helper compose with the manual sleeper too:

```swift
@Test
func slowOperationTimesOut() async throws {
  let sleeper = ManualSleeper()
  let timeout = TimeoutPolicy(.seconds(5), sleeper: sleeper)

  do {
    _ = try await timeout.run { try await Task.never() }
    Issue.record("expected timeout")
  } catch let error as WithTimeoutError {
    #expect(error.elapsed == .seconds(5))
  }

  // Resume the timeout sleeper so the helper's internal task tree
  // unwinds before the test returns.
  _ = await sleeper.advance()
}
```

## When to reach for which policy

| If your code… | Use |
|---|---|
| waits a fixed duration before continuing | ``DelayPolicy`` |
| retries a failure with constant or exponential backoff | ``RetryPolicy`` |
| collapses a burst of events into a single trailing call | ``DebouncePolicy`` |
| polls until a predicate returns non-`nil` | ``PollingPolicy`` |
| caps an async operation at a maximum duration | ``TimeoutPolicy`` / ``withTimeout(of:operation:)`` |
| yields cooperatively to allow other actor work to advance | ``CooperativeYieldPolicy`` |

Every one of them shares the same `sleeper` parameter, the same
default `TaskSleeper`, and the same test path.

## See also

- The `Lifetime` article "Testing with Lifetime" covers the broader
  test patterns this article fits into.
- `LifetimePolicies.RetryDelay` defines the retry schedule shapes
  (`.constant`, `.exponential`) used by ``RetryPolicy``.
