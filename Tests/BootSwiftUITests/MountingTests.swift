import Testing

@testable import Boot
@testable import BootSwiftUI

@MainActor
@Suite
struct MountingTests {
  @Test
  func declarativeMountPublishesOnlyAfterComponentResolves() async throws {
    let root = Scope.root()
    let started = Continuation<Void>()
    let release = Continuation<Void>()
    let source = try root.components.shared(
      DelayedDependency.self,
      input: .init(started: started, release: release, cancelled: nil)
    )

    let mounting = Mounting(source: source)

    await started()
    #expect(mounting.phase == .mounting)
    #expect(mounting.component == nil)

    try release.yield()
    try await eventuallyMounted(mounting)
    #expect(mounting.isMounted)
    let component = try #require(mounting.component)
    #expect(try await component.exports.value.get() == "ready")
  }

  @Test
  func directReplacementCancelsOldBeforePublishingNew() async throws {
    let root = Scope.root()
    let factory = try root.components.factory(DelayedDependency.self)
    let firstProbe = CancelProbe()
    let secondProbe = CancelProbe()
    let first = try await factory.make(.init(cancelled: firstProbe))
    let second = try await factory.make(.init(cancelled: secondProbe))
    let mounting = Mounting<DelayedDependency>()

    await mounting.replace(with: first)
    #expect(await firstProbe.count == 0)

    await mounting.replace(with: second)

    #expect(await firstProbe.count == 1)
    #expect(await secondProbe.count == 0)
    let component = try #require(mounting.component)
    #expect(try await component.exports.value.get() == "ready")
  }

  @Test
  func sourceReplacementCancelsOldBeforeNewBecomesVisible() async throws {
    let root = Scope.root()
    let firstProbe = CancelProbe()
    let secondProbe = CancelProbe()
    let first = try root.components.shared(DelayedDependency.self, input: .init(cancelled: firstProbe))
    let second = try root.components.shared(DelayedDependency.self, input: .init(cancelled: secondProbe))
    let mounting = Mounting(source: first)

    try await eventuallyMounted(mounting)
    let initial = try #require(mounting.component)
    #expect(try await initial.exports.value.get() == "ready")

    mounting.bindSource(second)
    try await eventuallyMounted(mounting)

    #expect(await firstProbe.count == 1)
    #expect(await secondProbe.count == 0)
    let replaced = try #require(mounting.component)
    #expect(try await replaced.exports.value.get() == "ready")
  }

  @Test
  func unmountCancelsAndClearsCurrentComponent() async throws {
    let root = Scope.root()
    let probe = CancelProbe()
    let factory = try root.components.factory(DelayedDependency.self)
    let component = try await factory.make(.init(cancelled: probe))
    let mounting = Mounting<DelayedDependency>()

    await mounting.replace(with: component)
    await mounting.unmount()

    #expect(mounting.phase == .idle)
    #expect(mounting.component == nil)
    #expect(await probe.count == 1)
  }

  @Test
  func failedMountLeavesNoLiveComponentBehind() async throws {
    let root = Scope.root()
    let source = try root.components.shared(FailingDependency.self, input: ())
    let mounting = Mounting(source: source)

    try await eventually {
      mounting.phase == .failed
    }

    #expect(mounting.component == nil)
    #expect(mounting.error is Failure)
  }

  @Test
  func projectedMountingReferenceCanBePassedThroughAnotherType() async throws {
    let root = Scope.root()
    let source = try root.components.shared(DelayedDependency.self, input: .init())
    let mounting = Mounting(source: source)
    let holder = Holder(mounting: mounting)

    try await eventuallyMounted(mounting)

    #expect(holder.mounting === mounting)
    #expect(holder.mounting.isMounted)
  }

  private func eventuallyMounted(_ mounting: Mounting<DelayedDependency>) async throws {
    try await eventually {
      mounting.component != nil && mounting.phase == .mounted
    }
  }

  private func eventually(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition() {
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for condition.")
  }
}

private struct Holder<D: Dependency> {
  let mounting: Mounting<D>
}

private actor CancelProbe {
  private(set) var count: Int = 0

  func markCancelled() {
    count += 1
  }
}

private struct DelayedDependency: Dependency {
  struct Input: Sendable {
    var started: Continuation<Void>? = nil
    var release: Continuation<Void>? = nil
    var cancelled: CancelProbe? = nil
  }

  let value: Scoped<String>

  init(with requirement: Input, in scope: Scope) async throws {
    if let started = requirement.started {
      try! started.yield()
    }
    if let release = requirement.release {
      await release()
    }
    if let cancelled = requirement.cancelled {
      try scope.onShutdown {
        await cancelled.markCancelled()
      }
    }
    value = try scope.entities.instance("ready")
  }
}

private struct FailingDependency: Dependency {
  init(with requirement: (), in scope: Scope) async throws {
    _ = scope
    throw Failure.expected
  }
}

private enum Failure: Error {
  case expected
}
