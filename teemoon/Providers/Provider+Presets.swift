//
//  Provider+Presets.swift
//  teemoon
//
//  ────────────────────────────────────────────────────────────────────────────
//  Edit this file to add, remove, or update built-in provider presets and
//  their known model lists.
//
//  • Presets appear as buttons in the quick-start row of the provider form.
//  • Model lists power the browse sheet when supportsModelBrowsing = true.
//  • Prices are per 1 million tokens (input / output) and change frequently —
//    update them here as providers publish new pricing.
//  ────────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Provider presets
//
// Fixed UUIDs ensure saved provider selections survive app updates.
// Add new entries to the `presets` array to include them in quick-start.

extension Provider {

    static let nearAI = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
        name:                 "near.ai",
        endpoint:             "https://cloud-api.near.ai/v1/chat/completions",
        model:                "z-ai/glm-5.2",   // top e2ee flagship (not a proxied Claude)
        supportsModelBrowsing: true,
        presetDescription:    "open models running inside attested enclaves encrypted to the llm model, so the operator can't read your chats. teemoon checks the proof on the device.",
        // cloud.near.ai CTAs ("Get an API key") land here; app.near.ai redirects to marketing.
        signupURL:            "https://cloud.near.ai/signin"
    )

    static let braveAnswers = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
        name:                 "Brave Answers",
        endpoint:             "https://api.search.brave.com/res/v1/chat/completions",
        model:                "brave",
        authHeaderName:       "X-Subscription-Token",
        extraParams:          ["enable_citations": "true"],
        maxMessages:          1,
        hasBuiltInGrounding:  true,
        omitSystemPrompt:     true,
        presetDescription:    "single answers grounded in live web search, with citations. has a different key than brave llm grounding api.",
        // Keys UI (unauth → login?redirect=/app/keys). Marketing root api.search.brave.com
        // only funnels to brave.com/search/api/.
        signupURL:            "https://api-dashboard.search.brave.com/app/keys"
    )

    static let grok = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
        name:                 "Grok",
        endpoint:             "https://api.x.ai/v1/chat/completions",
        model:                "grok-4.3",
        supportsModelBrowsing: true,
        presetDescription:    "xai's models, with a 2m token context window, reasoning modes, and live web and x knowledge.",
        // Deliberately the bare console, unlike the other three. The keys page is
        // /team/<slug>/api-keys, and "default" is only the slug for accounts that
        // never renamed their team — hardcoding it sends everyone else to a 404.
        // The console root resolves to whichever team you're actually in.
        signupURL:            "https://console.x.ai/"
    )

    static let fireworks = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!,
        name:                 "Fireworks",
        endpoint:             "https://api.fireworks.ai/inference/v1/chat/completions",
        model:                "accounts/fireworks/models/kimi-k2p6",
        supportsModelBrowsing: true,
        presetDescription:    "fast, low-cost inference for open models. large catalog — kimi, deepseek, qwen, glm, and more.",
        // fireworks.ai/api-keys → app.fireworks.ai/settings/users/api-keys
        signupURL:            "https://fireworks.ai/api-keys"
    )

    /// Order here controls the button order in the quick-start row.
    static let presets: [Provider] = [.nearAI, .grok, .fireworks, .braveAnswers]

    /// Endpoints whose MODEL LIST is gated behind the api key, so asking without
    /// one can only 401.
    ///
    /// Measured 2026-07-31, unauthenticated GET:
    ///
    ///     cloud-api.near.ai/v1/models           200   ← public, absent here
    ///     api.x.ai/v1/models                    401
    ///     api.fireworks.ai/inference/v1/models  401
    ///
    /// near.ai's absence is the point: its catalogue really is fetchable without
    /// a key, which is why its Where row shows a live model count while the
    /// others say "add key". A blanket "never fetch before a key" would throw
    /// that away.
    ///
    /// This is a small table of third-party behaviour and can therefore rot — a
    /// vendor may open or close their list. It is only ever used to SKIP a
    /// request that would fail, never to claim one would succeed: if an entry
    /// goes stale the app asks anyway and learns from the answer, which is the
    /// safe direction to be wrong in.
    /// HOSTS, not full URLs. Matching the whole endpoint string missed the
    /// moment anything differed — a trailing slash, a path the user edited, a
    /// preset whose completions path is not what the probe URL ends up being —
    /// and a miss here is silent: the button simply fails to grey out, which is
    /// how this was found.
    static let modelListRequiresKeyHosts: Set<String> = [
        "api.x.ai",
        "api.fireworks.ai",
    ]


    /// Per-provider rule for picking the default/highlighted model from the LIVE
    /// catalogue — never a pinned version. Cloud users want the biggest model they
    /// can't run locally, so near.ai defaults to the most-expensive E2EE (flagship);
    /// Brave has no /models endpoint so its model is fixed. See [[ModelDefaultRule]].
    static let defaultModelRules: [UUID: ModelDefaultRule] = [
        Provider.nearAI.id:       .mostExpensive(e2eeOnly: true),
        Provider.grok.id:         .first,                 // one family — refine later
        Provider.fireworks.id:    .first,                 // .curated([…]) once curated
        Provider.braveAnswers.id: .fixed("brave"),        // no /models endpoint
    ]

    /// The default-model rule for this provider, if it's a known preset.
    var defaultModelRule: ModelDefaultRule? { Provider.defaultModelRules[id] }

    /// The preset this provider's endpoint matches, if any. Matching by endpoint
    /// (not id) is what makes it work for a provider the user added themselves:
    /// `save()` mints a fresh UUID, so the preset's id is long gone by then.
    var matchingPreset: Provider? {
        let target = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        return Provider.presets.first { $0.endpoint.lowercased() == target }
    }

    /// Vendor console / keys / credits URL for this provider when it matches a
    /// cloud preset (or carries its own `signupURL`). nil for custom / self-hosted.
    var consoleURL: URL? {
        let raw = matchingPreset?.signupURL ?? signupURL
        guard let raw, let url = URL(string: raw) else { return nil }
        return url
    }

    /// Short vendor name for console CTAs ("near.ai", "Grok") — not the user's
    /// free-form label ("near.ai glm 5.2").
    var consoleDisplayName: String {
        matchingPreset?.name ?? name
    }

    /// Last two labels of a host — the vendor, ignoring which box answered.
    /// `cloud-api.near.ai`, `glm-5-2.completions.near.ai` → `near.ai`;
    /// `api.fireworks.ai`, `app.fireworks.ai` → `fireworks.ai`.
    ///
    /// Deliberately NOT substring matching: `"phoenix.ai".contains("x.ai")` is
    /// true, so a user self-hosting at llm.phoenix.ai would have been sent to
    /// xAI's billing page on a 401. Two labels is right for every preset here
    /// (all are vendor.tld); it would under-match a multi-part suffix like
    /// .co.uk, which none of them use.
    private static func vendorDomain(of host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Resolve a cloud console URL for a chat/inference error so 401/402 can
    /// deep-link out. Prefers request-host match, then active provider, then
    /// name containment (user labels often include the preset name).
    static func consoleRecovery(
        for error: LLMError,
        activeProvider: Provider?
    ) -> (url: URL, displayName: String)? {
        if case .braveGrounding = error.source {
            guard let url = Provider.braveAnswers.consoleURL else { return nil }
            return (url, Provider.braveAnswers.name)
        }

        // 1. Request URL host → preset (works even when the label was renamed).
        if let host = error.url?.host?.lowercased() {
            for preset in presets {
                guard let presetHost = URL(string: preset.endpoint)?.host?.lowercased() else { continue }
                if vendorDomain(of: host) == vendorDomain(of: presetHost),
                   let url = preset.consoleURL {
                    return (url, preset.name)
                }
            }
        }

        // 2. Active provider (usual case: the model that just failed is current).
        if let active = activeProvider, let url = active.consoleURL {
            return (url, active.consoleDisplayName)
        }

        // 3. Label contains a preset name ("near.ai glm 5.2" → near.ai).
        if case .provider(let label) = error.source {
            let lower = label.lowercased()
            if let preset = presets.first(where: { lower.contains($0.name.lowercased()) }),
               let url = preset.consoleURL {
                return (url, preset.name)
            }
        }

        return nil
    }

    /// Hard wire-shape constraints of the endpoint, NOT preferences: Brave's
    /// answers API rejects a request carrying more than one message —
    /// `422 "List should have at most 1 item after validation"` — and counts the
    /// system message toward that one (verified live 2026-07-26).
    ///
    /// These fall back to the matched preset because a stored provider is user
    /// data: it can predate a field, or be edited into a shape the endpoint will
    /// refuse. The stored value still wins when set, so a deliberate override is
    /// respected; the preset only fills a gap that would otherwise 422.
    var effectiveMaxMessages: Int? { maxMessages ?? matchingPreset?.maxMessages }
    var effectiveOmitSystemPrompt: Bool { omitSystemPrompt || (matchingPreset?.omitSystemPrompt ?? false) }

    /// True when the endpoint answers ONE question at a time and cannot see the
    /// conversation. Drives the chat-side note, so a follow-up that lands
    /// context-free is explained rather than looking like a broken model.
    var answersSingleTurnOnly: Bool { (effectiveMaxMessages ?? .max) <= 1 }

    /// Endpoint that can verify this provider's key when it has **no** `/models`
    /// list to probe. Only Brave qualifies today: its answers API is POST-only,
    /// so the key is checked against Brave's web-search endpoint instead.
    ///
    /// Caveat worth knowing: a 200 there proves the **token**, not that the
    /// subscription includes the AI-answers option — a search-only plan still
    /// returns HTTP 400 `OPTION_NOT_IN_PLAN` on the first message. That case is
    /// surfaced verbatim by `apiErrorMessage`, which reads Brave's `detail`.
    var keyValidationEndpoint: ProviderKeyValidator.Endpoint? {
        id == Provider.braveAnswers.id ? .braveSearch : nil
    }

    /// Base URL for inference. For near.ai providers, returns the model's direct
    /// completions URL when available, bypassing the gateway TEE. Falls back to
    /// the provider's configured endpoint for all other cases.
    var inferenceBaseURL: URL? {
        if capabilities.contains(.attestation),
           let direct = KnownModel.nearAIModels.first(where: { $0.id == model })?.directBaseURL {
            return URL(string: direct)
        }
        return openAIBaseURL
    }

    /// Direct GPU-node URL when the model exposes one distinct from the
    /// gateway — used for parallel GPU attestation and signing-key re-fetch.
    var directGPUNodeURL: URL? {
        guard let inference = inferenceBaseURL, inference != openAIBaseURL else { return nil }
        return inference
    }
}

// MARK: - Known models
//
// Each provider with supportsModelBrowsing = true should have a matching entry.
// Prices: "$input/$output per 1M tokens". Update as pricing changes.

extension KnownModel {

    // ── Near.ai ──────────────────────────────────────────────────────────────

    // ── BEGIN GENERATED · near.ai catalog ───────────────────────────────────
    // Edits between these markers are overwritten by --write; regenerate,
    // review the git diff, and commit manually — never auto-applied.
    /// Curated near.ai models — used for display metadata (price, context)
    /// and as the offline fallback for the model browser, which otherwise
    /// loads the live catalogue from `/v1/models` (see NearAIModelCatalog).
    /// Snapshot of /v1/models + /endpoints taken 2026-08-31; refresh both
    /// together (prices/context from /v1/models `pricing`/`context_length`,
    /// direct hosts from /endpoints, tiers from `owned_by`).
    ///
    /// THREE tiers, mirroring `owned_by`:
    ///  · nearai        — near.ai's own TEE fleet: E2EE-capable, each with a
    ///                    direct confidential host (the only tier teemoon can
    ///                    attest end-to-end).
    ///  · attested 3p   — third-party "attested" hosting (Chutes): anonymous,
    ///                    NO confidential endpoint, NO E2EE path. Never give
    ///                    these a directBaseURL.
    ///  · proxied       — plain passthrough to the upstream vendor API:
    ///                    anonymized, no enclave.
    static let nearAIModels: [KnownModel] = [
        // Ordering: newest first within each vendor family; vendor blocks by
        // their newest entry. Confidential tiers use the catalog's `created`;
        // the proxied tier uses semantic version recency (its `created` is
        // mostly one bulk-import date and would mislead).

        // ── nearai · own TEE fleet (E2EE) ────────────────────────────────────
        KnownModel(id: "Qwen/Qwen3.8-27B",                 displayName: "Qwen3.8 27B",       vendor: "Qwen",     price: "$0.44/$3.30",  contextWindow: "262K",              directBaseURL: "https://qwen3-8-27b.completions.near.ai/v1"),
        KnownModel(id: "Qwen/Qwen3.6-35B-A3B-FP8",         displayName: "Qwen3.6 35B",       vendor: "Qwen",     price: "$0.17/$1.10",  contextWindow: "262K",              directBaseURL: "https://qwen3-6-35b.completions.near.ai/v1"),
        KnownModel(id: "Qwen/Qwen3-VL-30B-A3B-Instruct",   displayName: "Qwen3-VL 30B",      vendor: "Qwen",     price: "$0.15/$0.55",  contextWindow: "16K",               directBaseURL: "https://qwen3-vl-30b.completions.near.ai/v1"),
        KnownModel(id: "z-ai/glm-5.2",                     displayName: "GLM 5.2",           vendor: "Z.ai",     price: "$1.40/$4.40",  contextWindow: "1M",                directBaseURL: "https://glm-5-2.completions.near.ai/v1"),
        KnownModel(id: "zai-org/GLM-5.1-FP8",              displayName: "GLM 5.1",           vendor: "Z.ai",     price: "$1.40/$4.40",  contextWindow: "203K",              directBaseURL: "https://glm-5-1.completions.near.ai/v1"),
        KnownModel(id: "deepseek-ai/DeepSeek-V4-Flash",    displayName: "DeepSeek V4 Flash", vendor: "DeepSeek", price: "$0.17/$0.35",  contextWindow: "1M",                directBaseURL: "https://dsv4-flash.completions.near.ai/v1"),

        // ── attested 3p · Chutes hardware (anonymous, NOT E2EE) ──────────────
        KnownModel(id: "moonshotai/kimi-k3",               displayName: "Kimi K3",           vendor: "Moonshot", price: "$3.30/$16.50", contextWindow: "1M"),
        KnownModel(id: "moonshotai/kimi-k2.6",             displayName: "Kimi K2.6",         vendor: "Moonshot", price: "$0.81/$3.85",  contextWindow: "262K"),
        KnownModel(id: "deepseek/deepseek-v3.2",           displayName: "DeepSeek V3.2",     vendor: "DeepSeek", price: "$1.10/$1.10",  contextWindow: "128K"),
        KnownModel(id: "qwen/qwen3.5-397b-a17b",           displayName: "Qwen3.5 397B",      vendor: "Qwen",     price: "$0.50/$3.30",  contextWindow: "128K"),
        KnownModel(id: "qwen/qwen3-32b",                   displayName: "Qwen3 32B",         vendor: "Qwen",     price: "$0.11/$0.46",  contextWindow: "128K"),

        // ── proxied · upstream vendor APIs (anonymized, no enclave) ──────────
        KnownModel(id: "qwen/qwen3.7-max",                 displayName: "Qwen3.7 Max",       vendor: "Qwen",      price: "$2.80/$7.50",  contextWindow: "1M"),
        KnownModel(id: "google/gemini-3.5-flash",          displayName: "Gemini 3.5 Flash",  vendor: "Google",    price: "$1.50/$9.00",  contextWindow: "1M"),
        KnownModel(id: "google/gemini-3.1-flash-lite",     displayName: "Gemini 3.1 Flash Lite", vendor: "Google", price: "$0.25/$1.50", contextWindow: "1M"),
        KnownModel(id: "google/gemini-2.5-pro",            displayName: "Gemini 2.5 Pro",    vendor: "Google",    price: "$1.25/$10.00", contextWindow: "1M"),
        KnownModel(id: "google/gemini-2.5-flash",          displayName: "Gemini 2.5 Flash",  vendor: "Google",    price: "$0.30/$2.50",  contextWindow: "1M"),
        KnownModel(id: "google/gemini-2.5-flash-lite",     displayName: "Gemini 2.5 Flash Lite", vendor: "Google", price: "$0.10/$0.40", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-fable-5",         displayName: "Claude Fable 5",    vendor: "Anthropic", price: "$10.00/$50.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-opus-5",          displayName: "Claude Opus 5",     vendor: "Anthropic", price: "$5.00/$25.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-sonnet-5",        displayName: "Claude Sonnet 5",   vendor: "Anthropic", price: "$2.00/$10.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-opus-4-8",        displayName: "Claude Opus 4.8",   vendor: "Anthropic", price: "$5.00/$25.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-opus-4-7",        displayName: "Claude Opus 4.7",   vendor: "Anthropic", price: "$5.00/$25.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-opus-4-6",        displayName: "Claude Opus 4.6",   vendor: "Anthropic", price: "$5.00/$25.00", contextWindow: "200K"),
        KnownModel(id: "anthropic/claude-sonnet-4-6",      displayName: "Claude Sonnet 4.6", vendor: "Anthropic", price: "$3.00/$15.00", contextWindow: "1M"),
        KnownModel(id: "anthropic/claude-sonnet-4-5",      displayName: "Claude Sonnet 4.5", vendor: "Anthropic", price: "$3.00/$15.00", contextWindow: "200K"),
        KnownModel(id: "anthropic/claude-haiku-4-5",       displayName: "Claude Haiku 4.5",  vendor: "Anthropic", price: "$1.00/$5.00",  contextWindow: "200K"),
        KnownModel(id: "openai/gpt-5.6-sol",               displayName: "GPT-5.6 Sol",       vendor: "OpenAI",    price: "$4.00/$20.00", contextWindow: "1.1M"),
        KnownModel(id: "openai/gpt-5.5",                   displayName: "GPT-5.5",           vendor: "OpenAI",    price: "$5.00/$30.00", contextWindow: "1.1M"),
        KnownModel(id: "openai/gpt-5.4",                   displayName: "GPT-5.4",           vendor: "OpenAI",    price: "$2.50/$15.00", contextWindow: "1.1M"),
        KnownModel(id: "openai/gpt-5.4-mini",              displayName: "GPT-5.4 Mini",      vendor: "OpenAI",    price: "$0.75/$4.50",  contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5.4-nano",              displayName: "GPT-5.4 Nano",      vendor: "OpenAI",    price: "$0.20/$1.25",  contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5.2",                   displayName: "GPT-5.2",           vendor: "OpenAI",    price: "$1.75/$14.00", contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5.1",                   displayName: "GPT-5.1",           vendor: "OpenAI",    price: "$1.25/$10.00", contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5",                     displayName: "GPT-5",             vendor: "OpenAI",    price: "$1.25/$10.00", contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5-mini",                displayName: "GPT-5 Mini",        vendor: "OpenAI",    price: "$0.25/$2.00",  contextWindow: "400K"),
        KnownModel(id: "openai/gpt-5-nano",                displayName: "GPT-5 Nano",        vendor: "OpenAI",    price: "$0.05/$0.40",  contextWindow: "400K"),
        KnownModel(id: "openai/o4-mini",                   displayName: "o4 Mini",           vendor: "OpenAI",    price: "$1.10/$4.40",  contextWindow: "200K"),
        KnownModel(id: "openai/o3",                        displayName: "o3",                vendor: "OpenAI",    price: "$2.00/$8.00",  contextWindow: "200K"),
        KnownModel(id: "openai/o3-mini",                   displayName: "o3 Mini",           vendor: "OpenAI",    price: "$1.10/$4.40",  contextWindow: "200K"),
        KnownModel(id: "openai/gpt-4.1",                   displayName: "GPT-4.1",           vendor: "OpenAI",    price: "$2.00/$8.00",  contextWindow: "1M"),
        KnownModel(id: "openai/gpt-4.1-mini",              displayName: "GPT-4.1 Mini",      vendor: "OpenAI",    price: "$0.40/$1.60",  contextWindow: "1M"),
        KnownModel(id: "openai/gpt-4.1-nano",              displayName: "GPT-4.1 Nano",      vendor: "OpenAI",    price: "$0.10/$0.40",  contextWindow: "1M"),
    ]

    /// The `attested 3p` tier ids from the 2026-08-31 snapshot — third-party
    /// (Chutes) hosting with no confidential endpoint. Used by
    /// `NearAIModelCatalog.classify` so the offline heuristic doesn't misfile
    /// them as E2EE-capable (their lowercased ids collide with the own-fleet
    /// namespace, e.g. `qwen/…` vs `Qwen/…`, so an exact-id set is the only
    /// safe offline discriminator).
    static let nearAIAttestedThirdPartyIDs: Set<String> = [
        "deepseek/deepseek-v3.2", "moonshotai/kimi-k2.6",
        "moonshotai/kimi-k3", "qwen/qwen3-32b",
        "qwen/qwen3.5-397b-a17b",
    ]
    // ── END GENERATED · near.ai catalog ─────────────────────────────────────

    /// Attested-3p ids RETIRED from the live catalog. APPEND-ONLY, hand-kept:
    /// a user can still have one equipped, and the offline classifier must not
    /// misfile a Chutes model as E2EE-capable just because it left the fleet.
    /// When a regen drops an id from the generated set above, it moves here.
    static let nearAIRetiredAttestedThirdPartyIDs: Set<String> = [
        "minimax/minimax-m2.5", "moonshotai/kimi-k2.5", "z-ai/glm-5",
    ]

    // ── xAI / Grok ───────────────────────────────────────────────────────────
    //
    // NOT a snapshot: xAI publishes price, context window, modalities and
    // `created` on `GET /v1/(language-)models`, so the live catalogue is the
    // source of truth for everything about a Grok model EXCEPT what it should be
    // called. Ids read like build artifacts ("grok-4.20-0309-non-reasoning"), so
    // this is the id → product-name map, and nothing else. An id missing here
    // still lists — `XAIAdapter.displayName(forID:)` synthesizes a readable name.
    //
    // Verified read-only by the catalog generator: every id must still be a
    // live CANONICAL model (xAI retires ids by demoting them to aliases of a
    // newer model, which silently redirects), and live models missing from the
    // map are reported so a new Grok gets a proper name.

    static let grokDisplayNames: [String: String] = [
        "grok-4.5":                     "Grok 4.5",
        "grok-4.3":                     "Grok 4.3",
        "grok-4.20-0309-reasoning":     "Grok 4.20 Reasoning",
        "grok-4.20-0309-non-reasoning": "Grok 4.20",
        "grok-4.20-multi-agent-0309":   "Grok 4.20 Multi-Agent",
        "grok-build-0.1":               "Grok Build",
    ]

    // ── Fireworks.ai ─────────────────────────────────────────────────────────
    //
    // Price ONLY, because it is the one thing Fireworks does not serve over an
    // API. Verified 2026-07-26: no price/cost/rate field at any depth of the
    // control-plane model record (list or single), and /v1/pricing,
    // /v1/accounts/fireworks/pricing, /inference/v1/pricing,
    // /v1/billing/pricing, /v1/accounts/fireworks/serverlessPricing and
    // /openapi.json all 404. Their published rates live on the docs HTML page.
    //
    // Everything else now comes from the live control plane: existence,
    // displayName, contextLength, tools/vision, READY state, deprecation, and
    // `createTime` (which drives the "new" badge and ordering). A model missing
    // here still lists — it just shows no price.
    //
    // Rates are per 1M tokens, input/output, from docs.fireworks.ai/serverless/pricing
    // (2026-07-30 — every rate below re-read that day, and only K3 had changed:
    // the other twelve are unchanged from the 2026-07-18 pass). Verified read-only
    // by the catalog generator: every id must exist upstream, be serverless +
    // READY + not deprecated, and live serverless models with no price here are
    // reported.
    //
    // **THE PRICING PAGE IS NOT THE WHOLE CATALOGUE.** Found on device 2026-07-30:
    // `inkling` came back from the live control plane, rendered with a context
    // window and no price, and it is absent from that pricing table entirely — its
    // rate is published on its own model page (fireworks.ai/models/fireworks/…).
    // So a refresh has to walk the model pages for anything serverless that the
    // pricing table omits; reading the table alone is what left a row priceless.
    //
    // Cached-input tiers (inkling quotes $0.17) are deliberately not modelled: a
    // picker row quotes the rate a first request pays.
    //
    // NOT here: `accounts/fireworks/routers/kimi-k3-us`, the US-only K3 at +10%
    // (docs: "$3.30/$16.50"). It is a **router**, not a model — a different path
    // segment — so it never appears in the `/v1/accounts/fireworks/models` list
    // the adapter reads, and an entry for it could only ever be dead weight.

    static let fireworksPrices: [String: String] = [
        // Standard tier. K3 also sells a "Fast" variant at a premium, as do
        // K2.7 Code, K2.6 and both GLMs; the standard rate is what a picker row
        // should quote — same rule as Grok's base tier over its long-context one.
        "accounts/fireworks/models/kimi-k3":                "$3.00/$15.00",
        // 975B MoE (41B active) from Thinking Machines Lab, multimodal. Priced on
        // its model page only — see the note above about the pricing table.
        "accounts/fireworks/models/inkling":                "$1.00/$4.05",
        "accounts/fireworks/models/kimi-k2p7-code":         "$0.95/$4.00",
        "accounts/fireworks/models/kimi-k2p6":              "$0.95/$4.00",
        "accounts/fireworks/models/glm-5p2":                "$1.40/$4.40",
        "accounts/fireworks/models/glm-5p1":                "$1.40/$4.40",
        "accounts/fireworks/models/qwen3p7-plus":           "$0.40/$1.60",
        "accounts/fireworks/models/minimax-m3":             "$0.30/$1.20",
        "accounts/fireworks/models/nemotron-3-ultra-nvfp4": "$0.60/$2.40",
        "accounts/fireworks/models/gpt-oss-120b":           "$0.15/$0.60",
    ]

    // ── Lookup ───────────────────────────────────────────────────────────────

    /// Offline rows for a preset — the fallback when its live catalogue can't be
    /// reached, and the source of the pretty name in the providers list. near.ai
    /// ships a full snapshot (it also carries the E2EE hosts); xAI and Fireworks
    /// are synthesized from their minimal maps, since everything else about them
    /// is live-sourced.
    static func models(for providerID: UUID) -> [KnownModel] {
        switch providerID {
        case Provider.nearAI.id: return nearAIModels
        case Provider.grok.id:
            return grokDisplayNames
                .map { KnownModel(id: $0.key, displayName: $0.value, vendor: "xAI", price: "",
                                  // xAI's per-model doc page. The slug is the api
                                  // id verbatim — verified for every id in this
                                  // table; a bogus one 307s where a real one 200s.
                                  // Set here as well as in `XAIAdapter` so the
                                  // link is there before the live fetch lands,
                                  // and offline.
                                  modelPageURL: "https://docs.x.ai/developers/models/" + $0.key) }
                .sorted { $0.displayName > $1.displayName }   // newest name first, stable
        case Provider.fireworks.id:
            return fireworksPrices
                .map { KnownModel(id: $0.key,
                                  displayName: ModelCatalog.displayName(forID: $0.key),
                                  vendor: ModelCatalog.familyVendor(forID: ModelCatalog.slug($0.key)) ?? "Fireworks",
                                  price: $0.value) }
                .sorted { $0.id < $1.id }
        case Provider.braveAnswers.id:
            // ONE FIXED SERVICE, not a catalogue — but it still gets a row in
            // `ready now` once set up, and that row's long press should reach
            // something. The docs page is its equivalent of a model page.
            //
            // No `price`: Brave bills per REQUEST plus per token ($4/1,000
            // requests + $5/1M), a shape `price` cannot express, and half of it
            // rendered as a per-1M rate would be wrong. It goes in the summary,
            // in words, where it can say what it actually is.
            return [KnownModel(
                id: Provider.braveAnswers.model,
                displayName: "Brave Answers",
                vendor: "Brave",
                price: "",
                summary: "Single answers grounded in live web search, with citations. "
                    + "Billed per request plus per token — $4 per 1,000 requests and "
                    + "$5 per 1M input/output tokens — so it does not price like a model.",
                features: ["grounding", "citations"],
                modelPageURL: "https://api-dashboard.search.brave.com/documentation/services/answers")]
        default: return []
        }
    }
}
