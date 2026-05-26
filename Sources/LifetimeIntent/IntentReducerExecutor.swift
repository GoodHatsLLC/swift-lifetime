// © GoodHatsLLC

import Foundation
public import Lifetime
import LifetimePrimitives
import Synchronization

/// A reducer-driven executor for repeatable intents that should not block the
/// synchronous caller.
///
/// The executor owns a single serialized pump. Callers synchronously submit
/// events with ``send(event:)``; the reducer folds those events into bounded
/// pending state. The pump repeatedly asks ``nextExecutable`` to consume one
/// executable from that state, runs it to completion, drains its resource
/// teardown, then asks again.
///
/// ``finish()`` closes intake and drains pending executables. ``cancel()``
/// closes intake, cooperatively cancels the active executable, and waits for the
/// pump task to finish.
public final class IntentReducerExecutor<IntentEvent: Sendable, PendingState: Sendable>:
  Sendable, LifetimeHandle
{
  public enum ActiveDisposition: Sendable {
    case keepRunning
    case cancelActive
  }

  /// A scope-bound deferred command consumed by the executor pump.
  ///
  /// `Executable` aliases `ResourceFactory<Void, Void>` deliberately. The
  /// pump drives an executable in two phases: it calls `make()` to run the
  /// factory's `create` closure (the work), then immediately calls
  /// `cancel()` on the returned `Resource` to run its `destroy` closure
  /// (the cleanup). The intermediate `Resource<Void>` is never surfaced;
  /// its value type is `Void`.
  ///
  /// Reusing `ResourceFactory` here is load-bearing, not cosmetic.
  /// `ResourceFactory.init` is package-internal: the only public path to
  /// construct one is through ``Lifetime/Scope/resourceFactory(_:name:create:destroy:)-…``
  /// (or its overloads). That guarantees every executable submitted to an
  /// executor is bound to a live ``Lifetime/Scope`` — when that scope
  /// cancels, in-flight executable work tears down through the standard
  /// scope cancellation path rather than escaping into an orphan task.
  ///
  /// Construct executables by calling `scope.resourceFactory { /* work */ }`
  /// on whichever scope should own the work's lifetime.
  public typealias Executable = ResourceFactory<Void, Void>
  public typealias Reducer =
    @Sendable (_ state: inout PendingState, _ event: IntentEvent) -> ActiveDisposition
  public typealias NextExecutable = @Sendable (_ state: inout PendingState) -> Executable?
  public typealias ErrorHandler = @Sendable (_ error: any Error) async -> Void

  private struct ActiveRun: Sendable {
    let id = UUID()
    let work: ActorOwnedWork<Void>
  }

  private struct RuntimeState {
    var pending: PendingState
    var active: ActiveRun?
    var isClosed = false
    var isCancelling = false
    var isIdle = true
    var idleWaiters: [Continuation<Void>] = []
  }

  private let state: Mutex<RuntimeState>
  private let wakeSignal = AsyncSignal<Void>()
  private let pumpWork: Mutex<ActorOwnedWork<Void>?> = .init(nil)
  private let reduce: Reducer
  private let nextExecutable: NextExecutable
  private let onError: ErrorHandler?

  public init(
    initialState: PendingState,
    reduce: @escaping Reducer,
    nextExecutable: @escaping NextExecutable,
    onError: ErrorHandler? = nil
  ) {
    self.state = Mutex(RuntimeState(pending: initialState))
    self.reduce = reduce
    self.nextExecutable = nextExecutable
    self.onError = onError
    pumpWork.withLock { pumpWork in
      pumpWork = ActorOwnedWork { [weak self] in
        await self?.runPump()
      }
    }
  }

  deinit {
    let active = closeIntake(cancelling: true)
    active?.work.cancelNow()
    pumpWork.withLock { $0 }?.cancelNow()
  }

  /// Folds `event` into pending state and wakes the executor pump.
  ///
  /// Returns `false` after intake has been closed by ``finish()`` or
  /// ``cancel()``.
  @discardableResult
  public func send(event: IntentEvent) -> Bool {
    let result = state.withLock { runtime -> (accepted: Bool, active: ActiveRun?) in
      guard !runtime.isClosed else { return (false, nil) }
      let disposition = reduce(&runtime.pending, event)
      runtime.isIdle = false
      let active: ActiveRun? =
        switch disposition {
        case .keepRunning:
          nil
        case .cancelActive:
          runtime.active
        }
      return (true, active)
    }

    if result.accepted {
      result.active?.work.cancelNow()
      wakeSignal.signal()
    }
    return result.accepted
  }

  /// Suspends until the pump has consumed all currently executable pending
  /// state. Intake remains open.
  public func waitUntilIdle() async {
    let waiter = Continuation<Void>()
    let shouldWait = state.withLock { runtime in
      guard !runtime.isIdle else { return false }
      runtime.idleWaiters.append(waiter)
      return true
    }

    if shouldWait {
      await waiter()
    }
  }

  /// Closes intake and waits for the pump to run all pending executables that
  /// remain valid. The active executable is not task-cancelled.
  public func finish() async {
    _ = closeIntake(cancelling: false)
    await pumpWork.withLock { $0 }?.value
    markIdleIfNoActive()
  }

  /// Closes intake, cooperatively cancels the active executable, and waits for
  /// the pump task to stop.
  public func cancel() async {
    let active = closeIntake(cancelling: true)
    await active?.work.cancel()
    await pumpWork.withLock { $0 }?.cancel()
    if let active {
      clearActive(active)
    }
    markIdleIfNoActive()
  }

  private func runPump() async {
    defer {
      markIdleIfNoActive()
    }

    for await _ in wakeSignal.events() {
      guard !Task.isCancelled else { break }
      await drainExecutableQueue()
    }

    if !Task.isCancelled {
      await drainExecutableQueue()
    }
  }

  private func drainExecutableQueue() async {
    while !Task.isCancelled {
      guard let active = activeRun() ?? claimNextActiveRun() else {
        markIdleIfNoActive()
        break
      }

      await active.work.value
      clearActive(active)
    }
  }

  private func activeRun() -> ActiveRun? {
    state.withLock { runtime in
      runtime.active
    }
  }

  private func claimNextActiveRun() -> ActiveRun? {
    state.withLock { runtime in
      guard !runtime.isCancelling else { return nil }
      if let executable = nextExecutable(&runtime.pending) {
        let active = ActiveRun(
          work: ActorOwnedWork { [onError] in
            await Self.run(executable, onError: onError)
          })
        runtime.active = active
        runtime.isIdle = false
        return active
      }
      return nil
    }
  }

  private static func run(_ executable: Executable, onError: ErrorHandler?) async {
    do {
      let resource = try await executable.make()
      await resource.cancel()
    } catch is CancellationError {
      return
    } catch {
      await onError?(error)
    }
  }

  private func closeIntake(cancelling: Bool) -> ActiveRun? {
    let result = state.withLock { runtime -> (shouldWake: Bool, active: ActiveRun?) in
      if cancelling {
        runtime.isCancelling = true
      }
      guard !runtime.isClosed else { return (false, runtime.active) }
      runtime.isClosed = true
      runtime.isIdle = false
      return (true, runtime.active)
    }

    if result.shouldWake {
      wakeSignal.finish()
    }
    return result.active
  }

  private func clearActive(_ active: ActiveRun) {
    state.withLock { runtime in
      guard runtime.active?.id == active.id else { return }
      runtime.active = nil
    }
  }

  private func markIdleIfNoActive() {
    let waiters = state.withLock { runtime -> [Continuation<Void>] in
      guard runtime.active == nil else { return [] }
      runtime.isIdle = true
      let waiters = runtime.idleWaiters
      runtime.idleWaiters.removeAll()
      return waiters
    }

    for waiter in waiters {
      try? waiter.yield()
    }
  }
}
