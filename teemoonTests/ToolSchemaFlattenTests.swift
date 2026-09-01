//
//  ToolSchemaFlattenTests.swift
//  teemoonTests
//
//  teemoon flattens the `@Generable` `$ref`/`$defs` schema into a plain inline object
//  before sending tools on the wire. With the raw `$ref` form, a small model can't see
//  the real parameters and hallucinates the argument shape — verified live: gemma4:e2b
//  emitted `{"queries":[...]}` 5/5 (temp 0) with `$ref`, and the declared `{"query":...}`
//  5/5 once flattened. These tests pin that the outbound schema is fully inlined.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Tool schema flattening")
@MainActor
struct ToolSchemaFlattenTests {

    private var schema: [String: Any] {
        GenerationEngine.flattenedToolSchema(BraveWebSearchTool(apiKey: ""))
    }

    @Test func rawSchemaHasTheRefIndirection() throws {
        // Guards the premise: the @Generable schema really is `$ref`/`$defs`-shaped, so
        // the flatten step is doing something (not a no-op on already-flat input).
        let raw = try #require(GenerationEngine.toolSchemaJSON(BraveWebSearchTool(apiKey: "")))
        #expect(raw["$ref"] != nil)
        #expect(raw["$defs"] != nil)
    }

    @Test func flattenedSchemaHasNoRefOrDefs() {
        #expect(schema["$ref"] == nil)
        #expect(schema["$defs"] == nil)
    }

    @Test func flattenedSchemaExposesQueryDirectly() throws {
        // The whole point: the model must see `query` (string, required) at the top level.
        #expect(schema["type"] as? String == "object")
        let props = try #require(schema["properties"] as? [String: Any])
        let query = try #require(props["query"] as? [String: Any])
        #expect(query["type"] as? String == "string")
        let required = try #require(schema["required"] as? [String])
        #expect(required.contains("query"))
    }
}
