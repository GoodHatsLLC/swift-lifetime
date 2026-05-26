// © GoodHatsLLC

import Foundation

/// A named polling cadence backed by an injectable sleeper.
///
/// Use this for loops that intentionally re-check state at a fixed interval.
/// It keeps polling cadence visible and makes tests injectable without raw
/// scheduler calls in feature code.
public struct PollingPolicy: Sendable {
  public let interval: Duration
  private let sleeper: any AsyncSleeper

  public init(
    interval: Duration,
    sleeper: any AsyncSleeper = TaskSleeper()
  ) {
    self.interval = interval
    self.sleeper = sleeper
  }

  public func waitForNextPoll() async throws {
    guard interval > .zero else { return }
    try await sleeper.sleep(for: interval)
  }
}
