import Synchronization
import Foundation

public enum DependencyResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
  case dependencyCycle(path: [String])
  case scopeShutdown

  public var description: String {
    switch self {
    case .dependencyCycle(let path):
      return "Dependency cycle detected: \(path.joined(separator: " -> "))"
    case .scopeShutdown:
      return "Dependency scope has been shut down."
    }
  }
}

private enum DependencyAccessContext {
  struct Frame: Sendable {
    let id: UUID
    let label: String
  }
  @TaskLocal static var stack: [Frame] = []
}


public final class Scope: Sendable, CancellableType {
  nonisolated let id: UUID = .init()

  private let parent: Scope?

  struct RuntimeState: Sendable {
    fileprivate var children: [UUID: WeakScopeRef] = [:]
    fileprivate var shutdownActions: [UUID: @Sendable () async -> Void] = [:]
  }

  enum State: Sendable {
    case running(RuntimeState)
    case cancelling(AnyAwaitable)

    mutating func resultWithRuntime<T>(_ body: (inout RuntimeState) -> T) -> Result<T, DependencyResolutionError> {
      switch self {
      case .running(var runtime):
        let result = body(&runtime)
        self = .running(runtime)
        return .success(result)
      case .cancelling:
        return .failure(DependencyResolutionError.scopeShutdown)
      }
    }
  }

  private let state: Mutex<State> = .init(.running(.init()))

  package init() {
    self.parent = nil
  }

  package init(parent: Scope) {
    self.parent = parent
  }

  public static func root() -> Scope {
    Scope()
  }

  /// Creates a child scope linked to this scope for shutdown cascading.
  public func child() throws(DependencyResolutionError) -> Scope {
    pruneSubscopes()
    let child = Scope(parent: self)
    let ref = WeakScopeRef(child)
    return try state.withLock { stateMaybe in
      stateMaybe.resultWithRuntime { state in
        state.children[child.id] = ref
        return child
      }
    }.get()
  }

  func bindShared<Value: Sendable>(
    _ isolation: IsolationClass = .inherited,
    name: String? = nil,
    retryOnError: Bool = false,
    builder: @Sendable @escaping () async throws -> Value,
    tearDown: @Sendable @escaping (_ value: Value) async -> Void = { _ in }
  ) throws(DependencyResolutionError) -> Scoped<Value> {

    let dependencyID = UUID()
    let dependencyName = Self.makeDependencyLabel(
      dependencyID: dependencyID,
      explicitName: name,
      valueType: Value.self
    )
    let cached = LazyAsync(.inherited, retryOnError: retryOnError) { [scope = self] in
      try await scope.executeFactory(isolation: isolation, builder: builder)
    }
    return try state.withLock { stateMaybe in
      stateMaybe.resultWithRuntime { state in
        state.shutdownActions[dependencyID] = {
          await cached.cancel()
          guard await cached.hasResolvedValue else { return }
          let value = try? await cached.get()
          guard let value else { return }
          await tearDown(value)
        }
        return Scoped(id: dependencyID, name: dependencyName) { [scope = self] in
          try await scope.resolve(
            dependencyID: dependencyID,
            dependencyName: dependencyName
          ) {
            try await cached.get()
          }
        }
      }
    }.get()
  }

  func bindFactory<Value: Sendable>(
    _ isolation: IsolationClass = .inherited,
    name: String? = nil,
    builder: @Sendable @escaping () async throws -> Value,
    tearDown: @Sendable @escaping (_ instance: Value) async -> Void = { _ in }
  ) throws(DependencyResolutionError) -> EntityFactory<Value> {
    let dependencyID = UUID()
    let dependencyName = Self.makeDependencyLabel(
      dependencyID: dependencyID,
      explicitName: name,
      valueType: Value.self
    )
    try ensureRunning()
    return EntityFactory { [scope = self] in
      try await scope.resolve(
        dependencyID: dependencyID,
        dependencyName: dependencyName
      ) {
        let instance = try await scope.executeFactory(isolation: isolation, builder: builder)
        do {
          try scope.ensureRunning()
        } catch {
          await tearDown(instance)
          throw error
        }
        return Owned(value: instance, tearDown: tearDown)
      }
    }
  }

  func bindInstance<Value: Sendable>(
    name: String? = nil,
    value: Value,
    tearDown: @Sendable @escaping (_ value: Value) async -> Void = { _ in }
  ) throws(DependencyResolutionError) -> Scoped<Value> {
    try bindShared(.inherited, name: name, builder: { value }, tearDown: tearDown)
  }

  /// Registers an action to run when this scope is shut down.
  public func onShutdown(_ action: @Sendable @escaping () async -> Void) throws {
    try state.withLock { state in
      state.resultWithRuntime { state in
        state.shutdownActions[UUID()] = action
      }
    }.get()
  }

  /// Adopts a `CancellableType` so it is cancelled when the scope shuts down.
  public func onShutdown(cancel cancellable: some CancellableType) throws {
    try onShutdown {
      await cancellable.cancel()
    }
  }

  private static func performCancellation(parent: Scope?, childID: UUID, runtime: RuntimeState) -> AnyAwaitable {
    let task = Task.detached {

      let childScopes = runtime.children.values.compactMap(\.value)

      await withTaskGroup(of: Void.self) { group in
        for child in childScopes {
          group.addTask {
            await child.cancel()
          }
        }
        await group.waitForAll()
      }
      let actions = runtime.shutdownActions.values

      await withTaskGroup(of: Void.self) { group in
        for action in actions {
          group.addTask {
            await action()
          }
        }
        await group.waitForAll()
      }
      parent?.detachChild(id: childID)
    }
    return .init(erasing: task)
  }

  /// Shuts down this scope, cascading to children and cancelling all scoped dependencies.
  public func cancel() async {
    let awaitable = state.withLock { state in
      switch state {
      case .running(let runtimeState):
        let awaitable = Self.performCancellation(parent: parent, childID: id, runtime: runtimeState)
        state = .cancelling(awaitable)
        return awaitable
      case .cancelling(let anyAwaitable):
        return anyAwaitable
      }
    }
    _ = await awaitable()
  }

  // MARK: - Internal

  private func resolve<Value: Sendable>(
    dependencyID: UUID,
    dependencyName: String,
    _ operation: @Sendable @escaping () async throws -> Value
  ) async throws -> Value {
    try ensureRunning()

    let stack = DependencyAccessContext.stack
    if let cycleStartIndex = stack.firstIndex(where: { $0.id == dependencyID }) {
      let path = Array(stack[cycleStartIndex...].map(\.label)) + [dependencyName]
      throw DependencyResolutionError.dependencyCycle(path: path)
    }

    let current = DependencyAccessContext.Frame(id: dependencyID, label: dependencyName)
    let value = try await DependencyAccessContext.$stack.withValue(stack + [current]) {
      try await operation()
    }
    try ensureRunning()
    return value
  }

  private func executeFactory<Value: Sendable>(
    isolation: IsolationClass,
    builder: @Sendable @escaping () async throws -> Value
  ) async throws -> Value {
    let resolutionStack = DependencyAccessContext.stack
    switch isolation {
    case .detached:
      return try await Task.detached {
        try await DependencyAccessContext.$stack.withValue(resolutionStack) {
          try await builder()
        }
      }.value
    case .inherited:
      return try await DependencyAccessContext.$stack.withValue(resolutionStack) {
        try await builder()
      }
    case .mainActor:
      return try await Task { @MainActor in
        try await DependencyAccessContext.$stack.withValue(resolutionStack) {
          try await builder()
        }
      }.value
    }
  }

  private func detachChild(id: UUID) {
    _ = state.withLock { state in
      state.resultWithRuntime { rt in
        rt.children[id] = nil
      }
    }
  }

  private func pruneSubscopes() {
    _ = state.withLock { state in
      state.resultWithRuntime { rt in
        rt.children = rt.children.filter { $0.value.value != nil }
      }
    }
  }

  func ensureRunning() throws(DependencyResolutionError) {
    let isRunning = state.withLock { state in
      switch state {
      case .running:
        return true
      case .cancelling:
        return false
      }
    }
    guard isRunning else {
      throw DependencyResolutionError.scopeShutdown
    }
  }

  private nonisolated static func makeDependencyLabel<Value>(
    dependencyID: UUID,
    explicitName: String?,
    valueType _: Value.Type
  ) -> String {
    let fallback = String(describing: Value.self)
    let trimmed = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseName = if let trimmed, !trimmed.isEmpty { trimmed } else { fallback }
    let shortID = dependencyID.uuidString.split(separator: "-").first ?? Substring(
      dependencyID.uuidString
    )
    return "\(baseName)<\(shortID)>"
  }

  package static func currentDependencyResolutionLabels() -> [String] {
    DependencyAccessContext.stack.map(\.label)
  }
}

private final class WeakScopeRef: Sendable {
  weak let value: Scope?

  init(_ value: Scope) {
    self.value = value
  }
}
