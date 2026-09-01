//
//  ModelCapabilities.swift
//  teemoon
//
//  What a *specific model* can do — modeled in the catalog, not discovered by
//  reacting to a 400 in the inference hot path. teemoon gates behavior on these
//  *before* a request: don't attach a `web_search` tool to a model that can't
//  call tools, and (later) only offer image/file input to models that accept it.
//
//  Distinct from `Provider.Capabilities`, which describes the *provider/endpoint*
//  (attestation, E2EE, built-in grounding). This describes the *model*.
//
//  Optionality convention (important): a `ModelCapabilities?` of **nil means
//  "unknown"** — the source didn't tell us (a generic `/v1/models` endpoint like
//  llama.cpp exposes no capability metadata). A **non-nil** value means "known"
//  (an empty set is a *known* "supports none of these"). Callers treat unknown
//  optimistically (see `Provider.modelSupportsTools`).
//

import Foundation

struct ModelCapabilities: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    /// The model can call function/tools (OpenAI `tools`). Gates `BraveWebSearchTool`.
    static let tools    = ModelCapabilities(rawValue: 1 << 0)
    /// The model accepts image input (multimodal). Reserved — wired when vision lands.
    static let vision   = ModelCapabilities(rawValue: 1 << 1)
    /// The model accepts file/document uploads. Reserved — wired when uploads land.
    static let uploads  = ModelCapabilities(rawValue: 1 << 2)
    /// The model accepts audio input.
    ///
    /// Both live sources report it and teemoon dropped it: Ollama lists `audio`
    /// for gemma4 (`/api/show`), and near.ai lists it in `input_modalities`.
    /// A peer of `vision` — same axis, same treatment.
    static let audio    = ModelCapabilities(rawValue: 1 << 3)
    /// The model reasons before answering.
    ///
    /// Ollama calls it `thinking`, near.ai calls it `reasoning` in
    /// `supported_features` (24 of 47 models). One capability, two names on the
    /// wire — which is exactly why it belongs in a type instead of at each
    /// call site.
    static let thinking = ModelCapabilities(rawValue: 1 << 4)

    // MARK: Role flags — read the warning before gating on these
    //
    // These say what a model is FOR, and unlike the flags above their ABSENCE is
    // meaningful. That makes them dangerous under this type's all-or-nothing
    // semantics: a `ModelCapabilities?` is unknown as a WHOLE, so there is no way
    // to say "known: vision, unknown: completion".
    //
    // Only Ollama reports them. near.ai, xAI, Fireworks and LM Studio set caps
    // without them, so a near.ai model has no `.completion` bit and NOT because
    // it cannot complete. **Never write `if !caps.contains(.completion)` and
    // conclude a model can't chat** — you would be reading "this source didn't
    // say" as "no". They are recorded because dropping data the server sent is
    // how the `audio` gap happened; giving them a consumer needs per-capability
    // unknown first (see EndpointModelCatalog's note on the same trap).

    /// Text generation. Absent from every source but Ollama.
    static let completion = ModelCapabilities(rawValue: 1 << 5)
    /// Embeddings. A model with this and no `completion` cannot answer a chat.
    static let embedding  = ModelCapabilities(rawValue: 1 << 6)
    /// Fill-in-the-middle insertion.
    static let insert     = ModelCapabilities(rawValue: 1 << 7)

    /// Build from Ollama `/api/show` `capabilities`, e.g.
    /// `["completion","vision","audio","tools","thinking"]` — the real response
    /// for `gemma4:latest`.
    ///
    /// Ollama enumerates the model's COMPLETE capability set, which is what
    /// makes mapping the role flags safe here and nowhere else. Unrecognised
    /// strings are still ignored, so a newer Ollama can add a word without
    /// breaking the decode.
    ///
    /// Always returns a *known* (non-nil) value — Ollama tells us explicitly.
    static func fromOllama(_ raw: [String]) -> ModelCapabilities {
        var caps: ModelCapabilities = []
        for c in raw {
            switch c.lowercased() {
            case "tools":      caps.insert(.tools)
            case "vision":     caps.insert(.vision)
            case "audio":      caps.insert(.audio)
            case "thinking":   caps.insert(.thinking)
            case "completion": caps.insert(.completion)
            case "embedding":  caps.insert(.embedding)
            case "insert":     caps.insert(.insert)
            default:           break
            }
        }
        return caps
    }
}
