//
//  ToolCallFormatTests.swift
//  teemoonTests
//
//  The pluggable text tool-call formats: marker dispatch + the Gemma ```tool_code
//  python-call parser (the format teemoon couldn't read before, which made Gemma
//  look incapable of tools).
//

import Foundation
import Testing
@testable import teemoon

@Suite("ToolCallFormat")
struct ToolCallFormatTests {

    /// Decode a call's argument JSON to a dict (key order isn't stable, so assert values).
    private func args(_ s: ToolCallState) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.arguments.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Gemma ```tool_code

    @Test func gemmaParsesStringAndNumberArgs() throws {
        let content = """
        Let me look that up.
        ```tool_code
        web_search(query="weather in SF", count=5)
        ```
        """
        let calls = GemmaToolCode.parse(content)
        #expect(calls.count == 1)
        let call = try #require(calls[0])
        #expect(call.name == "web_search")
        let a = args(call)
        #expect(a["query"] as? String == "weather in SF")
        #expect(a["count"] as? Int == 5)
    }

    @Test func gemmaStripsPrintWrapper() throws {
        let content = "```tool_code\nprint(get_time(zone='PST'))\n```"
        let call = try #require(GemmaToolCode.parse(content)[0])
        #expect(call.name == "get_time")
        #expect(args(call)["zone"] as? String == "PST")
    }

    @Test func gemmaKeepsCommasInsideQuotedValues() throws {
        // The top-level split must not break on the comma inside the quoted string.
        let content = #"```tool_code\#nsend(text="hello, world", urgent=true)\#n```"#
        let call = try #require(GemmaToolCode.parse(content)[0])
        let a = args(call)
        #expect(a["text"] as? String == "hello, world")
        #expect(a["urgent"] as? Bool == true)
    }

    @Test func gemmaTakesLastSegmentOfDottedName() throws {
        let call = try #require(GemmaToolCode.parse("```tool_code\nfunctions.web_search(query=\"x\")\n```")[0])
        #expect(call.name == "web_search")
    }

    @Test func gemmaParsesMultipleCalls() {
        let content = "```tool_code\na(x=1)\nb(y=2)\n```"
        let calls = GemmaToolCode.parse(content)
        #expect(calls.count == 2)
        #expect(calls[0]?.name == "a")
        #expect(calls[1]?.name == "b")
    }

    // MARK: dispatch (detect-by-marker)

    @Test func parseAnyRoutesGemmaVsAngleBracket() throws {
        // ```tool_code → Gemma parser.
        let gemma = ToolCallFormat.parseAny("```tool_code\nsearch(q=\"a\")\n```", tools: [])
        #expect(gemma[0]?.name == "search")

        // <tool_call> JSON → the angle-bracket parser (unchanged behaviour).
        let ang = ToolCallFormat.parseAny(#"<tool_call>{"name":"search","arguments":{"q":"a"}}</tool_call>"#, tools: [])
        #expect(ang[0]?.name == "search")

        // No marker → nothing.
        #expect(ToolCallFormat.parseAny("just a normal reply", tools: []).isEmpty)
    }

    @Test func registryExposesMarkers() {
        #expect(ToolCallFormat.allMarkers.contains("<tool_call>"))
        #expect(ToolCallFormat.allMarkers.contains("```tool_code"))
        #expect(ToolCallFormat.maxMarkerLength >= "```tool_code".count)
    }

    // MARK: real Gemma output (captured live)

    /// Verbatim `content` emitted by `gemma4:e2b-it-qat` through an OpenAI-compatible
    /// endpoint when the server does NOT native-parse tool calls (so the ```tool_code
    /// block arrives as raw text — the case teemoon's parser exists for). Captured live
    /// 2026-07-25; these are the exact bytes, not hand-written approximations. Run through
    /// parseAny — the real dispatch entry — to guard against drift from actual model output.
    @Test func parsesRealGemmaOutput() throws {
        // 1. quoted string arg
        let weather = ToolCallFormat.parseAny("```tool_code\nget_weather(city=\"San Francisco\")\n```", tools: [])
        #expect(weather[0]?.name == "get_weather")
        #expect(args(try #require(weather[0]))["city"] as? String == "San Francisco")

        // 2. quoted string with spaces
        let search = ToolCallFormat.parseAny("```tool_code\nweb_search(query=\"top 3 Swift programming language results\")\n```", tools: [])
        #expect(search[0]?.name == "web_search")
        #expect(args(try #require(search[0]))["query"] as? String == "top 3 Swift programming language results")

        // 3. two bare integers, comma-split
        let dice = ToolCallFormat.parseAny("```tool_code\nroll_dice(sides=20, count=3)\n```", tools: [])
        let d = try #require(dice[0])
        #expect(d.name == "roll_dice")
        #expect(args(d)["sides"] as? Int == 20)
        #expect(args(d)["count"] as? Int == 3)
    }
}
