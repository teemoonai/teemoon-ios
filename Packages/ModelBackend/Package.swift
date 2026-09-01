// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ModelBackend",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "ModelBackend", targets: ["ModelBackend"]),
    ],
    dependencies: [
        // NO MLX TRAIT. The `MLX` trait pulls in mlx-swift-lm, which teemoon no
        // longer uses — see LocalModelCatalog.swift for why the runtime was
        // retired. Dropping it also drops two build prerequisites that cost
        // real time: mlx-swift's `CudaBuild` build-tool plugin (headless
        // xcodebuild needed -skipPackagePluginValidation) and the separately
        // downloaded Metal Toolchain.
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel",
            from: "0.8.0"
        ),
        // Google's LiteRT-LM — the on-device runtime. VENDORED: see
        // Packages/LiteRTLM/Package.swift for why upstream cannot be used by
        // URL. Linked but NOT re-exported: it declares its own `Tool`, which
        // would collide with AnyLanguageModel's.
        .package(path: "../LiteRTLM"),
    ],
    targets: [
        .target(
            name: "ModelBackend",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "LiteRTLM", package: "LiteRTLM"),
            ]
        ),
    ]
)
