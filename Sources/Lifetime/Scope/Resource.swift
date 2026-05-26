/// A caller-owned runtime resource with deterministic async teardown via
/// ``cancel()``.
///
/// `Resource` is a `final class` because it owns the cancellation state
/// machine that drives both ``cancel()`` and the `deinit` safety net;
/// reference identity is required for that state to survive being passed
/// across actor boundaries.
///
/// Cancellation is idempotent. `await cancel()` is the contract; `deinit`
/// is a **fallback only**. Releasing the final strong reference without
/// cancelling first fires teardown on a detached task as a backstop
/// against leaks — the trigger site does not block and completion is not
/// observable. Do not rely on `deinit` for ordering, sequencing, or any
/// teardown a test or shutdown sequence must wait on.
public final class Resource<Value: Sendable>: Sendable, NamedLifetimeHandle,
  CustomStringConvertible, CustomDebugStringConvertible
{
  /// Optional human-readable label propagated from the factory that created it.
  public let name: String?
  /// The wrapped runtime value.
  public let value: Value

  private let cancellation: Cancelling

  /// Creates a resource around `value` and registers its destroy hook.
  public init(
    value: Value,
    name: String? = nil,
    destroy: @escaping @Sendable (_ value: Value) async -> Void = { _ in }
  ) {
    self.name = name
    self.value = value
    self.cancellation = Cancelling {
      await destroy(value)
    }
  }

  public var description: String {
    guard let name else {
      return "Resource<\(Value.self)>"
    }
    return "Resource<\(Value.self)>(name: \(name))"
  }

  public var debugDescription: String { description }

  public func cancel() async {
    await cancellation.cancel()
  }
}

/// A factory that creates caller-owned runtime resources on demand.
///
/// Each `make(_:)` call produces a new ``Resource`` whose lifetime is
/// independent of the factory. The factory does not retain its originating
/// ``Scope``; calling `make(_:)` after that scope has ended throws
/// ``ScopeError/cancelled``.
public struct ResourceFactory<Input: Sendable, Value: Sendable>: Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  /// Optional human-readable label used in factory, resource, and scope descriptions.
  public let name: String?

  private let createResource: @Sendable (Input) async throws -> Resource<Value>

  init(
    name: String? = nil,
    create: @escaping @Sendable (Input) async throws -> Resource<Value>
  ) {
    self.name = name
    self.createResource = create
  }

  /// Creates a new resource for `input`.
  public func make(_ input: Input) async throws -> Resource<Value> {
    try await createResource(input)
  }

  public var description: String {
    guard let name else {
      return "ResourceFactory<\(Input.self), \(Value.self)>"
    }
    return "ResourceFactory<\(Input.self), \(Value.self)>(name: \(name))"
  }

  public var debugDescription: String { description }

  /// Convenience shorthand for ``make(_:)``.
  public func callAsFunction(_ input: Input) async throws -> Resource<Value> {
    try await make(input)
  }
}

extension ResourceFactory where Input == Void {
  /// Creates a new resource when the factory does not require input.
  public func make() async throws -> Resource<Value> {
    try await make(())
  }

  /// Convenience shorthand for ``make()``.
  public func callAsFunction() async throws -> Resource<Value> {
    try await make()
  }
}
