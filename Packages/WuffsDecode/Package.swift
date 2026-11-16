// swift-tools-version: 5.9

import PackageDescription

// Wuffs, the memory-safe image decoder untrusted image bytes go through (docs/IMAGES.md §2).
// The C source is vendored verbatim (VENDORING.md); only PNG, JPEG and GIF are compiled in.
let package = Package(
    name: "WuffsDecode",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WuffsDecode", targets: ["WuffsDecode"]),
    ],
    targets: [
        .target(
            name: "CWuffs",
            path: "Sources/CWuffs",
            exclude: ["wuffs-v0.4.c"],
            sources: ["shim.cpp"],
            publicHeadersPath: "include"
        ),
        .target(name: "WuffsDecode", dependencies: ["CWuffs"]),
        .testTarget(name: "WuffsDecodeTests", dependencies: ["WuffsDecode"]),
    ],
    cxxLanguageStandard: .cxx17
)
