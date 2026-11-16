//
//  EmphasisTailTests.swift
//  teemoonTests
//
//  Unclosed emphasis in the streaming tail (the maintainer via pm, 2026-10-25: "Both"): `*Have a good` painted its
//  literal asterisk until the closer arrived. Held back like an incomplete link: the marker goes, the words
//  show plain, and they turn italic or bold when the closer arrives. Android's EmphasisTailTest (f65a885)
//  carries the same cases.
//

import Testing
@testable import teemoon

@Suite("Streaming tail — unclosed emphasis")
struct EmphasisTailTests {
    func d(_ s: String) -> String { MarkdownStreamSplitter.displayTail(s) }

    @Test func anUnclosedOpenerLosesItsMarker() {
        #expect(d("updated each morning. *Have a good") == "updated each morning. Have a good")
        #expect(d("the **three things you") == "the three things you")
        #expect(d("an _italic") == "an italic")
        #expect(d("**bold and *ital") == "bold and ital")
    }

    @Test func closedEmphasisIsUntouched() {
        #expect(d("*Have a good walk.*") == "*Have a good walk.*")
        #expect(d("The **three things** you must") == "The **three things** you must")
        #expect(d("**bold** then *ital") == "**bold** then ital")
    }

    @Test func aMarkerStillArrivingIsHeld() {
        #expect(d("a good *") == "a good ")
        #expect(d("a good **") == "a good ")
    }

    @Test func whatIsNotEmphasisStays() {
        #expect(d("snake_case_name") == "snake_case_name")
        #expect(d("2 * 3 = 6") == "2 * 3 = 6")
        #expect(d("* a list item") == "* a list item")
        #expect(d("- Water: at least **two") == "- Water: at least two")
        #expect(d("use `a*b` here") == "use `a*b` here")
        #expect(d("use `*x") == "use `*x")
        #expect(d("```\n*not emphasis\n") == "```\n*not emphasis\n")
    }

    @Test func onlyTheLastParagraphIsRead() {
        #expect(d("Done *here*.\n\n*Next para") == "Done *here*.\n\nNext para")
    }
}
