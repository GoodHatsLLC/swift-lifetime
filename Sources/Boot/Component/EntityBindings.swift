//
//  EntityBindings.swift
//  Boot
//
//  Created by adamz on 2026-03-06.
//



public struct EntityBindings: Sendable {
  private let scope: Scope

  init(scope: Scope) {
    self.scope = scope
  }

  public func instance<T: Sendable>(
    _ value: T,
    name: String? = nil,
    tearDown: @Sendable @escaping () async -> Void = {}
  ) throws -> Scoped<T> {
    try scope.bindInstance(name: name, value: value) { _ in
      await tearDown()
    }
  }

  public func shared<T: Sendable>(
    _ isolation: IsolationClass = .inherited,
    name: String? = nil,
    retryOnError: Bool = false,
    _ build: @Sendable @escaping () async throws -> T,
    tearDown: @Sendable @escaping () async -> Void = {}
  ) throws -> Scoped<T> {
    try scope.bindShared(
      isolation,
      name: name,
      retryOnError: retryOnError,
      builder: build
    ) { _ in
      await tearDown()
    }
  }

  public func factory<T: Sendable>(
    _ isolation: IsolationClass = .inherited,
    name: String? = nil,
    _ build: @Sendable @escaping () async throws -> T,
    tearDown: @Sendable @escaping (_ value: T) async -> Void = { _ in }
  ) throws -> EntityFactory<T> {
    try scope.bindFactory(
      isolation,
      name: name,
      builder: build,
      tearDown: tearDown
    )
  }
}


public struct EntityFactory<Output: Sendable>: Sendable {
  private let makeValue: @Sendable () async throws -> Owned<Output>

  init(_ makeValue: @escaping @Sendable () async throws -> Owned<Output>) {
    self.makeValue = makeValue
  }

  public func make() async throws -> Owned<Output> {
    try await makeValue()
  }

  public func callAsFunction() async throws -> Owned<Output> {
    try await make()
  }
}
