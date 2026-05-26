import Foundation
import Synchronization
import Testing

@testable import Lifetime

@Suite
struct DetachedLaunchPolicyTests {
  /// A cancellation-aware detached builder should unwind when the caller's
  /// task is cancelled while awaiting the builder.
  @Test
  func detachedBuilderUnwindsWhenCallerTaskIsCancelled() async throws {
    let started = AsyncSignalBox()
    let observedCancellation = AsyncSignalBox()

    let outer = Task {
      try await Scope.withRoot { scope in
        do {
          _ = try await scope.start("DetachedWork", launchPolicy: .detached) {
            started.signal()
            // Cooperative wait: throws CancellationError on cancel.
            try await Task.sleep(for: .seconds(60))
            return "should not reach here"
          }
          Issue.record("Expected detached builder to be cancelled.")
        } catch is CancellationError {
          observedCancellation.signal()
        }
      }
    }

    await started.wait()
    outer.cancel()
    await observedCancellation.wait()

    try await outer.value
  }

  /// When the caller's task is cancelled, the detached `Task` returned by
  /// `Task.detached` is itself cancelled — confirmed by observing
  /// `Task.isCancelled` inside the builder.
  @Test
  func detachedTaskObservesIsCancelledAfterCallerCancellation() async throws {
    let started = AsyncSignalBox()
    let isCancelledFlag = Atomic<Bool>(false)
    let builderFinished = AsyncSignalBox()

    let outer = Task {
      _ = try? await Scope.withRoot { scope in
        _ = try await scope.start("Probe", launchPolicy: .detached) { () -> Void in
          started.signal()
          // Spin with cooperative checks; record whether we observed
          // cancellation before exiting.
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
          }
          isCancelledFlag.store(true, ordering: .sequentiallyConsistent)
          builderFinished.signal()
        }
      }
    }

    await started.wait()
    outer.cancel()
    await builderFinished.wait()
    _ = await outer.value

    let observed = isCancelledFlag.load(ordering: .sequentiallyConsistent)
    #expect(observed)
  }
}

/// Minimal Sendable one-shot signal used by the tests above.
private final class AsyncSignalBox: Sendable {
  private let continuation = Continuation<Void>()

  func signal() {
    try? continuation.yield()
  }

  func wait() async {
    await continuation()
  }
}
