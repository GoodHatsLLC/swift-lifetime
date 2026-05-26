import Foundation
import LifetimePolicies

@testable import Lifetime

func waitUntil(
  timeout: Duration,
  pollInterval: Duration = .milliseconds(10),
  _ predicate: @Sendable @escaping () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if await predicate() {
      return true
    }
    try? await DelayPolicy(pollInterval).wait()
  }

  return await predicate()
}

@MainActor
func waitUntil(
  timeout: Duration,
  pollInterval: Duration = .milliseconds(10),
  _ predicate: @MainActor @escaping () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if predicate() {
      return true
    }
    try? await DelayPolicy(pollInterval).wait()
  }

  return predicate()
}
