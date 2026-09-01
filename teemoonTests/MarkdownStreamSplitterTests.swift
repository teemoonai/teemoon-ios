import Foundation
import Testing

@testable import teemoon

@Suite("Markdown stream splitter")
struct MarkdownStreamSplitterTests {

    /// A representative assistant answer: prose, a loose list, a fence with a
    /// blank line in it, a table, and a quote.
    static let answer = """
        Here is the short version, and then the detail.

        ## What changed

        - The parse moved off the hot path
        - The settled blocks stopped re-rendering

        1. First step

        2. Second step

        ```swift
        func stream() {

            print("blank line inside a fence")
        }
        ```

        | Approach | Cost |
        | --- | --- |
        | Whole document | O(n) |

        > Only the tail should cost anything per frame.

        That is the whole idea.
        """

    private func rejoin(_ split: MarkdownStreamSplitter.Split) -> String {
        (split.settled + [split.tail]).joined(separator: "\n\n")
    }

    @Test("settled blocks plus tail reproduce the source")
    func roundTrip() {
        let split = MarkdownStreamSplitter.split(Self.answer)
        #expect(rejoin(split) == Self.answer)
    }

    @Test("a block never changes once it has settled")
    func settledIsAppendOnly() {
        var previous: [String] = []
        // Grow the document one character at a time, the way a stream does.
        for end in 1...Self.answer.count {
            let prefix = String(Self.answer.prefix(end))
            let settled = MarkdownStreamSplitter.split(prefix).settled

            #expect(
                settled.count >= previous.count,
                "settled shrank at prefix length \(end)"
            )
            #expect(
                Array(settled.prefix(previous.count)) == previous,
                "a settled block was rewritten at prefix length \(end)"
            )
            previous = settled
        }
    }

    @Test("never splits inside a fenced code block")
    func fenceStaysWhole() {
        let split = MarkdownStreamSplitter.split(Self.answer)
        for block in split.settled + [split.tail] {
            let fences = block.components(separatedBy: "```").count - 1
            #expect(fences % 2 == 0, "unbalanced fence in block:\n\(block)")
        }
    }

    @Test("a loose ordered list is not broken apart")
    func looseOrderedListStaysWhole() {
        // Splitting this would restart the numbering at 1.
        let markdown = "1. First step\n\n2. Second step\n\n# Done"
        let split = MarkdownStreamSplitter.split(markdown)
        let listBlocks = (split.settled + [split.tail]).filter { $0.contains("step") }
        #expect(listBlocks.count == 1, "the list was split across \(listBlocks.count) blocks")
    }

    @Test("a loose unordered list is not broken apart")
    func looseUnorderedListStaysWhole() {
        // NB: the heading must not contain "one" — "Done" does, and matched the
        // filter below.
        let markdown = "- alpha\n\n- beta\n\n# End\n"
        let split = MarkdownStreamSplitter.split(markdown)
        let listBlocks = (split.settled + [split.tail]).filter {
            $0.contains("alpha") || $0.contains("beta")
        }
        #expect(listBlocks.count == 1, "the list was split across \(listBlocks.count) blocks")
    }

    @Test("a table's rows stay in one block")
    func tableStaysWhole() {
        // A table contains no blank lines, so it can never be split internally.
        // Two tables separated by a blank line ARE two blocks in GFM, and
        // splitting them is correct.
        let markdown = "Intro.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nDone.\n"
        let split = MarkdownStreamSplitter.split(markdown)
        let tableBlocks = (split.settled + [split.tail]).filter { $0.contains("|") }
        #expect(tableBlocks.count == 1)
        #expect(tableBlocks.first?.contains("| 1 | 2 |") == true)
    }

    @Test("a thematic break is a real block start")
    func thematicBreakSplits() {
        let markdown = "Before.\n\n---\n\nAfter."
        let split = MarkdownStreamSplitter.split(markdown)
        #expect(split.settled.first == "Before.")
    }

    @Test("the last block is never settled")
    func tailIsNeverSettled() {
        // "Second" may still grow, so it has to stay in the tail.
        let split = MarkdownStreamSplitter.split("First.\n\n# Second\n")
        #expect(split.settled == ["First."])
        #expect(split.tail == "# Second\n")
    }

    @Test("an incomplete final line is never treated as a block start")
    func partialFinalLineIsNotTrusted() {
        // "-" alone looks like a thematic break; "- " is a list item. Settling
        // on the former would rewrite a settled block one character later.
        #expect(MarkdownStreamSplitter.split("Intro.\n\n-").settled.isEmpty)
        #expect(MarkdownStreamSplitter.split("Intro.\n\n- ").settled.isEmpty)
    }

    @Test("empty and whitespace input are handled")
    func emptyInput() {
        #expect(MarkdownStreamSplitter.split("") == .init(settled: [], tail: ""))
        #expect(MarkdownStreamSplitter.split("\n\n").settled.isEmpty)
    }
}

@Suite("Streaming tail stabilizer")
struct StreamingTailStabilizerTests {

    @Test("an incomplete link displays as its label, not the raw syntax")
    func incompleteLinkShowsLabel() {
        #expect(MarkdownStreamSplitter.displayTail("[docs](https://example.com/long") == "docs")
        #expect(
            MarkdownStreamSplitter.displayTail("See [docs](https://example.com/long")
                == "See docs"
        )
        #expect(MarkdownStreamSplitter.displayTail("See [docs](https://example.com/long)")
            == "See [docs](https://example.com/long)")
    }

    @Test("a half-typed link label is shown without the opening bracket")
    func partialLinkLabel() {
        #expect(MarkdownStreamSplitter.displayTail("See [do") == "See do")
        #expect(MarkdownStreamSplitter.displayTail("See [docs]") == "See [docs]")
    }

    @Test("a complete link earlier in the tail is left alone")
    func completeLinkThenIncomplete() {
        let tail = "See [one](https://a.com) and [two](https://b.com/x"
        #expect(MarkdownStreamSplitter.displayTail(tail) == "See [one](https://a.com) and two")
    }

    @Test("an incomplete image is held, not shown as alt text")
    func incompleteImageIsHeld() {
        #expect(MarkdownStreamSplitter.displayTail("Hi ![alt](http://x.com/a") == "Hi ")
        #expect(MarkdownStreamSplitter.displayTail("Hi ![al") == "Hi ")
    }

    @Test("code spans and unclosed fences are not treated as links")
    func codeIsNotALink() {
        #expect(MarkdownStreamSplitter.displayTail("see `[docs](http://x") == "see `[docs](http://x")
        #expect(
            MarkdownStreamSplitter.displayTail("```\n[docs](http://x.com\n")
                == "```\n[docs](http://x.com\n"
        )
    }

    @Test("an escaped bracket is not a link opener")
    func escapedBracket() {
        #expect(MarkdownStreamSplitter.displayTail("arr\\[0") == "arr\\[0")
    }

    @Test("a table header without a delimiter paints as a table, not a paragraph")
    func incompleteTableGetsDelimiter() {
        let displayed = MarkdownStreamSplitter.displayTail("| Name | Age |\n")
        #expect(displayed.contains("| --- "))
        #expect(displayed.contains("| Name | Age |"))
    }

    @Test("a table that already has a delimiter is unchanged")
    func completeTableUnchanged() {
        let table = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n"
        #expect(MarkdownStreamSplitter.displayTail(table) == table)
    }

    @Test("a half-typed table row is held until the row is complete")
    func incompleteTableRowHeld() {
        #expect(MarkdownStreamSplitter.displayTail("| Nam") == "")
        let displayed = MarkdownStreamSplitter.displayTail("| Name | Age |\n| Ad")
        #expect(displayed.contains("| Name | Age |"))
        #expect(!displayed.contains("| Ad"))
    }

    @Test("a complete document's tail display is the document")
    func completeTailIsIdentity() {
        let md = "Hello **world** and a [link](https://example.com).\n"
        #expect(MarkdownStreamSplitter.displayTail(md) == md)
    }
}
