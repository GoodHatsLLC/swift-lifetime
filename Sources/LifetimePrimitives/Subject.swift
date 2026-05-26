// © GoodHatsLLC

/// A single-producer, multi-consumer subject that owns its producer
/// continuation and exposes a read side via ``broadcaster``.
///
/// Producers call ``send(_:)`` synchronously; subscribers iterate the
/// broadcaster. Call ``finish()`` to terminate the stream; the deinit
/// finishes it as a safety net.
public final class Subject<T: Sendable>: Sendable {
  let cont: AsyncSignalContinuation<T>
  let _broadcaster: AsyncBroadcaster<T>

  /// Creates a subject with explicit producer and subscriber buffering.
  ///
  /// The subject owns the producer continuation. Call `finish()` to terminate
  /// the stream; deinitialization also finishes it as a safety net.
  public init(
    producerBuffer: AsyncBuffer = .unbounded,
    subscriberBuffer: AsyncBuffer = .unbounded,
  ) {
    let (stream, cont) = AsyncSignalStream<T>.makeStream(bufferingPolicy: .init(producerBuffer))
    _broadcaster = stream.broadcast(subscriberBuffer: subscriberBuffer)
    self.cont = cont
  }

  deinit {
    cont.finish()
  }

  public var broadcaster: AsyncBroadcaster<T> {
    _broadcaster
  }

  public nonisolated func send(_ input: T) {
    cont.yield(input)
  }

  public nonisolated func finish() {
    cont.finish()
  }
}
