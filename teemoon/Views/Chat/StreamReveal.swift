//
//  StreamReveal.swift
//  teemoon
//
//  "Whole if quick" (the maintainer, 2026-10-25): what is SHOWN of a streaming answer, given what has ARRIVED and when.
//  Display only. Pure and clocked by the caller; conformance/reveal.json (ConformanceRevealTests) pins it, and
//  Android's StreamReveal runs the same vector.
//

import Foundation

struct StreamReveal {
    /// A paragraph is held this long from its first arrived character before it is revealed piecemeal.
    static let holdMs = 600.0
    /// The answer's first paragraph is held only this long: nothing is on screen yet (the maintainer, 2026-10-26).
    static let firstHoldMs = 250.0
    /// On the phone the first paragraph is not held at all (the maintainer, 2026-10-31).
    static let onDeviceFirstHoldMs = 0.0
    /// A paragraph that appears whole fades in over this long.
    static let fadeMs = 300.0
    /// One reveal step per this much elapsed time, whatever the refresh rate.
    static let stepMs = 1000.0 / 60
    /// Each step moves the shown end ceil(deficit / divisor) characters.
    static let divisor = 9
    /// A trailing word whose end has not arrived holds the reveal at most this long.
    static let partialWaitMs = 300.0

    /// Where the stream comes from; only the first paragraph's hold differs.
    enum Origin: String, Encodable { case cloud, onDevice }

    struct Shown: Equatable {
        /// Characters of the arrived text to show.
        let length: Int
        /// Where the paragraph that appeared whole starts, while it fades.
        let fadeFrom: Int?
    }

    private let firstHold: Double
    private var arrived: [Character] = []
    private var firstArrivalAt: [Int: Double] = [:]
    private var shown = 0
    private var lastStepAt: Double?
    private var partialSince: Double?
    private var fadeFrom: Int?
    private var fadeStartedAt: Double?
    private var finished = false

    init(origin: Origin = .cloud) {
        firstHold = origin == .onDevice ? Self.onDeviceFirstHoldMs : Self.firstHoldMs
    }

    /// The answer so far (cumulative, as the engine emits it), arrived at `now` (ms).
    mutating func arrive(_ text: String, at now: Double) {
        let next = Array(text)
        if next.count < arrived.count || !next.starts(with: arrived) {
            shown = min(shown, zip(arrived, next).prefix { $0 == $1 }.count)
        }
        arrived = next
        for p in Self.paragraphs(arrived) where p.end > p.start && firstArrivalAt[p.start] == nil {
            firstArrivalAt[p.start] = now
        }
    }

    /// The end of the stream, or a stop: everything that arrived is shown.
    mutating func finish() {
        finished = true
        shown = arrived.count
    }

    /// What to show at `now` (ms), once a frame.
    mutating func frame(at now: Double) -> Shown {
        if finished { return Shown(length: arrived.count, fadeFrom: nil) }
        for p in Self.paragraphs(arrived) where shown < p.end {
            let t0 = firstArrivalAt[p.start] ?? now
            let hold = p.start == 0 ? firstHold : Self.holdMs
            if p.complete {
                // Finished: shown at once, fading only when none of it was showing yet.
                if shown <= p.start, now - t0 <= hold { fadeFrom = p.start; fadeStartedAt = now }
                shown = p.end
                continue
            }
            if now - t0 < hold { lastStepAt = nil; break }
            shown = max(shown, p.start)
            // The first frame after the hold takes exactly one step; later ones one per stepMs elapsed.
            var steps = 1
            if let last = lastStepAt {
                steps = Int(((now - last) / Self.stepMs).rounded(.down))
                lastStepAt = last + Double(steps) * Self.stepMs
            } else {
                lastStepAt = now
            }
            while steps > 0, shown < arrived.count {
                steps -= 1
                let deficit = arrived.count - shown
                let next = snap(shown + (deficit + Self.divisor - 1) / Self.divisor, now: now)
                if next == shown { break }
                shown = next
            }
            break
        }
        if let started = fadeStartedAt, now - started >= Self.fadeMs { fadeFrom = nil; fadeStartedAt = nil }
        return Shown(length: shown, fadeFrom: fadeFrom)
    }

    /// Forward to the end of the word `at` falls in, when that end has arrived; a trailing word still arriving
    /// waits at the last boundary until `partialWaitMs` pass. Shown text ends at a word's end, before its space.
    private mutating func snap(_ at: Int, now: Double) -> Int {
        var i = min(at, arrived.count)
        while i < arrived.count, !arrived[i].isWhitespace { i += 1 }
        if i < arrived.count { partialSince = nil; return i }
        let since = partialSince ?? now
        partialSince = since
        if now - since >= Self.partialWaitMs { return arrived.count }
        let boundary = arrived.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) ?? 0
        return max(shown, boundary)
    }

    struct Paragraph: Equatable { let start: Int, end: Int, complete: Bool }

    /// Split at blank lines outside a fence; `end` includes the blank line that closes a paragraph.
    static func paragraphs(_ text: [Character]) -> [Paragraph] {
        var out: [Paragraph] = []
        var start = 0, lineStart = 0, inFence = false
        var i = 0
        while i <= text.count {
            if i == text.count || text[i] == "\n" {
                let line = text[lineStart..<i]
                let marker = String(line.drop { $0 == " " }.prefix(3))
                if marker == "```" || marker == "~~~" { inFence.toggle() }
                if !inFence, line.allSatisfy(\.isWhitespace), i < text.count, lineStart > start {
                    out.append(Paragraph(start: start, end: i + 1, complete: true))
                    start = i + 1
                }
                lineStart = i + 1
            }
            i += 1
        }
        if start < text.count { out.append(Paragraph(start: start, end: text.count, complete: false)) }
        return out
    }
}

/// What the streaming view shows each frame: thinking as it arrives, the answer after `</think>` through
/// StreamReveal. StreamRevealFeedTests pins the split.
struct StreamRevealFeed {
    /// Made at the first answer character, when the turn's origin is known.
    private var reveal: StreamReveal?
    private var lastSource = ""
    private(set) var arrivals = 0

    /// The text to draw at `now` (ms), and where in it a whole paragraph is fading in.
    mutating func frame(source: String, origin: StreamReveal.Origin = .cloud, at now: Double) -> (text: String, fadeFrom: Int?) {
        let (head, answer) = Self.split(source)
        if source != lastSource {
            lastSource = source
            arrivals &+= 1
            if let answer, !answer.isEmpty || reveal != nil {
                if reveal == nil { reveal = StreamReveal(origin: origin) }
                reveal?.arrive(answer, at: now)
            }
        }
        guard let answer else { return (source, nil) }
        guard var reveal else { return (head, nil) }
        let shown = reveal.frame(at: now)
        self.reveal = reveal
        return (head + String(answer.prefix(shown.length)), shown.fadeFrom.map { head.count + $0 })
    }

    /// Thinking (through `</think>`) and the answer after it; an open think block is all head.
    static func split(_ source: String) -> (head: String, answer: String?) {
        guard source.contains("<think>") else { return ("", source) }
        guard let close = source.range(of: "</think>") else { return (source, nil) }
        return (String(source[..<close.upperBound]), String(source[close.upperBound...]))
    }
}
