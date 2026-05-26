import Synchronization
import Testing

@testable import Lifetime

@Suite
struct CancellationTests {
  @Test func cancellationCancelsOnce() async {
    let counter = LockedCounter()
    let cancelling = Cancelling {
      counter.increment()
    }

    await cancelling.cancel()
    await cancelling.cancel()

    #expect(counter.value == 1)
  }

  @Test func cancellationCancelsOnDeinit() {
    let counter = LockedCounter()
    do {
      let cancelling = Cancelling {
        counter.increment()
      }
      #expect(counter.value == 0)
      _ = cancelling
    }

    #expect(counter.value == 1)
  }

  private final class LockedCounter: Sendable {
    private let lock = Mutex(0)

    var value: Int {
      lock.withLock { $0 }
    }

    func increment() {
      lock.withLock { $0 += 1 }
    }
  }
}
