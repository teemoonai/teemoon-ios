//
//  WhereSheetCaptureUITests.swift
//  teemoonUITests
//
//  Baseline transcript rig for `WhereSheetView`, extending the design-parity
//  pattern — walk the sheet, dump the ordered
//  accessibility tree. The dump is lossless copy: no vision errors.
//
//  RUN THIS ON A DEVICE. NWPathMonitor reports `.unsatisfied` in the simulator
//  even with working network, and `filteredProviders` then drops everything but
//  `.phone` — so all four segments collapse to the same offline empty state and
//  the transcript is worthless. Verified 2026-07-29.
//
//  Writes the files directly when it can (simulator, where the runner shares the
//  host filesystem) and always attaches them, which is how a device run's output
//  comes back.
//
//  Appearance is deliberately NOT varied. These files are element TRANSCRIPTS —
//  labels and structure, which are identical in light and dark. Only
//  screenshots differ, and screenshots are the other harness's job.
//

import XCTest

final class WhereSheetCaptureUITests: XCTestCase {

    /// Every segment of the locality picker, `all` first (`filter == nil`).
    private let segments = ["all", "phone", "home", "cloud"]

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/teemoonUITests/ThisFile.swift
            .deletingLastPathComponent()          // …/teemoonUITests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("docs/design-baseline")
    }

    func testCaptureWhereSheetSegments() throws {
        let app = XCUIApplication()
        // DELIBERATELY UNSEEDED BY DEFAULT.
        //
        // `ContentView`'s seed does `providerStore.providers.removeAll()` before
        // installing its one provider — on a simulator that is the point, on a
        // DEVICE it would destroy the user's real setups and orphan their
        // Keychain entries. So seeding is opt-in, and the device capture (the
        // only one that works: NWPathMonitor reports unsatisfied in the
        // simulator, which collapses every segment to the offline empty state)
        // runs against whatever is really configured.
        if let seed = ProcessInfo.processInfo.environment["UITEST_SEED_NEARAI_MODEL"] {
            app.launchArguments = ["--uitesting"]
            app.launchEnvironment["UITEST_SEED_NEARAI_MODEL"] = seed
        }
        app.launch()

        let chip = app.buttons["chat.whereChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "the Where chip never appeared")

        let sha = Self.headSHA()
        for segment in segments {
            // FRESH SHEET PER SEGMENT. Paging scrolls the locality picker off the
            // top, so after page 1 the next segment's button is no longer on
            // screen — the first run captured `all` and then failed with
            // "no 'phone' segment". Reopening resets the scroll offset.
            chip.tap()
            let button = app.buttons[segment]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no '\(segment)' segment")
            button.tap()
            Thread.sleep(forTimeInterval: 2.0)   // .task work (home probe, warmth) mutates rows

            // Page the sheet with IN-SHEET DRAGS. Never the grabber: a drag on the
            // grabber dismisses the sheet instead of scrolling it, which is the
            // trap the mac-parity design records for the ladder rig.
            var merged: [String] = []
            var mergedSpec: [String] = []
            var page = 1
            var lastTail = ""
            while page <= Self.maxPages {
                let dump = app.debugDescription
                let t = Self.transcript(of: dump)
                // Union in order: pages overlap, so append only what is new.
                for l in t.labels where !merged.contains(l) { merged.append(l) }
                for e in t.spec.components(separatedBy: " | ")
                where !e.isEmpty && !mergedSpec.contains(e) { mergedSpec.append(e) }

                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "where-\(segment)-p\(page)"
                shot.lifetime = .keepAlways
                add(shot)

                // Bottom reached when the last few elements stop changing.
                let tail = merged.suffix(3).joined(separator: "|")
                if tail == lastTail && page > 1 { break }
                lastTail = tail

                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                start.press(forDuration: 0.05, thenDragTo: end)
                Thread.sleep(forTimeInterval: 1.2)
                page += 1
            }

            write(merged, to: "where-\(segment)-full-labels.txt", sha: sha, segment: segment)
            write([mergedSpec.joined(separator: " | ")],
                  to: "where-\(segment)-full-spec.txt", sha: sha, segment: segment)

            for (name, body) in [("full-labels", merged.joined(separator: "\n")),
                                 ("full-spec", mergedSpec.joined(separator: " | "))] {
                let a = XCTAttachment(string: body)
                a.name = "where-\(segment)-\(name)"
                a.lifetime = .keepAlways
                add(a)
            }
            NSLog("[capture] \(segment): \(page) page(s), \(merged.count) elements")

            // Close so the next iteration reopens at the top. The CLOSE BUTTON,
            // never a downward drag on the grabber — that dismisses mid-gesture
            // and leaves the next tap racing the animation.
            let close = app.buttons["close"]
            if close.exists { close.tap() } else { app.swipeDown() }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Enough to reach the bottom of the longest segment; the loop exits early
    /// when the tail stops changing.
    private static let maxPages = 8

    // MARK: - Transcript

    /// Ordered buttons and static texts, in accessibility-tree order — the same
    /// two markers the existing baselines use (`[B]` / `[S]`).
    ///
    /// Parses `app.debugDescription`, which is what the mac-parity rig
    /// attaches, rather than walking `allElementsBoundByIndex`: the walk issues
    /// one query per element and took ~5 minutes per segment, while the dump is
    /// a single snapshot and preserves the same tree order.
    static func transcript(of dump: String) -> (labels: [String], spec: String) {
        var labels: [String] = []
        var spec: [String] = []
        var lastButtonLabel: String?

        for line in dump.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let kind: String
            if trimmed.hasPrefix("Button,") { kind = "B" }
            else if trimmed.hasPrefix("StaticText,") { kind = "S" }
            else { continue }
            guard let range = trimmed.range(of: "label: '") else { continue }
            let rest = trimmed[range.upperBound...]
            // Labels can contain apostrophes ("you're offline"), so close on the
            // last quote rather than the first.
            guard let end = rest.lastIndex(of: "'") else { continue }
            let label = String(rest[rest.startIndex..<end]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }

            if kind == "B" {
                labels.append("[B] \(label)")
                spec.append("BTN{\(label)}")
                lastButtonLabel = label
            } else {
                labels.append("[S] \(label)")
                // A button's own inner text repeats its label; the existing
                // baselines keep both in the labels file and collapse them in
                // the spec, so the spec stays one entry per thing on screen.
                if label != lastButtonLabel { spec.append("T{\(label)}") }
            }
        }
        return (labels, spec.joined(separator: " | "))
    }

    private func write(_ lines: [String], to name: String, sha: String, segment: String) {
        let header = """
            # \(name)
            # WhereSheetView — segment: \(segment)\(segment == "all" ? " (filter == nil)" : "")
            # commit: \(sha)
            # captured: \(Self.captureContext())
            # NOTE: element transcripts are appearance-invariant (labels, not pixels).

            """
        let body = header + lines.joined(separator: "\n") + "\n"
        let url = outputDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Expected on a device: the runner has no host filesystem. The
            // attachments carry the same content, so this is not a failure.
            NSLog("[capture] could not write \(name) (attachments still added): \(error)")
        }
    }

    /// How this run was produced, for the file header.
    static func captureContext() -> String {
        let seeded = ProcessInfo.processInfo.environment["UITEST_SEED_NEARAI_MODEL"] != nil
        #if targetEnvironment(simulator)
        let host = "iOS Simulator (WARNING: NWPathMonitor reports offline here)"
        #else
        let host = "physical device"
        #endif
        return host + (seeded ? ", seeded via --uitesting" : ", against the real configured providers")
    }

    /// Best-effort: the runner cannot shell out, so the sha is stamped by the
    /// caller through the environment when available.
    private static func headSHA() -> String {
        ProcessInfo.processInfo.environment["UITEST_COMMIT_SHA"] ?? "unknown"
    }
}
