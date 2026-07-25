// © GoodHatsLLC

import Foundation

// MARK: - Timeout

/// The error thrown when a ``withTimeout(of:operation:)`` call exceeds its
/// duration.
///
/// Carries the source location of the call site, the duration that elapsed,
/// and a string description of the operation's return type for diagnostics.
public struct Timeout: Error, Sendable, Hashable, CustomStringConvertible {
  public let fromLocation: SourceLocation
  public let afterDuration: Duration
  public let type: String

  public init(fromLocation: SourceLocation, afterDuration: Duration, type: String) {
    self.fromLocation = fromLocation
    self.afterDuration = afterDuration
    self.type = type
  }

  public var description: String {
    "withTimeout<\(type)> invocation at \(fromLocation.short) timed out after \(afterDuration)."
  }
}

public enum WithTimeoutError<Failure: Error & Sendable>: Error, Sendable,
  CustomStringConvertible
{
  case timedOut(Timeout)
  case operationFailed(Failure)
  case cancelled

  public var description: String {
    switch self {
    case .timedOut(let timeout):
      timeout.description
    case .operationFailed(let failure):
      String(describing: failure)
    case .cancelled:
      "withTimeout cancelled"
    }
  }
}

public enum TimeoutOnlyError: Error, Sendable, CustomStringConvertible {
  case timedOut(Timeout)
  case cancelled

  public var description: String {
    switch self {
    case .timedOut(let timeout):
      timeout.description
    case .cancelled:
      "withTimeout cancelled"
    }
  }
}

public func withTimeout<Return: Sendable>(
  of duration: Duration,
  file: StaticString = #file,
  line: UInt = #line,
  column _: UInt = #column,
  function: StaticString = #function,
  _ operation: @Sendable @escaping @isolated(any) () async -> Return,
) async throws(TimeoutOnlyError) -> Return {
  let location = SourceLocation(file: file, fun: function, line: line)
  let result = await withTaskGroup(of: Either<Return, TimeoutOnlyError>.self) { group in
    group.addTask {
      do {
        try await Task.sleep(for: duration)
        return .rhs(
          .timedOut(
            Timeout(fromLocation: location, afterDuration: duration, type: "\(Return.self)"),
          ),
        )
      } catch {
        return .rhs(.cancelled)
      }
    }

    group.addTask {
      await .lhs(operation())
    }

    let initial = await group.next()
    defer { group.cancelAll() }
    return initial
  }

  switch result {
  case .none:
    throw .cancelled
  case .lhs(let value):
    return value
  case .rhs(let error):
    throw error
  }
}

/// A timeout with triggers for async work.
///
/// - Parameters:
///   - duration: The duration to wait before timing out.
///   - operation: The operation to execute.
/// - Returns: The result of the operation, if any.
/// - Throws: `WithTimeoutError` if the operation times out, fails, or the surrounding task is cancelled.
///
/// Disfavored so a *non-throwing* operation resolves to the overload above, which
/// throws the narrower `TimeoutOnlyError`. A non-throwing closure satisfies this
/// one too (with `Failure == Never`), and from Swift 6.4 the compiler reports the
/// call as ambiguous rather than picking one. Genuinely throwing operations are
/// unaffected: this remains their only viable candidate.
@_disfavoredOverload
public func withTimeout<Return: Sendable, Failure: Error & Sendable>(
  of duration: Duration,
  file: StaticString = #file,
  line: UInt = #line,
  column _: UInt = #column,
  function: StaticString = #function,
  _ operation: @Sendable @escaping @isolated(any) () async throws(Failure) -> Return,
) async throws(WithTimeoutError<Failure>)
  -> Return
{
  let location = SourceLocation(file: file, fun: function, line: line)
  let result = await withTaskGroup(
    of: Either<Result<Return, WithTimeoutError<Failure>>, Timeout>.self,
  ) { group in
    group.addTask {
      do {
        try await Task.sleep(for: duration)
        return .rhs(
          Timeout(fromLocation: location, afterDuration: duration, type: "\(Return.self)"),
        )
      } catch {
        return .lhs(.failure(.cancelled))
      }
    }

    let run: () async throws(Failure) -> Return = { () async throws(Failure) -> Return in
      try await operation()
    }

    group.addTask {
      do {
        let ret = try await run()
        return .lhs(Result<Return, WithTimeoutError<Failure>>.success(ret))
      } catch let failure as Failure {
        return .lhs(.failure(.operationFailed(failure)))
      } catch {
        preconditionFailure("Unexpected error type: \(error)")
      }
    }
    let initial = await group.next()
    defer { group.cancelAll() }
    return initial
  }
  switch result {
  case .none: throw .cancelled
  case .lhs(.success(let value)):
    return value
  case .lhs(.failure(let error)):
    throw error
  case .rhs(let timeout):
    throw .timedOut(timeout)
  }
}

// MARK: - Flag

private actor Flag {
  var value: Bool = false

  func set(value: Bool) {
    self.value = value
  }

  func performIf(expected: Bool, perform: @Sendable () -> Bool) {
    if value == expected {
      value = perform()
    }
  }
}

public struct SourceLocation: Sendable, Hashable, Codable, CustomStringConvertible {
  public init(
    file: StaticString = #file,
    fun: StaticString = #function,
    line: UInt = #line,
    col: UInt = #column,
    _ comment: Any = "",
  ) {
    self.file = file.description
    self.fun = fun.description
    self.line = line
    self.col = col
    self.comment = "\(comment.self)"
  }

  public var description: String {
    "\(comment)#\(file):\(line):\(col):\(fun)"
  }

  public var short: String {
    "\(file):\(line)"
  }

  public let file: String
  public let fun: String
  public let line: UInt
  public let col: UInt
  public let comment: String
}

private enum Either<LHS, RHS> {
  case lhs(LHS)
  case rhs(RHS)
}

extension Either: Sendable where LHS: Sendable, RHS: Sendable {}
