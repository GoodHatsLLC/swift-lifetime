// © GoodHatsLLC

import Testing

@testable import LifetimePrimitives

struct AsyncBroadcasterTests {
  @Test
  func finishesSubscribersWhenSourceFinishes() async {
    let source = AsyncSignalStream<Int>.makeStream(bufferingPolicy: .unbounded)
    let broadcaster = AsyncBroadcaster(replay: .none, sequence: source.stream)
    var iterator = broadcaster.makeAsyncIterator()

    source.continuation.yield(10)
    #expect(await iterator.next() == 10)

    source.continuation.finish()
    #expect(await iterator.next() == nil)
  }

  @Test
  func replaysRetainedElementsAfterSourceFinishes() async {
    let source = AsyncSignalStream<Int>.makeStream(bufferingPolicy: .unbounded)
    let broadcaster = AsyncBroadcaster(replay: .latest(2), sequence: source.stream)
    var liveIterator = broadcaster.makeAsyncIterator()

    source.continuation.yield(1)
    #expect(await liveIterator.next() == 1)
    source.continuation.yield(2)
    #expect(await liveIterator.next() == 2)
    source.continuation.yield(3)
    #expect(await liveIterator.next() == 3)
    source.continuation.finish()
    #expect(await liveIterator.next() == nil)

    var replayIterator = broadcaster.makeAsyncIterator()
    #expect(await replayIterator.next() == 2)
    #expect(await replayIterator.next() == 3)
    #expect(await replayIterator.next() == nil)
  }
}
