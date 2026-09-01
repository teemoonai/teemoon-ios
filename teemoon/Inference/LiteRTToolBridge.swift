//
//  LiteRTToolBridge.swift
//  teemoon
//
//  Lets LiteRT-LM call teemoon's tools.
//
//  ARCHITECTURAL EXCEPTION, stated plainly: for this transport the tool LOOP
//  lives inside LiteRT, not in `GenerationEngine`. Everywhere else teemoon owns
//  the loop precisely so local and remote cannot drift. LiteRT's API does not
//  offer the choice — `Conversation` calls `ToolManager.execute` internally and
//  feeds the result back itself; there is no hook that surfaces a pending call
//  for the caller to run.
//
//  What teemoon keeps despite that:
//    - its own tool implementations actually execute (via this bridge)
//    - `flattenedToolSchema`, so the model sees a self-contained schema with no
//      `$ref` it cannot resolve
//    - `coerceArgsToSchema`, so a stringified scalar still decodes
//    - the sources/queries callbacks, so the grounding rail still populates
//
//  What it loses: `maxToolRounds` bounding and `ToolCallFormat` text recovery,
//  both of which are LiteRT's business once it owns the loop.
//
//  THE SHAPE OF THE PROBLEM: LiteRT's `Tool` requires `static var name`, and
//  `ToolManager` instantiates conformers through a no-argument `init()`. Both
//  mean a conformer cannot carry per-instance state — so the teemoon tool it
//  should call is looked up through a static registry, keyed by name.
//

import Foundation
import ModelBackend
import os

import LiteRTLM

private let logger = Logger(subsystem: "ai.teemoon", category: "inference.litert")

/// Maps tool name → the teemoon tool that implements it, plus where to report
/// what happened.
///
/// Static because `LiteRTLM.Tool` conformers are built by reflection with no
/// arguments; there is nowhere else to put this.
actor LiteRTToolRegistry {
    static let shared = LiteRTToolRegistry()

    struct Registration {
        let tool: any AnyLanguageModel.Tool
        /// Called with (name, arguments) BEFORE the tool runs.
        ///
        /// Needed for the same reason `GenerationEngine` fires
        /// `onQueriesFound` before dispatching: that is what turns the chip from
        /// "thinking" to "searching". Without it a grounded on-device query
        /// looks like the model thinking for a very long time, which is exactly
        /// how a tool loop was mistaken for a stall.
        let onStarted: @Sendable (String, [String: Any]) -> Void
        /// Called with (name, argumentsJSON, result) after each execution, so the
        /// transport can report the round to the UI.
        let onExecuted: @Sendable (String, String, String) -> Void
    }

    private var registrations: [String: Registration] = [:]

    func register(_ registration: Registration, for name: String) {
        registrations[name] = registration
    }

    func registration(for name: String) -> Registration? { registrations[name] }

    func clear() { registrations.removeAll() }
}

/// The bridge LiteRT actually calls.
///
/// One concrete type per tool name, because `static var name` admits no other
/// arrangement. teemoon has few tools, so explicit types are clearer than a
/// generic-over-descriptor trick — and the compiler tells you when a new tool
/// needs one.
struct LiteRTWebSearchTool: LiteRTLM.Tool {
    static var name: String { "web_search" }
    static var description: String {
        "Search the web for current, real-time information: recent events, news, "
        + "live prices, or anything that may have changed since training."
    }

    /// Whatever the model emitted, verbatim and undecoded.
    ///
    /// NOT typed properties, and that is the point. `ToolManager` decodes the
    /// model's arguments into a fresh instance of this type *before* `run()` is
    /// called, so any `let query: String` here would put `JSONDecoder` in front
    /// of teemoon's coercion — and a strict decode is exactly what small models
    /// fail. Measured: Gemma 4 emitted a call whose arguments lacked `query`,
    /// and the turn died with `keyNotFound` inside LiteRT, where teemoon's
    /// repair could never reach it.
    ///
    /// Storing the raw payload instead means argument shape is fixed in one
    /// place — `coerceArgsToSchema`, the same one the MLX path uses.
    private var rawArguments: [String: JSONValue] = [:]

    init() {}

    /// Accepts any object. See `rawArguments`.
    init(from decoder: any Decoder) throws {
        // Decode the object DIRECTLY, not through a single-value container.
        //
        // `singleValueContainer()` is for a scalar; the model's arguments arrive
        // as a JSON *object*, and asking for a single value on one fails. With
        // the failure swallowed by `try?`, that silently produced `[:]` — so
        // every tool call reached the tool with EMPTY arguments. The user-visible
        // result was a model that appeared not to search: `web_search` ran 8/8,
        // got `query: ""`, returned "Empty query — skipping search", and the
        // model then said, correctly, that it had no real-time information.
        //
        // Permissive decoding is still right — a small model's argument shape is
        // not to be trusted — but permissive must not mean silent, hence the log.
        rawArguments = (try? [String: JSONValue](from: decoder)) ?? [:]
        if rawArguments.isEmpty {
            logger.error("[litert] tool arguments decoded to EMPTY — the tool will run with nothing")
        }
    }

    /// teemoon's schema, not the one `Mirror` would infer.
    ///
    /// This is the override that makes the bridge worth having: the default
    /// `getSchema()` reflects over `@ToolParam` properties, and using it would
    /// mean maintaining a second, parallel description of every tool. Instead
    /// the model sees exactly the schema teemoon sends everywhere else —
    /// flattened, with `$ref` inlined, which small models demonstrably need.
    ///
    /// THE ENVELOPE IS LOAD-BEARING. It must be
    /// `{"type": "function", "function": {…, "parameters": …}}`, matching the
    /// default implementation above — a flat `{name, description, parameters}`
    /// is accepted without complaint and then carries no parameters into the
    /// native layer, so constrained decoding has nothing to constrain and the
    /// model invents its own argument names.
    func getSchema() -> [String: Any] {
        var function: [String: Any] = [
            "name": Self.name,
            "description": Self.description,
        ]
        if let parameters = LiteRTToolBridge.schemaCache[Self.name] {
            function["parameters"] = parameters
        }
        return ["type": "function", "function": function]
    }

    func run() async throws -> Any {
        await LiteRTToolBridge.execute(
            name: Self.name, arguments: rawArguments.mapValues(\.anyValue)
        )
    }
}

/// A JSON value that decodes from anything.
///
/// Exists so the shim above can hold the model's arguments without asserting
/// their shape. Deliberately minimal — it is a transport for one hop, between
/// LiteRT's decoder and teemoon's coercion.
private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognised JSON value")
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        // Whole numbers come back as Int so they re-serialise as `5`, not `5.0`
        // — a model asked for `count` should not see a float echoed back.
        case .number(let value): return value == value.rounded() ? Int(value) : value
        case .object(let value): return value.mapValues(\.anyValue)
        case .array(let value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }
}

/// Wiring between teemoon's tools and LiteRT's registry.
enum LiteRTToolBridge {
    /// Schemas keyed by tool name, filled at registration.
    ///
    /// `nonisolated(unsafe)` with a lock rather than an actor: `getSchema()` is
    /// synchronous and non-throwing in LiteRT's protocol, so there is no way to
    /// await from it.
    nonisolated(unsafe) private static var _schemaCache: [String: [String: Any]] = [:]
    private static let cacheLock = NSLock()

    /// Tool rounds used in the current turn.
    ///
    /// LiteRT owns the tool loop for this transport, and its own ceiling is
    /// `recurringToolCallLimit = 25` — against teemoon's `maxToolRounds` of 2.
    /// On a phone each round is a live search plus a full re-prefill of the
    /// results plus a decode, so twenty-five of them is minutes of pinned GPU
    /// with the UI showing nothing.
    ///
    /// Harmless until today: the bridge was passing empty arguments, so every
    /// search returned "Empty query" instantly and the model gave up. Once
    /// arguments actually arrived, the model could genuinely keep searching —
    /// and did: 160 s and counting on "what's the weather like in new york
    /// ny", no answer rendered.
    nonisolated(unsafe) private static var _roundsUsed = 0
    private static let roundLock = NSLock()

    /// Rounds teemoon allows, mirroring `GenerationEngine.maxToolRounds` for the
    /// on-device path. Two still allows search-then-answer, which is the shape
    /// essentially every grounded query actually takes.
    static let maxToolRounds = 2

    /// Reset where the turn's tools are wired — see `bridged`.

    static var schemaCache: [String: [String: Any]] {
        cacheLock.withLock { _schemaCache }
    }

    /// Registers teemoon's tools and returns the LiteRT shims to hand to
    /// `ConversationConfig`. Returns empty when nothing maps, so the caller can
    /// skip tool wiring entirely.
    static func bridged(
        tools: [any AnyLanguageModel.Tool],
        onStarted: @escaping @Sendable (String, [String: Any]) -> Void = { _, _ in },
        onExecuted: @escaping @Sendable (String, String, String) -> Void
    ) async -> [LiteRTLM.Tool] {
        // The round budget resets HERE rather than in a separate `beginTurn()`
        // the transport has to remember to call: this runs exactly once per
        // turn, immediately before the conversation is created, so the reset
        // cannot drift out of step with the thing it bounds.
        roundLock.withLock { _roundsUsed = 0 }
        var shims: [LiteRTLM.Tool] = []
        for tool in tools {
            // Only tools with a shim type can cross over. Silently dropping the
            // rest would make a tool look broken, so it is logged.
            guard tool.name == LiteRTWebSearchTool.name else {
                logger.warning("[litert] no bridge for tool '\(tool.name, privacy: .public)' — it will not be offered")
                continue
            }
            cacheLock.withLock {
                _schemaCache[tool.name] = GenerationEngine.flattenedToolSchema(tool)
            }
            await LiteRTToolRegistry.shared.register(
                .init(tool: tool, onStarted: onStarted, onExecuted: onExecuted), for: tool.name
            )
            shims.append(LiteRTWebSearchTool())
        }
        return shims
    }

    /// Runs the registered teemoon tool and reports the round.
    ///
    /// Never throws: a thrown error inside LiteRT's loop aborts the whole
    /// generation, whereas an error *string* lets the model recover — which is
    /// how teemoon's own engine already treats tool failures.
    static func execute(name: String, arguments: [String: Any]) async -> String {
        guard let registration = await LiteRTToolRegistry.shared.registration(for: name) else {
            return "[Tool '\(name)' not found]"
        }

        // Bound the loop teemoon does not own. Refusing the CALL rather than
        // throwing matters: an error propagates out of `sendMessageStream` and
        // kills the whole generation, losing the answer the model could still
        // give from what it already found. A string keeps the turn alive and
        // tells the model to stop searching and answer.
        let over = roundLock.withLock { () -> Bool in
            _roundsUsed += 1
            return _roundsUsed > maxToolRounds
        }
        if over {
            logger.warning("[litert] tool-round limit (\(maxToolRounds, privacy: .public)) reached — refusing further searches")
            return "[Search limit reached. Answer the user now, using the results you already have.]"
        }

        // Announce the call BEFORE running it, so the UI can say "searching"
        // for the seconds it actually takes.
        registration.onStarted(name, arguments)
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let result = await run(registration.tool, argumentsJSON: argsJSON)
        registration.onExecuted(name, argsJSON, result)
        return result
    }

    /// Same coercion path the shared engine uses, so a model that stringifies a
    /// scalar (`"count": "5"`) is tolerated identically on both runtimes.
    private static func run(_ tool: some AnyLanguageModel.Tool, argumentsJSON: String) async -> String {
        let coerced = GenerationEngine.toolSchemaJSON(tool)
            .map { GenerationEngine.coerceArgsToSchema(argumentsJSON, schema: $0) } ?? argumentsJSON
        guard let content = try? GeneratedContent(json: coerced) else {
            return "[Failed to parse tool arguments JSON]"
        }
        do {
            let args = try type(of: tool).Arguments(content)
            let output = try await tool.call(arguments: args)
            if let string = output as? String { return string }
            return output.promptRepresentation.description
        } catch {
            return "[Tool call failed: \(error)]"
        }
    }
}
