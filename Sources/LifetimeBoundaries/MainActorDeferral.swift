// © GoodHatsLLC

import Foundation

/// Defers a synchronous callback onto the main actor.
///
/// Fire-and-forget — no handle is returned, so the caller cannot await or
/// cancel the deferred work. Use ``MainActorTaskRunner`` when teardown
/// visibility or test-time draining is required.
public func deferToMainActor(_ operation: @escaping @MainActor () -> Void) {
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      operation()
    }
  }
}
