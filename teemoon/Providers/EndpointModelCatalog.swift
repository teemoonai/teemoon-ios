//
//  EndpointModelCatalog.swift
//  teemoon
//
//  Probes an arbitrary OpenAI-compatible endpoint. `GET {baseURL}/models`
//  doubles as the connection test AND the model-list fetch for the verify-first
//  add-provider flow. This is the provider-agnostic generalization of
//  `NearAIModelCatalog.fetchLive` — no near.ai coupling (no tier recording, no
//  curated merge, no EndpointDirectory). Cloud confidentiality tiers stay in
//  NearAIModelCatalog; this just lists whatever models an endpoint reports.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "endpoint-catalog")

enum EndpointModelCatalog {

    /// Specific, user-facing failure reasons the add-provider UI renders as one
    /// inline line. Mirrors the status→result mapping in `ProviderKeyValidator`,
    /// plus the transport cases that matter for local/self-hosted endpoints.
    /// `Error`-conforming so adapters can carry it in a `Result` while they
    /// assemble a list from more than one call.
    enum FailureKind: Equatable, Error {
        case nothingListening   // connection refused / no host — server down, wrong host or port
        case noModelsEndpoint   // reachable but /models 404s — wrong path (missing /v1?)
        case httpBlocked        // iOS ATS blocked cleartext http:// to a non-loopback host
        case unauthorized       // 401 / 403 — key wrong or missing
        /// 403 when no key was even sent — the server refused the REQUEST, not a
        /// credential. The case that motivated it: Ollama behind `tailscale
        /// serve` 403s every proxied call, because the proxy forwards the
        /// original `Host` and Ollama only trusts local hostnames. Reported as
        /// "key rejected" that sends you looking for a key Ollama doesn't have.
        ///
        /// The fix we surface is to **rewrite `Host` in the proxy** (a two-line
        /// Caddy `header_up`), which leaves Ollama bound to loopback. Setting
        /// `OLLAMA_HOST=0.0.0.0` also clears the 403 and is one command, which
        /// is why it was the original advice — but it binds every interface and
        /// Ollama has no authentication whatsoever, so it publishes the user's
        /// model server to their whole LAN to fix a header. Wrong trade to put
        /// in an error message.
        ///
        /// NOT `OLLAMA_ORIGINS`, which is CORS and was measured to make no
        /// difference here. Both verified live.
        case forbidden
        case paymentRequired    // 402 — no credits
        case rateLimited        // 429
        case badResponse        // 200 but unparseable / empty model list
        case offline            // any other transport error
    }

    enum ProbeResult: Equatable {
        case connected([KnownModel])
        case failed(FailureKind)
    }

    // MARK: - Failure mapping (shared by every adapter)

    /// HTTP status → failure, or nil when the status is a success. Every adapter
    /// maps statuses here so "key rejected" / "no credits" read identically no
    /// matter which endpoint answered.
    ///
    /// `body` matters because not every provider uses 401 for a bad key: xAI
    /// answers **HTTP 400** with `{"code":"invalid-argument","error":"Incorrect
    /// API key provided…"}` (verified 2026-07-26). Classified on status alone
    /// that reads as `.offline` → "couldn't reach that endpoint", sending the
    /// user to check their network when the key is what's wrong.
    ///
    /// `sentKey` separates "your key was refused" from "the server refused the
    /// request". A 403 answering a call that carried NO key cannot be about the
    /// key, and saying so sends the user hunting for a credential that may not
    /// exist — the Ollama-behind-`tailscale serve` case (see `.forbidden`).
    static func failureKind(forStatus status: Int, body: Data? = nil,
                            sentKey: Bool = true) -> FailureKind? {
        switch status {
        case 200..<300: return nil
        case 403 where !sentKey: return .forbidden
        case 401, 403:  return .unauthorized
        case 402:       return .paymentRequired
        case 404:       return .noModelsEndpoint
        case 429:       return .rateLimited
        case 400..<500 where saysKeyIsBad(body): return .unauthorized
        default:        return .offline
        }
    }

    /// Whether an error body blames the API key. Deliberately narrow: it must
    /// mention a key or authentication, so a validation error about some other
    /// field isn't mistaken for a credential problem.
    private static func saysKeyIsBad(_ body: Data?) -> Bool {
        guard let body, body.count < 8_192,
              let text = String(data: body, encoding: .utf8)?.lowercased() else { return false }
        let mentionsKey = text.contains("api key") || text.contains("api_key")
            || text.contains("apikey") || text.contains("authentication")
            || text.contains("unauthorized")
        let soundsWrong = text.contains("incorrect") || text.contains("invalid")
            || text.contains("missing") || text.contains("provided")
            || text.contains("expired") || text.contains("unauthorized")
        return mentionsKey && soundsWrong
    }

    /// Transport error → failure. Distinguishes "nothing is listening there"
    /// from an ATS block, which need different fixes from the user.
    static func failureKind(forTransport error: Error) -> FailureKind {
        guard let err = error as? URLError else { return .offline }
        switch err.code {
        case .appTransportSecurityRequiresSecureConnection:
            return .httpBlocked
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .timedOut:
            return .nothingListening
        default:
            return .offline
        }
    }

    /// A self-hosted server's native API lives at the host ROOT, a sibling of the
    /// OpenAI-compat `/v1` (Ollama's `/api/*`, LM Studio's `/api/v0/*`), so the
    /// configured base URL's path has to come off first.
    static func rootURL(from base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = ""
        comps?.query = nil
        comps?.fragment = nil
        return comps?.url ?? base
    }

    // MARK: - Catalogue source

    // (see `LocalServerKind` below for the self-hosted counterpart)

    /// Which catalogue serves an endpoint. Cloud providers publish richer
    /// catalogues than the OpenAI-compat `/models` list (price, context window,
    /// capabilities, tiers), and routing to them is what keeps the model picker
    /// from rendering bare ids. Ollama is NOT here — it's detected with a live
    /// probe (`/api/version`), not by host.
    enum Source: Equatable {
        case nearAI
        case xAI
        case fireworks
        /// Plain `GET {base}/models` — a self-hosted server or an unknown cloud.
        case generic

        static func resolve(host: String?) -> Source {
            guard let host = host?.lowercased() else { return .generic }
            if host == "near.ai" || host.hasSuffix(".near.ai") { return .nearAI }
            if XAIAdapter.handles(host: host) { return .xAI }
            if FireworksAdapter.handles(host: host) { return .fireworks }
            return .generic
        }
    }

    /// `GET {baseURL}/models` with optional auth. `authHeaderName` mirrors
    /// `Provider.authHeaderName` (nil → `Authorization: Bearer <key>`, set → used
    /// as-is). Auth is sent only when the key is non-empty, so keyless local
    /// servers work. Returns the parsed model list, or a specific failure.
    static func probe(
        baseURL: URL,
        authHeaderName: String? = nil,
        apiKey: String = "",
        session: URLSession = .shared
    ) async -> ProbeResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 12
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            if let headerName = authHeaderName {
                request.setValue(key, forHTTPHeaderField: headerName)
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let kind = failureKind(forTransport: error)
            if kind == .offline {
                logger.warning("[probe] transport error for \(baseURL.absoluteString): \(error.localizedDescription)")
            }
            return .failed(kind)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `key.isEmpty` is the honest signal: auth is only attached above when a
        // key exists, so a 403 here answered a request that carried none.
        if let kind = failureKind(forStatus: status, body: data, sentKey: !key.isEmpty) {
            logger.warning("[probe] HTTP \(status) for \(baseURL.absoluteString)")
            return .failed(kind)
        }

        guard let list = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data),
              !list.data.isEmpty else {
            return .failed(.badResponse)
        }

        var seen = Set<String>()
        let models: [KnownModel] = list.data.compactMap { m in
            guard !ModelCatalog.isNonChat(m.id),
                  seen.insert(m.id.lowercased()).inserted else { return nil }
            return KnownModel(
                id: m.id,
                displayName: ModelCatalog.displayName(forID: m.id),
                // A self-hosted id is usually `{uploader}/{repo}:{quant}`
                // (`bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M`), so the namespace
                // names whoever published the GGUF, not the model's vendor —
                // grouping by it filed Qwen under "Bartowski". Family first here,
                // namespace only as the fallback.
                vendor: ModelCatalog.familyVendor(forID: ModelCatalog.slug(m.id))
                        ?? ModelCatalog.vendorLabel(forID: m.id),
                price: "",
                contextWindow: m.contextLabel
            )
        }
        logger.info("[probe] \(models.count) chat model(s) at \(baseURL.absoluteString)")
        return models.isEmpty ? .failed(.badResponse) : .connected(models)
    }
}

// MARK: - Wire contract
//
// `GET {base}/models` — the OpenAI "list models" response
// (https://platform.openai.com/docs/api-reference/models), plus the extensions
// self-hosted servers add. Every field below was observed on a live server;
// they are nil on servers that don't send them.

struct OpenAIModelsResponse: Decodable {
    let object: String?
    let data: [Model]

    struct Model: Decodable {
        /// The id you send as `model` in a chat request.
        let id: String
        let object: String?
        let created: Int?
        /// "llamacpp" · "library" (Ollama) · "organization_owner" (LM Studio) —
        /// too generic to identify the server, which is why kind comes from a
        /// detection probe instead.
        let owned_by: String?

        // ── llama.cpp (llama-server / router) ────────────────────────────────
        let aliases: [String]?
        let tags: [String]?
        /// "loaded" | "unloaded" — the router keeps models cold until first use,
        /// so this is the same "warm" signal Ollama's `/api/ps` gives. Not yet
        /// surfaced: `KnownModel` has nowhere to carry it (follow-up).
        let status: Status?
        /// Modalities the loaded model accepts, e.g. `["text","image","audio"]`
        /// for gemma-4. Deliberately NOT mapped into `ModelCapabilities`: that
        /// type expresses "known" as a whole set, so recording vision here would
        /// also assert "known: no tools" and make teemoon withhold tools from a
        /// llama.cpp model that supports them (nil = unknown = optimistic).
        let architecture: Architecture?
        /// "preset" | "user" — where the router got this entry.
        let source: String?
        let can_remove: Bool?
        /// Older llama-server builds report the loaded model's GGUF metadata here.
        let meta: Meta?

        struct Status: Decodable {
            let value: String?
            /// The server's launch argv for this model (contains `--ctx-size`,
            /// the GGUF path, …). Informational — too brittle to parse.
            let args: [String]?
        }
        struct Architecture: Decodable {
            let input_modalities: [String]?
            let output_modalities: [String]?
        }
        struct Meta: Decodable {
            let n_ctx_train: Int?     // native context window
            let n_ctx: Int?           // context the server actually allocated
            let n_params: Int64?
            let n_embd: Int?
            let n_vocab: Int?
            let size: Int64?
            let ftype: String?        // quantization, e.g. "Q4_K_M"
        }

        /// "32k · Q4_K_M" from `meta` when the server sends it, else empty —
        /// the row then shows nothing rather than a guess.
        var contextLabel: String {
            let ctx = ModelCatalog.contextLabel(meta?.n_ctx ?? meta?.n_ctx_train)
            return [ctx, meta?.ftype].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }
}

// MARK: - Local server kind

/// Which self-hosted server is behind an endpoint. The cloud counterpart
/// (`EndpointModelCatalog.Source`) resolves by host, but a local server is just
/// an address — the kind has to be PROBED, and only its native surface answers.
///
/// `owned_by` in `/v1/models` is not that signal: llama.cpp says "llamacpp", but
/// Ollama says "library" and LM Studio "organization_owner".
enum LocalServerKind: Equatable {
    case ollama
    case lmStudio
    /// llama.cpp, vLLM, or anything else OpenAI-compatible → the generic probe.
    case unknown

    /// The persisted equivalent, for `ConfigStore.recordProbe`.
    ///
    /// `.unknown` maps to NIL rather than to `.openAICompatible`: this enum's
    /// unknown means "detection didn't tell us", and writing that as a definite
    /// kind would erase an `.ollama` an earlier probe established — which costs
    /// the machine its `/api/pull` affordance (§2.4's dead end). A kind we can't
    /// determine must leave the stored one alone.
    var stored: ServerKind? {
        switch self {
        case .ollama:   return .ollama
        case .lmStudio: return .lmStudio
        case .unknown:  return nil
        }
    }

    /// One cheap request per candidate, run concurrently: the whole detection
    /// costs one round-trip, not one per kind.
    static func detect(baseURL: URL, session: URLSession = .shared) async -> LocalServerKind {
        async let ollama = OllamaAdapter.isOllama(baseURL: baseURL, session: session)
        async let lmStudio = LMStudioAdapter.isLMStudio(baseURL: baseURL, session: session)
        if await ollama { return .ollama }
        if await lmStudio { return .lmStudio }
        return .unknown
    }

    /// What to call the server in the UI. `unknown` is nil: llama.cpp, vLLM and
    /// anything else OpenAI-compatible land here indistinguishably.
    var displayName: String? {
        switch self {
        case .ollama:   return "ollama"
        case .lmStudio: return "lm studio"
        case .unknown:  return nil
        }
    }
}
