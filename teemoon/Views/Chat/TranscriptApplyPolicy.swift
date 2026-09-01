//
//  TranscriptApplyPolicy.swift
//  teemoon
//

#if os(iOS) || os(visionOS)

import Foundation

/// When the developer-mode debug card is the only thing that changed, the
/// insert has to animate and the settle pin has to stand down. Otherwise the
/// panel pops in at full height and the pin yanks the answer up in one frame.
///
/// A turn-end that also wants the card is TWO applies: the hand-off first
/// (streaming view → persisted row, unanimated), then this reveal. Doing
/// both in one snapshot either yanks the answer or leaves a frame with
/// neither the overlay nor the row — the flash before the panel appears.
enum TranscriptApplyPolicy {
    static func isDebugCardReveal(
        previousTranscript: [TranscriptItem],
        previousTail: [TranscriptItem],
        transcript: [TranscriptItem],
        tail: [TranscriptItem]
    ) -> Bool {
        guard previousTranscript == transcript else { return false }
        let hadDebug = previousTail.contains { $0.isDebugInfo }
        let hasDebug = tail.contains { $0.isDebugInfo }
        return hasDebug && !hadDebug
    }

    /// Tail to apply with the persisted row. Debug is stripped so the
    /// hand-off snapshot cannot also insert the ~400pt panel.
    static func handoffTail(_ tail: [TranscriptItem]) -> [TranscriptItem] {
        tail.filter { !$0.isDebugInfo }
    }

    static func hasDebugCard(_ tail: [TranscriptItem]) -> Bool {
        tail.contains { $0.isDebugInfo }
    }
}

#endif
