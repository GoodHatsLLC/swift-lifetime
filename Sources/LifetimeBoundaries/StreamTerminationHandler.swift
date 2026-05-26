// © GoodHatsLLC

import Foundation
public import LifetimePrimitives

/// Installs `handler` as the `onTermination` callback for an
/// `AsyncSignalContinuation`.
///
/// Wraps the platform API in a named boundary so termination behavior is
/// grep-able from the call site. `handler` fires when the stream finishes
/// or its consuming task is cancelled.
public func installTerminationHandler<Element>(
  for continuation: AsyncSignalContinuation<Element>,
  _ handler: @Sendable @escaping (AsyncSignalContinuation<Element>.Termination) -> Void
) {
  continuation.onTermination = handler
}
