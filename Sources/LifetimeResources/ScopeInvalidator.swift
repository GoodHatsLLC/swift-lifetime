import Lifetime
import LifetimePolicies

/// Schedules scope-cancellation work against a named delay trigger.
///
/// Use this to invalidate a scope after a delay tied to a specific reason
/// — background pressure, timeout, or manual trigger. Scheduling a new
/// invalidation replaces the previous pending one. Cancellation is
/// idempotent; the invalidator is reusable after ``cancelAll()``.
public actor ScopeInvalidator: Sendable {
  public enum Trigger: Sendable, Equatable {
    case background
    case timeout
    case manual
  }

  private var pending: TaskHandle?
  private var work = Scope.root(cancellationPolicy: .parallelUnordered)

  public init() {}

  public func schedule(
    trigger _: Trigger,
    delay: Duration,
    perform: @Sendable @escaping () async -> Void
  ) async {
    let work = self.work
    let delayPolicy = DelayPolicy(delay)
    await replacePending(
      with: TaskHandle { [work] in
        do {
          try await delayPolicy.wait()
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await work.supervise {
          await perform()
        }
      }
    )
  }

  public func invalidateNow(
    trigger _: Trigger = .manual,
    perform: @Sendable @escaping () async -> Void
  ) async {
    let work = self.work
    await replacePending(with: nil)
    await work.supervise {
      await perform()
    }
  }

  public func cancelAll() async {
    let previousWork = work
    work = .root(cancellationPolicy: .parallelUnordered)
    await replacePending(with: nil)
    await previousWork.cancel()
  }

  private func replacePending(with next: TaskHandle?) async {
    let previous = pending
    pending = next
    if let previous {
      await previous.cancel()
    }
  }
}
