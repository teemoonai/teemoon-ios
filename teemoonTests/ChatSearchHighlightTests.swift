import Foundation
import Testing
@testable import teemoon

/// The snippet delimiters are safe by construction, but this parser still has
/// to survive malformed input: a truncated snippet is a normal thing for sqlite
/// to return, and swallowing the tail of a result would be worse than showing
/// an unstyled one.
@Suite("Chat search highlight")
struct ChatSearchHighlightTests {

    private let open = ChatSearchIndex.highlightOpen
    private let close = ChatSearchIndex.highlightClose

    @Test func segments_splitsMatchedRunsOut() {
        let segments = ChatSearchHighlight.segments("the \(open)kettle\(close) broke")
        #expect(segments.count == 3)
        #expect(segments[0].text == "the ")
        #expect(segments[0].isMatch == false)
        #expect(segments[1].text == "kettle")
        #expect(segments[1].isMatch == true)
        #expect(segments[2].text == " broke")
        #expect(segments[2].isMatch == false)
    }

    @Test func segments_handlesMultipleMatches() {
        let text = "\(open)a\(close) and \(open)b\(close)"
        let matches = ChatSearchHighlight.segments(text).filter(\.isMatch).map(\.text)
        #expect(matches == ["a", "b"])
    }

    @Test func segments_unterminatedMatchStillRenders() {
        // sqlite truncates at the snippet budget; the tail must not vanish.
        let segments = ChatSearchHighlight.segments("start \(open)tail")
        #expect(segments.map(\.text).joined() == "start tail")
        #expect(segments.last?.isMatch == true)
    }

    @Test func segments_unpairedCloserIsNotARun() {
        let segments = ChatSearchHighlight.segments("plain\(close)text")
        #expect(segments.count == 1)
        #expect(segments[0].isMatch == false)
        #expect(segments[0].text == "plaintext")
    }

    @Test func plainText_dropsEveryDelimiter() {
        let snippet = "…the \(open)appliance\(close)s were \(open)late\(close)…"
        let plain = ChatSearchHighlight.plainText(snippet)
        #expect(!plain.contains(open))
        #expect(!plain.contains(close))
        #expect(plain == "…the appliances were late…")
    }

    @Test func attributed_emphasisesOnlyTheMatch() {
        let result = ChatSearchHighlight.attributed("a \(open)b\(close) c")
        let emphasised = result.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(result[$0.range].characters) }
        #expect(emphasised == ["b"])
        #expect(String(result.characters) == "a b c")
    }

    @Test func attributed_prefixMatchBoldsThePrefixOnly() {
        // The trailing `*` in the match expression is what produces this: the
        // screenshot's `**Appliance**s`, not a whole-word bold.
        let result = ChatSearchHighlight.attributed("\(open)Applianc\(close)es")
        let emphasised = result.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(result[$0.range].characters) }
        #expect(emphasised == ["Applianc"])
        #expect(String(result.characters) == "Appliances")
    }

    @Test func attributed_plainSnippetHasNoEmphasis() {
        let result = ChatSearchHighlight.attributed("nothing matched here")
        #expect(result.runs.allSatisfy { $0.inlinePresentationIntent != .stronglyEmphasized })
    }
}
