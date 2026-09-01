// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TDXQuoteVerifier",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TDXQuoteVerifier", targets: ["TDXQuoteVerifier"]),
    ],
    targets: [
        .target(name: "TDXQuoteVerifier"),
        .testTarget(name: "TDXQuoteVerifierTests", dependencies: ["TDXQuoteVerifier"]),
    ]
)
