public final class Owned<Value: Sendable>: Sendable, CancellableType {
  public let value: Value
  private let cancellation: Cancelling

  public init(
    value: Value,
    tearDown: @escaping @Sendable (_ value: Value) async -> Void = { _ in }
  ) {
    self.value = value
    self.cancellation = Cancelling {
      await tearDown(value)
    }
  }

  public func cancel() async {
    await cancellation.cancel()
  }
}
