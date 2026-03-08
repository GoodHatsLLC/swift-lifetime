import Testing

@testable import Boot

@Suite
struct LazyAsyncTests {
  @Test func asyncValueIsLazy() async throws {
    let counter = Counter()
    let value = LazyAsync {
      await counter.increment()
      return 7
    }

    #expect(await counter.value == 0)

    _ = try await value.get()

    #expect(await counter.value == 1)
  }

  @Test func asyncValueCachesResult() async throws {
    let counter = Counter()
    let value = LazyAsync {
      await counter.increment()
      return 42
    }

    let first = try await value.get()
    let second = try await value.get()

    #expect(first == second)
    #expect(await counter.value == 1)
  }

  @Test func asyncValueExecutesOnceWithConcurrentAwaiters() async throws {
    let counter = Counter()
    let value = LazyAsync {
      await counter.increment()
      try await Task.sleep(nanoseconds: 50_000_000)
      return 99
    }
    let iterations = 16

    let results = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<iterations {
        group.addTask {
          try await value.get()
        }
      }

      var values: [Int] = []
      values.reserveCapacity(iterations)

      for try await v in group {
        values.append(v)
      }

      return values
    }

    #expect(results.count == iterations)
    #expect(results.allSatisfy { $0 == 99 })
    #expect(await counter.value == 1)
  }

  @Test func asyncValueReset() async throws {
    let counter = Counter()
    let value = LazyAsync {
      await counter.increment()
      return await counter.value
    }

    let first = try await value.get()
    #expect(first == 1)

    await value.reset()

    let second = try await value.get()
    #expect(second == 2)
    #expect(await counter.value == 2)
  }

  @Test func asyncValueStateTransitions() async throws {
    let value = LazyAsync {
      try await Task.sleep(nanoseconds: 50_000_000)
      return "done"
    }

    #expect(await value.currentState == .pending)

    _ = try await value.get()

    #expect(await value.currentState == .resolved)
    #expect(await value.isResolved == true)
  }

  @Test func asyncValueResolveAliasesGet() async throws {
    let value = LazyAsync {
      11
    }

    let first = try await value.resolve()
    let second = try await value.get()
    let third = try await value()

    #expect(first == 11)
    #expect(second == 11)
    #expect(third == 11)
    #expect(await value.state == .resolved)
    #expect(await value.hasResolvedValue)
  }

  private actor Counter {
    private(set) var value = 0

    func increment() {
      value += 1
    }
  }
}
