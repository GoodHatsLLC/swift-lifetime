import SwiftUI

struct RedmondStart: View {

  static let intrinsicSize = CGSize(width: 30, height: 28)

  struct Group: View {

    struct S: View { // SVGPath

      struct Sh: Shape {

        func path(in rect: CGRect) -> Path {
          Path { path in
            path.addLines([
              CGPoint(x: 24, y: 12),
              CGPoint(x: 22, y: 10),
              CGPoint(x: 22, y: 4),
              CGPoint(x: 26, y: 4),
              CGPoint(x: 28, y: 6),
              CGPoint(x: 28, y: 12)
            ])
            path.closeSubpath()
          }
        }
      }

      var body: some View {
        Sh()
          .fill(Color(red: 0, green: 1, blue: 0))
      }
    }

    struct Path1: View { // SVGPath

      struct Path1: Shape {

        func path(in rect: CGRect) -> Path {
          Path { path in
            path.addLines([
              CGPoint(x: 24, y: 22),
              CGPoint(x: 22, y: 20),
              CGPoint(x: 22, y: 14),
              CGPoint(x: 26, y: 14),
              CGPoint(x: 28, y: 16),
              CGPoint(x: 28, y: 22)
            ])
            path.closeSubpath()
          }
        }
      }

      var body: some View {
        Path1()
          .fill(Color(red: 1, green: 1, blue: 0))
      }
    }

    struct Path2: View { // SVGPath

      struct Path2: Shape {

        func path(in rect: CGRect) -> Path {
          Path { path in
            path.addLines([
              CGPoint(x: 4, y: 24),
              CGPoint(x: 4, y: 20),
              CGPoint(x: 6, y: 20),
              CGPoint(x: 6, y: 24)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 14, y: 22),
              CGPoint(x: 14, y: 16),
              CGPoint(x: 16, y: 14),
              CGPoint(x: 20, y: 14),
              CGPoint(x: 20, y: 20),
              CGPoint(x: 18, y: 22)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 0, y: 22),
              CGPoint(x: 0, y: 18),
              CGPoint(x: 2, y: 18),
              CGPoint(x: 2, y: 22)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 8, y: 22),
              CGPoint(x: 8, y: 18),
              CGPoint(x: 10, y: 18),
              CGPoint(x: 10, y: 22)
            ])
            path.closeSubpath()
          }
        }
      }

      var body: some View {
        Path2()
          .fill(Color(red: 0, green: 0, blue: 1))
      }
    }

    struct Path3: View { // SVGPath

      struct Path3: Shape {

        func path(in rect: CGRect) -> Path {
          Path { path in
            path.addLines([
              CGPoint(x: 14, y: 12),
              CGPoint(x: 14, y: 6),
              CGPoint(x: 14, y: 6),
              CGPoint(x: 16, y: 4),
              CGPoint(x: 20, y: 4),
              CGPoint(x: 20, y: 10),
              CGPoint(x: 19, y: 11),
              CGPoint(x: 18, y: 12)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 4, y: 12),
              CGPoint(x: 4, y: 8),
              CGPoint(x: 6, y: 8),
              CGPoint(x: 6, y: 12)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: -0, y: 10),
              CGPoint(x: -0, y: 6),
              CGPoint(x: 2, y: 6),
              CGPoint(x: 2, y: 10)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 8, y: 10),
              CGPoint(x: 8, y: 6),
              CGPoint(x: 10, y: 6),
              CGPoint(x: 10, y: 10)
            ])
            path.closeSubpath()
          }
        }
      }

      var body: some View {
        Path3()
          .fill(Color(red: 1, green: 0, blue: 0))
      }
    }

    struct Path4: View { // SVGPath

      struct Path4: Shape {

        func path(in rect: CGRect) -> Path {
          Path { path in
            path.addLines([
              CGPoint(x: 4, y: 28),
              CGPoint(x: 4, y: 26),
              CGPoint(x: 6, y: 26),
              CGPoint(x: 6, y: 28)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 2, y: 26),
              CGPoint(x: -0, y: 26),
              CGPoint(x: 0, y: 24),
              CGPoint(x: 2, y: 24)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 10, y: 26),
              CGPoint(x: 8, y: 26),
              CGPoint(x: 8, y: 24),
              CGPoint(x: 10, y: 24)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 12, y: 2),
              CGPoint(x: 16, y: 2),
              CGPoint(x: 16, y: 0),
              CGPoint(x: 21, y: 0),
              CGPoint(x: 26, y: 0),
              CGPoint(x: 26, y: 2),
              CGPoint(x: 30, y: 2),
              CGPoint(x: 30, y: 14),
              CGPoint(x: 30, y: 26),
              CGPoint(x: 26, y: 26),
              CGPoint(x: 26, y: 24),
              CGPoint(x: 16, y: 24),
              CGPoint(x: 16, y: 26),
              CGPoint(x: 12, y: 26),
              CGPoint(x: 12, y: 14)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 18, y: 22),
              CGPoint(x: 18, y: 21),
              CGPoint(x: 19, y: 20),
              CGPoint(x: 20, y: 20),
              CGPoint(x: 20, y: 14),
              CGPoint(x: 16, y: 14),
              CGPoint(x: 16, y: 15),
              CGPoint(x: 15, y: 16),
              CGPoint(x: 14, y: 16),
              CGPoint(x: 14, y: 22)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 28, y: 22),
              CGPoint(x: 28, y: 16),
              CGPoint(x: 27, y: 16),
              CGPoint(x: 26, y: 15),
              CGPoint(x: 26, y: 14),
              CGPoint(x: 22, y: 14),
              CGPoint(x: 22, y: 20),
              CGPoint(x: 23, y: 20),
              CGPoint(x: 24, y: 21),
              CGPoint(x: 24, y: 22)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 4, y: 14),
              CGPoint(x: 6, y: 14),
              CGPoint(x: 6, y: 16),
              CGPoint(x: 6, y: 18),
              CGPoint(x: 4, y: 18),
              CGPoint(x: 4, y: 16)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: -0, y: 12),
              CGPoint(x: 2, y: 12),
              CGPoint(x: 2, y: 14),
              CGPoint(x: 2, y: 16),
              CGPoint(x: -0, y: 16),
              CGPoint(x: -0, y: 14)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 8, y: 12),
              CGPoint(x: 10, y: 12),
              CGPoint(x: 10, y: 14),
              CGPoint(x: 10, y: 16),
              CGPoint(x: 8, y: 16),
              CGPoint(x: 8, y: 14)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 18, y: 12),
              CGPoint(x: 18, y: 11),
              CGPoint(x: 19, y: 10),
              CGPoint(x: 20, y: 10),
              CGPoint(x: 20, y: 4),
              CGPoint(x: 16, y: 4),
              CGPoint(x: 16, y: 5),
              CGPoint(x: 15, y: 6),
              CGPoint(x: 14, y: 6),
              CGPoint(x: 14, y: 12)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 28, y: 12),
              CGPoint(x: 28, y: 6),
              CGPoint(x: 27, y: 6),
              CGPoint(x: 26, y: 5),
              CGPoint(x: 26, y: 4),
              CGPoint(x: 22, y: 4),
              CGPoint(x: 22, y: 10),
              CGPoint(x: 23, y: 10),
              CGPoint(x: 24, y: 11),
              CGPoint(x: 24, y: 12)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 6, y: 6),
              CGPoint(x: 4, y: 6),
              CGPoint(x: 4, y: 4),
              CGPoint(x: 6, y: 4)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 2, y: 4),
              CGPoint(x: -0, y: 4),
              CGPoint(x: 0, y: 2),
              CGPoint(x: 2, y: 2)
            ])
            path.closeSubpath()
            path.addLines([
              CGPoint(x: 8, y: 4),
              CGPoint(x: 8, y: 2),
              CGPoint(x: 10, y: 2),
              CGPoint(x: 10, y: 4)
            ])
            path.closeSubpath()
          }
        }
      }

      var body: some View {
        Path4()
          .fill(Color(white: 0))
      }
    }

    var body: some View {
      ZStack(alignment: .topLeading) {
        S()
        Path1()
        Path2()
        Path3()
        Path4()
      }
    }
  }

  @Environment(\.pixelLength) var pixel
  var body: some View {
      GeometryReader { proxy in
        Group()
          .frame(width: 30, height: 28,
                 alignment: .topLeading)
          .scaleEffect(x: proxy.size.width  / 30,
                       y: proxy.size.height / 28)
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
      .aspectRatio(28.0/30.0, contentMode: .fit)
      .frame(maxWidth: 30.0*pixel)
  }
}

#Preview {
  RedmondStart()
    .padding(20)
}
