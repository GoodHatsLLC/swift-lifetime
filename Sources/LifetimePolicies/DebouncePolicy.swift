// © GoodHatsLLC

import Foundation

/// A named debounce delay backed by the shared async scheduler boundary.
///
/// Feature code should depend on this policy instead of calling raw scheduler
/// primitives for debounce behavior. Tests can inject a manual sleeper to make
/// debounce release deterministic.
public struct DebouncePolicy: Sendable {
  public let delay: Duration

  private let sleeper: any AsyncSleeper

  public init(
    delay: Duration,
    sleeper: any AsyncSleeper = TaskSleeper()
  ) {
    self.delay = delay
    self.sleeper = sleeper
  }

  public func wait() async throws {
    try await sleeper.sleep(for: delay)
  }
}
