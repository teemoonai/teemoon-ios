//
//  Motion.swift
//  teemoon
//
//  The app's motion tokens (pm/features/motion-audit.md §3, the maintainer 2026-11-14 "do all"). A call site names the job, not
//  a duration; each token already answers Reduce Motion. Sheets, pushes, alerts and the keyboard stay the system's.
//

import SwiftUI

enum Motion {
    /// Something appears or disappears in place: cards, retry, chips. A dissolve is Reduce Motion's own substitute,
    /// so it stays.
    static let fade = Animation.easeOut(duration: 0.2)
    /// A streamed paragraph fading in (kept at its measured 0.3).
    static let paragraphFade = Animation.easeOut(duration: 0.3)
    /// One thing replaced by another in place: copy confirmations, the lock glyph, the where chip's label.
    static let swap = Animation.smooth(duration: 0.2)

    /// Something moves or resizes; Reduce Motion: none.
    static func spatial(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth }
    /// Only the photo thumbnail's arrival; Reduce Motion: none.
    static func playful(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3) }
    /// A size cue (point-here, settle, a chip arriving) that Reduce Motion holds at full size.
    static func scale(_ value: CGFloat, reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : value }

    /// An entrance that grows in; Reduce Motion: the fade alone.
    static func grow(from scale: CGFloat, anchor: UnitPoint = .center, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: scale, anchor: anchor))
    }

    /// Point-here, settle, a deep-link flash: once; Reduce Motion: none (the colour change says it).
    static func attention(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.35) }
}
