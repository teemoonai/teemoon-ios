//
//  TranscriptItemsPolicy.swift
//  teemoon
//

#if os(iOS) || os(visionOS)

import Foundation

/// Which list a row belongs to. The transcript's LAST item is the one the
/// hand-off sizes — the `.latest` section's absolute height, the streamed
/// height stored as its floor, the one re-measure — so it must be the
/// reply. The newest message's web-search offer therefore opens the tail
/// instead of following its message; offers on earlier messages stay in
/// place. See TranscriptItemsPolicyTests.
///
/// AN OFFER IS A CLAIM THAT SEARCH IS OFF. Once a key is in — from the
/// card, from settings, from the web chip — every offer row goes, whatever
/// the offer map still remembers. Only the card's own paste path cleared
/// the map, so a key entered in settings left "turn on web search" standing
/// under a reply while searches ran (device, 2026-09-18).
enum TranscriptItemsPolicy {
    struct Lists: Equatable {
        var transcript: [TranscriptItem]
        /// The newest message's offer, or nil. Goes first in the tail.
        var tailOffer: TranscriptItem?
    }

    static func lists(messageIDs: [UUID],
                      freshStarts: Set<Int>,
                      searchConfigured: Bool,
                      offered: (UUID) -> Bool) -> Lists {
        var transcript: [TranscriptItem] = []
        transcript.reserveCapacity(messageIDs.count + 1)
        var tailOffer: TranscriptItem?
        for (index, id) in messageIDs.enumerated() {
            if freshStarts.contains(index) {
                transcript.append(.freshStart(before: id))
            }
            transcript.append(.message(id))
            guard !searchConfigured, offered(id) else { continue }
            if index == messageIDs.indices.last {
                tailOffer = .offer(id)
            } else {
                transcript.append(.offer(id))
            }
        }
        return Lists(transcript: transcript, tailOffer: tailOffer)
    }
}

#endif
