import SwiftUI
import Boot
import BootSwiftUI


struct SessionWindow: RedmondWindow {
  let mounting: Mounting<SessionDependency>

  let title: String = "HI you're logged in"
  let close: () async -> Void
  var content: some View {
    if let component = mounting.component {
      InfoForm(title: "Your Profile") {
        Text("Mounted session for \(component.exports.session.name)")
      }
    } else {
      ProgressView()
    }
  }
}
