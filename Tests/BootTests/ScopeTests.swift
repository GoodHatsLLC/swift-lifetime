import Foundation
import Testing

@testable import Boot

@Suite
struct ScopeTests {
  @Test
  func lazySharedResolvesOnce() async throws {
    let counter = Counter()
    let scope = Scope()

    let value = try scope.entities.shared {
      await counter.increment()
      return await counter.value
    }

    let first = try await value.get()
    let second = try await value.get()

    #expect(first == 1)
    #expect(second == 1)
    #expect(await counter.value == 1)
  }

  @Test
  func builderReturnsNewValueEachTime() async throws {
    let scope = Scope()
    let dependency = try scope.entities.factory {
      UUID()
    }

    let first = try await dependency.make()
    let second = try await dependency.make()
    #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
    #expect(first.value != second.value)
  }

  @Test
  func detectsDependencyCyclesBetweenTypedHandles() async throws {
    let scope = Scope()
    let boxA = DependencyBox<Int>()
    let boxB = DependencyBox<Int>()

    let a = try scope.entities.shared {
      let b = await boxB.read()
      return try await b.get()
    }
    let b = try scope.entities.shared {
      let a = await boxA.read()
      return try await a.get()
    }

    await boxA.write(a)
    await boxB.write(b)

    do {
      _ = try await a.get()
      Issue.record("Expected dependency cycle.")
    } catch let error as DependencyResolutionError {
      switch error {
      case .dependencyCycle(let path):
        #expect(path.count >= 2)
      default:
        Issue.record("Unexpected error: \(error)")
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func cyclePathUsesDependencyNamesWhenProvided() async throws {
    let scope = Scope()
    let boxA = DependencyBox<Int>()
    let boxB = DependencyBox<Int>()

    let settings = try scope.entities.shared(name: "Settings") {
      let profile = await boxB.read()
      return try await profile()
    }
    let profile = try scope.entities.shared(name: "Profile") {
      let settings = await boxA.read()
      return try await settings()
    }

    await boxA.write(settings)
    await boxB.write(profile)

    do {
      _ = try await settings()
      Issue.record("Expected dependency cycle.")
    } catch let error as DependencyResolutionError {
      switch error {
      case .dependencyCycle(let path):
        #expect(path.contains(where: { $0.contains("Settings") }))
        #expect(path.contains(where: { $0.contains("Profile") }))
      default:
        Issue.record("Unexpected error: \(error)")
      }
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func childCanUseParentDependencyHandleExplicitly() async throws {
    let root = Scope()
    let rootValue = try root.entities.instance(42)
    let child = try root.child()

    let childValue = try child.entities.factory {
      try await rootValue.get()
    }

    let resolved = try await childValue.make()
    #expect(resolved.value == 42)
  }

  @Test
  func shutdownInvalidatesDependenciesAndChildren() async throws {
    let root = Scope()
    let rootValue = try root.entities.instance(1)
    let child = try root.child()
    let childValue = try child.entities.instance(2)

    _ = try await rootValue.get()
    _ = try await childValue.get()

    await root.cancel()

    await expectScopeShutdown(rootValue)
    await expectScopeShutdown(childValue)

    do {
      _ = try child.entities.factory { 9 }
      Issue.record("Expected child scope shutdown error.")
    } catch let error {
      let error = try #require(error as? DependencyResolutionError)
      #expect(error == .scopeShutdown)
    }
  }

  @Test
  func shutdownCancelsInFlightlazySharedResolution() async throws {
    let started = Continuation<Void>()
    let scope = Scope()
    let value = try scope.entities.shared {
      try! started.yield()
      try await Task.sleep(for: .seconds(10))
      return 1
    }

    let task = Task {
      try await value.get()
    }

    await started()
    await scope.cancel()

    switch await task.result {
    case .success:
      Issue.record("Expected cancellation due to shutdown.")
    case .failure(let error):
      let isCancellation = error is CancellationError
      let isScopeShutdown = (error as? DependencyResolutionError) == .scopeShutdown
      #expect(isCancellation || isScopeShutdown)
    }
  }

  @Test
  func creatingBindingsAfterShutdownFails() async throws {
    let scope = Scope()
    await scope.cancel()

    do {
      _ = try scope.entities.shared { 1 }
      Issue.record("Expected scope shutdown error.")
    } catch let error {
      let error = try #require(error as? DependencyResolutionError)
      #expect(error == .scopeShutdown)
    }
  }

  @Test
  func onShutdownActionsRunOnce() async throws {
    let scope = Scope()
    let counter = Counter()

    try scope.onShutdown {
      await counter.increment()
    }

    await scope.cancel()
    await scope.cancel()

    #expect(await counter.value == 1)
  }

  @Test
  func adoptCancelsOnShutdown() async throws {
    let scope = Scope()
    let probe = CancelProbe()
    let cancellable = ProbeCancellable(probe: probe)
    try scope.onShutdown(cancel: cancellable)

    await scope.cancel()

    #expect(await probe.cancelCount == 1)
  }

  @Test
  func lazySharedTearDownRunsAfterResolvedShutdown() async throws {
    let scope = Scope()
    let counter = Counter()
    let dependency = try scope.entities.shared(.inherited, { 1 }) {
      await counter.increment()
    }

    _ = try await dependency.get()
    await scope.cancel()

    #expect(await counter.value == 1)
  }

  @Test
  func ownedHandlesCancelIndividually() async throws {
    let scope = Scope()
    let tearDowns = Counter()
    let dependency = try scope.entities.factory {
      UUID()
    } tearDown: { _ in
      await tearDowns.increment()
    }

    let first = try await dependency.make()
    let second = try await dependency.make()
    await first.cancel()
    await second.cancel()

    #expect(await tearDowns.value == 2)
  }

  @Test
  func scopeShutdownCancelsAdoptedOwnedHandlesOnly() async throws {
    let scope = Scope()
    let tearDowns = Counter()
    let dependency = try scope.entities.factory {
      UUID()
    } tearDown: { _ in
      await tearDowns.increment()
    }

    let adopted = try await dependency.make()
    let retained = try await dependency.make()
    try scope.onShutdown(cancel: adopted)

    await scope.cancel()

    #expect(await tearDowns.value == 1)
    _ = retained
  }

  @Test
  func ownedHandleCancelsOnDeinitWhenUnadopted() async throws {
    let scope = Scope()
    let cancelled = Continuation<Void>()
    let dependency = try scope.entities.factory {
      UUID()
    } tearDown: { _ in
      try? cancelled.yield()
    }

    do {
      _ = try await dependency.make()
    }

    await cancelled()
    await scope.cancel()
  }

  @Test
  func detachedFactoryCycleDetectionPreservesNames() async throws {
    enum Sentinel: Error {
      case recursionLimitReached
    }

    let scope = Scope()
    let calls = Counter()
    let box = FactoryBox<UUID>()

    let looping = try scope.entities.factory(.detached, name: "LoopFactory") {
      let currentCount = await calls.incrementAndRead()
      guard currentCount < 10 else {
        throw Sentinel.recursionLimitReached
      }
      let factory = await box.read()
      let owned = try await factory.make()
      return owned.value
    }

    await box.write(looping)

    do {
      _ = try await looping.make()
      Issue.record("Expected dependency cycle.")
    } catch let error as DependencyResolutionError {
      switch error {
      case .dependencyCycle(let path):
        #expect(path.contains(where: { $0.contains("LoopFactory") }))
      default:
        Issue.record("Unexpected error: \(error)")
      }
    } catch Sentinel.recursionLimitReached {
      Issue.record("Detached dependency resolution lost its cycle context.")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func detachedSharedResolutionKeepsDependencyContext() async throws {
    let scope = Scope()
    let detached = try scope.entities.shared(.detached, name: "DetachedShared") {
      Scope.currentDependencyResolutionLabels()
    }

    let labels = try await detached.get()
    #expect(labels.contains(where: { $0.contains("DetachedShared") }))
  }

  @Test
  func shutdownDuringDetachedFactoryBuildTearsDownBuiltValue() async throws {
    let scope = Scope()
    let started = Continuation<Void>()
    let release = Continuation<Void>()
    let tearDowns = Counter()
    let dependency = try scope.entities.factory(.detached) {
      try! started.yield()
      await release()
      return UUID()
    } tearDown: { _ in
      await tearDowns.increment()
    }

    let task = Task {
      try await dependency.make()
    }

    await started()
    await scope.cancel()
    try! release.yield()

    switch await task.result {
    case .success:
      Issue.record("Expected scope shutdown while building detached handle.")
    case .failure(let error):
      let shutdown = try #require(error as? DependencyResolutionError)
      #expect(shutdown == .scopeShutdown)
    }

    #expect(await tearDowns.value == 1)
  }

  private actor Counter {
    private(set) var value: Int = 0

    func increment() {
      value += 1
    }

    func incrementAndRead() -> Int {
      value += 1
      return value
    }
  }

  private actor DependencyBox<Value: Sendable> {
    private var dependency: Scoped<Value>?

    func write(_ dependency: Scoped<Value>) {
      self.dependency = dependency
    }

    func read() -> Scoped<Value> {
      dependency!
    }
  }

  private actor FactoryBox<Value: Sendable> {
    private var factory: EntityFactory<Value>?

    func write(_ factory: EntityFactory<Value>) {
      self.factory = factory
    }

    func read() -> EntityFactory<Value> {
      factory!
    }
  }

  private actor CancelProbe {
    private(set) var cancelCount: Int = 0

    func markCancelled() {
      cancelCount += 1
    }
  }

  private struct ProbeCancellable: CancellableType {
    let probe: CancelProbe

    func cancel() async {
      await probe.markCancelled()
    }
  }

  private func expectScopeShutdown<T: Sendable>(_ dependency: Scoped<T>) async {
    do {
      _ = try await dependency.get()
      Issue.record("Expected scope shutdown error.")
    } catch let error as DependencyResolutionError {
      #expect(error == .scopeShutdown)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
