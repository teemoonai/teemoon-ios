//
//  Data+LogPreview.swift
//  teemoon
//
//  Bounded, non-public previews of HTTP response bodies for log lines.
//

import Foundation

extension Data {
    /// How much of a response body a log line may carry.
    ///
    /// 2 KB is enough for the whole of a typical JSON error envelope and the
    /// opening of a stray HTML error page — which is all these lines are for
    /// ("what did the attestation host actually say?"). Past that, a body is a
    /// full attestation report or a proxy's error page, and pasting kilobytes
    /// of it into the unified log helps nobody.
    static let logPreviewLimit = 2048

    /// A size-bounded, printable preview of this body for a log line.
    ///
    /// Pair it with `privacy: .private`. Attestation responses are not secrets
    /// by design, but they are SERVER-CONTROLLED bytes on the failure path —
    /// which is exactly where a gateway substitutes an HTML error page, an SSO
    /// redirect, or an echo of the request. Logging those `.public` writes them
    /// into the unified log in the clear, where a sysdiagnose picks them up.
    /// Status codes, URLs and hosts stay `.public`: they are the diagnostic
    /// part, and they are ours, not the server's.
    func previewForLog(limit: Int = Data.logPreviewLimit) -> String {
        let bound = Swift.max(0, limit)
        let slice = prefix(bound)
        // A byte-count cut can land mid-codepoint. Back off up to three bytes
        // (the longest possible UTF-8 tail) before calling a body binary.
        var text: String?
        for drop in 0..<Swift.min(4, slice.count + 1) {
            if let decoded = String(data: slice.dropLast(drop), encoding: .utf8) {
                text = decoded
                break
            }
        }
        guard var preview = text else { return "<binary, \(count) bytes>" }
        if count > bound { preview += "… (+\(count - bound) bytes truncated)" }
        return preview
    }
}
