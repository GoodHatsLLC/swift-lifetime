import Foundation
public import Observation
public import SwiftUI

/// A component that can be torn down asynchronously when its mount is
/// invalidated.
///
/// ``ComponentMount/invalidate()`` calls `shutdown()` on the outgoing
/// component so subtrees release their owned scopes deterministically.
public protocol MountInvalidatableComponent: Sendable {
  func shutdown() async
}

/// An `@Observable`, `@MainActor` mount point for a SwiftUI-bound component
/// subtree.
///
/// Owns the lifetime of the mounted component and tracks a monotonically
/// increasing ``epoch`` that drives ``MountedComponentView`` rebuilds.
/// ``mount(_:)`` and ``detach()`` swap or clear the component without
/// shutting it down; ``invalidate(shutdown:)`` (or the
/// ``MountInvalidatableComponent`` overload) detaches and then runs the
/// outgoing component's shutdown asynchronously.
@MainActor
@Observable
public final class ComponentMount<Component: Sendable>: Sendable {
  public private(set) var epoch: UInt64 = 0
  public private(set) var component: Component?

  public init(component: Component? = nil) {
    self.component = component
  }

  public func mount(_ component: Component) {
    self.component = component
  }

  @discardableResult
  public func detach() -> Component? {
    let previous = component
    component = nil
    if previous != nil {
      epoch &+= 1
    }
    return previous
  }

  public func invalidate(
    shutdown: @Sendable @escaping (Component) async -> Void
  ) async {
    guard let previous = detach() else { return }
    await Task.yield()
    await shutdown(previous)
  }

  public func invalidate() async where Component: MountInvalidatableComponent {
    await invalidate { mounted in
      await mounted.shutdown()
    }
  }
}

/// Renders content for a ``ComponentMount`` and rebuilds when the mount's
/// epoch changes.
///
/// Renders `placeholder` while the mount is empty; renders `content` keyed
/// on the mount's epoch so SwiftUI tears down and rebuilds the subtree on
/// each new mount.
public struct MountedComponentView<Component: Sendable, Content: View, Placeholder: View>: View {
  @Bindable private var mount: ComponentMount<Component>
  private let content: (Component) -> Content
  private let placeholder: () -> Placeholder

  public init(
    mount: ComponentMount<Component>,
    @ViewBuilder content: @escaping (Component) -> Content,
    @ViewBuilder placeholder: @escaping () -> Placeholder
  ) {
    self.mount = mount
    self.content = content
    self.placeholder = placeholder
  }

  public var body: some View {
    Group {
      if let component = mount.component {
        content(component)
          .id(mount.epoch)
      } else {
        placeholder()
      }
    }
  }
}

extension MountedComponentView where Placeholder == EmptyView {
  public init(
    mount: ComponentMount<Component>,
    @ViewBuilder content: @escaping (Component) -> Content
  ) {
    self.init(mount: mount, content: content, placeholder: { EmptyView() })
  }
}
