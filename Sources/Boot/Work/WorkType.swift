public import Foundation
import Synchronization

/// A type conforming to ``WorkType`` must have an identity and be both awaitable and cancellable.
public protocol WorkType<Success, Failure>: Identifiable, Sendable, AwaitableType, CancellableType {
  var id: UUID { get }
}

/// An ``Identifiable`` holder for a ``Task``.
public struct Work<Success: Sendable, Failure: Error>: WorkType {
  public let id: UUID = .init()

  public init(task: Task<Success, Failure>) {
    self.task = task
  }

  public init(immediate: sending @escaping () async throws -> Success) where Failure == any Error {
    self.task = Task<Success, any Error> {
      try await immediate()
    }
  }

  let task: Task<Success, Failure>

  public func cancel() async {
    task.cancel()
    _ = await task.result
  }
  public var value: Success {
    get async throws {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }
  public var result: Result<Success, Failure> {
    get async {
      await withTaskCancellationHandler {
        await task.result
      } onCancel: {
        task.cancel()
      }
    }
  }
}
