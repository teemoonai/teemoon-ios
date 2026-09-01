// swift-tools-version: 5.9
//
// 5.9 deliberately, matching upstream. Under 6.x tools the target defaults to
// the Swift 6 language mode and upstream's `ExperimentalFlags` fails to compile
// — a dozen "nonisolated global shared mutable state" errors. This is vendored
// third-party code: it should build exactly as its authors build it, not be
// patched to satisfy a stricter mode.
import PackageDescription

// A VENDORED copy of Google's LiteRT-LM Swift wrapper.
// Upstream: https://github.com/google-ai-edge/LiteRT-LM @ v0.14.0
// Commit:   80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6
// Licence:  Apache 2.0 (see LICENSE; sources carry Google's copyright headers)
//
// WHY VENDORED, and what to check before deleting this package:
//
// Upstream's v0.14.0 manifest declares binary-target checksums that do not match
// its own published release assets — the artifacts were evidently re-uploaded
// after tagging. SPM refuses to resolve:
//
//     checksum of downloaded artifact of binary target 'CLiteRTLM'
//     (dddac2f6…) does not match checksum specified by the manifest (4a4bdb0e…)
//
// Pinning to 0.13.1 did not help: SPM kept resolving 0.14.0 even after clearing
// Package.resolved, the repository cache and the checkout.
//
// The checksums below are the REAL ones, obtained by downloading each artifact
// and running `swift package compute-checksum` — not copied from the error
// message. Honest limitation: that verifies the artifacts are self-consistent,
// NOT that they are authentic. Authenticity rests on HTTPS from Google's
// official GitHub releases, and on the zips containing a well-formed xcframework
// (ios-arm64 + ios-arm64-simulator slices, checked by hand).
//
// DELETE THIS PACKAGE and depend on upstream directly once
// `.package(url: "https://github.com/google-ai-edge/LiteRT-LM", from: …)`
// resolves cleanly.
//
// Note for whoever revisits: cloning upstream also trips a Git LFS smudge error
// (`remote missing object`). `GIT_LFS_SKIP_SMUDGE=1` is the fix — the
// `prebuilt/` dylibs are Bazel artifacts and SPM takes its binaries from
// GitHub Releases, so nothing is lost by skipping them.
//
// See VENDORING.md in this directory for the patch register, the macOS-slice
// repackage procedure, and the checksum-verification caveat.
let package = Package(
    name: "LiteRTLM",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LiteRTLM", targets: ["LiteRTLM"]),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM.xcframework.zip",
            checksum: "dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
        ),
        // THE macOS SLICE IS REPACKAGED LOCALLY — it is not consumed from the URL.
        //
        // Upstream ships iOS as a framework but macOS as a "library-type" slice:
        // loose `Headers/` next to a `.dylib`. Xcode copies a library-type slice's
        // headers into the SHARED `$BUILT_PRODUCTS_DIR/include/`. Phala's dcap-qvl
        // ships its macOS slice the same way, so both try to write
        // `include/module.modulemap` and the build dies during PLANNING:
        //
        //     error: Multiple commands produce '…/Debug/include/module.modulemap'
        //
        // Not a compile error — nothing compiles at all, the entire macOS
        // destination is unbuildable. iOS never hit this because Google's iOS
        // slice is a framework and puts nothing in `include/`.
        //
        // The repackage procedure in `Packages/LiteRTLM/VENDORING.md` corrects
        // the SHAPE rather than working around the symptom: it verifies the
        // upstream zip's SHA-256, then rebuilds the slice as a framework — the same shape Google already
        // uses for iOS. Headers move inside the bundle, `include/` stays empty,
        // and the collision cannot recur for any future library-type dependency.
        // Both architectures survive, so Intel Macs stay supported, and the
        // module stays named `CLiteRTLM` — which is what upstream's own macOS
        // modulemap declares — so `import CLiteRTLM` needs no platform #if.
        //
        // THE ARTIFACT IS COMMITTED, VIA GIT LFS — it is not fetched at resolve
        // time. `.binaryTarget(path:)` is validated when the MANIFEST loads, on
        // every platform, so a missing artifact does not merely break macOS: it
        // stops the package resolving at all and takes the iOS build with it.
        // The file therefore has to be present in a fresh clone. Git LFS
        // delivers it there with no per-machine auth or setup — which is why
        // the artifact is committed via LFS rather than fetched from a
        // release URL.
        //
        // Regenerate (only needed when bumping the upstream version) by
        // following the repackage procedure in `Packages/LiteRTLM/VENDORING.md`.
        //
        // The procedure is bit-for-bit reproducible — same upstream zip in,
        // same bytes out — so the committed artifact can always be re-derived
        // and checked against what is here. VENDORING.md records what is
        // preserved (the Mach-O, both archs, Google's headers verbatim) and
        // what is not (Google's code signature, invalidated by the
        // install-name rewrite and replaced ad-hoc — Xcode re-signs on embed
        // regardless).
        //
        // Only the Mach-O is LFS-tracked, by exact path. A glob would also match
        // the bundle's five symlinks and LFS would rewrite them into pointer
        // files, quietly breaking the framework.
        .binaryTarget(
            name: "CLiteRTLM_mac",
            path: "artifacts/CLiteRTLM_mac.xcframework"
        ),
        // NO dSYM SHIPS FOR THIS FRAMEWORK, and none can be made.
        //
        // Every archive upload draws: "The archive did not include a dSYM for
        // CLiteRTLM.framework with the UUIDs [7826BF37-E5CD-3CE1-9AE9-447F3F8A285D]".
        // It is a WARNING — the build uploads and distributes normally.
        //
        // Checked rather than assumed (2026-07-30, v0.14.0):
        //   • the device slice's UUID is exactly the one App Store Connect names
        //   • `dwarfdump --debug-info` on that binary prints an EMPTY .debug_info —
        //     it ships stripped, so there is no DWARF to build a dSYM out of
        //   • the upstream release has three assets, all payload: the two xcframework
        //     zips and a macOS CLI. No dSYM asset exists to fetch.
        //
        // So this cannot be fixed here. The cost is narrow and worth knowing: a crash
        // INSIDE LiteRT's native code will show raw addresses for its frames in
        // Organizer and ASC. teemoon's own frames still symbolicate — the app targets
        // build `dwarf-with-dsym`, verified in the Release settings.
        //
        // The real fix is upstream publishing dSYMs alongside the xcframework. Until
        // then, the version pinned above is the thing to keep: `atos -o` against this
        // exact binary can still resolve EXPORTED symbols, which is the difference
        // between a rough frame and nothing at all.
        .target(
            name: "LiteRTLM",
            dependencies: [
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/LiteRTLM"
            // UPSTREAM'S `-all_load` IS DELIBERATELY DROPPED.
            //
            // It breaks every SwiftUI Preview in the app: the flag forces the
            // linker to pull all objects out of *every* static archive on the
            // command line — including the compiler runtime — and the preview's
            // JIT linker then dies on
            // `duplicate definition of symbol '___absvdi2'` in
            // libclang_rt.iossim.a. Not specific to this view; it took out
            // previews project-wide.
            //
            // Dropping it is safe here because `-all_load` only affects STATIC
            // archives, and CLiteRTLM.framework's binary is a Mach-O
            // *dynamically linked shared library* — checked with `file`, on the
            // simulator slice this actually links against. There are no
            // archive members to force-load, so the flag was doing nothing for
            // this artefact.
            //
            // Verified rather than assumed: the live device suite (engine load,
            // generation, tool calling through the bridge) passes without it.
            // If a future release ships a static slice, the targeted fix is
            // `-force_load <that archive>`, never `-all_load`.
        ),
    ]
)
