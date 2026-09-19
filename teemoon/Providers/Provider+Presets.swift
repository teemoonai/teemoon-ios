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
        model:                "z-ai/glm-5.3-flash",   // the E2EE flagship near.ai still serves (5.2 retired 2026-09-12)
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
        model:                "grok-4.6",   // the fallback before a key exists; live picks newest-first
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

    static let openRouter = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!,
        name:                 "OpenRouter",
        endpoint:             "https://openrouter.ai/api/v1/chat/completions",
        model:                "moonshotai/kimi-k3",   // open weights first: the fallback before a key exists
        supportsModelBrowsing: true,
        presetDescription:    "one key for every vendor's models — claude, gpt, gemini, deepseek and hundreds more, each with its price and context window.",
        signupURL:            "https://openrouter.ai/settings/keys"
    )

    static let nvidia = Provider(
        id:                   UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!,
        name:                 "NVIDIA",
        endpoint:             "https://integrate.api.nvidia.com/v1/chat/completions",
        model:                "nvidia/nemotron-3-super-120b-a12b",
        supportsModelBrowsing: true,
        // "free" is a fact about the tier, not a promise: the hosted catalogue
        // is free for development under the NVIDIA Developer Program and
        // rate-limited per model. There is no per-token price to show.
        presetDescription:    "nvidia's hosted catalog — nemotron, kimi, deepseek, gemma and more. free, rate limited to 40 requests per minute.",
        signupURL:            "https://build.nvidia.com/settings/api-keys"
    )

    /// Order here controls the button order in the quick-start row.
    static let presets: [Provider] = [.nearAI, .grok, .fireworks, .openRouter, .nvidia, .braveAnswers]

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
        Provider.grok.id:         .first,                 // closed weights; the list is newest-first
        // Open-weight hosts: the strongest published model wins, by price
        // tier, then parameter count, then recency — no shortlist to keep.
        Provider.fireworks.id:    .strongestOpenWeight,
        Provider.openRouter.id:   .strongestOpenWeight,
        Provider.nvidia.id:       .strongestOpenWeight,
        Provider.braveAnswers.id: .fixed("brave"),        // no /models endpoint
    ]

    /// The default-model rule for this provider, if it's a known preset.
    /// Falls through `matchingPreset`: `save()` mints a fresh UUID, so a saved
    /// setup no longer carries the preset's id.
    var defaultModelRule: ModelDefaultRule? {
        Provider.defaultModelRules[id] ?? matchingPreset.flatMap { Provider.defaultModelRules[$0.id] }
    }

    /// The preset this provider's endpoint matches, if any. `sameEndpoint`, not
    /// a raw `==`: the saved spelling may carry `/chat/completions` or a trailing
    /// slash, and matching literally made a keyed setup read as unconfigured.
    var matchingPreset: Provider? {
        Provider.presets.first { $0.sameEndpoint(as: self) }
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
        switch matchingPreset?.id ?? id {
        case Provider.braveAnswers.id: return .braveSearch
        case Provider.openRouter.id:   return .openRouter   // /models is 200 for any key
        default:                       return nil
        }
    }

    /// Base URL for inference. For near.ai providers, returns the model's direct
    /// completions URL when available, bypassing the gateway TEE. Falls back to
    /// the provider's configured endpoint for all other cases.
    var inferenceBaseURL: URL? {
        if capabilities.contains(.attestation),
           let direct = EndpointDirectory.persistedBase(forModel: model) {
            return direct
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

    /// near.ai's `attested 3p` ids — third-party (Chutes) hosting, attested but
    /// with NO confidential endpoint, so no E2EE path via near.ai. APPEND-ONLY,
    /// and never pruned: a user can still have a retired one equipped, and the
    /// offline classifier must not promote it to E2EE-capable. Live tiers from
    /// `/v1/models` override this the moment they arrive.
    static let nearAIAttestedThirdPartyIDs: Set<String> = [
        "deepseek/deepseek-v3.2", "minimax/minimax-m2.5", "moonshotai/kimi-k2.5",
        "moonshotai/kimi-k2.6", "moonshotai/kimi-k3", "qwen/qwen3-32b",
        "qwen/qwen3.5-397b-a17b", "z-ai/glm-5",
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
    // Rates are per 1M tokens, uncached input/output, Standard tier (never Fast,
    // Priority, or a US-only premium), from docs.fireworks.ai/serverless/pricing,
    // last re-read 2026-09-10. The catalog generator verifies every id upstream
    // (serverless, READY, not deprecated) and reports live models with no price.
    //
    // The pricing page is not the whole catalogue: some models are priced only
    // on their own model page, so a refresh walks the page of every live
    // serverless model the table omits.
    //
    // Dated snapshots are keyed by their FULL id (`deepseek-v4-flash-0731`);
    // do not tidy them to the undated family name — the row goes blank.
    //
    // Deliberately absent: `qwen3p8-2p4t-a95b` — same weights as `qwen3p8-max`
    // (both HF Qwen/Qwen3.8-2.4T-A95B) but its model page is login-gated and it
    // is not in the pricing table, so its rate is unpublished. A blank row is
    // the honest state; do not borrow Max's number.
    //
    // Cached-input tiers are deliberately not modelled: a picker row quotes the
    // rate a first request pays.
    //
    // NOT here: `accounts/fireworks/routers/kimi-k3-us`, the US-only K3 at +10%
    // (docs: "$3.30/$16.50"). It is a **router**, not a model — a different path
    // segment — so it never appears in the `/v1/accounts/fireworks/models` list
    // the adapter reads, and an entry for it could only ever be dead weight.

    static let fireworksPrices: [String: String] = [
        "accounts/fireworks/models/kimi-k3":                       "$3.00/$15.00",
        "accounts/fireworks/models/kimi-k2p7-code":                "$0.95/$4.00",
        "accounts/fireworks/models/kimi-k2p6":                     "$0.95/$4.00",
        // 975B MoE (41B active) from Thinking Machines Lab, multimodal.
        "accounts/fireworks/models/inkling":                       "$1.00/$4.05",
        "accounts/fireworks/models/deepseek-v4p1-flash":           "$0.22/$0.66",
        "accounts/fireworks/models/deepseek-v4-flash-0731":        "$0.22/$0.66",
        "accounts/fireworks/models/deepseek-v4-flash-vision-exp":  "$0.22/$0.66",
        "accounts/fireworks/models/deepseek-v4-pro-0813":          "$1.32/$3.96",
        "accounts/fireworks/models/glm-5p3":                       "$1.40/$4.40",
        "accounts/fireworks/models/glm-5p3-flash":                 "$0.15/$0.50",
        "accounts/fireworks/models/glm-5p2":                       "$1.40/$4.40",
        "accounts/fireworks/models/qwen3p8-max":                   "$2.00/$6.00",
        "accounts/fireworks/models/muse-glimmer-30b":              "$0.35/$1.50",
        "accounts/fireworks/models/minimax-m3":                    "$0.30/$1.20",
        "accounts/fireworks/models/nemotron-lightning-3p5-30b-a3b": "$0.05/$0.20",
        "accounts/fireworks/models/nemotron-3-ultra-nvfp4":        "$0.60/$2.40",
        "accounts/fireworks/models/gpt-oss-120b":                  "$0.15/$0.60",
    ]

    // ── The one fixed service ────────────────────────────────────────────────

    /// Brave Answers is a service, not a catalogue: one id, no `/models`. It
    /// still gets a `ready now` row whose long press must reach something, so
    /// the row lives here rather than in a model list.
    ///
    /// No `price`: Brave bills per REQUEST plus per token ($4/1,000 requests +
    /// $5/1M), a shape `price` cannot express, and half of it rendered as a
    /// per-1M rate would be wrong. It goes in the summary, in words.
    static let braveAnswersModel = KnownModel(
        id: Provider.braveAnswers.model,
        displayName: "Brave Answers",
        vendor: "Brave",
        price: "",
        summary: "Single answers grounded in live web search, with citations. "
            + "Billed per request plus per token — $4 per 1,000 requests and "
            + "$5 per 1M input/output tokens — so it does not price like a model.",
        features: ["grounding", "citations"],
        modelPageURL: "https://api-dashboard.search.brave.com/documentation/services/answers")

}
