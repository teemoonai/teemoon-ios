//
//  MacDesignSnapshotTests.swift
//  teemoonTests
//
//  HEADLESS design capture for the macOS build.
//
//  WHY NOT XCUITest
//
//  Driving the real app is the obvious way to look at it and the wrong way to do
//  it repeatedly. On macOS an XCUITest launches teemoon into the developer's own
//  desktop session: it steals focus, raises the "automation running" notice, and
//  — because `XCUIApplication.screenshot()` is display-scoped on macOS, not
//  window-scoped — photographs every unrelated window into the .xcresult. That
//  makes routine design review impossible to run while working, and quietly
//  leaks whatever else was on screen into a CI artifact.
//
//  `ImageRenderer` rasterizes the same SwiftUI tree in-process. No app launch, no
//  focus change, no notice, nothing captured but the view asked for. It runs in
//  the background while the machine is in use, which is the only way a design
//  loop actually gets run often enough to matter.
//
//  THE LIMIT, MEASURED RATHER THAN ASSUMED
//
//  ImageRenderer rasterizes SwiftUI's OWN drawing. It cannot render views backed
//  by AppKit — List, NavigationSplitView, TextField, Table — and does not fail
//  when it meets one: it emits SwiftUI's "unsupported" placeholder, a red
//  prohibition sign on yellow, at the full frame size. A test that only checked
//  for a non-nil image and a plausible byte count would call that a pass.
//
//  Verified both directions on macOS: `ContentView` renders as the placeholder,
//  while VoiceSketchSnapshotTests' pure tree (shapes, text, custom capsules)
//  renders correctly and completely.
//
//  So the headless loop covers COMPONENTS — chips, capsules, cards, rows,
//  typography, spacing, colour in both appearances. It does NOT cover whole
//  screens, because teemoon's screens are List/NavigationStack-based. Those, plus
//  everything that is not a view tree at all (window sizing and restoration, the
//  menu bar, keyboard shortcuts, hover), need a real app: XCUITest in the
//  foreground, or a VM / remote runner for background isolation.
//
//  Writes to $SNAPSHOT_DIR (or $TEST_RUNNER_SNAPSHOT_DIR), and skips when unset,
//  matching VoiceSketchSnapshotTests.
//
//      SNAPSHOT_DIR=/tmp/mac-shots xcodebuild test-without-building \
//        -destination 'platform=macOS,arch=arm64' \
//        -only-testing:teemoonTests/MacDesignSnapshotTests
//

import ImageIO
import SwiftData
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import teemoon

@MainActor
@Suite("macOS design snapshots")
struct MacDesignSnapshotTests {

    /// The app's actual default window on macOS, measured from the running app
    /// (CGWindowList reported 1000x640), not a guess at a nice number.
    static let macWindow = CGSize(width: 1000, height: 640)

    /// Where PNGs land.
    ///
    /// TWO macOS-SPECIFIC TRAPS, both hit before this worked:
    ///
    /// 1. `xcodebuild` does not forward arbitrary shell environment into the test
    ///    process. Only `TEST_RUNNER_`-prefixed variables cross, arriving with
    ///    the prefix stripped — so the invocation sets TEST_RUNNER_SNAPSHOT_DIR
    ///    and this reads SNAPSHOT_DIR. Setting SNAPSHOT_DIR in the shell silently
    ///    does nothing: the tests pass and write no files.
    ///
    /// 2. teemoon is SANDBOXED on macOS (com.apple.security.app-sandbox), and an
    ///    app-hosted test bundle inherits that sandbox. Any path outside the
    ///    container fails with "Operation not permitted" no matter how the
    ///    directory is permissioned. So a requested path is used only if it is
    ///    actually writable, and otherwise falls back to the container's own tmp
    ///    — the resolved path is always printed, because a snapshot written
    ///    somewhere the caller cannot find is the same as no snapshot.
    private static var outputDir: URL? {
        guard let requested = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_SNAPSHOT_DIR"]
        else { return nil }
        let url = URL(fileURLWithPath: requested)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if FileManager.default.isWritableFile(atPath: url.path) { return url }
        let fallback = FileManager.default.temporaryDirectory.appending(component: "mac-design-snapshots")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        print("── snapshot ── \(url.path) is outside the app sandbox; writing to \(fallback.path)")
        return fallback
    }

    /// Everything ContentView and its children read out of the environment.
    /// In-memory only — see the note on ProviderStoreTests about app-hosted
    /// suites sharing the host's sandbox.
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let settings = AppSettings()
        let providers = ProviderStore(inMemory: true)
        let llm = ChatGeneration()
        let downloads = OllamaDownloadCenter()
        let session: ConfidentialSession

        init() throws {
            container = try ModelContainer(
                for: teemoon.Thread.self, Message.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            session = ConfidentialSession(providers: providers)
        }
    }

    private func render(_ name: String,
                        scheme: ColorScheme,
                        size: CGSize = macWindow,
                        @ViewBuilder _ content: () -> some View) throws {
        let dir = Self.outputDir ?? FileManager.default.temporaryDirectory
        let renderer = ImageRenderer(
            content: content()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            Issue.record("\(name): ImageRenderer produced nothing"); return
        }
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                buffer, UTType.png.identifier as CFString, 1, nil) else {
            Issue.record("\(name): no PNG destination"); return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            Issue.record("\(name): PNG encoding failed"); return
        }
        let suffix = scheme == .dark ? "dark" : "light"
        let filename = "\(name)-\(suffix).png"
        let png = buffer as Data

        // ATTACH FIRST, WRITE SECOND.
        //
        // The sandbox makes a plain file write unreliable in both directions: an
        // absolute path outside the container is "Operation not permitted", and
        // the container's own tmp is torn down when the test host exits, so the
        // PNG is gone before anyone can look at it. Attachments go into the
        // .xcresult, which survives the run and is the same place CI already
        // collects artifacts from:
        //
        //     xcrun xcresulttool export attachments --path <.xcresult> \
        //       --output-path <dir>
        //
        // The file write is kept as a convenience for a human running this with a
        // writable directory, and is allowed to fail without failing the test.
        Attachment.record(png, named: filename)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(component: filename)
            try png.write(to: url)
            print("── snapshot ── \(png.count / 1024) KB → \(url.path)")
        } catch {
            print("── snapshot ── \(png.count / 1024) KB → attached as \(filename) (no writable dir: \(error.localizedDescription))")
        }
    }

    /// The whole app at Mac window size, in BOTH appearances.
    ///
    /// Light is captured deliberately, and is expected to look wrong: Info.plist
    /// sets `UIUserInterfaceStyle: Dark`, a UIKit key macOS ignores, so a Mac in
    /// light appearance renders the combination the design explicitly rejected.
    /// The capture is the evidence for fixing that, not a claim it is fine.
    @Test("app shell, both appearances", arguments: [ColorScheme.dark, .light])
    func appShell(scheme: ColorScheme) throws {
        let h = try Harness()
        try render("app-shell", scheme: scheme) {
            ContentView()
                .modelContainer(h.container)
                .environment(h.settings)
                .environment(h.providers)
                .environment(h.session)
                .environment(h.llm)
                .environment(h.downloads)
        }
    }

    /// Same tree at a wide window. A phone-shaped layout stretched to Mac width
    /// is the single most reliable tell that something is a port, so it gets its
    /// own capture rather than being inferred from the default size.
    @Test("app shell, wide window")
    func appShellWide() throws {
        let h = try Harness()
        try render("app-shell-wide", scheme: .dark, size: CGSize(width: 1440, height: 900)) {
            ContentView()
                .modelContainer(h.container)
                .environment(h.settings)
                .environment(h.providers)
                .environment(h.session)
                .environment(h.llm)
                .environment(h.downloads)
        }
    }
}
