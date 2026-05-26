import Foundation
import Testing

@testable import Lifetime

@Suite
struct ScopeTests {
  @Test
  func withRootCancelsScopeOnSuccess() async throws {
    let tearDowns = Counter()

    let result = try await Scope.withRoot { root in
      _ = try await root.start("RootResource") {
        UUID()
      } destroy: { _ in
        await tearDowns.increment()
      }
      return "ok"
    }

    #expect(result == "ok")
    #expect(await tearDowns.value == 1)
  }

  @Test
  func withRootCancelsScopeOnFailure() async throws {
    let tearDowns = Counter()

    do {
      _ = try await Scope.withRoot { root in
        _ = try await root.start("RootResource") {
          UUID()
        } destroy: { _ in
          await tearDowns.increment()
        }
        throw TestFailure.expected
      }
      Issue.record("Expected withRoot to rethrow the operation error.")
    } catch let error {
      let failure = try #require(error as? TestFailure)
      #expect(failure == .expected)
    }

    #expect(await tearDowns.value == 1)
  }

  @Test
  func withRootAcceptsParallelCancellationPolicy() async throws {
    let entered = StartBarrier(expectedCount: 2)
    let release = Continuation<Void>()

    let task = Task {
      try await Scope.withRoot(cancellationPolicy: .parallelUnordered) { root in
        try root.onCancel {
          await entered.arrive()
          await release()
        }
        try root.onCancel {
          await entered.arrive()
          await release()
        }
      }
    }

    await entered.waitUntilAllArrived()

    try? release.yield()
    _ = try await task.value
  }

  @Test
  func withLifetimeCancelsHandleOnSuccess() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    let value = try await scope.withLifetime(
      make: {
        Resource(value: "ready") { _ in
          await tearDowns.increment()
        }
      },
      { resource in
        resource.value
      }
    )

    #expect(value == "ready")
    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func withLifetimeCancelsHandleOnFailure() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    do {
      _ = try await scope.withLifetime(
        make: {
          Resource(value: UUID()) { _ in
            await tearDowns.increment()
          }
        },
        { _ in
          throw TestFailure.expected
        }
      )
      Issue.record("Expected withLifetime to rethrow the operation error.")
    } catch let error {
      let failure = try #require(error as? TestFailure)
      #expect(failure == .expected)
    }

    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func withResourceCancelsResourceOnSuccess() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    let greeting = try await scope.withResource(
      "Greeting",
      create: {
        "hello"
      },
      destroy: { _ in
        await tearDowns.increment()
      },
      { value in
        value.uppercased()
      }
    )

    #expect(greeting == "HELLO")
    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func withResourceFactoryCancelsResourceOnFailure() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()
    let makeResource = try scope.resourceFactory(name: "Temp") {
      UUID()
    } destroy: { _ in
      await tearDowns.increment()
    }

    do {
      _ = try await scope.withResource(makeResource, input: ()) { _ in
        throw TestFailure.expected
      }
      Issue.record("Expected withResource(factory:) to rethrow the operation error.")
    } catch let error {
      let failure = try #require(error as? TestFailure)
      #expect(failure == .expected)
    }

    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func scopeCancelWaitsForWithResourceTeardown() async throws {
    let scope = Scope.root()
    let started = Continuation<Void>()
    let releaseOperation = Continuation<Void>()
    let events = EventLog()

    let task = Task {
      try await scope.withResource(
        "Transient",
        create: {
          UUID()
        },
        destroy: { _ in
          await events.record("resource:destroy")
        }
      ) { _ in
        await events.record("operation:start")
        try? started.yield()
        await releaseOperation()
        await events.record("operation:end")
      }
    }

    await started()

    await scope.cancel()
    await events.record("cancel:return")

    let snapshotAtCancelReturn = await events.snapshot()
    let destroyIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "resource:destroy"))
    let cancelReturnIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "cancel:return"))
    #expect(destroyIndex < cancelReturnIndex)
    #expect(!snapshotAtCancelReturn.contains("operation:end"))

    try? releaseOperation.yield()
    _ = try await task.value
  }

  @Test
  func scopeCancelWaitsForWithResourceFactoryTeardown() async throws {
    let scope = Scope.root()
    let started = Continuation<Void>()
    let releaseOperation = Continuation<Void>()
    let events = EventLog()
    let makeResource = try scope.resourceFactory(name: "TransientFactory") {
      UUID()
    } destroy: { _ in
      await events.record("resource:destroy")
    }

    let task = Task {
      try await scope.withResource(makeResource, input: ()) { _ in
        await events.record("operation:start")
        try? started.yield()
        await releaseOperation()
        await events.record("operation:end")
      }
    }

    await started()

    await scope.cancel()
    await events.record("cancel:return")

    let snapshotAtCancelReturn = await events.snapshot()
    let destroyIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "resource:destroy"))
    let cancelReturnIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "cancel:return"))
    #expect(destroyIndex < cancelReturnIndex)
    #expect(!snapshotAtCancelReturn.contains("operation:end"))

    try? releaseOperation.yield()
    _ = try await task.value
  }

  @Test
  func scopeCancelWaitsForStartTeardown() async throws {
    let scope = Scope.root()
    let started = Continuation<Void>()
    let releaseCreate = Continuation<Void>()
    let events = EventLog()

    let task = Task { () -> Result<String, any Error> in
      do {
        let value = try await scope.start(
          "Transient",
          create: {
            try? started.yield()
            await releaseCreate()
            return "ready"
          },
          destroy: { _ in
            await events.record("resource:destroy")
          }
        )
        return .success(value)
      } catch {
        return .failure(error)
      }
    }

    await started()

    let cancellation = Task {
      await scope.cancel()
      await events.record("cancel:return")
    }

    try? releaseCreate.yield()
    await cancellation.value

    let snapshotAtCancelReturn = await events.snapshot()
    let destroyIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "resource:destroy"))
    let cancelReturnIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "cancel:return"))
    #expect(destroyIndex < cancelReturnIndex)

    switch await task.value {
    case .success:
      Issue.record("Expected scope cancellation while starting a scope-owned resource.")
    case .failure(let error):
      let scopeError = try #require(error as? ScopeError)
      #expect(scopeError == .cancelled())
    }
  }

  @Test
  func scopeCancelWaitsForStartFromFactoryTeardown() async throws {
    let scope = Scope.root()
    let started = Continuation<Void>()
    let releaseCreate = Continuation<Void>()
    let events = EventLog()
    let makeResource = try! scope.resourceFactory(name: "TransientFactory") {
      try? started.yield()
      await releaseCreate()
      return "ready"
    } destroy: { _ in
      await events.record("resource:destroy")
    }

    let task = Task { () -> Result<String, any Error> in
      do {
        return .success(try await scope.start(makeResource, input: ()))
      } catch {
        return .failure(error)
      }
    }

    await started()

    let cancellation = Task {
      await scope.cancel()
      await events.record("cancel:return")
    }

    try? releaseCreate.yield()
    await cancellation.value

    let snapshotAtCancelReturn = await events.snapshot()
    let destroyIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "resource:destroy"))
    let cancelReturnIndex = try #require(snapshotAtCancelReturn.firstIndex(of: "cancel:return"))
    #expect(destroyIndex < cancelReturnIndex)

    switch await task.value {
    case .success:
      Issue.record("Expected scope cancellation while starting from a resource factory.")
    case .failure(let error):
      let scopeError = try #require(error as? ScopeError)
      #expect(scopeError == .cancelled())
    }
  }

  @Test
  func withChildCancelsChildOnSuccess() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    let token = try await scope.withChild(
      name: "Session",
      input: "Avery",
      build: { userName, child in
        try child.onCancel {
          await tearDowns.increment()
        }
        return SessionExports(
          userName: userName,
          token: "token-\(userName)"
        )
      },
      { child in
        child.exports.token
      }
    )

    #expect(token == "token-Avery")
    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func withChildFactoryCancelsChildOnFailure() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()
    let makeSession = try scope.childFactory(name: "Session") { (userName: String, child: Scope) in
      try child.onCancel {
        await tearDowns.increment()
      }
      return SessionExports(
        userName: userName,
        token: "token-\(userName)"
      )
    }

    do {
      _ = try await scope.withChild(makeSession, input: "Avery") { _ in
        throw TestFailure.expected
      }
      Issue.record("Expected withChild(factory:) to rethrow the operation error.")
    } catch let error {
      let failure = try #require(error as? TestFailure)
      #expect(failure == .expected)
    }

    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func withChildScopeCancelsEphemeralScopeOnReturn() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    let result = try await scope.withChildScope(name: "Job") { child in
      try child.onCancel {
        await tearDowns.increment()
      }
      return "done"
    }

    #expect(result == "done")
    #expect(await tearDowns.value == 1)

    await scope.cancel()
  }

  @Test
  func resourceFactoryCreatesDistinctResources() async throws {
    let scope = Scope.root()
    let makeIdentifier = try scope.resourceFactory {
      UUID()
    }

    let first = try await makeIdentifier.make()
    let second = try await makeIdentifier.make()

    #expect(first.value != second.value)

    await first.cancel()
    await second.cancel()
    await scope.cancel()
  }

  @Test
  func startOwnsResourceForScopeLifetime() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()

    _ = try await scope.start("SessionCache") {
      UUID()
    } destroy: { _ in
      await tearDowns.increment()
    }

    await scope.cancel()

    #expect(await tearDowns.value == 1)
  }

  @Test
  func startFromFactoryAdoptsCreatedResource() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()
    let makeCache = try scope.resourceFactory(name: "Cache") { (name: String) in
      "cache-\(name)"
    } destroy: { _ in
      await tearDowns.increment()
    }

    let cache = try await scope.start(makeCache, input: "session")
    #expect(cache == "cache-session")

    await scope.cancel()

    #expect(await tearDowns.value == 1)
  }

  @Test
  func startNameAppearsInScopeDescription() async throws {
    let scope = Scope.root()

    _ = try await scope.start("SessionCache") {
      UUID()
    }

    #expect(String(describing: scope).contains("SessionCache"))

    await scope.cancel()
  }

  @Test
  func startAfterScopeCancelFailsWithoutCreatingResource() async throws {
    let scope = Scope.root()
    let creates = Counter()

    await scope.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await scope.start("Late") {
        await creates.increment()
        return "value"
      }
    }

    #expect(await creates.value == 0)
  }

  @Test
  func startFromFactoryAfterScopeCancelFailsWithoutCreatingResource() async throws {
    let scope = Scope.root()
    let creates = Counter()
    let makeResource = try scope.resourceFactory(name: "Late") { (label: String) in
      await creates.increment()
      return label
    }

    await scope.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await scope.start(makeResource, input: "value")
    }

    #expect(await creates.value == 0)
  }

  @Test
  func startDuringConcurrentScopeCancelCleansUpResource() async throws {
    let attempts = 48
    let scope = Scope.root()
    let started = StartBarrier(expectedCount: attempts)
    let release = Continuation<Void>()
    let tearDowns = Counter()

    let tasks = (0..<attempts).map { index in
      Task { () -> Result<String, any Error> in
        do {
          let value = try await scope.start("Stress-\(index)") {
            await started.arrive()
            await release()
            return "value-\(index)"
          } destroy: { _ in
            await tearDowns.increment()
          }
          return .success(value)
        } catch {
          return .failure(error)
        }
      }
    }

    await started.waitUntilAllArrived()

    let cancellation = Task {
      await scope.cancel()
    }

    try release.yield()
    await cancellation.value

    var successes = 0
    var failures = 0

    for task in tasks {
      switch await task.value {
      case .success:
        successes += 1
      case .failure(let error):
        failures += 1
        let scopeError = try #require(error as? ScopeError)
        #expect(scopeError == .cancelled())
      }
    }

    #expect(successes + failures == attempts)
    #expect(await tearDowns.value == attempts)
  }

  @Test
  func childFactoryCreatesDistinctChildScopes() async throws {
    let root = Scope.root()
    let tearDowns = Counter()
    let makeSession = try root.childFactory(name: "Session") {
      (
        userName: String,
        session: Scope
      ) in
      let token = try await session.start("Token") {
        "token-\(userName)"
      } destroy: { _ in
        await tearDowns.increment()
      }

      return SessionExports(
        userName: userName,
        token: token
      )
    }

    let first = try await makeSession.make("one")
    let second = try await makeSession.make("two")

    #expect(first.scope.id != second.scope.id)
    #expect(first.exports.userName == "one")
    #expect(second.exports.userName == "two")
    #expect(first.exports.token == "token-one")
    #expect(second.exports.token == "token-two")

    await first.cancel()
    await second.cancel()
    await root.cancel()

    #expect(await tearDowns.value == 2)
  }

  @Test
  func resourceFactoryNamePropagatesToHandlesAndDescriptions() async throws {
    let scope = Scope.root()
    let makeCache = try scope.resourceFactory(name: "Cache") {
      UUID()
    }

    #expect(makeCache.name == "Cache")
    #expect(String(describing: makeCache).contains("Cache"))

    let cache = try await makeCache.make()
    #expect(cache.name == "Cache")
    #expect(String(describing: cache).contains("Cache"))

    try scope.adopt(cache)

    #expect(String(describing: scope).contains("Cache"))

    await scope.cancel()
  }

  @Test
  func childFactoryNamePropagatesToHandlesAndDescriptions() async throws {
    let root = Scope.root()
    let makeSession = try root.childFactory(name: "Session") { (userName: String, _: Scope) in
      SessionExports(
        userName: userName,
        token: "token-\(userName)"
      )
    }

    #expect(makeSession.name == "Session")
    #expect(String(describing: makeSession).contains("Session"))

    let session = try await makeSession.make("one")
    #expect(session.name == "Session")
    #expect(String(describing: session).contains("Session"))
    #expect(String(describing: root).contains("Session"))

    await session.cancel()
    await root.cancel()
  }

  @Test
  func onCancelActionsRunOnce() async throws {
    let scope = Scope.root()
    let counter = Counter()

    try scope.onCancel {
      await counter.increment()
    }

    await scope.cancel()
    await scope.cancel()

    #expect(await counter.value == 1)
  }

  @Test
  func onCancelAfterScopeCancelThrows() async throws {
    let scope = Scope.root()

    await scope.cancel()

    #expect(throws: ScopeError.self) {
      try scope.onCancel {}
    }
  }

  @Test
  func adoptAfterScopeCancelThrows() async throws {
    let scope = Scope.root()

    await scope.cancel()

    #expect(throws: ScopeError.self) {
      try scope.adopt(Resource(value: "orphan"))
    }
  }

  @Test
  func cancelActionsUseSerialLIFOByDefault() async throws {
    let scope = Scope.root()
    let firstStarted = Continuation<Void>()
    let release = Continuation<Void>()
    let events = EventLog()

    try scope.onCancel {
      await events.record("first:start")
      try? firstStarted.yield()
      await release()
      await events.record("first:end")
    }

    try scope.onCancel {
      await events.record("second")
    }

    let cancellation = Task {
      await scope.cancel()
    }

    await firstStarted()
    #expect(await events.snapshot() == ["second", "first:start"])

    try? release.yield()
    await cancellation.value

    #expect(await events.snapshot() == ["second", "first:start", "first:end"])
  }

  @Test
  func cancelActionsCanEnterInParallelWhenPolicyIsParallelUnordered() async throws {
    let scope = Scope.root(cancellationPolicy: .parallelUnordered)
    let entered = StartBarrier(expectedCount: 2)
    let release = Continuation<Void>()

    try scope.onCancel {
      await entered.arrive()
      await release()
    }

    try scope.onCancel {
      await entered.arrive()
      await release()
    }

    let cancellation = Task {
      await scope.cancel()
    }

    await entered.waitUntilAllArrived()

    try? release.yield()
    await cancellation.value
  }

  @Test
  func siblingChildTeardownsUseSerialLIFOByDefault() async throws {
    let root = Scope.root()
    let firstStarted = Continuation<Void>()
    let release = Continuation<Void>()
    let events = EventLog()
    var children: [Child<Void>] = []

    let first = try await root.child { child in
      try child.onCancel {
        await events.record("first:start")
        try? firstStarted.yield()
        await release()
        await events.record("first:end")
      }
      return ()
    }
    children.append(first)

    let second = try await root.child { child in
      try child.onCancel {
        await events.record("second")
      }
      return ()
    }
    children.append(second)

    let cancellation = Task {
      await root.cancel()
    }

    await firstStarted()
    #expect(await events.snapshot() == ["second", "first:start"])

    try? release.yield()
    await cancellation.value

    #expect(await events.snapshot() == ["second", "first:start", "first:end"])
    _ = children
  }

  @Test
  func siblingChildTeardownsCanEnterInParallelWhenPolicyIsParallelUnordered() async throws {
    let root = Scope.root(cancellationPolicy: .parallelUnordered)
    let entered = StartBarrier(expectedCount: 2)
    let release = Continuation<Void>()
    var children: [Child<Void>] = []

    for _ in 0..<2 {
      let child = try await root.child { child in
        try child.onCancel {
          await entered.arrive()
          await release()
        }
        return ()
      }
      children.append(child)
    }

    let cancellation = Task {
      await root.cancel()
    }

    await entered.waitUntilAllArrived()

    try? release.yield()
    await cancellation.value
    _ = children
  }

  @Test
  func serialLIFOInterleavesChildrenAndCancelActionsInRegistrationOrder() async throws {
    // The unified registration log means serialLIFO tears down children
    // and cancel actions in strict reverse registration order, not
    // children-first-then-actions. Order entries deliberately so the
    // children-first ordering would produce a different sequence than
    // strict LIFO.
    let events = EventLog()
    let scope = Scope.root()

    let beforeChild = try await scope.child { childScope in
      try childScope.onCancel { await events.record("BeforeChild") }
      return ()
    }
    try scope.onCancel { await events.record("MiddleAction") }
    let afterChild = try await scope.child { childScope in
      try childScope.onCancel { await events.record("AfterChild") }
      return ()
    }
    try scope.onCancel { await events.record("LastAction") }

    await scope.cancel()

    // Strict LIFO across both kinds of entry:
    //   LastAction → afterChild → MiddleAction → beforeChild
    let snapshot = await events.snapshot()
    #expect(snapshot == ["LastAction", "AfterChild", "MiddleAction", "BeforeChild"])

    _ = (beforeChild, afterChild)
  }

  @Test
  func scopeCancelStaysSingleShotUnderConcurrentCalls() async throws {
    let rounds = 20

    for _ in 0..<rounds {
      let scope = Scope.root()
      let counter = Counter()

      try scope.onCancel {
        await counter.increment()
      }

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<64 {
          group.addTask {
            await scope.cancel()
          }
        }
        await group.waitForAll()
      }

      #expect(await counter.value == 1)
    }
  }

  @Test
  func adoptCancelsHandleOnScopeCancel() async throws {
    let scope = Scope.root()
    let tearDowns = Counter()
    let resource = Resource(value: UUID()) { _ in
      await tearDowns.increment()
    }

    try scope.adopt(resource)
    await scope.cancel()

    #expect(await tearDowns.value == 1)
  }

  @Test
  func resourceCancelStaysSingleShotUnderConcurrentCalls() async throws {
    let rounds = 20

    for _ in 0..<rounds {
      let tearDowns = Counter()
      let resource = Resource(value: UUID()) { _ in
        await tearDowns.increment()
      }

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<64 {
          group.addTask {
            await resource.cancel()
          }
        }
        await group.waitForAll()
      }

      #expect(await tearDowns.value == 1)
    }
  }

  @Test
  func childCancelStaysSingleShotUnderConcurrentCalls() async throws {
    let rounds = 20

    for _ in 0..<rounds {
      let root = Scope.root()
      let tearDowns = Counter()
      let child = try await root.child { child in
        try child.onCancel {
          await tearDowns.increment()
        }
        return ()
      }

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<64 {
          group.addTask {
            await child.cancel()
          }
        }
        await group.waitForAll()
      }

      #expect(await tearDowns.value == 1)
      await root.cancel()
    }
  }

  @Test
  func droppedChildCancelsOnDeinit() async throws {
    let root = Scope.root()
    let cancelled = Continuation<Void>()

    do {
      _ = try await root.child { child in
        try child.onCancel {
          try? cancelled.yield()
        }
        return ()
      }
    }

    await cancelled()
    await root.cancel()
  }

  @Test
  func droppedResourceCancelsOnDeinit() async throws {
    let scope = Scope.root()
    let cancelled = Continuation<Void>()
    let makeResource = try scope.resourceFactory {
      UUID()
    } destroy: { _ in
      try? cancelled.yield()
    }

    do {
      _ = try await makeResource.make()
    }

    await cancelled()
    await scope.cancel()
  }

  @Test
  func droppedScopeCancelsOnDeinit() async throws {
    let cancelled = Continuation<Void>()

    do {
      let scope = Scope.root()
      try scope.onCancel {
        try? cancelled.yield()
      }
    }

    await cancelled()
  }

  @Test
  func makingFromFactoryAfterScopeCancelFails() async throws {
    let scope = Scope.root()
    let makeResource = try scope.resourceFactory {
      UUID()
    }

    await scope.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await makeResource.make()
    }
  }

  @Test
  func resourceFactoryDoesNotKeepOwnerScopeAlive() async throws {
    let cancelled = Continuation<Void>()
    let makeResource: ResourceFactory<Void, UUID>
    weak var weakScope: Scope?

    do {
      let scope = Scope.root()
      weakScope = scope
      try scope.onCancel {
        try? cancelled.yield()
      }
      makeResource = try scope.resourceFactory {
        UUID()
      }
    }

    await cancelled()
    #expect(weakScope == nil)

    await #expect(throws: ScopeError.self) {
      _ = try await makeResource.make()
    }
  }

  @Test
  func buildingChildAfterScopeCancelFails() async throws {
    let scope = Scope.root()

    await scope.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await scope.child { _ in
        ()
      }
    }
  }

  @Test
  func makingChildFromFactoryAfterScopeCancelFails() async throws {
    let scope = Scope.root()
    let makeChild = try scope.childFactory(name: "AfterCancel") { _ in
      ()
    }

    await scope.cancel()

    await #expect(throws: ScopeError.self) {
      _ = try await makeChild.make()
    }
  }

  @Test
  func childFactoryDoesNotKeepOwnerScopeAlive() async throws {
    let cancelled = Continuation<Void>()
    let makeChild: ChildFactory<Void, Void>
    weak var weakScope: Scope?

    do {
      let scope = Scope.root()
      weakScope = scope
      try scope.onCancel {
        try? cancelled.yield()
      }
      makeChild = try scope.childFactory(name: "AfterDrop") { _ in
        ()
      }
    }

    await cancelled()
    #expect(weakScope == nil)

    await #expect(throws: ScopeError.self) {
      _ = try await makeChild.make()
    }
  }

  @Test
  func shutdownDuringDetachedResourceBuildTearsDownBuiltValue() async throws {
    let scope = Scope.root()
    let started = Continuation<Void>()
    let release = Continuation<Void>()
    let tearDowns = Counter()
    let makeResource = try scope.resourceFactory(.detached) {
      try! started.yield()
      await release()
      return UUID()
    } destroy: { _ in
      await tearDowns.increment()
    }

    let task = Task {
      try await makeResource.make()
    }

    await started()

    let cancellation = Task {
      await scope.cancel()
    }

    try! release.yield()
    await cancellation.value

    switch await task.result {
    case .success:
      Issue.record("Expected scope cancellation while building detached resource.")
    case .failure(let error):
      let scopeError = try #require(error as? ScopeError)
      #expect(scopeError == .cancelled())
    }

    #expect(await tearDowns.value == 1)
  }

  @Test
  func detachedFactoryDoesNotInheritTaskLocalValues() async throws {
    let scope = Scope.root()
    let makeInline = try scope.resourceFactory(.inline) {
      TaskLocals.label
    }
    let makeDetached = try scope.resourceFactory(.detached) {
      TaskLocals.label
    }

    let inline = try await TaskLocals.$label.withValue("parent") {
      try await makeInline.make()
    }
    let detached = try await TaskLocals.$label.withValue("parent") {
      try await makeDetached.make()
    }

    #expect(inline.value == "parent")
    #expect(detached.value == nil)

    await inline.cancel()
    await detached.cancel()
    await scope.cancel()
  }

  @Test
  func detachedFactoryPropagatesCallerTaskCancellation() async throws {
    // A detached factory still runs on a detached task — it doesn't
    // inherit the caller's isolation, priority, or task-local values —
    // but caller cancellation now propagates into that detached task
    // through the withTaskCancellationHandler around the await. The
    // builder observes Task.isCancelled once the caller's task is
    // cancelled.
    let scope = Scope.root()
    let started = Continuation<Void>()
    let release = Continuation<Void>()
    let makeDetached = try scope.resourceFactory(.detached) {
      try? started.yield()
      await release()
      return Task.isCancelled
    }

    let caller = Task {
      try await makeDetached.make()
    }

    await started()
    caller.cancel()
    try release.yield()

    let resource = try await caller.value
    #expect(resource.value == true)

    await resource.cancel()
    await scope.cancel()
  }

  @Test
  func concurrentInlineFactoryShutdownRaceCleansUpAllResources() async throws {
    try await assertConcurrentFactoryShutdownRaceCleansUpAllResources(launchPolicy: .inline)
  }

  @Test
  func concurrentDetachedFactoryShutdownRaceCleansUpAllResources() async throws {
    try await assertConcurrentFactoryShutdownRaceCleansUpAllResources(launchPolicy: .detached)
  }

  @Test
  func concurrentChildFactoryShutdownRaceCleansUpAllResources() async throws {
    let attempts = 48
    let root = Scope.root()
    let started = StartBarrier(expectedCount: attempts)
    let release = Continuation<Void>()
    let tearDowns = Counter()
    let makeSession = try root.childFactory(name: "Session") { (userName: String, child: Scope) in
      _ = try await child.start("Token") {
        await started.arrive()
        await release()
        return "token-\(userName)"
      } destroy: { _ in
        await tearDowns.increment()
      }

      return SessionExports(
        userName: userName,
        token: "export-\(userName)"
      )
    }

    let tasks = (0..<attempts).map { index in
      Task { () -> Result<Child<SessionExports>, any Error> in
        do {
          return .success(try await makeSession.make("user-\(index)"))
        } catch {
          return .failure(error)
        }
      }
    }

    await started.waitUntilAllArrived()

    let cancellation = Task {
      await root.cancel()
    }

    try release.yield()
    await cancellation.value

    var successes = 0
    var failures = 0

    for task in tasks {
      switch await task.value {
      case .success(let child):
        successes += 1
        await child.cancel()
      case .failure(let error):
        failures += 1
        let scopeError = try #require(error as? ScopeError)
        #expect(scopeError == .cancelled())
      }
    }

    #expect(successes + failures == attempts)
    #expect(await tearDowns.value == attempts)
  }

  @Test
  func cancelReleasesAdoptedResourceAfterCompletion() async throws {
    let scope = Scope.root()
    weak var weakResource: Resource<UUID>?

    do {
      let resource = Resource(value: UUID())
      weakResource = resource
      try scope.adopt(resource)
      await scope.cancel()
    }

    #expect(weakResource == nil)
  }

  private actor Counter {
    private(set) var value: Int = 0

    func increment() {
      value += 1
    }
  }

  private actor EventLog {
    private var entries: [String] = []

    func record(_ entry: String) {
      entries.append(entry)
    }

    func snapshot() -> [String] {
      entries
    }
  }

  private actor StartBarrier {
    private let expectedCount: Int
    private let allArrived = Continuation<Void>()
    private var arrivedCount: Int = 0

    init(expectedCount: Int) {
      self.expectedCount = expectedCount
    }

    func arrive() {
      arrivedCount += 1
      if arrivedCount == expectedCount {
        try? allArrived.yield()
      }
    }

    func waitUntilAllArrived() async {
      await allArrived()
    }
  }

  private struct SessionExports: Sendable {
    let userName: String
    let token: String
  }

  private enum TestFailure: Error, Equatable, Sendable {
    case expected
  }

  private enum TaskLocals {
    @TaskLocal static var label: String?
  }

  private func assertConcurrentFactoryShutdownRaceCleansUpAllResources(
    launchPolicy: LaunchPolicy
  ) async throws {
    let attempts = 48
    let scope = Scope.root()
    let started = StartBarrier(expectedCount: attempts)
    let release = Continuation<Void>()
    let tearDowns = Counter()
    let makeResource = try scope.resourceFactory(launchPolicy, name: "StressResource") {
      await started.arrive()
      await release()
      return UUID()
    } destroy: { _ in
      await tearDowns.increment()
    }

    let tasks = (0..<attempts).map { _ in
      Task { () -> Result<Resource<UUID>, any Error> in
        do {
          return .success(try await makeResource.make())
        } catch {
          return .failure(error)
        }
      }
    }

    await started.waitUntilAllArrived()

    let cancellation = Task {
      await scope.cancel()
    }

    try release.yield()
    await cancellation.value

    var successes = 0
    var failures = 0

    for task in tasks {
      switch await task.value {
      case .success(let resource):
        successes += 1
        await resource.cancel()
      case .failure(let error):
        failures += 1
        let scopeError = try #require(error as? ScopeError)
        #expect(scopeError == .cancelled())
      }
    }

    #expect(successes + failures == attempts)
    #expect(await tearDowns.value == attempts)
  }

}
