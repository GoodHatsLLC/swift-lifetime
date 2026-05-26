// © GoodHatsLLC

import Foundation

/// A named delay boundary backed by an injectable sleeper.
///
/// Use this where code intentionally waits for a duration before continuing.
/// Tests can inject a manual sleeper to drive the wait deterministically.
public struct DelayPolicy: Sendable {
  public let duration: Duration
  private let sleeper: any AsyncSleeper

  public init(
    _ duration: Duration,
    sleeper: any AsyncSleeper = TaskSleeper()
  ) {
    self.duration = duration
    self.sleeper = sleeper
  }

  public func wait() async throws {
    guard duration > .zero else { return }
    try await sleeper.sleep(for: duration)
  }
}

/// A named cooperative executor-yield boundary.
///
/// Use this only where the desired behavior is explicitly "allow pending actor
/// work/update cycles to run"; it is not a substitute for causal test probes.
public struct CooperativeYieldPolicy: Sendable {
  public let cycles: Int

  public init(cycles: Int = 1) {
    self.cycles = max(0, cycles)
  }

  public func wait() async {
    guard cycles > 0 else { return }
    for _ in 0..<cycles {
      await Task.yield()
    }
  }
}
