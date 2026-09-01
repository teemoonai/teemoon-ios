//  ToolArgumentCoercionTests.swift
//  teemoonTests
//
//  Regression coverage for GenerationEngine.coerceArgsToSchema — models such as
//  GLM-5.2 on near.ai emit numeric tool arguments as JSON strings
//  (`"count": "15"`), which used to fail strict @Generable decoding with a
//  `typeMismatch` and surface as "[Tool call failed: typeMismatch]".

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Tool argument coercion")
struct ToolArgumentCoercionTests {

    // The exact `@Generable`-derived schema teemoon sends the model (with
    // $ref/$defs indirection) — same value production coercion keys off.
    private var braveSchema: [String: Any] {
        GenerationEngine.toolSchemaJSON(BraveWebSearchTool(apiKey: "x"))!
    }

    private func value(_ json: String, _ key: String) -> Any? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj?[key]
    }

    // MARK: - coerceArgsToSchema

    @Test func coercesStringIntegerToNumber() {
        let input = #"{"query": "bonsai reviews", "count": "15"}"#
        let out = GenerationEngine.coerceArgsToSchema(input, schema: braveSchema)
        #expect(value(out, "count") as? Int == 15)
        // The query is declared as a string in the schema and must stay a string.
        #expect(value(out, "query") as? String == "bonsai reviews")
    }

    @Test func leavesNumericStringQueryUntouched() {
        // A query that happens to be all digits must NOT become a number — the
        // schema declares `query` as a string, so coercion is schema-driven.
        let input = #"{"query": "15", "count": "15"}"#
        let out = GenerationEngine.coerceArgsToSchema(input, schema: braveSchema)
        #expect(value(out, "query") as? String == "15")
        #expect(value(out, "count") as? Int == 15)
    }

    @Test func leavesWellFormedArgumentsUnchanged() {
        let input = #"{"query": "hello", "count": 20}"#
        let out = GenerationEngine.coerceArgsToSchema(input, schema: braveSchema)
        #expect(value(out, "count") as? Int == 20)
        #expect(value(out, "query") as? String == "hello")
    }

    @Test func ignoresNonNumericStringForNumericField() {
        // Garbage that isn't parseable as an Int is left as-is (decoding will
        // then fail loudly rather than silently coercing to a wrong value).
        let input = #"{"query": "x", "count": "lots"}"#
        let out = GenerationEngine.coerceArgsToSchema(input, schema: braveSchema)
        #expect(value(out, "count") as? String == "lots")
    }

    @Test func returnsInputUnchangedWhenNotJSON() {
        let input = "not json at all"
        #expect(GenerationEngine.coerceArgsToSchema(input, schema: braveSchema) == input)
    }

    @Test func acceptsIntegralDoubleStringForIntegerField() {
        // Models sometimes emit whole numbers with a trailing ".0".
        let out = GenerationEngine.coerceArgsToSchema(#"{"query": "x", "count": "20.0"}"#, schema: braveSchema)
        #expect(value(out, "count") as? Int == 20)
    }

    @Test func leavesNonIntegralDoubleForIntegerField() {
        let out = GenerationEngine.coerceArgsToSchema(#"{"query": "x", "count": "20.5"}"#, schema: braveSchema)
        #expect(value(out, "count") as? String == "20.5")
    }

    @Test func leavesOverflowingIntegerAsString() {
        // Int.max + 1 — not representable, must not be silently truncated.
        let out = GenerationEngine.coerceArgsToSchema(#"{"query": "x", "count": "9223372036854775808"}"#, schema: braveSchema)
        #expect(value(out, "count") as? String == "9223372036854775808")
    }

    @Test func nonFiniteNumberIsLeftAsStringAndDoesNotCrash() {
        // Guards the JSONSerialization ObjC-exception crash: NaN/Infinity parse as
        // Double but must not reach serialization.
        let numberSchema: [String: Any] = [
            "type": "object", "properties": ["x": ["type": "number"]]
        ]
        for bad in ["NaN", "inf", "Infinity", "-Infinity"] {
            let out = GenerationEngine.coerceArgsToSchema("{\"x\": \"\(bad)\"}", schema: numberSchema)
            #expect(value(out, "x") as? String == bad, "\(bad) should be left as a string")
        }
    }

    @Test func coercesWellFormedNumberString() {
        let numberSchema: [String: Any] = [
            "type": "object", "properties": ["x": ["type": "number"]]
        ]
        let out = GenerationEngine.coerceArgsToSchema(#"{"x": "3.14"}"#, schema: numberSchema)
        #expect(value(out, "x") as? Double == 3.14)
    }

    // MARK: - Full decode path (the exact GLM-5.2 failure)

    @Test func stringCountDecodesIntoArgumentsAfterCoercion() throws {
        // Reproduces the screenshot: GLM-5.2 emitted count as a string.
        let raw = #"{"query": "Bonsai 27B PrismML review quality criticism", "count": "15"}"#

        // Before coercion this throws typeMismatch.
        let coerced = GenerationEngine.coerceArgsToSchema(raw, schema: braveSchema)
        let content = try GeneratedContent(json: coerced)
        let args = try BraveWebSearchTool.Arguments(content)

        #expect(args.count == 15)
        #expect(args.query == "Bonsai 27B PrismML review quality criticism")
    }

    // MARK: - $ref / $defs and nested arrays

    /// The `@Generable` schema uses a top-level `$ref` into `$defs`; coercion must
    /// resolve it (proven implicitly above) and recurse through array `items`
    /// without corrupting nested string values.
    @Test func nestedArrayOfObjectsPassesThroughUnchanged() throws {
        let schema = GenerationEngine.toolSchemaJSON(NestedArrayTool())!

        let raw = #"{"places": [{"name": "Sushi Noz", "address": "181 E 78th St", "notes": "12 seats"}]}"#
        let out = GenerationEngine.coerceArgsToSchema(raw, schema: schema)

        let obj = (try JSONSerialization.jsonObject(with: Data(out.utf8))) as! [String: Any]
        let places = obj["places"] as! [[String: Any]]
        #expect(places.count == 1)
        #expect(places[0]["name"] as? String == "Sushi Noz")
        // "12 seats" is a string field and must remain a string — not mangled by
        // recursion through the unresolved PlaceInput ref.
        #expect(places[0]["notes"] as? String == "12 seats")
    }
}

/// Same `$ref` / nested-array shape the parked save-places tool provided, without
/// pulling MapKit or SwiftData into this suite.
private struct NestedArrayTool: Tool {
    let name = "nested_array_fixture"
    let description = "test fixture"
    @Generable
    struct Arguments: Sendable {
        var places: [PlaceInput]
    }
    @Generable
    struct PlaceInput: Sendable {
        var name: String
        var address: String
        var notes: String?
    }
    func call(arguments: Arguments) async throws -> String { "" }
}
