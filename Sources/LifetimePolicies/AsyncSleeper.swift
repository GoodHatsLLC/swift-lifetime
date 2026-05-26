// © GoodHatsLLC

import Foundation

/// Suspends for a duration behind a named scheduler boundary.
///
/// Application code should depend on this protocol or a higher-level policy
/// instead of calling the raw scheduler directly. Production uses `TaskSleeper`;
/// tests can provide deterministic manual sleepers.
public protocol AsyncSleeper: Sendable {
  func sleep(for duration: Duration) async throws
}

public struct TaskSleeper: AsyncSleeper {
  public init() {}

  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
