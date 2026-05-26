// © GoodHatsLLC

import Foundation

public typealias AsyncSignalStream<Element: Sendable> = AsyncStream<Element>
public typealias AsyncThrowingSignalStream<Element: Sendable> = AsyncThrowingStream<
  Element,
  any Error
>
public typealias AsyncSignalContinuation<Element: Sendable> = AsyncStream<Element>.Continuation

/// A signal channel owned by this object: one async consumer woken in
/// response to events from synchronous producers.
///
/// Coalesces wakeups according to its `BufferingPolicy` (defaulting to
/// "latest only"), so producers can fire freely without queueing pressure.
/// ``finish()`` and deinitialization both terminate the channel.
public final class AsyncSignal<Element: Sendable>: Sendable {
  private let stream: AsyncSignalStream<Element>
  private let continuation: AsyncSignalContinuation<Element>

  /// Creates a signal channel owned by this object.
  ///
  /// `bufferingPolicy` declares the stream's event buffering. Calling
  /// `finish()`, downstream termination, or object deinitialization terminates
  /// the channel.
  public init(
    bufferingPolicy: AsyncSignalContinuation<Element>.BufferingPolicy = .bufferingNewest(1),
    terminationHandler: (@Sendable (AsyncSignalContinuation<Element>.Termination) -> Void)? = nil,
  ) {
    let signal = AsyncSignalStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
    stream = signal.stream
    continuation = signal.continuation
    if let terminationHandler {
      continuation.onTermination = terminationHandler
    }
  }

  deinit {
    continuation.finish()
  }

  public func events() -> AsyncSignalStream<Element> {
    stream
  }

  public func yield(_ element: Element) {
    continuation.yield(element)
  }

  public func finish() {
    continuation.finish()
  }
}

extension AsyncSignal where Element == Void {
  public func signal() {
    yield(())
  }
}
