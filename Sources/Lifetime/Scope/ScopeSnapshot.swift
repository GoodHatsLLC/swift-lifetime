/// A structural snapshot of a ``Scope``'s ownership tree at the moment
/// ``Scope/snapshot()`` was called.
///
/// Snapshots are immutable value types intended for debugging,
/// observability, and test assertions. They preserve the registration
/// order of children and cancellation actions, in contrast to the
/// summary string produced by ``Scope/description`` which deduplicates
/// and sorts names.
///
/// Once a scope has entered ``Phase/cancelling`` or ``Phase/cancelled``
/// its runtime state is no longer available; snapshots taken during
/// those phases expose only the phase itself, with empty children and
/// ``cancellationActions``. Take a snapshot before triggering
/// cancellation if you need to compare before/after structures.
public struct ScopeSnapshot: Sendable, Hashable, CustomStringConvertible {
  /// The lifecycle phase the scope was in when the snapshot was taken.
  public enum Phase: Sendable, Hashable {
    /// The scope is accepting new children and cancellation actions.
    case running
    /// The scope has begun teardown; no new work is accepted.
    case cancelling
    /// The scope has completed teardown.
    case cancelled
  }

  /// One child scope owned by the snapshotted scope.
  public struct ChildEntry: Sendable, Hashable, CustomStringConvertible {
    /// The child scope's identity.
    public let id: LifetimeID
    /// The optional human-readable label registered with the child.
    public let name: String?
    /// A recursive snapshot of the child, or `nil` if the child has
    /// already been deallocated (the weak reference is gone).
    public let snapshot: ScopeSnapshot?

    public var description: String {
      let label = name ?? "<unnamed>"
      guard let snapshot else {
        return "\(label) (\(id), released)"
      }
      return "\(label) (\(id), \(snapshot.phase))"
    }
  }

  /// One cancellation action registered with the snapshotted scope.
  public struct CancellationEntry: Sendable, Hashable, CustomStringConvertible {
    /// The action's identity.
    public let id: LifetimeID
    /// The optional human-readable label registered with the action
    /// (propagated from named resources, adopted handles, etc.).
    public let name: String?

    public var description: String {
      let label = name ?? "<unnamed>"
      return "\(label) (\(id))"
    }
  }

  /// The snapshotted scope's identity.
  public let id: LifetimeID
  /// The scope's lifecycle phase at the moment of the snapshot.
  public let phase: Phase
  /// Direct child scopes in registration order. Empty when the scope is
  /// in ``Phase/cancelling`` or ``Phase/cancelled``.
  public let children: [ChildEntry]
  /// Registered cancellation actions in registration order. Empty when
  /// the scope is in ``Phase/cancelling`` or ``Phase/cancelled``.
  public let cancellationActions: [CancellationEntry]

  public init(
    id: LifetimeID,
    phase: Phase,
    children: [ChildEntry] = [],
    cancellationActions: [CancellationEntry] = []
  ) {
    self.id = id
    self.phase = phase
    self.children = children
    self.cancellationActions = cancellationActions
  }

  public var description: String {
    "ScopeSnapshot(id: \(id), phase: \(phase), children: \(children.count), cancellations: \(cancellationActions.count))"
  }
}
