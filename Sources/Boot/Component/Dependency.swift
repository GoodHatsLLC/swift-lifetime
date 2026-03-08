public protocol Dependency<Requirement>: Sendable {
  associatedtype Requirement: Sendable
  init(with requirement: Requirement, in scope: Scope) async throws
}

extension Dependency where Requirement == () {
  init(in scope: Scope) async throws {
    try await self.init(with: (), in: scope)
  }
}
