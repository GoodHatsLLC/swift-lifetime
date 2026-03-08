public struct ComponentBindings: Sendable {
  private let scope: Scope

  init(scope: Scope) {
    self.scope = scope
  }

  public func instance<Exports: Sendable>(
    _ handle: Component<Exports>,
    name: String? = nil
  ) throws -> Scoped<Component<Exports>> {
    try scope.bindInstance(name: name, value: handle) { handle in
      await handle.cancel()
    }
  }

  public func shared<D: Dependency>(
    _ type: D.Type,
    name: String? = nil,
    input: @Sendable @escaping () async throws -> D.Requirement
  ) throws -> Scoped<Component<D>> {
    try scope.bindShared(name: name) {
      let required = try await input()
      return try await launch(type, with: required)
    } tearDown: { handle in
      await handle.cancel()
    }
  }

  public func shared<D: Dependency>(
    _ type: D.Type,
    name: String? = nil,
    input: D.Requirement
  ) throws -> Scoped<Component<D>> {
    try scope.bindShared(name: name) {
      return try await launch(type, with: input)
    } tearDown: { handle in
      await handle.cancel()
    }
  }

  public func factory<D: Dependency>(
    _ type: D.Type,
    name: String? = nil
  ) throws -> ComponentFactory<D.Requirement, D> {
    try scope.ensureRunning()
    return ComponentFactory { input in
      try await launch(type, with: input)
    }
  }

  private func launch<D: Dependency>(
    _ type: D.Type,
    with input: D.Requirement
  ) async throws -> Component<D> {
    try scope.ensureRunning()
    let child = try scope.child()
    do {
      let exports = try await D(with: input, in: child)
      try scope.ensureRunning()
      return Component(scope: child, exports: exports)
    } catch {
      await child.cancel()
      throw error
    }
  }
}

public struct ComponentFactory<Input: Sendable, Exports: Dependency>: Sendable {
  private let makeComponent: @Sendable (Input) async throws -> Component<Exports>

  init(_ makeComponent: @escaping @Sendable (Input) async throws -> Component<Exports>) {
    self.makeComponent = makeComponent
  }

  public func make(_ input: Input) async throws -> Component<Exports> {
    try await makeComponent(input)
  }

  public func callAsFunction(_ input: Input) async throws -> Component<Exports> {
    try await make(input)
  }
}
