//
//  LogPrivacyTests.swift
//  teemoonTests
//
//  The 1.0.4 audit (carried into 1.0.5) found three unified-log lines that
//  interpolated the model's reply and tool arguments without a privacy mark:
//  ChatGeneration's "Done … output=", GenerationEngine's containment warning and
//  its "[ToolCall] args=". os.Logger redacts dynamic strings by default, but a
//  connected Mac or a sysdiagnose with private data on sees them, and the
//  default is not something a reviewer can read off the line. Build 41 marked
//  them `.private`; the audit's bar (build 43) is stricter: no body text in the
//  unified log at any privacy level. They log counts now.
//
//  Also pins the Brave test override: `hasPrefix("http://127.0.0.1:")` accepted
//  `http://127.0.0.1:1@evil/`, whose host is `evil`.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Log privacy")
struct LogPrivacyTests {

    /// Interpolations that carry a reply, a tool's arguments or result, or a prompt.
    private static let sensitive = ["output", "arguments", "removedMarkup", "answer", "prompt", "reply", "query", "result"]

    @Test func noLoggerInterpolatesUserOrModelTextAtAnyPrivacyLevel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appending(component: "teemoon")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "did not find the app sources at \(root.path)")
        let logCall = try Regex(#"logger\.(debug|info|notice|warning|error|fault|log)\("#)
        let interpolation = try Regex(#"\\\(((?:[^()]|\([^()]*\))*)\)"#)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(logCall) {
                for match in line.matches(of: interpolation) {
                    let expr = String(line[match.range])
                    // A count or a length is a number, not the text.
                    if Self.sensitive.contains(where: { expr.range(of: $0, options: .caseInsensitive) != nil }),
                       !expr.contains(".count") {
                        offenders.append("\(file.lastPathComponent):\(i + 1): \(expr)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "log lines carrying user or model text (log a count instead):\n\(offenders.joined(separator: "\n"))")
    }

    @Test func theBraveTestOverrideMustParseToLoopback() {
        #expect(BraveWebSearchTool.isLoopbackOverride("http://127.0.0.1:8123/res/v1/llm/context"))
        #expect(!BraveWebSearchTool.isLoopbackOverride("http://127.0.0.1:1@evil/"))
        #expect(!BraveWebSearchTool.isLoopbackOverride("http://127.0.0.1.evil.com:80/"))
        #expect(!BraveWebSearchTool.isLoopbackOverride("https://127.0.0.1:443/"))
        #expect(!BraveWebSearchTool.isLoopbackOverride("http://127.0.0.1/"))
        #expect(!BraveWebSearchTool.isLoopbackOverride("http://user:pw@127.0.0.1:80/"))
    }
}
