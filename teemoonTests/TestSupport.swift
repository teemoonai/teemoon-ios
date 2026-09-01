//
//  TestSupport.swift
//  teemoonTests
//

import Foundation

/// Read a secret from the Mac home. Simulator tests see that directory as
/// `SIMULATOR_HOST_HOME`. Never use process environment for keys.
///
/// Live suites must treat `nil` as skip (`guard let … else { return }`),
/// never `#require` — a machine without the file is not a failed test.
func hostHomeFile(_ name: String) -> String? {
    let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
        ?? NSHomeDirectory()
    let url = URL(fileURLWithPath: home).appendingPathComponent(name)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Polls `condition` until it holds or `timeout` elapses. Test-only —
/// production code awaits results instead of polling observable state.
func waitFor(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: interval)
    }
}
