// © GoodHatsLLC

import Foundation

/// A named timeout delay backed by an injectable sleeper.
///
/// Use this for timeout branches in task groups when the operation's error
/// type does not fit the higher-level `withTimeout` helpers.
public struct TimeoutPolicy: Sendable {
  public let duration: Duration
  private let sleeper: any AsyncSleeper

  public init(
    _ duration: Duration,
    sleeper: any AsyncSleeper = TaskSleeper()
  ) {
    self.duration = duration
    self.sleeper = sleeper
  }

  public func waitForTimeout() async throws {
    guard duration > .zero else { return }
    try await sleeper.sleep(for: duration)
  }
}
