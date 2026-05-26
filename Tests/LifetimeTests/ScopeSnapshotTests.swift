import Foundation
import Testing

@testable import Lifetime

@Suite
struct ScopeSnapshotTests {
  @Test
  func snapshotOfEmptyRootIsRunningWithNoEntries() {
    let scope = Scope.root()
    let snapshot = scope.snapshot()

    #expect(snapshot.phase == .running)
    #expect(snapshot.children.isEmpty)
    #expect(snapshot.cancellationActions.isEmpty)
    #expect(snapshot.id == scope.id)
  }

  @Test
  func snapshotReflectsRegisteredCancellationActions() async throws {
    let scope = Scope.root()
    _ = try await scope.start("DB") {
      "connection"
    } destroy: { _ in
    }
    _ = try await scope.start("Cache") {
      "cache"
    } destroy: { _ in
    }

    let snapshot = scope.snapshot()
    #expect(snapshot.cancellationActions.count == 2)
    #expect(snapshot.cancellationActions.map(\.name) == ["DB", "Cache"])
    #expect(snapshot.children.isEmpty)

    await scope.cancel()
  }

  @Test
  func snapshotPreservesRegistrationOrderAcrossChildrenAndResources() async throws {
    let scope = Scope.root()
    let child1 = try await scope.child { _ in () }
    _ = try await scope.start("Resource") {
      "value"
    } destroy: { _ in
    }
    let child2 = try await scope.child { _ in () }
    // Keep both Child values alive so the parent's weak refs remain populated.
    _ = (child1, child2)

    let snapshot = scope.snapshot()
    #expect(snapshot.children.count == 2)
    #expect(snapshot.cancellationActions.count == 1)
    #expect(snapshot.cancellationActions[0].name == "Resource")

    await scope.cancel()
  }

  @Test
  func snapshotReportsReleasedChildrenWithNilSubsnapshot() async throws {
    let scope = Scope.root()
    // The returned Child was not bound, so the child scope has no strong
    // owner. The parent's weak reference goes nil; the bookkeeping entry
    // remains until pruneChildren runs (which only happens during
    // makeChildScope, not start). The snapshot is honest about this:
    // the entry appears but its `snapshot` field is nil.
    _ = try await scope.child { _ in () }

    let snapshot = scope.snapshot()
    #expect(snapshot.children.count == 1)
    let entry = try #require(snapshot.children.first)
    #expect(entry.snapshot == nil)

    await scope.cancel()
  }

  @Test
  func snapshotRecursesIntoChildren() async throws {
    let scope = Scope.root()
    let child = try await scope.child { childScope in
      _ = try await childScope.start("LeafResource") {
        "leaf"
      } destroy: { _ in
      }
      return ()
    }

    let snapshot = scope.snapshot()
    #expect(snapshot.children.count == 1)
    let childEntry = try #require(snapshot.children.first)
    let childSnapshot = try #require(childEntry.snapshot)
    #expect(childSnapshot.phase == .running)
    #expect(childSnapshot.cancellationActions.count == 1)
    #expect(childSnapshot.cancellationActions[0].name == "LeafResource")
    #expect(childSnapshot.id == child.scope.id)

    await scope.cancel()
  }

  @Test
  func snapshotOfCancelledScopeReportsCancelledPhaseWithNoEntries() async throws {
    let scope = Scope.root()
    _ = try await scope.start("R") {
      "v"
    } destroy: { _ in
    }
    await scope.cancel()

    let snapshot = scope.snapshot()
    #expect(snapshot.phase == .cancelled)
    #expect(snapshot.children.isEmpty)
    #expect(snapshot.cancellationActions.isEmpty)
  }
}
