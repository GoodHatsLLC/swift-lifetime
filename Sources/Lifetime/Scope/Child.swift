/// A nested lifetime boundary with typed exports.
///
/// `Child` is a value-typed wrapper: it adds typed ``exports`` around a
/// ``Scope`` but carries no identity of its own. Cancelling the child
/// forwards to the underlying scope, which provides both the cancellation
/// state machine and the `deinit` safety net.
///
/// Cancelling the child cancels its underlying scope and everything owned by it.
public struct Child<Exports: Sendable>: Sendable, NamedLifetimeHandle,
  CustomStringConvertible, CustomDebugStringConvertible
{
  /// Optional human-readable label propagated from the factory that created it.
  public let name: String?
  /// The child scope that owns the exported lifetime.
  public let scope: Scope
  /// Values exported from the child scope.
  public let exports: Exports

  init(name: String? = nil, scope: Scope, exports: Exports) {
    self.name = name
    self.scope = scope
    self.exports = exports
  }

  public var description: String {
    guard let name else {
      return "Child<\(Exports.self)>"
    }
    return "Child<\(Exports.self)>(name: \(name))"
  }

  public var debugDescription: String { description }

  public func cancel() async {
    await scope.cancel()
  }
}

/// A factory that creates caller-owned child lifetimes on demand.
///
/// Each `make(_:)` call produces a new ``Child`` whose lifetime is
/// independent of the factory. The factory does not retain its originating
/// ``Scope``; calling `make(_:)` after that scope has ended throws
/// ``ScopeError/cancelled``.
public struct ChildFactory<Input: Sendable, Exports: Sendable>: Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  /// Optional human-readable label used in factory, child, and parent-scope descriptions.
  public let name: String?

  private let createChild: @Sendable (Input) async throws -> Child<Exports>

  init(
    name: String? = nil,
    create: @escaping @Sendable (Input) async throws -> Child<Exports>
  ) {
    self.name = name
    self.createChild = create
  }

  /// Creates a new child lifetime for `input`.
  public func make(_ input: Input) async throws -> Child<Exports> {
    try await createChild(input)
  }

  public var description: String {
    guard let name else {
      return "ChildFactory<\(Input.self), \(Exports.self)>"
    }
    return "ChildFactory<\(Input.self), \(Exports.self)>(name: \(name))"
  }

  public var debugDescription: String { description }

  /// Convenience shorthand for ``make(_:)``.
  public func callAsFunction(_ input: Input) async throws -> Child<Exports> {
    try await make(input)
  }
}

extension ChildFactory where Input == Void {
  /// Creates a new child lifetime when the factory does not require input.
  public func make() async throws -> Child<Exports> {
    try await make(())
  }

  /// Convenience shorthand for ``make()``.
  public func callAsFunction() async throws -> Child<Exports> {
    try await make()
  }
}
