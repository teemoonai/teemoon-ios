//
//  LiteRTToolBridgeTests.swift
//  teemoonTests
//
//  Proves the LiteRT tool bridge works WITHOUT depending on a model choosing to
//  call anything.
//
//  The live test asked Gemma 4 to search and it replied "I need more context"
//  (`toolRan=false`), leaving the bridge untested — and the assertion was
//  conditional on the model calling, so it passed while proving nothing. That is
//  the same trap already recorded for small models: *whether* a model decides to
//  call a tool is a question about the model; *whether the wiring works* is a
//  question about the code, and only the second belongs in a deterministic test.
//
//  These drive the bridge directly. No engine, no GPU, no weights — so they run
//  in the simulator and in CI, unlike everything else LiteRT-related.
//

import Foundation
import Testing
import ModelBackend
import LiteRTLM
@testable import teemoon

/// Qualified because importing LiteRTLM puts a second `Tool` in scope — the same
/// three-way collision the bridge itself exists to manage.
private typealias LMTool = AnyLanguageModel.Tool

private struct PlantedTool: LMTool {
    let name = "web_search"
    let description = "Search the web."
    let planted: String
    let ran: LockedBox<Bool>

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
        @Guide(description: "How many results.")
        var count: Int
    }

    func call(arguments: Arguments) async throws -> String {
        ran.value = true
        return "RESULT[\(arguments.query)|\(arguments.count)] \(planted)"
    }
}

/// Stands in for any teemoon tool that has no LiteRT shim type — `saved_places`
/// today. File scope, not nested in the test: `@Generable` cannot be attached to
/// a local type.
private struct UnbridgedTool: LMTool {
    let name = "saved_places"
    let description = "Look up saved places."
    @Generable struct Arguments: Sendable {
        @Guide(description: "The place to look up.")
        var query: String
    }
    func call(arguments: Arguments) async throws -> String { "unused" }
}

@Suite("LiteRT tool bridge", .serialized)
struct LiteRTToolBridgeTests {

    /// The whole chain minus the model: register → look up → coerce → execute →
    /// report.
    @Test @MainActor func executesTheRegisteredTeemoonTool() async throws {
        let ran = LockedBox<Bool>(false)
        let tool = PlantedTool(planted: "ZX9", ran: ran)
        let reported = LockedBox<[(String, String, String)]>([])

        let shims = await LiteRTToolBridge.bridged(tools: [tool]) { name, args, result in
            reported.value = reported.value + [(name, args, result)]
        }
        #expect(shims.count == 1, "web_search should have produced one LiteRT shim")

        let result = await LiteRTToolBridge.execute(
            name: "web_search", arguments: ["query": "oil price", "count": 5]
        )
        #expect(ran.value, "the teemoon tool never ran")
        #expect(result.contains("ZX9"), "the tool's own output did not come back: \(result)")
        #expect(result.contains("oil price"), "arguments did not reach the tool: \(result)")

        // The report is what feeds the grounding rail — LiteRT owns the loop, so
        // without this the UI would never learn a search happened.
        #expect(reported.value.count == 1)
        #expect(reported.value.first?.0 == "web_search")
    }

    /// A stringified scalar must decode, exactly as it does on the MLX path.
    ///
    /// Small models emit `"count": "5"` constantly. If the bridge skipped
    /// `coerceArgsToSchema`, this would fail to decode and the tool would look
    /// broken on LiteRT while working on MLX.
    @Test @MainActor func coercesStringifiedScalarsLikeTheSharedEngine() async throws {
        let ran = LockedBox<Bool>(false)
        let tool = PlantedTool(planted: "ZX9", ran: ran)
        _ = await LiteRTToolBridge.bridged(tools: [tool]) { _, _, _ in }

        let result = await LiteRTToolBridge.execute(
            name: "web_search", arguments: ["query": "oil", "count": "5"]   // string!
        )
        #expect(ran.value, "coercion failed, so the tool never ran: \(result)")
        #expect(result.contains("|5]"), "count did not coerce to an Int: \(result)")
    }

    /// The schema handed to LiteRT must be teemoon's flattened one, wrapped in
    /// the envelope LiteRT's native layer actually reads.
    ///
    /// Both halves are load-bearing, and the second cost a device run to find.
    /// The envelope must be `{"type": "function", "function": {…}}` — the shape
    /// the protocol's own default `getSchema()` produces. A flat
    /// `{name, description, parameters}` is accepted silently, carries no
    /// parameters into the native layer, and leaves constrained decoding with
    /// nothing to constrain: the model then invents argument names and the turn
    /// dies with `keyNotFound: "query"` inside LiteRT.
    ///
    /// So this asserts the envelope, not merely that the keys exist somewhere.
    /// The first version of this test checked the flat shape and passed against
    /// the broken implementation.
    @Test @MainActor func exposesTeemoonsFlattenedSchemaInLiteRTsEnvelope() async throws {
        let tool = PlantedTool(planted: "ZX9", ran: LockedBox(false))
        _ = await LiteRTToolBridge.bridged(tools: [tool]) { _, _, _ in }

        let schema = LiteRTWebSearchTool().getSchema()
        #expect(schema["type"] as? String == "function",
                "missing the type:function envelope — the native layer will not find the parameters")
        let function = try #require(schema["function"] as? [String: Any],
                                    "no function object — the schema is in the flat shape that silently drops parameters")
        #expect(function["name"] as? String == "web_search")

        let parameters = try #require(function["parameters"] as? [String: Any],
                                      "no parameters — the model would see no arguments at all")
        #expect(parameters["$ref"] == nil, "an unresolved $ref reached the model")
        #expect(parameters["$defs"] == nil, "$defs indirection reached the model")
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["query"] != nil)
        #expect(properties["count"] != nil)
    }

    /// The shim must accept arguments that do not match the schema, because
    /// LiteRT decodes them before teemoon can repair them.
    ///
    /// This is the unit-level form of the failure a device run produced: Gemma 4
    /// emitted a call with no `query`, `JSONDecoder` threw `keyNotFound` inside
    /// `ToolManager.execute`, and LiteRT turned that into a thrown error that
    /// killed the whole generation. With typed properties on the shim there is
    /// no way for teemoon's coercion to ever see those arguments.
    @Test @MainActor func shimDecodesArgumentsThatDoNotMatchTheSchema() throws {
        let wrongShape = try #require(#"{"q": "oil", "extra": [1, 2], "nested": {"a": null}}"#.data(using: .utf8))
        // Decoding must not throw. What the tool does with odd arguments is
        // teemoon's business; refusing to decode them is LiteRT ending the turn.
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(LiteRTWebSearchTool.self, from: wrongShape)
        }
    }

    /// Decoding must PRESERVE the arguments, not merely survive them.
    ///
    /// This is the test whose absence cost the most today. The one above asserts
    /// the shim does not throw — and a shim that silently decodes every call to
    /// `[:]` passes it perfectly. That is exactly what shipped: the decoder
    /// asked for a `singleValueContainer()` (a scalar) while the model sends a
    /// JSON object, `try?` swallowed the mismatch, and every tool call arrived
    /// with empty arguments.
    ///
    /// It was invisible from every other angle. `LiteRTToolBridge.execute` is
    /// called directly by the other tests, so it never exercises this decoder at
    /// all; on device `web_search` ran 8/8 and returned "Empty query — skipping
    /// search", which reads as a model that chose not to search.
    @Test @MainActor func shimPreservesArgumentsRatherThanQuietlyDroppingThem() async throws {
        let ran = LockedBox<Bool>(false)
        let tool = PlantedTool(planted: "ZX9", ran: ran)
        _ = await LiteRTToolBridge.bridged(tools: [tool]) { _, _, _ in }

        // Exactly what `ToolManager.execute` hands the shim: the model's
        // arguments, re-serialised as a JSON object.
        let payload = try #require(#"{"query": "oil price", "count": 5}"#.data(using: .utf8))
        let shim = try JSONDecoder().decode(LiteRTWebSearchTool.self, from: payload)

        let result = try await shim.run()
        let text = try #require(result as? String)
        #expect(text.contains("oil price"),
                "the query never reached the tool — arguments were dropped in decoding: \(text)")
        #expect(text.contains("|5]"), "count never reached the tool: \(text)")
        #expect(ran.value)
    }

    /// Tool rounds must be bounded, and the bound must not kill the turn.
    ///
    /// LiteRT owns the tool loop for this transport and its own ceiling is
    /// `recurringToolCallLimit = 25`, against teemoon's `maxToolRounds` of 2. On
    /// a phone each round is a live search plus a full re-prefill plus a decode,
    /// so 25 is minutes of pinned GPU — observed as "160s and counting, no
    /// response" on an ordinary weather question.
    ///
    /// Refusing with a STRING rather than throwing is the load-bearing part: an
    /// error propagates out of `sendMessageStream` and destroys the generation,
    /// losing the answer the model could still give from what it already found.
    @Test @MainActor func toolRoundsAreBoundedWithoutKillingTheTurn() async throws {
        let ran = LockedBox<Bool>(false)
        let tool = PlantedTool(planted: "ZX9", ran: ran)
        _ = await LiteRTToolBridge.bridged(tools: [tool]) { _, _, _ in }

        var results: [String] = []
        for _ in 1...(LiteRTToolBridge.maxToolRounds + 2) {
            results.append(await LiteRTToolBridge.execute(
                name: "web_search", arguments: ["query": "oil", "count": 5]))
        }

        let allowed = results.filter { $0.contains("ZX9") }
        let refused = results.filter { $0.contains("Search limit reached") }
        #expect(allowed.count == LiteRTToolBridge.maxToolRounds,
                "expected exactly \(LiteRTToolBridge.maxToolRounds) rounds to run, got \(allowed.count)")
        #expect(refused.count == 2, "calls past the limit must be refused, not run")
        // Refused, not failed: the model has to be able to answer from what it has.
        #expect(refused.allSatisfy { !$0.lowercased().contains("error") })
    }

    /// Each turn gets a fresh budget — a long chat must not exhaust it.
    @Test @MainActor func theRoundBudgetResetsPerTurn() async throws {
        let tool = PlantedTool(planted: "ZX9", ran: LockedBox(false))
        for turn in 1...3 {
            // `bridged` is what the transport calls once per turn.
            _ = await LiteRTToolBridge.bridged(tools: [tool]) { _, _, _ in }
            let first = await LiteRTToolBridge.execute(
                name: "web_search", arguments: ["query": "oil", "count": 5])
            #expect(first.contains("ZX9"),
                    "turn \(turn) began already out of budget — the reset is not per-turn")
            _ = await LiteRTToolBridge.execute(name: "web_search", arguments: ["query": "oil", "count": 5])
            _ = await LiteRTToolBridge.execute(name: "web_search", arguments: ["query": "oil", "count": 5])
        }
    }

    /// A tool with no shim must be dropped loudly, not silently offered.
    @Test @MainActor func toolsWithoutABridgeAreNotOffered() async throws {
        let shims = await LiteRTToolBridge.bridged(tools: [UnbridgedTool()]) { _, _, _ in }
        #expect(shims.isEmpty, "a tool with no shim type must not be offered to the model")
    }

    /// An unregistered name must not throw: a thrown error inside LiteRT's loop
    /// aborts the whole generation, whereas a string lets the model recover.
    @Test @MainActor func unknownToolReturnsAMessageRatherThanThrowing() async throws {
        await LiteRTToolRegistry.shared.clear()
        let result = await LiteRTToolBridge.execute(name: "nope", arguments: [:])
        #expect(result.contains("not found"), "expected a recoverable message, got: \(result)")
    }
}
