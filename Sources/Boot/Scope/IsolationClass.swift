
// MARK: - Isolation Policy

/// Controls where the Boot builder executes.
public enum IsolationClass: Sendable {
  /// Runs in a detached task (default for Sendable builders).
  /// Best for CPU-bound work that shouldn't block any actor.
  case detached

  /// Inherits the caller's isolation context (default for non-Sendable builders).
  /// Best for work that needs to stay on a specific actor.
  case inherited

  /// Runs on the MainActor.
  /// Best for UI-related initialization.
  case mainActor

}
