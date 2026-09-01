//
//  TranscriptViewport.swift
//  teemoon
//
//  Where the transcript should be this layout pass. Pin, hold, and settle
//  used to be three independent timers; each fix for blanking or a jump
//  armed one without disarming the others. See TranscriptViewportTests.
//

#if os(iOS) || os(visionOS)

import CoreGraphics
import Foundation
import QuartzCore

/// One layout pass's geometry, in content coordinates, for the anchor rule.
///
/// ANCHOR THE PROMPT, GROW INTO SLACK. Pinning the newest token to the
/// bottom means every wrap moves `contentOffset` and every wrong estimate
/// of the last row moves `contentSize` under it. Holding the last USER
/// message near the top instead makes the common case — a reply shorter
/// than the remaining viewport — cost no offset movement at all: the reply
/// grows downward into slack and the reader's eye stays where they put it.
struct TranscriptAnchorGeometry: Equatable {
    /// The last user message's height. Its POSITION is deliberately not here:
    /// nothing scrolls to the prompt, so nothing needs to know where it is.
    var userHeight: CGFloat
    /// The collection view's own height.
    var visibleHeight: CGFloat
    /// Title/fade overlay covering the top of the viewport. Content scrolls
    /// UNDER it (it is a sibling overlay, not an inset), so the anchor has
    /// to clear it or the prompt lands behind the title.
    var topFade: CGFloat
    /// Composer chrome reserved at the bottom.
    var chrome: CGFloat
    /// Everything DRAWN below the prompt: the trailing streaming view while
    /// a turn runs, the persisted reply cell after the hand-off, plus any
    /// tail rows. One quantity across the seam, deliberately — see
    /// `placeholder`.
    var inkBelow: CGFloat

    /// `V` — the band a reply can actually use.
    var usableHeight: CGFloat { max(0, visibleHeight - topFade - chrome) }

    /// The slack the reply has not grown into yet.
    ///
    /// MEASURED FROM INK, AND CAPPED BY ONE VIEWPORT. That is what makes it
    /// a layout reserve rather than constraint 9's blank band: it is at most
    /// `V - U.height` — a fraction of a single screen, always directly under
    /// drawn content, with the reader anchored at the TOP of it. The 2,040pt
    /// blank was none of those things; it was the difference between two
    /// content ends, more than two screens tall, with the reader held inside.
    ///
    /// It is continuous across the hand-off BY CONSTRUCTION, and that is the
    /// point of measuring ink instead of flagging a live turn. The streaming
    /// view is the ink while the turn runs; the reply cell of the same height
    /// is the ink after. Were the reserve to vanish at `[DONE]`, the
    /// scrollable end would fall by exactly this much and the clamp would
    /// shove the anchored prompt back down the screen — the hand-off jump,
    /// rebuilt out of the fix for it.
    var placeholder: CGFloat {
        max(0, usableHeight - userHeight - inkBelow)
    }

}

enum TranscriptViewport: Equatable {
    /// Leave the offset alone.
    case free
    /// Hold the end of the content. `.throttled` during a live stream so
    /// the runloop can idle; `.immediate` while layout is settling.
    case pinToEnd(PinningCollectionView.PinMode)
    /// A reader who left the end. Outranks the pin. Never extends the
    /// scrollable range — a reserved empty band is a blank screen.
    case hold(y: CGFloat)

    /// Hold outranks pin. A live follow outranks a leftover settle.
    ///
    /// ONE WRITER, ONE TARGET. The prompt riding near the top is NOT a second
    /// scroll target — it is `placeholder` in `contentInset.bottom` moving the
    /// end of the scrollable content to where the prompt-at-top would be, so
    /// pinning the end lands there. An `.anchor` case existed briefly and was
    /// deleted: it was the only place an absolute position was derived from a
    /// cell's frame, and on device the frame at that index path belonged to
    /// the PREVIOUS message for a pass or two after a submit, so the offset
    /// was written to two places 5ms apart (measured: -1427 then +1894). A
    /// stale read now only mis-sizes a reserve, which the pin tracks
    /// continuously instead of teleporting.
    static func resolve(
        generating: Bool,
        interrupted: Bool,
        now: CFTimeInterval,
        settleUntil: CFTimeInterval,
        holdY: CGFloat?,
        holdUntil: CFTimeInterval
    ) -> TranscriptViewport {
        if let y = holdY, now < holdUntil { return .hold(y: y) }
        if generating && !interrupted { return .pinToEnd(.throttled) }
        if now < settleUntil { return .pinToEnd(.immediate) }
        return .free
    }
}

#endif
