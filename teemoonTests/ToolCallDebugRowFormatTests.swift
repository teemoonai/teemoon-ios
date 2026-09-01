import Foundation
import Testing
@testable import teemoon

/// Regression tests for the developer-mode tool-call rows.
///
/// The bug: a model may pass any subset of web_search's optional arguments, and
/// the header formatter matched a single-field shorthand BEFORE the web_search
/// case. Two identical searches in one card therefore rendered two different
/// ways — `web_search("…")` when the model sent only `query`, and
/// `web_search · n:5 -> 4` (no query anywhere in the header) when it also sent
/// `count`. Observed live with gemma4:latest over Ollama.
@Suite("Tool call debug row formatting")
struct ToolCallDebugRowFormatTests {

    private static let oneSource = """
        <source index="1"><url>https://example.com/a</url><title>A</title><content>body</content></source>
        """

    // MARK: - Header consistency

    @Test func signature_webSearch_sameFormatWithAndWithoutOptionalArgs() {
        let bare = toolCallSignature(
            name: "web_search", arguments: #"{"query":"what is an nyc city bodega"}"#,
            result: Self.oneSource
        )
        let withCount = toolCallSignature(
            name: "web_search", arguments: #"{"query":"what is an nyc city bodega","count":5}"#,
            result: Self.oneSource
        )
        // Both take the web_search branch: the query lives in the subtitle, and
        // the fetched-source count is reported for both.
        #expect(bare == "web_search -> 1")
        #expect(withCount == "web_search · n:5 -> 1")
        #expect(!bare.contains("bodega"))
    }

    @Test func signature_webSearch_queryOnly_reportsFetchedCount() {
        // The old shorthand returned `web_search("…")` and dropped `-> N`
        // entirely for exactly this shape.
        let sig = toolCallSignature(
            name: "web_search", arguments: #"{"query":"tokyo population"}"#,
            result: Self.oneSource
        )
        #expect(sig.hasSuffix("-> 1"))
    }

    @Test func signature_otherTool_keepsSingleFieldShorthand() {
        let sig = toolCallSignature(name: "lookup", arguments: #"{"term":"bodega"}"#)
        #expect(sig == #"lookup("bodega")"#)
    }

    // MARK: - Subtitle: a row is never blank

    @Test func subtitle_webSearch_showsQuery() {
        let sub = toolCallSubtitle(name: "web_search", arguments: #"{"query":"nyc bodega","count":5}"#)
        #expect(sub == #""nyc bodega""#)
    }

    @Test func subtitle_webSearch_noQuery_fallsBackToRawArguments() {
        // No `query` key: the header omits it too, so without this fallback the
        // row renders with no identifying text at all.
        let sub = toolCallSubtitle(name: "web_search", arguments: #"{"count":5}"#)
        #expect(sub == #"{"count":5}"#)
    }

    @Test func subtitle_webSearch_unparseableArguments_fallsBackToRawArguments() {
        let sub = toolCallSubtitle(name: "web_search", arguments: "{not json")
        #expect(sub == "{not json")
    }

    @Test func subtitle_webSearch_emptyArguments_isNil() {
        #expect(toolCallSubtitle(name: "web_search", arguments: "") == nil)
    }

    @Test func subtitle_otherTool_isNil() {
        #expect(toolCallSubtitle(name: "lookup", arguments: #"{"query":"x"}"#) == nil)
    }
}
