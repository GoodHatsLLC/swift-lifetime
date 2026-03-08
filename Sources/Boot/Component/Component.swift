public struct Component<Exports: Dependency>: Sendable, CancellableType {
  public let scope: Scope
  public let exports: Exports

  public init(scope: Scope, exports: Exports) {
    self.scope = scope
    self.exports = exports
  }

  public func cancel() async {
    await scope.cancel()
  }
}



