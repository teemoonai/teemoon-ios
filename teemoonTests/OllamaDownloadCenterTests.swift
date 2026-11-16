//
//  OllamaDownloadCenterTests.swift
//  teemoonTests
//
//  The pull sheet closes the moment a pull starts, so its "finished" callback —
//  re-probe and select the pulled model — could never fire. Completion is now
//  reported by the center, which outlives the sheet.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Ollama pull completion reaches its starter")
struct OllamaDownloadCenterTests {

    private func progress(_ status: String) -> OllamaPullProgress {
        OllamaPullProgress(status: status, digest: nil, total: nil, completed: nil, error: nil)
    }

    private func settle(_ center: OllamaDownloadCenter) async {
        for _ in 0..<200 where center.downloads.contains(where: { !$0.isFinished }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aFinishedPullIsReportedAfterTheSheetIsGone() async {
        let center = OllamaDownloadCenter(pull: { _, _ in
            AsyncThrowingStream { c in c.yield(self.progress("pulling manifest")); c.yield(self.progress("success")); c.finish() }
        })
        var done: [String] = []
        center.start(ref: "llama3.2", baseURL: URL(string: "http://box.local:11434/v1")!, onDone: { done.append($0) })
        await settle(center)
        let ref = center.downloads.first?.id
        #expect(center.downloads.first?.phase == .done)
        #expect(done == [ref].compactMap { $0 }, "the starter re-probes and selects the model on this")
    }

    @Test func aFailedPullIsNotReportedAsFinished() async {
        let center = OllamaDownloadCenter(pull: { _, _ in
            AsyncThrowingStream { c in c.finish(throwing: OllamaPullError(status: 500, message: "no")) }
        })
        var done: [String] = []
        center.start(ref: "llama3.2", baseURL: URL(string: "http://box.local:11434/v1")!, onDone: { done.append($0) })
        center.cancel(ref: "llama3.2")
        await settle(center)
        #expect(done.isEmpty)
    }
}
