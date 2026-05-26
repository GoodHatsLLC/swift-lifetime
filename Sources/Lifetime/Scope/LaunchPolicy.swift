// MARK: - Launch Policy

/// Controls how Lifetime launches builder work.
///
/// - ``inline``: builder runs in the caller's task context — the default.
/// - ``detached``: builder runs in a detached task that does not inherit
///   actor isolation, priority, or cancellation. Use only when creation
///   must run independently of the caller's executor.
///
/// ## Choosing a policy
///
/// Prefer ``inline``. It preserves the caller's isolation and task context,
/// so cancellation, priority, and task-local values flow naturally into the
/// builder. Reach for ``detached`` only when those exact properties must
/// be broken — for example, when the builder captures actor-confined
/// values that should not pin the caller's executor for the duration of
/// creation.
public enum LaunchPolicy: Sendable {
  /// Runs the builder on a detached task that does not inherit the
  /// caller's isolation, priority, or task-local values.
  ///
  /// Caller cancellation propagates into the detached task: if the
  /// caller's task is cancelled while awaiting the builder, the detached
  /// task is cancelled as well. Whether the builder *responds* to that
  /// cancellation follows standard Swift cooperative-cancellation rules
  /// — async APIs that check `Task.isCancelled` (or throw
  /// `CancellationError`) will unwind; CPU-bound builders that never
  /// check cancellation will run to completion regardless.
  ///
  /// Use only when creation must not inherit the caller's isolation or
  /// priority. Otherwise prefer ``inline``, which keeps cancellation,
  /// priority, and task-local values flowing into the builder
  /// automatically.
  case detached

  /// Runs the builder in the caller's current async context.
  ///
  /// This is the default. The builder inherits the caller's actor
  /// isolation, priority, task-local values, and cancellation. Cancelling
  /// the caller's task cancels the builder.
  case inline
}
