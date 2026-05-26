/// Controls how ``Scope`` performs teardown when cancelled.
///
/// Children (added via ``Scope/child(_:)``-like calls) and cancellation
/// actions (added via ``Scope/onCancel(_:)``, ``Scope/adopt(_:)``,
/// ``Scope/start(_:launchPolicy:create:destroy:)-…``, and similar) share
/// a single registration log inside the scope. The policy controls how
/// that log is walked at cancellation time.
///
/// - ``serialLIFO``: walks the unified log in **strict reverse
///   registration order**, dispatching each entry by kind. A child
///   registered after a resource is torn down before that resource;
///   the same registration sequence is reflected in teardown sequence,
///   one entry at a time. Deterministic and the default.
/// - ``parallelUnordered``: partitions the log into a children phase
///   and a cancellation-actions phase. All children cancel concurrently,
///   then all actions run concurrently. Use when teardown throughput
///   matters more than ordering. The two phases stay sequenced so that
///   resource destroy hooks (typically registered as actions) outlive
///   the child scopes that may have referenced them.
public enum ScopeCancellationPolicy: Sendable {
  /// Walks the unified registration log in strict reverse registration
  /// order, dispatching each entry one at a time. Children registered
  /// after a resource are torn down before that resource; resources
  /// registered after a child are torn down before that child.
  /// Deterministic and the default policy.
  case serialLIFO

  /// Cancels all child scopes concurrently, then runs all cancellation
  /// actions concurrently. Completion order within each phase is
  /// intentionally non-deterministic; the two phases remain sequenced.
  ///
  /// Use this when teardown throughput matters more than strict ordering.
  case parallelUnordered
}
