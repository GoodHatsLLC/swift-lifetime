// swift-tools-version: 6.2

import CompilerPluginSupport
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

let supportsAppleFrameworks: Bool = {
  #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    true
  #else
    false
  #endif
}()

var products: [Product] = [
  .library(name: "Lifetime", targets: ["Lifetime"]),
  .library(name: "LifetimePrimitives", targets: ["LifetimePrimitives"]),
  .library(name: "LifetimeBoundaries", targets: ["LifetimeBoundaries"]),
  .library(name: "LifetimePolicies", targets: ["LifetimePolicies"]),
  .library(name: "LifetimeIntent", targets: ["LifetimeIntent"]),
  .library(name: "LifetimeResources", targets: ["LifetimeResources"]),
]

var targets: [Target] = [
  .target(
    name: "Lifetime",
    path: "Sources/Lifetime",
    swiftSettings: swiftSettings()
  ),
  .target(
    name: "LifetimePrimitives",
    path: "Sources/LifetimePrimitives",
    swiftSettings: swiftSettings()
  ),
  .target(
    name: "LifetimeBoundaries",
    dependencies: ["Lifetime", "LifetimePrimitives"],
    path: "Sources/LifetimeBoundaries",
    swiftSettings: swiftSettings()
  ),
  .target(
    name: "LifetimePolicies",
    path: "Sources/LifetimePolicies",
    swiftSettings: swiftSettings()
  ),
  .target(
    name: "LifetimeIntent",
    dependencies: ["Lifetime", "LifetimePrimitives"],
    path: "Sources/LifetimeIntent",
    swiftSettings: swiftSettings()
  ),
  .target(
    name: "LifetimeResources",
    dependencies: ["Lifetime", "LifetimePolicies"],
    path: "Sources/LifetimeResources",
    swiftSettings: swiftSettings()
  ),
  .executableTarget(
    name: "LifetimeBenchmarks",
    dependencies: ["Lifetime"],
    swiftSettings: swiftSettings()
  ),
]

var lifetimeTestDependencies: [Target.Dependency] = [
  "Lifetime",
  "LifetimePolicies",
  "LifetimeResources",
]

if supportsAppleFrameworks {
  products.append(.library(name: "LifetimeSwiftUI", targets: ["LifetimeSwiftUI"]))
  targets.append(
    .target(
      name: "LifetimeSwiftUI",
      dependencies: ["LifetimeResources"],
      path: "Sources/LifetimeSwiftUI",
      swiftSettings: swiftSettings()
    )
  )
  lifetimeTestDependencies.append("LifetimeSwiftUI")
}

targets += [
  .testTarget(
    name: "LifetimeTests",
    dependencies: lifetimeTestDependencies,
    swiftSettings: swiftSettings()
  ),
  .testTarget(
    name: "LifetimePrimitivesTests",
    dependencies: ["LifetimePrimitives", "LifetimePolicies", "Lifetime"],
    swiftSettings: swiftSettings()
  ),
  .testTarget(
    name: "LifetimeBoundariesTests",
    dependencies: ["LifetimeBoundaries", "LifetimePrimitives", "Lifetime"],
    swiftSettings: swiftSettings()
  ),
  .testTarget(
    name: "LifetimePoliciesTests",
    dependencies: ["LifetimePolicies", "LifetimePrimitives", "LifetimeBoundaries", "Lifetime"],
    swiftSettings: swiftSettings()
  ),
  .testTarget(
    name: "LifetimeIntentTests",
    dependencies: ["LifetimeIntent", "LifetimePrimitives", "Lifetime"],
    swiftSettings: swiftSettings()
  ),
]

let package = Package(
  name: "swift-lifetime",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
  ],
  products: products,
  dependencies: [],
  targets: targets,
  swiftLanguageModes: [.v6]
)
