#if os(macOS)
import Foundation
import Testing
@testable import teemoon

/// The Mac window title is derived from the conversation's first message,
/// because nothing in the app ever writes `Thread.title`.
///
/// It used to be that message, whole. The title bar truncates it, which is why
/// it survived — but the same string is the app's identity in the Window menu,
/// Mission Control, ⌘` switching and the minimised Dock tile, and none of those
/// forgive a paragraph.
///
/// A UI test covers the visible result; these cover the edges a fixture cannot
/// conveniently reach.
@Suite("Mac window title")
struct MacWindowTitleTests {

    @Test("a short message is used unchanged, with no ellipsis")
    func shortMessageUntouched() {
        let title = ChatView.windowTitle(from: "does this run offline?")
        #expect(title == "does this run offline?")
        #expect(!title.contains("…"))
    }

    @Test("a long message is clipped and marked as clipped")
    func longMessageClipped() {
        let long = "when a provider says the model runs in a secure enclave, which specific claims can I check myself?"
        let title = ChatView.windowTitle(from: long)
        #expect(title.count < long.count)
        #expect(title.hasSuffix("…"))
    }

    /// The point of the word-boundary cut: "what exactly am I…" reads as an
    /// abbreviation, "what exactly am I trus…" reads as a bug.
    @Test("clipping lands on a word boundary, never mid-word")
    func clipsOnWordBoundary() {
        let title = ChatView.windowTitle(from: "when a provider says the model runs in a secure enclave, which claims hold?")
        let stem = title.dropLast()  // remove the ellipsis
        #expect(!stem.hasSuffix(" "), "trailing space before the ellipsis")
        // Every whole word in the stem must appear in the source as a whole word.
        let sourceWords = Set("when a provider says the model runs in a secure enclave, which claims hold?"
            .split(separator: " ").map(String.init))
        for word in stem.split(separator: " ").map(String.init) {
            #expect(sourceWords.contains(word), "\(word) was cut in half")
        }
    }

    /// One very long token has no space to back up to. Taking the hard cut is
    /// correct — returning the whole thing would defeat the purpose.
    @Test("a single unbroken token is still clipped")
    func unbrokenTokenStillClipped() {
        let token = String(repeating: "x", count: 200)
        let title = ChatView.windowTitle(from: token)
        #expect(title.count < 60)
        #expect(title.hasSuffix("…"))
    }

    /// Only the first line: a multi-line paste would otherwise put newlines into
    /// a menu item.
    @Test("only the first line is used")
    func firstLineOnly() {
        let title = ChatView.windowTitle(from: "first line\nsecond line\nthird line")
        #expect(title == "first line")
    }

    @Test("an empty message does not crash or produce a lone ellipsis")
    func emptyMessage() {
        #expect(ChatView.windowTitle(from: "") == "")
    }
}
#endif
