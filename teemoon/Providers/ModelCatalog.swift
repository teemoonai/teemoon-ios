//
//  ModelCatalog.swift
//  teemoon
//
//  Catalog helpers that are NOT provider-specific: turning a model id into a
//  slug / vendor label, formatting price + context for a row, and ordering a
//  live list the way its curated snapshot reads. Every adapter (near.ai, xAI,
//  Fireworks, Ollama, generic OpenAI-compat) builds `KnownModel`s through these,
//  so one endpoint's rows can't drift in shape from another's.
//
//  `NearAIModelCatalog` keeps its own names for these (it was here first) and
//  forwards; new adapters call `ModelCatalog` directly.
//

import Foundation

enum ModelCatalog {

    // MARK: - Identity

    /// Vendor-agnostic model key: the last path component, lowercased, minus a
    /// trailing precision/quant suffix — so a curated `glm-5.1-fp8` and a live
    /// `glm-5.1` share ONE slug (same model for metadata + ordering).
    static func slug(_ id: String) -> String {
        var s = displayName(forID: id).lowercased()
        for suffix in ["-fp8", "-fp16", "-bf16", "-int8", "-int4", "-awq", "-gptq", "-nvfp4"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
        }
        return s
    }

    /// The last path component of an id — the display name for models no
    /// curated list covers.
    static func displayName(forID id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Dash-separated words that describe the *build* of a model rather than the
    /// model: weight precision, container format, packaging, tuning markers.
    /// Nobody reading a nav bar needs any of them.
    private static let buildWords: Set<String> = [
        "fp8", "fp16", "fp32", "bf16", "f16", "f32", "int8", "int4",
        "awq", "gptq", "nvfp4", "gguf", "ggml", "safetensors",
        "qat", "instruct", "chat", "it", "hf", "ud",
        "k_m", "k_s", "k_l", "k_xl",
    ]

    /// File extensions that appear when a server is pointed straight at a weights
    /// file (llama.cpp serving a `.gguf`), so the "model id" is really a filename.
    private static let weightExtensions = [".gguf", ".ggml", ".safetensors", ".bin", ".pt"]

    /// True for one dash-separated word that names a build rather than a model —
    /// either a known word above or a quantisation code (`q4_k_m`, `q2_0`, `iq3_m`).
    private static func isBuildWord(_ word: String) -> Bool {
        if buildWords.contains(word) { return true }
        var rest = Substring(word)
        if rest.hasPrefix("iq")     { rest = rest.dropFirst(2) }
        else if rest.hasPrefix("q") { rest = rest.dropFirst(1) }
        else { return false }
        return rest.first?.isNumber == true      // q4…, q2_0, iq3_m
    }

    /// The shortest name that still identifies the model, for space-starved
    /// surfaces like the chat title bar: last path segment, lowercased, stripped
    /// of any weights-file extension, then stripped of every trailing build word.
    /// A trailing `:tag` keeps whatever of it names a *size* — `gemma4:e2b` and
    /// `gemma4:27b` are different models to the user, where `:UD-Q4_K_XL` is the
    /// same model packed smaller. Build words are peeled out of the tag by the
    /// same rule as the base, so a tag that mixes the two keeps only the part
    /// that identifies the model.
    ///
    ///     zai-org/GLM-5.1-FP8                        → glm-5.1
    ///     unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL → gemma-4-e4b
    ///     ternary-bonsai-8b-q2_0.gguf                → ternary-bonsai-8b
    ///     gemma4:e2b-it-qat                          → gemma4:e2b
    ///     gemma4:e2b                                 → gemma4:e2b
    static func compactName(forID id: String) -> String {
        var base = displayName(forID: id)
        var tag: String?
        if let colon = base.firstIndex(of: ":") {
            tag = String(base[base.index(after: colon)...]).lowercased()
            base = String(base[..<colon])
        }
        base = base.lowercased()

        for ext in weightExtensions where base.hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
            break
        }

        // The base must keep at least one word — peeling it to nothing would
        // leave no model at all. A tag may peel away entirely: a tag made only
        // of build words (`ud-q4_k_xl`) says nothing about which model this is.
        base = Self.peelingBuildWords(base, keepingAtLeastOneWord: true)
        if base.isEmpty { return displayName(forID: id).lowercased() }

        if let tag {
            let kept = Self.peelingBuildWords(tag, keepingAtLeastOneWord: false)
            if !kept.isEmpty { return base + ":" + kept }
        }
        return base
    }

    /// Drops build words from the end of a dash-separated name. Peeling stops at
    /// the first word that isn't one, so size words ("8b", "27b", "e4b") — which
    /// DO identify the model — survive anything trailing them.
    private static func peelingBuildWords(_ s: String, keepingAtLeastOneWord: Bool) -> String {
        var words = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let floor = keepingAtLeastOneWord ? 1 : 0
        while words.count > floor, let last = words.last, isBuildWord(last) {
            words.removeLast()
        }
        return words.joined(separator: "-")
    }

    /// What the chat title bar shows for a provider: the compacted model — unless
    /// the model id is just an echo of the provider's own name, as with Brave
    /// Answers, which has no `/models` endpoint and ships `model: "brave"`. There
    /// the provider name says strictly more.
    ///
    /// Matches on **prefix**, never containment. A self-hosted provider's
    /// auto-label is "<host> <model>", so it contains the model by construction —
    /// substituting the whole label there is both longer and less informative,
    /// and long enough to get dropped from the bar entirely.
    static func titleLabel(model: String, providerName: String) -> String? {
        guard !model.isEmpty else { return nil }
        let compact = compactName(forID: model)
        let name = providerName.lowercased()
        return name.hasPrefix(compact) ? name : compact
    }

    /// Model families that aren't conversational — excluded from every chat
    /// model browser (embeddings, rerankers, speech, image, PII filter). Media
    /// families an adapter can identify precisely (xAI's `grok-imagine-*`, which
    /// carries no text-token price) are filtered there, not by keyword here.
    private static let nonChatKeywords = [
        "embedding", "reranker", "whisper", "privacy-filter", "flux",
    ]

    static func isNonChat(_ id: String) -> Bool {
        let lower = id.lowercased()
        return nonChatKeywords.contains { lower.contains($0) }
    }

    // MARK: - Vendor

    /// Namespace → display vendor, for ids shaped `vendor/name`.
    private static let namespaceVendors: [String: String] = [
        "zai-org": "Z.ai", "z-ai": "Z.ai",
        "deepseek-ai": "DeepSeek", "deepseek": "DeepSeek",
        "qwen": "Qwen", "openai": "OpenAI", "anthropic": "Anthropic",
        "google": "Google", "moonshotai": "Moonshot", "minimax": "MiniMax",
        "meta-llama": "Meta", "mistralai": "Mistral", "nvidia": "NVIDIA",
        "black-forest-labs": "Black Forest Labs", "xai": "xAI",
    ]

    /// Family keyword → vendor, for ids whose namespace can't name a vendor:
    /// `grok-4.3` (xAI) and `qwen3.5:4b` (Ollama) have none at all, and
    /// `accounts/fireworks/models/kimi-k2p6` has the meaningless "accounts".
    /// Without this each such id became its own vendor section, because the
    /// fallback title-cased the id itself ("Grok-4.3", "Accounts").
    /// Ordered — the first match wins, so `gpt-oss` beats `gpt`.
    private static let familyVendors: [(keyword: String, vendor: String)] = [
        ("grok", "xAI"),
        ("gpt-oss", "OpenAI"),
        ("claude", "Anthropic"),
        ("gemma", "Google"), ("gemini", "Google"),
        ("deepseek", "DeepSeek"),
        ("qwen", "Qwen"), ("qwq", "Qwen"),
        ("glm", "Z.ai"),
        ("kimi", "Moonshot"),
        ("minimax", "MiniMax"),
        ("nemotron", "NVIDIA"),
        ("llama", "Meta"),
        ("mistral", "Mistral"), ("mixtral", "Mistral"), ("magistral", "Mistral"),
        ("devstral", "Mistral"), ("codestral", "Mistral"),
        ("phi-", "Microsoft"), ("phi3", "Microsoft"), ("phi4", "Microsoft"),
        ("command-", "Cohere"),
        ("granite", "IBM"),
        ("olmo", "AI2"),
        ("smollm", "Hugging Face"),
        ("flux", "Black Forest Labs"),
        ("gpt-", "OpenAI"), ("o3", "OpenAI"), ("o4", "OpenAI"),
    ]

    /// Vendor inferred from the model NAME's family, ignoring any namespace.
    /// nil when no family is recognized. Use this only where the namespace is
    /// known NOT to name a vendor (see `vendorLabel`).
    static func familyVendor(forID id: String) -> String? {
        let lower = id.lowercased()
        return familyVendors.first { lower.contains($0.keyword) }?.vendor
    }

    /// Display vendor for a model id — the section header in the model browser.
    ///
    /// The namespace is AUTHORITATIVE when the id carries one, and the family
    /// table is consulted only for ids without: `differentVendor` compares these
    /// labels to catch a node serving something other than what was requested
    /// (`QuantTrio/GLM-5.1-AWQ` vs `zai-org/GLM-5.1-FP8` must stay a mismatch),
    /// so a family keyword must never collapse two distinct namespaces.
    static func vendorLabel(forID id: String) -> String {
        guard id.contains("/") else { return familyVendor(forID: id) ?? "Other" }
        let namespace = (id.split(separator: "/").first.map(String.init) ?? "").lowercased()
        if let mapped = namespaceVendors[namespace] { return mapped }
        if namespace.isEmpty { return "Other" }
        return namespace.prefix(1).uppercased() + namespace.dropFirst()
    }

    /// A hand-written catalogue name, read like every other row.
    ///
    /// Fireworks is the one source that writes a `displayName` per model, so its
    /// names arrive in three styles at once and none of them is the app's:
    ///
    ///   - `OpenAI gpt-oss-20b` repeats the vendor the section header already
    ///     prints — "openai" above "openai gpt-oss-20b".
    ///   - `DeepSeek-V4-Flash` is hyphen-joined where every other row is spaced.
    ///   - `NVIDIA Nemotron 3 Ultra NVFP4` carries a precision suffix, which cost
    ///     the row its name: it rendered as "nvidia nemotron 3 ultra n…".
    ///
    /// near.ai's names are the standard ("DeepSeek V4 Flash", "gpt oss 120b")
    /// because they are what this browser has always rendered. Case is left alone
    /// — the row lowercases.
    ///
    /// The leading vendor word is dropped ONLY when what remains still names the
    /// family: "OpenAI gpt-oss-20b" → "gpt oss 20b" keeps `gpt-oss`, while
    /// "DeepSeek-V4-Flash" keeps its first word because there the vendor word IS
    /// the family word and "V4 Flash" names nothing. Same reason "Minimax M3"
    /// stays whole.
    static func productName(_ raw: String, vendor: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var words = spaced.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return raw }

        if words[0].compare(vendor, options: .caseInsensitive) == .orderedSame {
            let rest = Array(words.dropFirst())
            // The family check runs on the DASH-joined remainder, because that is
            // the shape `familyVendors` matches ("gpt-oss" has a hyphen in it).
            if !rest.isEmpty, familyVendor(forID: rest.joined(separator: "-")) != nil {
                words = rest
            }
        }
        // Trailing build words go, one word kept at minimum — the same rule
        // `compactName` applies to ids, so "…Ultra NVFP4" and "…3n it" lose the
        // part that describes the build rather than the model.
        while words.count > 1, isBuildWord(words[words.count - 1].lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    // MARK: - Row formatting

    /// "$1/$5" (whole) or "$1.40/$4.40" from per-1M-token input/output prices.
    static func priceLabel(inputPerMillion: Double?, outputPerMillion: Double?) -> String {
        guard let i = inputPerMillion, let o = outputPerMillion else { return "" }
        func fmt(_ v: Double) -> String {
            v == v.rounded() ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
        }
        return "\(fmt(i))/\(fmt(o))"
    }

    /// "128k" / "1m" from a LOCAL model's context length. GGUF context sizes are
    /// powers of two, so this is 1024-based: 131072 reads as "128k", which is what
    /// the model card says, not the "131k" a decimal label would print. Cloud
    /// catalogues quote round decimal numbers and use `contextLabel` instead.
    static func localContextLabel(_ n: Int?) -> String {
        guard let n, n > 0 else { return "" }
        if n >= 1_048_576 { return "\(n / 1_048_576)m" }
        if n >= 1024      { return "\(n / 1024)k" }
        return "\(n)"
    }

    /// "262k" / "1M" / "1.1M" from a token count. Empty when unknown.
    /// Rounds to one decimal FIRST: a real 1048576-token window is "1M", not the
    /// "1.0M" a raw whole-number test produces (near.ai quotes a round 1000000,
    /// so only Fireworks' power-of-two windows ever hit this).
    static func contextLabel(_ n: Int?) -> String {
        guard let n, n > 0 else { return "" }
        if n >= 1_000_000 {
            let m = (Double(n) / 100_000).rounded() / 10
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        return "\(n / 1000)k"
    }

    // MARK: - Recency

    /// How recently a model must have been published to wear the "new" badge.
    /// Matches the window the catalog generator uses for the near.ai block.
    static let newBadgeWindow: TimeInterval = 45 * 24 * 60 * 60

    /// Whether a model published at `created` still counts as new. Derived from
    /// the catalogue rather than hand-maintained, so a badge can't outlive its
    /// model — `isNew: true` left in a snapshot is invisible rot.
    static func isNew(created: Date?, now: Date = Date()) -> Bool {
        guard let created else { return false }
        let age = now.timeIntervalSince(created)
        return age >= 0 && age <= newBadgeWindow
    }

    /// ISO-8601 timestamp → Date, with or without fractional seconds (Fireworks
    /// sends "2026-04-24T04:09:07.488210Z").
    static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: - Ordering

    /// Order a live list the way its curated snapshot reads: vendor families in
    /// curated order (each led by its newest model), curated models keeping their
    /// curated (recency) order, uncurated live models at the HEAD of their family.
    /// Vendors absent from the curated list sort after, alphabetically.
    static func sortByVendorFamily(_ models: [KnownModel], curated: [KnownModel]) -> [KnownModel] {
        let curatedIndex = Dictionary(
            curated.enumerated().map { ($1.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first })
        let curatedSlugIndex = Dictionary(
            curated.enumerated().map { (slug($1.id), $0) },
            uniquingKeysWith: { first, _ in first })
        var vendorRank: [String: Int] = [:]
        for m in curated where vendorRank[m.vendor] == nil {
            vendorRank[m.vendor] = vendorRank.count
        }
        func rank(_ m: KnownModel) -> (Int, String, Int, String) {
            (vendorRank[m.vendor] ?? Int.max,
             vendorRank[m.vendor] != nil ? "" : m.vendor,   // unknown vendors alphabetical
             curatedIndex[m.id.lowercased()] ?? curatedSlugIndex[slug(m.id)] ?? -1,  // uncurated → family head
             m.id)
        }
        return models.sorted { rank($0) < rank($1) }
    }

    /// Curated metadata for a live id — exact id first, then slug, so a
    /// namespace or quant-suffix change upstream still carries price/name over.
    static func curatedMatch(for id: String, in curated: [KnownModel]) -> KnownModel? {
        if let exact = curated.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return exact
        }
        let key = slug(id)
        return curated.first { slug($0.id) == key }
    }

    // MARK: - Live catalogue routing

    /// Endpoint → its richest catalogue. **The only routing table**, because there
    /// are two doors onto a provider's model list and each used to carry its own
    /// copy: Settings' add/edit screen (`probeEndpoint`) and the Where sheet's
    /// `browse <provider>` row.
    ///
    /// The copies drifted, twice, in the same direction — the sheet rendered a
    /// curated `KnownModel` snapshot while Settings fetched live. near.ai was
    /// fixed in place on 2026-07-29 (it was badging models published 55 days
    /// earlier and quoting snapshot prices), and grok and fireworks were left
    /// behind by that fix, so the sheet still showed Grok rows with `price: ""`
    /// and no context window at all while the same key rendered a full row one
    /// screen away. A second table is a table that disagrees; this is the first
    /// one, and both doors now call it.
    ///
    /// `.generic` belongs here too. A custom cloud endpoint has no curated
    /// snapshot, so routing it through the probe is the difference between live
    /// bare ids and an empty browse sheet.
    ///
    /// Returns the same `ProbeResult` as every adapter — a failure is a failure,
    /// so the caller can keep whatever it was already showing rather than
    /// replacing a working list with an error.
    static func liveCatalog(
        for source: EndpointModelCatalog.Source,
        baseURL: URL,
        apiKey: String,
        authHeaderName: String? = nil,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        func genericProbe() async -> EndpointModelCatalog.ProbeResult {
            await EndpointModelCatalog.probe(
                baseURL: baseURL,
                authHeaderName: authHeaderName,
                apiKey: apiKey,
                session: session
            )
        }
        switch source {
        case .nearAI:
            // near.ai's fetch carries the curated merge and records confidentiality
            // tiers as a side effect, which is why it isn't an adapter. An EMPTY
            // list counts as a failure: nil is a decode failure and `[]` is a key
            // with nothing entitled, and both mean "show the fallback".
            if let live = await NearAIModelCatalog.fetchLive(apiKey: apiKey, session: session),
               !live.isEmpty {
                return .connected(live)
            }
            return await genericProbe()
        case .xAI:
            return await XAIAdapter.listModels(baseURL: baseURL, apiKey: apiKey, session: session)
        case .fireworks:
            return await FireworksAdapter.listModels(baseURL: baseURL, apiKey: apiKey, session: session)
        case .generic:
            return await genericProbe()
        }
    }
}
