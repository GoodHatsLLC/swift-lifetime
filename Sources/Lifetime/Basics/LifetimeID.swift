import Synchronization

/// A lightweight, process-unique identifier for Lifetime types.
///
/// Each ID is assigned from a monotonic atomic counter, so no two
/// IDs created within the same process will collide — even after
/// the owning object is deallocated.
public struct LifetimeID: Sendable, Hashable, CustomStringConvertible {
  private let rawValue: UInt64

  /// Creates a new process-unique identifier.
  public init() {
    self.rawValue = Self.next()
  }

  public var description: String {
    rawValue.description
  }

  private static let counter = Atomic<UInt64>(0)

  private static func next() -> UInt64 {
    counter.wrappingAdd(1, ordering: .relaxed).oldValue
  }
}
