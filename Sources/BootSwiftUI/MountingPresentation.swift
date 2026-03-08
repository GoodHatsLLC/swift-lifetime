#if canImport(SwiftUI)
public import Boot
import SwiftUI

// MARK: - Identifiable + Hashable wrapper

/// Wraps a `Component` to satisfy SwiftUI's `Identifiable` and `Hashable`
/// requirements for item-based presentation APIs.
private struct MountedItem<D: Dependency>: Identifiable, Hashable {
  let component: Component<D>
  var id: UUID { component.scope.id }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Sheet

extension View {
  /// Presents a sheet when the mounting's component becomes available.
  ///
  /// Dismissing the sheet unmounts the component.
  ///
  /// - Parameters:
  ///   - mounting: The projected value (`$mount`) of a `@Mount` property.
  ///   - onDismiss: An optional closure called after the sheet is dismissed.
  ///   - content: A view builder receiving the resolved component.
  @MainActor
  public func sheet<D: Dependency, C: View>(
    mounting: Mounting<D>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Component<D>) -> C
  ) -> some View {
    modifier(
      _MountingSheet(mounting: mounting, onDismiss: onDismiss, sheetContent: content)
    )
  }
}

@MainActor
private struct _MountingSheet<D: Dependency, SheetContent: View>: ViewModifier {
  var mounting: Mounting<D>
  var onDismiss: (() -> Void)?
  @ViewBuilder var sheetContent: (Component<D>) -> SheetContent

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(
        get: { mounting.component.map(MountedItem.init) },
        set: { newValue in
          if newValue == nil {
            Task { await mounting.unmount() }
          }
        }
      ),
      onDismiss: onDismiss
    ) { item in
      sheetContent(item.component)
    }
  }
}

// MARK: - Full Screen Cover

extension View {
  /// Presents a full-screen cover when the mounting's component becomes available.
  ///
  /// Dismissing the cover unmounts the component.
  ///
  /// - Parameters:
  ///   - mounting: The projected value (`$mount`) of a `@Mount` property.
  ///   - onDismiss: An optional closure called after the cover is dismissed.
  ///   - content: A view builder receiving the resolved component.
  @MainActor
  public func fullScreenCover<D: Dependency, C: View>(
    mounting: Mounting<D>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Component<D>) -> C
  ) -> some View {
    modifier(
      _MountingFullScreenCover(mounting: mounting, onDismiss: onDismiss, coverContent: content)
    )
  }
}

@MainActor
private struct _MountingFullScreenCover<D: Dependency, CoverContent: View>: ViewModifier {
  var mounting: Mounting<D>
  var onDismiss: (() -> Void)?
  @ViewBuilder var coverContent: (Component<D>) -> CoverContent

  func body(content: Content) -> some View {
    content.fullScreenCover(
      item: Binding(
        get: { mounting.component.map(MountedItem.init) },
        set: { newValue in
          if newValue == nil {
            Task { await mounting.unmount() }
          }
        }
      ),
      onDismiss: onDismiss
    ) { item in
      coverContent(item.component)
    }
  }
}

// MARK: - Navigation Destination

extension View {
  /// Pushes a navigation destination when the mounting's component becomes available.
  ///
  /// Popping the destination unmounts the component.
  ///
  /// - Parameters:
  ///   - mounting: The projected value (`$mount`) of a `@Mount` property.
  ///   - content: A view builder receiving the resolved component.
  @MainActor
  public func navigationDestination<D: Dependency, C: View>(
    mounting: Mounting<D>,
    @ViewBuilder content: @escaping (Component<D>) -> C
  ) -> some View {
    modifier(
      _MountingNavigationDestination(mounting: mounting, destinationContent: content)
    )
  }
}

@MainActor
private struct _MountingNavigationDestination<D: Dependency, DestinationContent: View>: ViewModifier
{
  var mounting: Mounting<D>
  @ViewBuilder var destinationContent: (Component<D>) -> DestinationContent

  func body(content: Content) -> some View {
    content.navigationDestination(
      item: Binding(
        get: { mounting.component.map(MountedItem.init) },
        set: { newValue in
          if newValue == nil {
            Task { await mounting.unmount() }
          }
        }
      )
    ) { item in
      destinationContent(item.component)
    }
  }
}

#endif
