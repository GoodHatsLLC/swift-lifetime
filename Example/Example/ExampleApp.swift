import Foundation
import Boot
import BootSwiftUI
import SwiftUI

struct AppDependency: Dependency {
  init(with requirement: (), in scope: Scope) async throws {
    let launch: LaunchContext = .init(launchID: "LAUNCH:\(UUID().uuidString)", startedAt: .now)
    self.launch = launch
    self.config = try scope.components.shared(DesktopDependency.self, input: {
      launch
    })
  }
  let launch: LaunchContext
  let config: Scoped<Component<DesktopDependency>>
}


@main
struct ExampleApp: App {
  private let appSource: Scoped<Component<AppDependency>>

  init() {
    let scope = Scope.root()
    self.appSource = try! scope.components.shared(AppDependency.self, input: ())
  }

  var body: some Scene {
    WindowArea {
      AppRoot(source: appSource)
    }
  }
}

private struct AppRoot: View {
  @Mount private var app: Component<AppDependency>?

  init(source: Scoped<Component<AppDependency>>) {
    _app = Mount(source)
  }

  var body: some View {
    Group {
      if let app {
        DesktopRoot(source: app.exports.config)
      } else {
        ProgressView()
      }
    }
  }
}

private struct DesktopRoot: View {
  @Mount private var desktop: Component<DesktopDependency>?

  init(source: Scoped<Component<DesktopDependency>>) {
    _desktop = Mount(source)
  }

  var body: some View {
    Group {
      if let desktop {
        DesktopView(component: desktop)
      } else {
        ProgressView()
      }
    }
  }
}

struct SessionDependency: Dependency {
  struct Input: Sendable {
    let session: AuthSession
  }

  let session: Scoped<AuthSession>
  let summary: Scoped<String>
  let authenticatedClient: Scoped<AuthenticatedNetworkClient>
  let loadTimeline: @Sendable () async throws -> [Post]

  init(with requirement: Input, in scope: Scope) async throws {
    let session = try scope.entities.instance(requirement.session, name: "AuthSession")
    let authenticatedClient = try scope.entities.shared(name: "AuthenticatedClient") {
      AuthenticatedNetworkClient(session: requirement.session)
    }
    self.session = session
    self.summary = try scope.entities.shared(name: "SessionSummary") {
      let current = try await session.get()
      return "Authenticated as \(current.displayName) on fake tenant REDMOND."
    }
    self.authenticatedClient = authenticatedClient
    self.loadTimeline = {
      let client = try await authenticatedClient.get()
      return try await client.listPosts()
    }
  }
}
