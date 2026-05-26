extension Scope {
  /// Adopts an external ``LifetimeHandle`` into this scope.
  ///
  /// The handle becomes part of this scope's teardown sequence and is
  /// cancelled when the scope cancels. If adoption fails because the
  /// scope has already begun shutdown, the supplied handle is cancelled
  /// immediately instead of being orphaned.
  public func supervise(work: some LifetimeHandle) async {
    do {
      try adopt(work)
    } catch {
      await work.cancel()
    }
  }

  /// Adopts a `Sendable` async closure as supervised background work.
  ///
  /// Convenience over ``supervise(work:)`` that wraps the closure in a
  /// ``TaskHandle``. Use the handle-taking overload when the caller
  /// needs an explicit awaitable handle to drain or cancel directly.
  public func supervise(
    priority: TaskPriority? = nil,
    work: @Sendable @escaping () async -> Void
  ) async {
    await supervise(work: TaskHandle(priority: priority, operation: work))
  }

  /// Creates a child scope whose lifetime is tied to this scope.
  ///
  /// Throws ``ScopeError/cancelled`` if the parent scope has already
  /// begun shutdown and can no longer accept new children.
  public func delegate() async throws -> Scope {
    let child = try await child { _ in
      ()
    }
    return child.scope
  }
}
