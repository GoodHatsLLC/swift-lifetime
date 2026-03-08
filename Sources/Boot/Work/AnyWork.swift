public import Foundation
import Synchronization

/// A fully type erased ``WorkType`` which can represent and trigger the upstream work's completion
/// but can not represent whether it succeeded or failed.
public struct AnyWork: WorkType {
  public init<S: Sendable, F: Error>(_ work: Work<S, F>) {
    self.id = work.id
    self.resultFunc = {
      await work.result
        .map { _ in () }
        .flatMapError { _ in .success(()) }
    }
    self.cancelFunc = {
      await work.cancel()
    }
  }
  public let id: UUID
  private let resultFunc: @Sendable () async -> Result<Void, Never>
  private let cancelFunc: @Sendable () async -> Void
  public var result: Result<Void, Never> {
    get async {
      await resultFunc()
    }
  }
  public func cancel() async {
    await cancelFunc()
  }
}
