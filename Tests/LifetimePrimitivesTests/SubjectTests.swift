// © GoodHatsLLC

import Testing

@testable import LifetimePrimitives

struct SubjectTests {
  @Test
  func finishTerminatesSubscribers() async {
    let subject = Subject<Int>()
    var iterator = subject.broadcaster.makeAsyncIterator()

    subject.send(5)
    #expect(await iterator.next() == 5)

    subject.finish()
    #expect(await iterator.next() == nil)
  }
}
