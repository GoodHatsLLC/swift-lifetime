import SwiftUI
import os

@propertyWrapper
private struct DragMeasure: DynamicProperty, @unchecked Sendable {

  struct SizeBounds: Sendable {
    static let unbounded: SizeBounds = .init(
      min: .init(width: -CGFloat.infinity, height: -CGFloat.infinity),
      max: .init(width: CGFloat.infinity, height: CGFloat.infinity)
    )
    static let nonNegative: SizeBounds = .init(
      min: .init(width: 0, height: 0),
      max: .init(width: CGFloat.infinity, height: CGFloat.infinity)
    )
    static let vertical: SizeBounds = .init(
      min: .init(width: 0, height: -CGFloat.infinity),
      max: .init(width: 0, height: CGFloat.infinity)
    )
    static let verticalNonNegative: SizeBounds = .init(
      min: .init(width: 0, height: 0),
      max: .init(width: 0, height: CGFloat.infinity)
    )
    static let horizontal: SizeBounds = .init(
      min: .init(width: -CGFloat.infinity, height: 0),
      max: .init(width: CGFloat.infinity, height: 0)
    )
    static let horizontalNonNegative: SizeBounds = .init(
      min: .init(width: 0, height: 0),
      max: .init(width: CGFloat.infinity, height: 0)
    )

    init(
      min: CGSize,
      max: CGSize
    ) {
      self.min = min
      self.max = max
    }
    var min: CGSize
    var max: CGSize

    func bounding(size: CGSize) -> CGSize {
      (size <|> min) >|< max
    }
  }

  init(
    wrappedValue: CGSize = .zero,
    minimumDistance: CGFloat = 0,
    coordinateSpace: CoordinateSpace = .global
  ) {
    self.minimumDistance = minimumDistance
    self.coordinateSpace = coordinateSpace
    self.posted = wrappedValue
    self.wrappedValue = wrappedValue
  }

  var projectedValue: Self { self }

  fileprivate let minimumDistance: CGFloat
  fileprivate let coordinateSpace: CoordinateSpace
  var wrappedValue: CGSize

  mutating func update() {
    let drag = dragCGSize ?? .zero

    wrappedValue = CGSize(
      width: posted.width + drag.width,
      height: posted.height + drag.height
    )
  }
  @GestureState var dragCGSize: CGSize?
  @State var posted: CGSize
}

private extension View {
  func draggable(
    updating measure: DragMeasure,
    smoothly: Bool = false,
    bounds: DragMeasure.SizeBounds = .unbounded,
    updateRatio: CGFloat = 1.0
  ) -> some View {
    self
      .gesture(
        DragGesture(
          minimumDistance: measure.minimumDistance,
          coordinateSpace: measure.coordinateSpace
        )
        .updating(
          measure.$dragCGSize,
          body: { value, state, _ in
            state = .init(
              width: value.translation.width * updateRatio,
              height: value.translation.height * updateRatio
            )
          }
        )
        .onEnded { value in
          let last = measure.posted
          let current = last + value.translation * updateRatio
          let next = last + value.predictedEndTranslation * updateRatio
          let fixedCurrent = bounds.bounding(size: current)
          measure.posted = fixedCurrent
          guard smoothly else { return }
          let fixedNext = bounds.bounding(size: next)
          let max = last <|> (current <|> next)
          let remainder = fixedNext - fixedCurrent
          let distValue = remainder.width + remainder.height
          let availValue = max.width + max.height
          withAnimation(
            .interpolatingSpring(
              stiffness: 200, damping: 35, initialVelocity: distValue / availValue)
          ) {
            measure.posted = fixedNext
          }
        }
      )
  }
}

infix operator <|>
private func <|> (lhs: CGSize, rhs: CGSize) -> CGSize {
  .init(
    width: max(lhs.width, rhs.width),
    height: max(lhs.height, rhs.height)
  )
}

infix operator <?-
private func <?- (lhs: CGSize, rhs: CGSize) -> CGSize {
  let it = ProposedViewSize(width: lhs.width, height: lhs.height)
    .replacingUnspecifiedDimensions(by: rhs)
  return .init(
    width: it.width.isFinite ? lhs.width : (rhs.width.isFinite ? rhs.width : .zero),
    height: it.height.isFinite ? lhs.height : (rhs.height.isFinite ? rhs.height : .zero)
  )
}

infix operator >|<
private func >|< (lhs: CGSize, rhs: CGSize) -> CGSize {
  .init(
    width: min(lhs.width, rhs.width),
    height: min(lhs.height, rhs.height)
  )
}

private func + (lhs: CGSize, rhs: CGSize) -> CGSize {
  let sumWidth =
  if lhs.width.isFinite && rhs.width.isFinite {
    lhs.width + rhs.width
  } else if lhs.width.isFinite {
    rhs.width
  } else {
    lhs.width
  }
  let sumHeight =
  if lhs.height.isFinite && rhs.height.isFinite {
    lhs.height + rhs.height
  } else if lhs.height.isFinite {
    rhs.height
  } else {
    lhs.height
  }
  return .init(width: sumWidth, height: sumHeight)
}

private func - (lhs: CGSize, rhs: CGSize) -> CGSize {
  let sumWidth =
  if lhs.width.isFinite && rhs.width.isFinite {
    lhs.width - rhs.width
  } else if lhs.width.isFinite {
    rhs.width
  } else {
    lhs.width
  }
  let sumHeight =
  if lhs.height.isFinite && rhs.height.isFinite {
    lhs.height - rhs.height
  } else if lhs.height.isFinite {
    rhs.height
  } else {
    lhs.height
  }
  return .init(width: sumWidth, height: sumHeight)
}

private func * (lhs: CGSize, rhs: CGFloat) -> CGSize {
  .init(width: lhs.width * rhs, height: lhs.height * rhs)
}
private func * (lhs: CGFloat, rhs: CGSize) -> CGSize {
  rhs * lhs
}

extension Color {
  static let redmondBackground = Color(white: 0.78)
  static let redmondShadow = Color(white: 0.55)
}

#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
#elseif os(macOS)
import AppKit
typealias PlatformFont = NSFont
#endif

extension View {
  @ViewBuilder
  func redmondBackground(invert: Bool = false) -> some View {
    let offset: CGFloat = invert ? 1 : 0
    self
      .offset(x: offset, y: offset)
      .background(
        ZStack {
          Rectangle().fill(Color.redmondBackground)
          Corner(
            style: invert
            ? .topLeft
            : .bottomRight
          )
          .stroke(
            Color.redmondShadow,
            style: .init(lineWidth: 2, lineCap: .square, lineJoin: .miter)
          ).padding(2)
          Corner(
            style: invert
            ? .bottomRight
            : .topLeft
          )
          .stroke(.gray.mix(with: .white, by: 0.9), style: .init(lineWidth: 2, lineCap: .square, lineJoin: .miter))
          Corner(
            style: invert
            ? .topLeft
            : .bottomRight
          )
          .stroke(.black, style: .init(lineWidth: 2, lineCap: .square, lineJoin: .miter))
        }
      )
  }
}

private struct Corner: Shape {
  enum Style { case topLeft, bottomRight }

  @State var style: Style

  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(
        to: CGPoint(
          x: 0,
          y: rect.size.height-1
        )
      )
      path.addLine(
        to: style == .topLeft
        ? .zero
        : CGPoint(
          x: rect.size.width-1,
          y: rect.size.height-1
        )
      )
      path.addLine(
        to: CGPoint(
          x: rect.size.width-1,
          y: 0
        )
      )
    }
  }
}

private struct RedmondView<V: View>: View {
  init(
    title: String,
    titleColor: Color,
    titleBarColor: Color,
    close: @escaping () async -> Void,
    @ViewBuilder content: @escaping () -> V
  ) {
    self.title = title
    self.titleColor = titleColor
    self.titleBarColor = titleBarColor
    self.content = content
    self._drag = .init(wrappedValue: .zero, minimumDistance: .zero, coordinateSpace: .global)
    self.close = close
  }

  let close:  () async -> Void
  let titleColor: Color
  let titleBarColor: Color
  let content: () -> V
  let title: String
  let bounds: DragMeasure.SizeBounds = .unbounded
  @State var zIndex = 0.0
  @DragMeasure var drag: CGSize

  var body: some View {
    Color.clear
      .frame(width: 0.001, height: 0.001)
      .overlay(alignment: .topLeading) {
        VStack {
          HStack {
            Text(title)
              .monospaced()
              .font(.callout.bold())
              .padding(4)
            Spacer()
            Button {
              Task { await close() }
            } label: {
              Image(systemName: "xmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 12, height: 12)
                .padding(2)
            }
            .buttonStyle(RedmondButtonStyle())
          }
          .padding(.vertical, 1)
          .foregroundStyle(titleColor)
          .background(titleBarColor)
          .padding(.trailing, 3)
          .draggable(updating: $drag, bounds: bounds)
          content()
        }
        .padding(4)
        .fixedSize()
        .redmondBackground()
        .offset(drag)
        .ignoresSafeArea()
        .zIndex(zIndex)
      }
  }
}

protocol RedmondWindow: View {
  associatedtype Content: View
  @ViewBuilder var content: Content { get }
  var titleColor: Color { get }
  var titleBarColor: Color { get }
  var title: String { get }
  var close: () async -> Void { get }
}

extension RedmondWindow {
  var titleColor: Color { .redmondTitleEnabledText }
  var titleBarColor: Color { .redmondTitleEnabledBar }
  var body: some View {
    RedmondView(title: title, titleColor: titleColor, titleBarColor: titleBarColor, close: close) {
      content
    }
  }
}

extension ShapeStyle where Self == Color {
  static var redmondTitleEnabledText: Color { Color(red: 0.988, green: 0.988, blue: 0.988, opacity: 1.0) }
  static var redmondTitleDisabledText: Color { Color(red: 0.753, green: 0.753, blue: 0.753, opacity: 1.0) }
  static var redmondTitleEnabledBar: Color { Color(red: 0.0, green: 0.0, blue: 0.627, opacity: 1.0) }
  static var redmondTitleDisabledBar: Color { Color(red: 0.455, green: 0.455, blue: 0.455, opacity: 1.0) }
  static var redmondDesktop: Color { Color(red: 0.212, green: 0.478, blue: 0.475, opacity: 1.0) }
}

extension View {
  func presenting<Dep, W: RedmondWindow>(_ item: Binding<Dep?>, @ViewBuilder builder: (Dep, _ close: @escaping () async -> Void) -> W) -> some View {
    VStack {
      self
      if let itemValue = item.wrappedValue {
        builder(itemValue, { item.wrappedValue = nil })
      } else {
        Color.clear.frame(width: 0.001, height: 0.001)
      }
    }
  }
}

struct WindowArea<V: View>: Scene {
  @ViewBuilder let content: () -> V
  let windows: [any RedmondWindow] = []
  @State var origin: CGPoint?
  @State var size: CGSize?
  var body: some Scene {
    WindowGroup {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .windowIdealPlacement { content, context in
      return .init(context.defaultDisplay.bounds.origin, size: context.defaultDisplay.bounds.size)
    }
  }
}

struct RedmondButtonStyle: ButtonStyle {

  private let win95Gray = Color(red: 0.75, green: 0.75, blue: 0.75)
  private let darkGray = Color(red: 0.5, green: 0.5, blue: 0.5)

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .regular, design: .default))
      .foregroundColor(.black)
      .padding(.horizontal, 3)
      .padding(.vertical, 3)
      .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
      .background(
        ZStack {
          win95Gray
          GeometryReader { geo in
            if configuration.isPressed {
              Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0))
              }
              .stroke(Color.black, lineWidth: 2)
              Path { p in
                p.move(to: CGPoint(x: 1, y: geo.size.height - 1))
                p.addLine(to: CGPoint(x: 1, y: 1))
                p.addLine(to: CGPoint(x: geo.size.width - 1, y: 1))
              }
              .stroke(darkGray, lineWidth: 2)
            } else {
              Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height))
                p.addLine(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0))
              }
              .stroke(Color.white, lineWidth: 2)
              Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                p.addLine(to: CGPoint(x: geo.size.width, y: 0))
              }
              .stroke(Color.black, lineWidth: 2)
              Path { p in
                p.move(to: CGPoint(x: 1, y: geo.size.height - 1))
                p.addLine(to: CGPoint(x: geo.size.width - 1, y: geo.size.height - 1))
                p.addLine(to: CGPoint(x: geo.size.width - 1, y: 1))
              }
              .stroke(darkGray, lineWidth: 2)
            }
          }
        }
      )
      .padding(.horizontal, 2)
      .padding(.bottom, 3)
      .padding(.top, 1)
  }
}


struct InfoForm<V: View>: View {
  @ScaledMetric(relativeTo: .caption) var off = 10
  let title: String
  @ViewBuilder let builder: () -> V
  var body: some View {
    let titleText = Text(title).font(.custom("System", size: off).bold())

    Form {
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: off*0.5) {
          ForEach(subviews: builder()) { v in
            v
          }
        }
        .padding(off)
      }
      .border(.separator)
      .invertedMask(alignment: .topLeading, {
        titleText
          .hidden()
          .overlay {
            Capsule()
              .fill(.black)
              .border(.black, width: 2)
          }
          .offset(x: off, y: -off*0.5)

      })
      .overlay(alignment: .topLeading) {
        titleText
          .offset(x: off, y: -off*0.5)
      }
    }
    .padding()
  }
}


@ViewBuilder
func StatusPill(_ label: String, value: String) -> some View {
  LabeledContent {
    Text(value)
  } label: {
    Text(label)
  }
  .labeledContentStyle(DetailStyle())
}


private struct DetailStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.label.monospaced().bold()
        .padding(.vertical, 2)
      Divider()
      configuration.content
        .padding(.vertical, 2)
    }
    .font(.caption)
    .padding(.horizontal, 4)
    .background(.ultraThinMaterial, in: .capsule)
    .background(.black.opacity(0.3), in: .capsule)
    .overlay { Capsule().stroke(.separator, lineWidth: 1) }
    .fixedSize()
  }
}

func AsyncButton(_ title: String, action: @escaping () async  -> Void) -> some View {
  Button(title, action: { Task { await action() } } )
    .buttonStyle(RedmondButtonStyle())
}

extension View {
  @inlinable
  func invertedMask<Mask: View>(
    alignment: Alignment = .center,
    @ViewBuilder _ mask: () -> Mask
  ) -> some View {
    self.mask {
      Rectangle()
        .overlay(alignment: alignment) {
          mask()
            .blendMode(.destinationOut)
        }
    }
  }
}
