//
//  LogBodyPreviewTests.swift
//  teemoonTests
//
//  `Data.previewForLog` is the bound on what an attestation failure path may
//  write into the unified log. The attestation services used to log whole
//  response bodies at `privacy: .public`.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Log body preview")
struct LogBodyPreviewTests {

    @Test func shortBody_isVerbatim() {
        let body = Data("{\"error\":\"nope\"}".utf8)
        #expect(body.previewForLog() == "{\"error\":\"nope\"}")
    }

    @Test func emptyBody_isEmpty() {
        #expect(Data().previewForLog() == "")
    }

    @Test func bodyAtTheLimit_isNotAnnotated() {
        let body = Data(String(repeating: "a", count: Data.logPreviewLimit).utf8)
        let preview = body.previewForLog()
        #expect(preview.count == Data.logPreviewLimit)
        #expect(!preview.contains("truncated"))
    }

    @Test func oversizeBody_isCappedAndSaysSo() {
        let body = Data(String(repeating: "a", count: 10_000).utf8)
        let preview = body.previewForLog()

        // The payload itself never exceeds the limit...
        #expect(preview.hasPrefix(String(repeating: "a", count: Data.logPreviewLimit)))
        #expect(!preview.hasPrefix(String(repeating: "a", count: Data.logPreviewLimit + 1)))
        // ...and the reader is told how much was dropped rather than being
        // shown a body that silently ends mid-sentence.
        #expect(preview.hasSuffix("… (+\(10_000 - Data.logPreviewLimit) bytes truncated)"))
    }

    @Test func customLimit_isHonoured() {
        let body = Data("abcdefghij".utf8)
        #expect(body.previewForLog(limit: 4) == "abcd… (+6 bytes truncated)")
        #expect(body.previewForLog(limit: 0) == "… (+10 bytes truncated)")
    }

    @Test func cutMidCodepoint_stillDecodes() {
        // 4 bytes: one 3-byte emoji-ish codepoint would be sliced by a byte cap.
        // The preview backs off to the last whole codepoint instead of
        // reporting the whole body as binary.
        let body = Data("aé漢字".utf8)          // 1 + 2 + 3 + 3 bytes
        let preview = body.previewForLog(limit: 4)  // cuts inside "漢"
        #expect(preview.hasPrefix("aé"))
        #expect(preview.contains("truncated"))
    }

    @Test func binaryBody_isDescribed_notDumped() {
        let body = Data([0xff, 0xfe, 0xff, 0xfe, 0xff, 0xfe, 0xff, 0xfe])
        #expect(body.previewForLog() == "<binary, 8 bytes>")
    }
}
