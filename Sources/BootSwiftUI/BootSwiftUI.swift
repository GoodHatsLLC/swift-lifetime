#if canImport(SwiftUI)
public import Observation
public import SwiftUI
public import Boot

@Observable
@MainActor
public final class Mounting<D: Dependency> {
  public enum Phase: Sendable {
    case idle
    case mounting
    case mounted
    case failed
  }

  public private(set) var phase: Phase = .idle
  public private(set) var component: Component<D>?
  public private(set) var error: (any Error)?

  public var isMounted: Bool {
    component != nil
  }

  @ObservationIgnored private var desiredSource: Scoped<Component<D>>?
  @ObservationIgnored private var desiredSourceID: String?
  @ObservationIgnored private var suppressedSourceID: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0

  public init(source: Scoped<Component<D>>? = nil) {
    bindSource(source)
  }

  isolated deinit {
    task?.cancel()
    let component = component
    guard let component else { return }
    Task {
      await component.cancel()
    }
  }

  public func unmount() async {
    suppressedSourceID = desiredSourceID
    await replaceCurrent(with: nil, phase: .idle)
  }

  public func replace(with component: Component<D>) async {
    suppressedSourceID = desiredSourceID
    await replaceCurrent(with: component, phase: .mounted)
  }

  func bindSource(_ source: Scoped<Component<D>>?) {
    let nextID = source?.dependencyToken
    guard desiredSourceID != nextID else { return }

    desiredSource = source
    desiredSourceID = nextID

    if suppressedSourceID != nil, suppressedSourceID != nextID {
      suppressedSourceID = nil
    }

    guard suppressedSourceID != nextID else { return }

    switch source {
    case .some(let source):
      scheduleLoad(from: source)
    case .none:
      scheduleReplace(with: nil, phase: .idle)
    }
  }

  private func scheduleLoad(from source: Scoped<Component<D>>) {
    let generation = beginTransition()
    phase = .mounting
    error = nil
    let prior = component
    component = nil

    task = Task { @MainActor [weak self] in
      if let prior {
        await prior.cancel()
      }
      guard let self, self.isCurrent(generation), !Task.isCancelled else { return }

      do {
        let resolved = try await source.get()
        guard self.isCurrent(generation), !Task.isCancelled else {
          await resolved.cancel()
          return
        }
        self.error = nil
        self.component = resolved
        self.phase = .mounted
      } catch {
        guard self.isCurrent(generation), !Task.isCancelled else { return }
        self.error = error
        self.phase = .failed
      }
    }
  }

  private func scheduleReplace(with next: Component<D>?, phase nextPhase: Phase) {
    let generation = beginTransition()
    phase = next == nil ? nextPhase : .mounting
    error = nil
    let prior = component
    component = nil

    task = Task { @MainActor [weak self] in
      if let prior {
        await prior.cancel()
      }
      guard let self, self.isCurrent(generation), !Task.isCancelled else {
        if let next {
          await next.cancel()
        }
        return
      }
      self.error = nil
      self.component = next
      self.phase = next == nil ? nextPhase : .mounted
    }
  }

  private func replaceCurrent(with next: Component<D>?, phase nextPhase: Phase) async {
    let generation = beginTransition()
    phase = next == nil ? nextPhase : .mounting
    error = nil
    let prior = component
    component = nil

    if let prior {
      await prior.cancel()
    }

    guard isCurrent(generation) else {
      if let next {
        await next.cancel()
      }
      return
    }

    error = nil
    component = next
    phase = next == nil ? nextPhase : .mounted
  }

  private func beginTransition() -> UInt64 {
    generation &+= 1
    task?.cancel()
    task = nil
    return generation
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    self.generation == generation
  }
}

@MainActor
@propertyWrapper
public struct Mount<D: Dependency>: @MainActor DynamicProperty {
  private let source: Scoped<Component<D>>?

  @State private var mounting: Mounting<D>

  public init() {
    self.source = nil
    _mounting = State(initialValue: Mounting())
  }

  public init(_ source: Scoped<Component<D>>) {
    self.source = source
    _mounting = State(initialValue: Mounting(source: source))
  }

  public var wrappedValue: Component<D>? {
    mounting.component
  }

  public var projectedValue: Mounting<D> {
    mounting
  }

  public mutating func update() {
    _mounting.update()
    MainActor.assumeIsolated {
      mounting.bindSource(source)
    }
  }
}

#endif
