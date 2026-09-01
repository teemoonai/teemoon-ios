//
//  OllamaAdapter.swift
//  teemoon
//
//  Ollama-specific behavior, contained in one file.
//  Ollama speaks OpenAI-compat at `{host}/v1/*`, but its native surface —
//  model list *with capabilities*, and server-side model pull — lives at the
//  host ROOT under `/api/*` (siblings of `/v1`). This adapter owns those calls
//  and their documented wire contracts.
//
//  Why native, not the generic /v1/models probe:
//   • /v1/models returns bare ids (no capability metadata), so tools/vision can't
//     be modeled. /api/show carries `capabilities`, which is how teemoon gates a
//     web_search tool away from a non-tool model *before* the request (no 400).
//   • /api/pull enables pulling a model to the server from the phone (no SSH),
//     including any HuggingFace GGUF repo via an `hf.co/{user}/{repo}` reference.
//
//  Wire contract — https://github.com/ollama/ollama/blob/main/docs/api.md
//  HF GGUF pull    — https://huggingface.co/docs/hub/en/ollama
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "ollama-adapter")

enum OllamaAdapter {

    // MARK: Root derivation

    /// Ollama's `/api/*` live at the host root, not under `/v1` — the same
    /// derivation every self-hosted adapter needs (see `EndpointModelCatalog`).
    static func rootURL(from base: URL) -> URL { EndpointModelCatalog.rootURL(from: base) }

    // MARK: Detection

    /// Cheap probe: is this endpoint an Ollama server? `GET {root}/api/version`
    /// returns `{"version":"…"}`. Swallows all errors → false.
    static func isOllama(baseURL: URL, session: URLSession = .shared) async -> Bool {
        var req = URLRequest(url: rootURL(from: baseURL).appendingPathComponent("api/version"))
        req.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONDecoder().decode(OllamaVersionResponse.self, from: data) else {
            return false
        }
        logger.info("[detect] ollama \(v.version) at \(rootURL(from: baseURL).absoluteString)")
        return true
    }

    // MARK: List models (+ capabilities)

    /// Native model list that doubles as the connection test — returns the same
    /// `ProbeResult` as the generic probe so the add-provider flow handles both
    /// identically. Lists installed models via `/api/tags`, then fills each one's
    /// `capabilities` via `/api/show` (in parallel). A model whose `/api/show`
    /// fails is still listed, with `capabilities == nil` (unknown, not dropped).
    static func listModels(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> EndpointModelCatalog.ProbeResult {
        let root = rootURL(from: baseURL)
        var req = URLRequest(url: root.appendingPathComponent("api/tags"))
        req.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError {
            switch err.code {
            case .appTransportSecurityRequiresSecureConnection: return .failed(.httpBlocked)
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .timedOut:                return .failed(.nothingListening)
            default:                                               return .failed(.offline)
            }
        } catch {
            return .failed(.offline)
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
            return .failed(.badResponse)
        }
        // AN EMPTY OLLAMA IS CONNECTED, NOT BROKEN. It answered /api/tags with a
        // valid, empty list — the server is healthy and has nothing installed
        // yet, which is the normal state of a fresh install.
        //
        // Reporting `.badResponse` made the add-provider screen show a failure
        // and, worse, hid "download a model": that button only renders in the
        // `.connected` branch, so the one action that fixes an empty server was
        // unreachable exactly when it was the only useful thing to do.
        //
        // Emptiness is the CALLER's business — the picker shows it, the download
        // button offers the remedy. A transport that cannot tell "no models"
        // from "no server" forces every caller to guess.
        if tags.models.isEmpty { return .connected([]) }

        // Fetch capabilities + metadata for every model concurrently.
        let names = tags.models.map(\.name)
        let metaByName: [String: OllamaModelMeta] = await withTaskGroup(
            of: (String, OllamaModelMeta).self
        ) { group in
            for name in names {
                group.addTask { (name, await showMeta(model: name, root: root, session: session)) }
            }
            var out: [String: OllamaModelMeta] = [:]
            for await (name, meta) in group { out[name] = meta }
            return out
        }

        let models: [KnownModel] = tags.models.map { m in
            let meta = metaByName[m.name]
            return KnownModel(
                id: m.name,
                displayName: m.name,   // Ollama names are already user-facing (e.g. "qwen3.5:4b")
                // Ollama's `details.family` is the GGUF architecture string
                // ("qwen35", "gemma4"), which reads as a section header like
                // "qwen35". Prefer the model family's real vendor, and keep the
                // architecture only when nothing recognizes the name.
                vendor: ModelCatalog.familyVendor(forID: m.name)
                        ?? m.details.family
                        ?? ModelCatalog.vendorLabel(forID: m.name),
                price: "",
                contextWindow: meta?.contextWindow ?? "",   // real context + quant, e.g. "256k · Q4_K_M"
                capabilities: meta?.caps,                    // nil when /api/show failed → "unknown"
                // A HOME MODEL'S FACTS, which /api/show already returned and the
                // list row could only render as one joined string.
                huggingFaceURL: huggingFaceURL(forOllamaName: m.name),
                modelPageURL: libraryURL(forOllamaName: m.name),
                quantization: meta?.quantization,
                parameterSize: m.details.parameter_size)
        }
        logger.info("[list] \(models.count) ollama model(s)")
        return .connected(models)
    }

    /// Per-model metadata from `/api/show`: capabilities + a display string
    /// ("256k · Q4_K_M") built from the real context length (`model_info`'s
    /// `*.context_length`) and quantization. nil caps = the call failed (unknown).
    struct OllamaModelMeta {
        let caps: ModelCapabilities?
        let contextWindow: String
        /// Kept SEPARATELY as well as inside `contextWindow`, because a row wants
        /// one string and a detail page wants the facts apart.
        var quantization: String? = nil
    }

    /// `POST {root}/api/show {model}`. Uses JSONSerialization because `model_info`
    /// has dynamic, family-prefixed keys (`qwen35.context_length`, …).
    private static func showMeta(
        model: String, root: URL, session: URLSession
    ) async -> OllamaModelMeta {
        var req = URLRequest(url: root.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(OllamaShowRequest(model: model))
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OllamaModelMeta(caps: nil, contextWindow: "")   // unknown
        }
        let caps = ModelCapabilities.fromOllama(obj["capabilities"] as? [String] ?? [])
        let quant = (obj["details"] as? [String: Any])?["quantization_level"] as? String
        var ctxLen: Int64?
        if let mi = obj["model_info"] as? [String: Any],
           let (_, v) = mi.first(where: { $0.key.hasSuffix(".context_length") }) {
            ctxLen = (v as? NSNumber)?.int64Value
        }
        // Same "128k · Q4_K_M" shape LM Studio rows use — one format for every
        // local server (see ModelCatalog.localContextLabel).
        let parts = [ModelCatalog.localContextLabel(ctxLen.map(Int.init)), quant]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return OllamaModelMeta(caps: caps, contextWindow: parts.joined(separator: " · "),
                               quantization: quant)
    }

    /// The model's page in Ollama's own library — `gemma4:e2b` →
    /// `ollama.com/library/gemma4`.
    ///
    /// Verified against the live site, including that a name it does not know
    /// 404s: without that check a derived URL is just a guess that returns 200
    /// on a catch-all, which is how a set of grok doc links nearly shipped
    /// pointing at a not-found page.
    ///
    /// nil for a namespaced pull (`user/model`, `hf.co/...`) — those are not in
    /// the library and the URL would be wrong.
    static func libraryURL(forOllamaName name: String) -> String? {
        let base = name.split(separator: ":").first.map(String.init) ?? name
        guard !base.isEmpty, !base.contains("/") else { return nil }
        return "https://ollama.com/library/" + base
    }

    /// The Hugging Face repo, but ONLY when the name already says so.
    ///
    /// Ollama names are registry names, not repo paths: `gemma4:e2b` is not
    /// `google/gemma4`, and mapping one to the other would be invention — the
    /// quantised GGUF a home box runs is usually somebody's conversion, not the
    /// vendor's own repo. A model PULLED from Hugging Face carries the path in
    /// its name (`hf.co/user/repo:Q4_K_M`), and that one is a fact rather than
    /// a guess.
    static func huggingFaceURL(forOllamaName name: String) -> String? {
        let base = name.split(separator: ":").first.map(String.init) ?? name
        let lower = base.lowercased()
        for prefix in ["hf.co/", "huggingface.co/"] where lower.hasPrefix(prefix) {
            let path = String(base.dropFirst(prefix.count))
            return path.contains("/") ? "https://huggingface.co/" + path : nil
        }
        return nil
    }

    // MARK: Loaded / warm state

    /// `GET {root}/api/ps` — names of models currently loaded in memory (warm).
    /// A cold model incurs a load delay on first token; a warm one doesn't.
    static func loadedModels(baseURL: URL, session: URLSession = .shared) async -> Set<String> {
        var req = URLRequest(url: rootURL(from: baseURL).appendingPathComponent("api/ps"))
        req.timeoutInterval = 6
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return []
        }
        return Set(models.compactMap { $0["name"] as? String })
    }

    /// Loads a model into the server's memory *before* the user sends anything.
    ///
    /// Ollama unloads an idle model after `OLLAMA_KEEP_ALIVE` (5m by default) and
    /// bringing it back is not cheap. Measured on an M-series 16 GB box with
    /// gemma4:latest (8B Q4): **14.3s cold, 10.8s with the weights still in the
    /// page cache, 0.6s once resident.** Only ~3.5s of that is disk — the rest is
    /// GPU allocation and dequantization, paid on every load, so no amount of
    /// caching makes waking cheap. It can only be *hidden*, which is what this
    /// does: fire it when a model is CHOSEN and the load runs while the user is
    /// still typing.
    ///
    /// `POST {root}/api/generate` with a model and no prompt is Ollama's
    /// documented preload idiom — it returns `done_reason: "load"` without
    /// generating a token. It returns as soon as the load is ACCEPTED (~0.3s
    /// measured), not when the model is resident; Ollama finishes loading in the
    /// background. That is exactly the shape wanted here — the caller must not
    /// block — but it means a 200 back is not proof the model is warm yet.
    /// Measured: preload, wait 15s, then a real request answers in 3.7s instead
    /// of the 14s it costs from cold.
    ///
    /// **Sends no `options`, deliberately.** Ollama keys a loaded runner by model
    /// *plus* options, so a warm-up carrying e.g. `num_ctx` that disagrees with
    /// the server's own default causes the next real request to evict this runner
    /// and reload — paying the load twice instead of zero times. Measured: a
    /// matched warm-up leaves the following request at 0.9s; a mismatched one
    /// reloaded from scratch. Server-side settings belong in the server's
    /// environment (`OLLAMA_CONTEXT_LENGTH`), never in a per-request override.
    ///
    /// Fire and forget. A warm-up is an optimization, never a precondition, so
    /// every failure is logged and swallowed — including the 404 a non-Ollama
    /// self-hosted server (llama.cpp) returns for `/api/generate`.
    static func warmUp(baseURL: URL, model: String, session: URLSession = .shared) async {
        var req = URLRequest(url: rootURL(from: baseURL).appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous despite the call returning fast: a server already busy loading
        // another model can sit on this. It runs detached, so waiting costs the
        // user nothing.
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (_, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            logger.debug("[warmup] '\(model)' did not warm (not Ollama, or unreachable) — ignoring")
            return
        }
        logger.info("[warmup] '\(model)' load accepted — finishing in the background")
    }

    /// Warms `provider`'s model if it is a self-hosted endpoint worth warming.
    ///
    /// Gated on `isSelfHosted` so a cloud provider never receives a stray
    /// `/api/generate`, and on `!isLocal` because an on-device model is loaded by
    /// teemoon itself, not by a server.
    static func warmUp(for provider: Provider?) {
        guard let provider, provider.isSelfHosted, !provider.isLocal,
              let baseURL = provider.openAIBaseURL else { return }
        let model = provider.model
        Task.detached(priority: .utility) {
            await warmUp(baseURL: baseURL, model: model)
        }
    }

    // MARK: Pull (server-side download)

    /// `POST {root}/api/pull` — streams NDJSON progress, one `OllamaPullProgress`
    /// per line, terminating with `status == "success"`. `ref` may be an Ollama
    /// library name (`qwen3.5`) or a HuggingFace GGUF reference
    /// (`hf.co/{user}/{repo}[:{quant}]`); normalize a pasted value with
    /// `normalizePullRef` first. The pull happens on the SERVER, not the phone.
    static func pullModel(
        _ ref: String,
        baseURL: URL,
        session: URLSession = .shared
    ) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let root = rootURL(from: baseURL)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var req = URLRequest(url: root.appendingPathComponent("api/pull"))
                req.httpMethod = "POST"
                // Idle (between-bytes) timeout. Must be generous: after the blob
                // downloads, Ollama runs "verifying sha256 digest" which streams NO
                // data while it hashes multi-GB blobs — a short timeout there makes
                // the stream drop right before "success" and loop forever.
                req.timeoutInterval = 600
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: ref))
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if http.statusCode >= 400 {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        let msg = String(decoding: body, as: UTF8.self)
                        throw OllamaPullError(status: http.statusCode, message: msg)
                    }
                    // NDJSON: assemble lines on \n (strip trailing \r), decode each.
                    var line = [UInt8]()
                    func flush() {
                        if line.last == 0x0D { line.removeLast() }
                        defer { line.removeAll(keepingCapacity: true) }
                        guard !line.isEmpty,
                              let p = try? JSONDecoder().decode(
                                OllamaPullProgress.self, from: Data(line)) else { return }
                        // Ollama reports errors in-band as {"error":"…"} too.
                        if let err = p.error {
                            continuation.finish(throwing: OllamaPullError(status: 200, message: err))
                            return
                        }
                        continuation.yield(p)
                    }
                    for try await b in bytes {
                        if Task.isCancelled { break }
                        if b == 0x0A { flush() } else { line.append(b) }
                    }
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `DELETE {root}/api/delete {model}` — removes the model manifest and any
    /// unreferenced blob layers, freeing disk ON THE SERVER. Throws on non-2xx
    /// (404 = not installed). Destructive + irreversible — call only on explicit
    /// user action (a confirmed swipe), never automatically.
    static func deleteModel(
        _ id: String, baseURL: URL, session: URLSession = .shared
    ) async throws {
        var req = URLRequest(url: rootURL(from: baseURL).appendingPathComponent("api/delete"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(OllamaDeleteRequest(model: id))
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OllamaPullError(status: status, message: String(decoding: data, as: UTF8.self))
        }
    }

    /// Normalize a user-pasted model reference into what `/api/pull` accepts.
    /// Handles: a full `ollama run/pull …` command, a HuggingFace browser URL
    /// (`https://huggingface.co/{user}/{repo}/tree/main` → `hf.co/{user}/{repo}`),
    /// an `hf.co/…:{quant}` snippet (tag preserved), or a bare library name.
    /// The installed model this ref would pull, or nil when the server hasn't got it.
    ///
    /// Ollama's ids carry a tag and a bare name means `:latest` — `gemma4` and
    /// `gemma4:latest` are the same model, and `/api/tags` reports the second form. A
    /// plain string compare therefore misses the most common way to name a model, so
    /// both sides get the implicit tag before they meet.
    ///
    /// Deliberately returns the INSTALLED id rather than a Bool: it is the server's
    /// own spelling, which is what a message should quote back.
    static func installedMatch(_ ref: String, in installed: [String]) -> String? {
        func tagged(_ s: String) -> String {
            let name = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { return name }
            // A digest pin (`model@sha256:…`) names one exact blob; leave it whole.
            if name.contains("@") { return name }
            // The tag is after the LAST colon, and only when it follows the final path
            // component — `registry:5000/team/model` is a port, not a tag.
            let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
            return lastComponent.contains(":") ? name : name + ":latest"
        }
        let target = tagged(normalizePullRef(ref))
        guard !target.isEmpty else { return nil }
        return installed.first { tagged($0) == target }
    }

    /// What's wrong with the pasted link, or nil to go ahead.
    ///
    /// **Plain URL validation.** The field says "paste the link here", so anything
    /// with a scheme or a known host is parsed as a `URL` and judged as one: the
    /// scheme, the host, and whether the path names a MODEL rather than a search or a
    /// listing. No character allowlists, no length caps, no control-character sweeps —
    /// those were guarding a hole that doesn't exist. The ref reaches the server as a
    /// JSON string field (`JSONEncoder`) and every request is built with
    /// `appendingPathComponent` on a fixed path, so the text never enters a url, a
    /// header, a query or a shell. There is nothing to escape it out of, and a
    /// validator that pretends otherwise is theatre with false rejections attached.
    ///
    /// Text that is NOT a link passes through untouched, and that is deliberate: the
    /// shortlist rows put a bare tag in this field (`gemma4:26b`), and a private
    /// registry ref (`registry.internal.example/team/model`) is a name too. Neither is
    /// advertised any more, both still work, and neither is a url to be validated.
    static func refProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // the button is already disabled

        guard let url = asLink(trimmed) else { return nil }   // a bare ref — allowed

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "only http and https links work here."
        }
        guard let host = url.host?.lowercased() else {
            return "that link has no address in it."
        }
        let path = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "ollama.com", "www.ollama.com":
            // ollama.com/library/{model} — or ollama.com/{user}/{model}.
            if path.first == "search" || path.isEmpty {
                return "that's ollama's search page. open a model from it, then copy that link."
            }
            if path == ["library"] {
                return "that's ollama's library index. open one model, then copy its link."
            }
            return nil

        case "huggingface.co", "www.huggingface.co", "hf.co":
            if path.first == "models" || path.isEmpty {
                return "that's hugging face's model list. open a repo, then copy its link."
            }
            if let first = path.first, ["datasets", "spaces", "docs", "blog", "papers"].contains(first) {
                return "that's a hugging face \(first) page, not a model repo."
            }
            if path.count < 2 {
                return "that link is missing the repo — a model page looks like huggingface.co/user/repo."
            }
            return nil

        default:
            return "that link isn't from ollama.com or hugging face. open the model's page on one of those and copy the link from there."
        }
    }

    /// The pasted text as a URL, or nil when it isn't a link at all.
    ///
    /// `URL(string:)` alone can't answer this: `gemma4:26b` parses with the scheme
    /// "gemma4", so every shortlist tag would be judged as a link with a bad scheme.
    /// A link is text carrying `://`, or text whose first component is one of the two
    /// hosts this screen sends people to (a paste from a share sheet sometimes loses
    /// the scheme).
    private static func asLink(_ s: String) -> URL? {
        let knownHosts = ["ollama.com", "www.ollama.com",
                          "huggingface.co", "www.huggingface.co", "hf.co"]
        if s.contains("://") { return URL(string: s) }
        // Schemeless URI forms — `javascript:`, `data:` — carry no "://", so without
        // this they'd be taken for model names. A named list, not a pattern: the
        // pattern for "starts with a scheme" also matches `gemma4:26b`, which is what
        // a shortlist row writes into this field.
        let schemelessURIs = ["javascript:", "data:", "mailto:", "tel:", "blob:", "about:"]
        if let prefix = schemelessURIs.first(where: { s.lowercased().hasPrefix($0) }) {
            // Handed back with a scheme the caller will reject by name.
            return URL(string: prefix + "//placeholder") ?? URL(string: "about:blank")
        }
        let firstComponent = s.split(separator: "/", maxSplits: 1).first.map {
            String($0).lowercased()
        }
        if let first = firstComponent, knownHosts.contains(first) {
            return URL(string: "https://" + s)
        }
        return nil
    }


    static func normalizePullRef(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ollama run ", "ollama pull "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // Strip scheme.
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        // …and any query or fragment, which a copied browser URL often carries.
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let host = parts.first?.lowercased() else { return s }

        // OLLAMA.COM URLS, because copying the page's link is what a phone user can
        // actually do. Finding "the model's name" on that page means reading a code
        // block; the link is already in the share sheet, and it says the same thing:
        //
        //   ollama.com/library/qwen3.5        → qwen3.5
        //   ollama.com/library/gemma4:26b     → gemma4:26b
        //   ollama.com/library/gemma4/tags    → gemma4
        //   ollama.com/some-user/their-model  → some-user/their-model
        //
        // Left alone before this, `ollama.com/library/qwen3.5` was passed to
        // `/api/pull` verbatim — a ref whose first path component reads as a REGISTRY
        // HOST, so it either 404s or asks ollama.com for a registry API it doesn't
        // serve. Either way the pull fails with nothing on screen to explain why.
        if host == "ollama.com" || host == "www.ollama.com" {
            var path = Array(parts.dropFirst())
            // `/tags` and `/blobs/…` are pages ABOUT a model, not part of its name.
            if let idx = path.firstIndex(where: { $0 == "tags" || $0 == "blobs" }) {
                path = Array(path[..<idx])
            }
            if path.first == "library" { path = Array(path.dropFirst()) }
            let ref = path.prefix(2).joined(separator: "/")
            return ref.isEmpty ? s : ref
        }

        guard host == "huggingface.co" || host == "hf.co" else {
            return s   // bare library name (possibly with :tag) — pass through
        }
        // hf.co/{user}/{repo[:quant]} — keep the first two path components only,
        // dropping /tree/main, /blob/…, query, etc. Rewrite host to hf.co.
        let path = parts.dropFirst().prefix(2).joined(separator: "/")
        return path.isEmpty ? s : "hf.co/\(path)"
    }
}

// MARK: - Wire contract — https://github.com/ollama/ollama/blob/main/docs/api.md

/// `GET /api/version`
struct OllamaVersionResponse: Decodable {
    let version: String
}

/// `GET /api/tags` — locally installed models.
struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String                 // "qwen3.5:4b" — the id you send in chat requests
        let model: String?               // usually == name
        let size: Int64?                 // bytes on disk
        let digest: String?
        let modified_at: String?
        struct Details: Decodable {
            let family: String?          // "qwen35"
            let families: [String]?
            let parameter_size: String?  // "4.7B"
            let quantization_level: String?  // "Q4_K_M"
            let format: String?          // "gguf"
        }
        let details: Details
    }
    let models: [Model]
}

/// `POST /api/show` — request body.
struct OllamaShowRequest: Encodable { let model: String }

/// `POST /api/show` — model metadata. `capabilities` is the field teemoon reads,
/// e.g. `["completion","tools","vision","thinking"]`. (Many more fields exist —
/// `modelfile`, `parameters`, `template`, `details`, `model_info` — omitted; add
/// here when consumed.)
struct OllamaShowResponse: Decodable {
    let capabilities: [String]?
}

/// `DELETE /api/delete` — request body.
struct OllamaDeleteRequest: Encodable { let model: String }

/// `POST /api/pull` — request body. Response streams NDJSON (`OllamaPullProgress`).
struct OllamaPullRequest: Encodable {
    let model: String
    var stream = true
    var insecure = false
}

/// One NDJSON line from `POST /api/pull`. Sequence:
/// `{"status":"pulling manifest"}` → repeated
/// `{"status":"pulling <digest>","digest":…,"total":…,"completed":…}` →
/// `{"status":"verifying sha256 digest"}` → `{"status":"writing manifest"}` →
/// `{"status":"success"}`. Errors may arrive in-band as `{"error":"…"}`.
struct OllamaPullProgress: Decodable {
    let status: String?
    let digest: String?
    let total: Int64?
    let completed: Int64?
    let error: String?

    var isSuccess: Bool { status == "success" }
    /// 0.0…1.0 when a byte-total is known, else nil (indeterminate phase).
    var fractionCompleted: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1.0, Double(completed) / Double(total))
    }
}

/// A non-2xx `/api/pull`, or an in-band `{"error":…}` line.
struct OllamaPullError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        message.isEmpty ? "Ollama pull failed (HTTP \(status))" : message
    }
}
