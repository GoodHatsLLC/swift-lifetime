import Testing

@testable import Lifetime
@testable import LifetimeResources

#if canImport(SwiftUI)
  @testable import LifetimeSwiftUI
#endif

@Suite
struct SupportAndUITests {
  @Test
  func lazyResourceCachesAndResets() async throws {
    let builds = Counter()
    let resource = LazyResource {
      await builds.incrementAndGet()
    }

    let first = try await resource.get()
    let second = try await resource.get()
    await resource.reset()
    let third = try await resource.get()

    #expect(first == 1)
    #expect(second == 1)
    #expect(third == 2)
  }

  @Test
  func lazyResourceResetDiscardsSupersededInFlightResult() async throws {
    let builds = Counter()
    let firstBuildStarted = Continuation<Void>()
    let releaseFirst = Continuation<Void>()
    let cancellationObserved = Continuation<Void>()
    let resource = LazyResource<Int>(.detached) {
      let buildNumber = await builds.incrementAndGet()
      if buildNumber == 1 {
        try? firstBuildStarted.yield()
        return await withTaskCancellationHandler {
          await releaseFirst()
          return buildNumber
        } onCancel: {
          try? cancellationObserved.yield()
        }
      }
      return buildNumber
    }

    let first = Task {
      try await resource.get()
    }

    await firstBuildStarted()

    let reset = Task {
      await resource.reset()
    }

    await cancellationObserved()
    try releaseFirst.yield()
    await reset.value

    let second = try await resource.get()
    #expect(second == 2)

    do {
      _ = try await first.value
      Issue.record("Expected the superseded build to be invalidated by reset().")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected CancellationError from the superseded build, got \(error).")
    }

    let third = try await resource.get()
    #expect(third == 2)
  }

  @Test
  func lazyResourceCancelWaitsForInFlightBuildToFinish() async throws {
    let started = Continuation<Void>()
    let cancellationObserved = Continuation<Void>()
    let releaseBuild = Continuation<Void>()
    let probe = CancellationQuiescenceProbe()
    let resource = LazyResource<Int>(.detached) {
      try? started.yield()
      return await withTaskCancellationHandler {
        await releaseBuild()
        await probe.markBuildFinished()
        return 1
      } onCancel: {
        try? cancellationObserved.yield()
      }
    }

    let getter = Task {
      try await resource.get()
    }

    await started()

    let cancellation = Task {
      await resource.cancel()
      await probe.markCancelReturned()
    }

    await cancellationObserved()
    try releaseBuild.yield()
    await cancellation.value

    do {
      _ = try await getter.value
      Issue.record("Expected CancellationError from the cancelled build.")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected CancellationError from the cancelled build, got \(error).")
    }

    #expect(await probe.cancelReturnedBeforeBuildFinished == false)
  }

  @Test
  func lazyResourceResetWaitsForSupersededInFlightBuildToFinish() async throws {
    let builds = Counter()
    let started = Continuation<Void>()
    let cancellationObserved = Continuation<Void>()
    let releaseBuild = Continuation<Void>()
    let probe = CancellationQuiescenceProbe()
    let resource = LazyResource<Int>(.detached) {
      let buildNumber = await builds.incrementAndGet()
      guard buildNumber == 1 else {
        return buildNumber
      }

      try? started.yield()
      return await withTaskCancellationHandler {
        await releaseBuild()
        await probe.markBuildFinished()
        return buildNumber
      } onCancel: {
        try? cancellationObserved.yield()
      }
    }

    let first = Task {
      try await resource.get()
    }

    await started()

    let reset = Task {
      await resource.reset()
      await probe.markCancelReturned()
    }

    await cancellationObserved()
    try releaseBuild.yield()
    await reset.value

    do {
      _ = try await first.value
      Issue.record("Expected CancellationError from the reset build.")
    } catch is CancellationError {
    } catch {
      Issue.record("Expected CancellationError from the reset build, got \(error).")
    }

    #expect(await probe.cancelReturnedBeforeBuildFinished == false)
    #expect(try await resource.get() == 2)
  }

  @Test
  func scopeInvalidatorIsReusableAfterCancelAll() async {
    let invalidator = ScopeInvalidator()
    let invalidated = Continuation<Void>()

    await invalidator.schedule(trigger: .background, delay: .seconds(1)) {
      try? invalidated.yield()
    }
    await invalidator.cancelAll()

    await invalidator.schedule(trigger: .manual, delay: .zero) {
      try? invalidated.yield()
    }

    await invalidated()

    await invalidator.cancelAll()
  }

  @Test
  func delegatedScopeCancelsSupervisedTasksWhenParentCancels() async throws {
    let root = Scope.root(cancellationPolicy: .parallelUnordered)
    let child = try await root.delegate()
    let cancellations = Counter()
    let cancelled = Continuation<Void>()

    await child.supervise {
      await withTaskCancellationHandler {
        await cancelled()
      } onCancel: {
        try? cancelled.yield()
      }
      await cancellations.increment()
    }

    await root.cancel()
    await cancelled()

    #expect(await cancellations.value == 1)
  }

  @Test
  func delegateThrowsWhenParentIsAlreadyCancelled() async {
    let root = Scope.root()
    await root.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await root.delegate()
    }
  }

  @Test
  @MainActor
  func resourceObserverPublishesReadyState() async {
    let observer = ResourceObserver(LazyResource { 42 })
    let handle = observer.start()

    #expect(
      await waitUntil(timeout: .seconds(1)) {
        switch observer.state {
        case .ready(let value):
          return value == 42
        case .loading, .failed:
          return false
        }
      }
    )

    await handle.cancel()
  }

  #if canImport(SwiftUI)
    @Test
    @MainActor
    func componentMountInvalidatesMountedComponent() async {
      let shutdowns = Counter()
      let mount = ComponentMount<MountedTestComponent>()

      mount.mount(
        MountedTestComponent {
          await shutdowns.increment()
        }
      )

      await mount.invalidate()

      #expect(mount.component == nil)
      #expect(mount.epoch == 1)
      #expect(await shutdowns.value == 1)
    }
  #endif

  private actor Counter {
    private var storage = 0

    var value: Int {
      storage
    }

    func increment() {
      storage += 1
    }

    func incrementAndGet() -> Int {
      storage += 1
      return storage
    }
  }

  private actor CancellationQuiescenceProbe {
    private var buildFinished = false
    private(set) var cancelReturnedBeforeBuildFinished = false

    func markBuildFinished() {
      buildFinished = true
    }

    func markCancelReturned() {
      if !buildFinished {
        cancelReturnedBeforeBuildFinished = true
      }
    }
  }

  #if canImport(SwiftUI)
    private struct MountedTestComponent: MountInvalidatableComponent {
      let shutdownAction: @Sendable () async -> Void

      func shutdown() async {
        await shutdownAction()
      }
    }
  #endif
}
