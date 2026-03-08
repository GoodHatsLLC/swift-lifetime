/// A Sendable type whose actively running behavior can be awaited to completion.
public protocol AwaitableType<Success, Failure>: Sendable {
  associatedtype Success: Sendable
  associatedtype Failure: Error

  /// Await the behavior's completion.
  var result: Result<Success, Failure> { get async }
}

extension AwaitableType {
  /// Await the erased type's behavior.
  /// - Note: convenience for ``wait()``
  public func callAsFunction() async -> Result<Success, Failure> {
    await result
  }
}

/// A Sendable type whose actively running behavior can be awaited to completion.
///
/// An erasure of some ``AwaitableType`` or ``Task``
public struct Awaitable<Success: Sendable, Failure: Error>: AwaitableType {

  /// Erase some ``AwaitableType`` to an ``Awaitable``.
  public init(_ upstream: some AwaitableType<Success, Failure>) {
    self.upstream = upstream
  }

  private let upstream: any AwaitableType<Success, Failure>

  /// Await the behavior's completion.
  public var result: Result<Success, Failure> {
    get async {
      await upstream.result
    }
  }
}

extension Awaitable {

  @available(
    *,
    unavailable,
    message: """
      An AwaitableType should be actively running.
      This initializer is prohibited because it does not enforce this contract.
      """
  )
  public init(_: () async -> Result<Success, Failure>) {
    fatalError()
  }

  /// Private bridging initializer allowing creating monitors for work
  fileprivate init(monitor: @escaping @Sendable () async -> Result<Success, Failure>) {
    self.upstream = MonitoringUpstream(monitor: monitor)
  }

  private struct MonitoringUpstream: AwaitableType {
    let monitor: @Sendable () async -> Result<Success, Failure>
    public var result: Result<Success, Failure> {
      get async {
        await monitor()
      }
    }
  }
}

extension Awaitable {

  private struct TaskUpstream: AwaitableType {
    let task: Task<Success, Failure>
    public var result: Result<Success, Failure> {
      get async {
        await task.result
      }
    }
  }

  /// Create an ``Awaitable`` by erasing a running task.
  public init(task: Task<Success, Failure>) {
    self.upstream = TaskUpstream(task: task)
  }

}

/// A fully type erased ``AwaitableType`` which can represent the upstream work's completion
/// but can not represent whether it succeeded or failed.
public struct AnyAwaitable: AwaitableType {
  public init<S: Sendable, F: Error>(erasing upstream: some AwaitableType<S, F>) {
    self.upstreamResult = {
      await upstream.result
        .map { _ in () }
        .flatMapError { _ in .success(()) }
    }
  }
  public init<S: Sendable, F: Error>(erasing task: Task<S, F>) {
    self.upstreamResult = {
      await task.result
        .map { _ in () }
        .flatMapError { _ in .success(()) }
    }
  }
  private let upstreamResult: @Sendable () async -> Result<Void, Never>
  public var result: Result<Void, Never> {
    get async {
      await upstreamResult()
    }
  }
}
