// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

func swiftSettings(_ settings: PackageDescription.SwiftSetting...) -> [PackageDescription
  .SwiftSetting]
{
  [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .defaultIsolation(.none),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  ] + settings
}

let package = Package(
  name: "Boot",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
    .tvOS(.v26),
    .watchOS(.v26),
  ],
  products: [
    .library(
      name: "Boot",
      targets: ["Boot"]
    ),
    .library(
      name: "BootSwiftUI",
      targets: ["BootSwiftUI"]
    ),
  ],
  targets: [
    .target(
      name: "Boot",
      swiftSettings: swiftSettings()
    ),
    .testTarget(
      name: "BootTests",
      dependencies: ["Boot"],
      swiftSettings: swiftSettings()
    ),
    .testTarget(
      name: "BootSwiftUITests",
      dependencies: ["Boot", "BootSwiftUI"],
      swiftSettings: swiftSettings()
    ),
    .target(
      name: "BootSwiftUI",
      dependencies: ["Boot"],
      swiftSettings: swiftSettings()
    ),
  ],
  swiftLanguageModes: [.v6]
)
