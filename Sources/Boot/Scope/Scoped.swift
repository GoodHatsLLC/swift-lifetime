import Foundation
/// A typed dependency handle whose value is produced within a scope.
public struct Scoped<Value: Sendable>: Sendable {
  public let name: String
  private let id: UUID
  private let resolver: @Sendable () async throws -> Value

  init(
    id: UUID,
    name: String,
    resolve: @escaping @Sendable () async throws -> Value
  ) {
    self.name = name
    self.id = id
    self.resolver = resolve
  }

  public func get() async throws -> Value {
    try await resolver()
  }

  public func callAsFunction() async throws -> Value {
    try await resolver()
  }

  package var dependencyToken: String { id.uuidString }
}
