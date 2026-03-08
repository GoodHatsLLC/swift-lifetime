import Observation
import SwiftUI
import Boot
import BootSwiftUI
 
struct DesktopDependency: Dependency {
  init(with requirement: LaunchContext, in scope: Scope) async throws {
    config = try scope.entities.instance(requirement)
    networkClient = try scope.entities.shared(.mainActor) {
      NetworkClient(launch: requirement)
    }
    makeSession = try scope.components.factory(SessionDependency.self)
  }
  let config: Scoped<LaunchContext>
  let networkClient: Scoped<NetworkClient>
  let makeSession: ComponentFactory<SessionDependency.Input, SessionDependency>
}

struct DesktopView: View {
  var component: Component<DesktopDependency>
  @Mount var session: Component<SessionDependency>?
  var body: some View {
    ZStack(alignment: .center) {
      Color.redmondDesktop
        .ignoresSafeArea()

      if let session {
        SessionWindow(mounting: $session) {
          await $session.unmount()
        }
      }

        TaskBar(component: component)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    .task {
      guard session == nil else { return }
      if let next = try? await component.exports.makeSession(
        .init(
          session: .init(
            userID: "50m3",
            displayName: "SomeDUDE",
            token: "",
            issuedAt: .now,
            expiresAt: .distantFuture
          )
        )
      ) {
        await $session.replace(with: next)
      }
    }
  }
}

extension DesktopView {
  private struct TaskBar: View {
    var component: Component<DesktopDependency>
    var body: some View {
      HStack(spacing: 10) {
        RedmondStart()
          .padding(.leading, 8)

        StatusPill("Boot", value: "222")
        StatusPill("Session", value: "111")
        Spacer()
        Text("???")
          .font(.caption)
          .foregroundStyle(.black)
          .lineLimit(1)
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, minHeight: 40)
      .background(Color(red: 0.75, green: 0.75, blue: 0.75))
      .overlay(alignment: .top) {
        Rectangle().fill(.white).frame(height: 2)
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(.black).frame(height: 2)
      }
    }
  }
}
