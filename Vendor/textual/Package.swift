// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "textual",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
  ],
  products: [
    .library(name: "Textual", targets: ["Textual"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.1"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.7"),
    .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "Textual",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        .product(name: "SwiftUIMath", package: "swiftui-math"),
      ],
      resources: [
        .process("Internal/Highlighter/Prism")
      ],
      swiftSettings: [
        .define("TEXTUAL_ENABLE_LINKS", .when(platforms: [.macOS, .iOS, .watchOS, .visionOS])),
        .define("TEXTUAL_ENABLE_TEXT_SELECTION", .when(platforms: [.macOS, .iOS, .visionOS])),
        // teemoon vendoring change (the ONLY one): markdown layout glue at
        // -Onone is what turned a heavy transcript into a frozen phone on
        // Debug device builds — unspecialised generics between every TextKit
        // call. Optimised even in Debug; the app's own code stays -Onone and
        // fully debuggable. unsafeFlags is legal here BECAUSE the package is
        // vendored — SPM rejects it in remote dependencies, which is the
        // reason this directory exists.
        .unsafeFlags(["-O"], .when(configuration: .debug)),
      ]
    ),
    .testTarget(
      name: "TextualTests",
      dependencies: [
        "Textual",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      exclude: [
        "Internal/TextInteraction/__Snapshots__",
        "StructuredText/__Snapshots__",
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .define("TEXTUAL_ENABLE_TEXT_SELECTION", .when(platforms: [.macOS, .iOS, .visionOS]))
      ]
    ),
  ]
)
