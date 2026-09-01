//
//  LocalServerLiveTests.swift
//  teemoonTests
//
//  Live end-to-end check against a local OpenAI-compatible server
//  (e.g. `llama serve … --port 8080`). It proves the three things that gate
//  "point teemoon at a local model and it works":
//
//    1. iOS ATS actually permits a cleartext http://127.0.0.1 connection.
//       (If it doesn't, the probe throws -1022 and this test FAILS loudly with
//       the fix — rather than silently skipping.)
//    2. A keyless, non-attested local provider streams text end-to-end through
//       the production engine (ConfidentialLanguageModel → GenerationEngine).
//    3. For such a provider, E2EE is OFF and NO Authorization header is sent.
//
//  It is intentionally NOT `.disabled`: when no server is listening on :8080
//  the reachability probe returns a connection error and the test skips
//  (early return), so CI stays green. It only exercises the real path when a
//  local server is actually reachable.
//
//  To run locally:
//    llama serve -hf bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M -c 8192 \
//      --port 8080 -a qwen2.5-7b
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Local server live")
struct LocalServerLiveTests {
    static let host = "127.0.0.1:8080"
    static let endpoint = "http://\(host)/v1"

    /// The model id to exercise, DISCOVERED from the live server rather than
    /// pinned: llama-server's router serves whatever presets the machine has
    /// (today `bartowski/Qwen2.5-7B-Instruct-GGUF:Q4_K_M`), so a hardcoded id
    /// silently turned "my local setup changed" into a red test.
    private func liveModelID() async -> String? {
        guard case .connected(let models) = await EndpointModelCatalog.probe(
            baseURL: URL(string: Self.endpoint)!) else { return nil }
        return models.first?.id
    }

    /// Probe the server. Returns `nil` when reachable; otherwise the `URLError`
    /// so the caller can distinguish an ATS block (a real failure we want to
    /// surface) from "no server running" (skip). The probe runs through the same
    /// ATS policy as the app, so a cleartext block shows up here as -1022.
    private func probe() async -> URLError? {
        var req = URLRequest(url: URL(string: "http://\(Self.host)/v1/models")!)
        req.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: req)
            return nil
        } catch let err as URLError {
            return err
        } catch {
            return URLError(.unknown)
        }
    }

    /// Verifies the redesign's generic model fetch (`EndpointModelCatalog.probe`,
    /// the "fetch models" action that doubles as the connection test): against the
    /// live local server it returns `.connected` with the served model, and a
    /// wrong port classifies as a specific `.nothingListening` failure rather than
    /// hanging or crashing.
    @Test @MainActor func endpointCatalogProbeFetchesModels() async throws {
        if await probe() != nil {
            print("[catalog-probe] server unreachable — skipping"); return
        }
        let base = URL(string: Self.endpoint)!   // http://127.0.0.1:8080/v1
        switch await EndpointModelCatalog.probe(baseURL: base) {
        case .connected(let models):
            #expect(!models.isEmpty)
            // Rows must be presentable, not raw ids: a self-hosted GGUF id is
            // `{uploader}/{repo}:{quant}`, so the uploader must not become the
            // vendor section ("Bartowski"/"Unsloth" instead of Qwen/Google).
            for m in models {
                #expect(!m.displayName.contains("/"), "\(m.id) shows its namespace in the row")
                #expect(!m.vendor.isEmpty)
                #expect(!["Bartowski", "Unsloth", "Lmstudio-community", "Mradermacher"]
                        .contains(m.vendor), "\(m.id) is filed under its uploader (\(m.vendor))")
            }
            print("[catalog-probe] \(models.map { "\($0.vendor)/\($0.displayName)" })")
        case .failed(let kind):
            Issue.record("probe of live server failed: \(kind)")
        }

        // A wrong port must classify specifically, not hang or crash.
        let badResult = await EndpointModelCatalog.probe(baseURL: URL(string: "http://127.0.0.1:8099/v1")!)
        if case .failed(let kind) = badResult {
            #expect(kind == .nothingListening || kind == .offline,
                    "wrong-port probe should fail as nothingListening/offline, got \(kind)")
        } else {
            Issue.record("wrong-port probe unexpectedly succeeded")
        }
    }

    @Test @MainActor func localProviderStreamsPlaintext() async throws {
        if let err = await probe() {
            // The one error we must NOT swallow: ATS blocked cleartext loopback.
            #expect(
                err.code != .appTransportSecurityRequiresSecureConnection,
                "iOS ATS blocked cleartext http://\(Self.host). Add NSAllowsLocalNetworking (or a scoped NSExceptionDomains entry) to teemoon/Info.plist so local providers can connect."
            )
            // Any other error → no local server on :8080 → skip silently (CI path).
            print("[local-live] server unreachable (\(err.code.rawValue)) — skipping")
            return
        }

        guard let modelID = await liveModelID() else {
            Issue.record("server is up but served no models"); return
        }
        // Keyless, non-attested local provider — the exact config a user enters
        // for a local llama.cpp/Ollama/LM Studio endpoint.
        let provider = Provider(
            name: "local qwen",
            endpoint: Self.endpoint,
            model: modelID,
            requiresAPIKey: false,
            extraParams: ["max_tokens": "32"]  // keep the response tiny/fast
        )

        let results = LockedBox<[RequestResult]>([])
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in },
            onQueriesFound: { _ in },
            onToolExecutionEnded: {},
            onSuccess: { r in results.value = results.value + [r] }
        )
        // context: nil → no TEE/E2EE. apiKey: "" → no auth header expected.
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: "", priorMessages: [],
            context: nil, events: callbacks
        )
        let session = LanguageModelSession(model: model)

        var text = ""
        for try await snapshot in session.streamResponse(to: "Reply with exactly one word: pong") {
            text = snapshot.content
        }

        // 1 & 2: the request went out over cleartext loopback and streamed text.
        #expect(!text.isEmpty, "empty response from local server")
        print("[local-live] response: \(text.prefix(80))")

        // 3: E2EE off, and no Authorization header for a keyless provider.
        //
        // WAIT FOR IT. `onSuccess` is delivered from a DETACHED Task inside
        // `GenerationEngine.run` — it awaits the response-signature verification
        // first — so the stream finishing does not mean the result has landed.
        // Reading it straight after the loop is a race the test only won by
        // luck, and it started losing: text streamed fine, the result was nil,
        // and the failure read as "no RequestResult delivered" rather than as a
        // timing bug. `GenerationTransportTests` already waits for exactly this.
        for _ in 0..<40 where results.value.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let result = try #require(results.value.first, "no RequestResult delivered")
        #expect(result.isE2EEActive == false,
                "E2EE must be inactive for a local, non-attested endpoint")
        let authHeader = result.requestHeaders?.first {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        #expect(authHeader == nil,
                "no Authorization header should be sent when the API key is empty")
    }

    /// Proves teemoon's FULL tool round-trip works against the local server: it
    /// sends a tool, the model emits a tool call, the engine executes it (here a
    /// canned stub — no network), feeds the result back, and finishes. If this
    /// passes, a failing tool call on-device is a CONFIG issue (no Brave key
    /// attached, so no tool is sent), NOT the model, server, or parser.
    @Test @MainActor func localProviderToolRoundTrip() async throws {
        if let err = await probe() {
            #expect(err.code != .appTransportSecurityRequiresSecureConnection,
                    "iOS ATS blocked cleartext http://\(Self.host).")
            print("[tool-rt] server unreachable (\(err.code.rawValue)) — skipping")
            return
        }

        guard let modelID = await liveModelID() else {
            Issue.record("server is up but served no models"); return
        }
        let provider = Provider(
            name: "local qwen", endpoint: Self.endpoint, model: modelID,
            requiresAPIKey: false
        )
        let results = LockedBox<[RequestResult]>([])
        let callbacks = StreamCallbacks(
            onSourcesFound: { _ in }, onQueriesFound: { _ in },
            onToolExecutionEnded: {},
            onSuccess: { r in results.value = results.value + [r] }
        )
        let model = ConfidentialLanguageModel(
            provider: provider, apiKey: "", priorMessages: [],
            context: nil, events: callbacks
        )
        let session = LanguageModelSession(model: model, tools: [StubWebSearchTool()])

        var text = ""
        for try await snapshot in session.streamResponse(to: "what is the weather in Paris today?") {
            text = snapshot.content
        }

        let result = try #require(results.value.first, "no RequestResult delivered")
        // A non-empty toolCalls proves the whole chain: tool sent → model called
        // it → engine executed the stub → fed the result back → produced an answer.
        #expect(!result.toolCalls.isEmpty,
                "expected a tool-call round-trip — the model should have called web_search")
        #expect(!text.isEmpty, "empty final answer after tool round-trip")
        print("[tool-rt] toolCalls=\(result.toolCalls.count) answer=\(text.prefix(200))")
    }
}

/// LM Studio (`localhost:1234`) as a **custom provider** — the third local
/// server teemoon must handle, alongside llama.cpp and Ollama. It speaks
/// OpenAI-compat at `/v1`, so it goes through the generic probe today.
///
/// It ships GGUFs from its own store (`~/.cache/lm-studio/models`, laid out as
/// `{publisher}/{repo}/*.gguf`), which can be SYMLINKED to the HuggingFace cache
/// llama.cpp already downloads into — one copy of each model, both servers.
/// (Ollama's store can't be shared that way: it is content-addressed blobs plus
/// manifests, not named `.gguf` files.)
///
/// Skips when nothing is listening on :1234, like the suites above.
@Suite("LM Studio live")
struct LMStudioLiveTests {
    static let endpoint = "http://127.0.0.1:1234/v1"

    private func models() async -> [KnownModel]? {
        guard case .connected(let models) = await LMStudioAdapter.listModels(
            baseURL: URL(string: Self.endpoint)!) else { return nil }
        return models
    }

    /// The endpoint must resolve to LM Studio, not fall through to the generic
    /// probe — that routing is what gets the rows their metadata.
    @Test @MainActor func detectsAsLMStudio() async throws {
        let base = URL(string: Self.endpoint)!
        guard await LMStudioAdapter.isLMStudio(baseURL: base) else {
            print("[lmstudio] not running on :1234 — skipping"); return
        }
        #expect(await LocalServerKind.detect(baseURL: base) == .lmStudio)
        // It must NOT answer Ollama's probe — the two would otherwise race.
        #expect(await OllamaAdapter.isOllama(baseURL: base) == false)
    }

    @Test @MainActor func probeListsChatModelsWithRealMetadata() async throws {
        guard let models = await models() else {
            print("[lmstudio] not running on :1234 — skipping"); return
        }
        #expect(!models.isEmpty)
        // LM Studio lists embedding models next to chat models; offering one as a
        // chat model produces a 400 on first message.
        #expect(!models.contains { $0.id.contains("embedding") })
        // Its ids carry no namespace ("qwen2.5-7b-instruct", "gemma-4-…@q4_k_xl"),
        // so the vendor has to come from the family — `owned_by` is the useless
        // "organization_owner", and the publisher is the GGUF uploader.
        #expect(!models.contains { $0.vendor.lowercased().contains("organization") })
        for m in models {
            #expect(!m.vendor.isEmpty)
            // The whole point of the adapter: context + quant, and capabilities
            // that are KNOWN rather than nil.
            #expect(!m.contextWindow.isEmpty, "\(m.id) has no context/quant")
            #expect(m.capabilities != nil, "\(m.id) reported no capabilities")
            #expect(!m.displayName.contains("@"), "\(m.id) shows its quant in the name")
        }
        print("[lmstudio] \(models.map { "\($0.vendor)/\($0.displayName) \($0.contextWindow)" })")
    }

    /// The full engine against LM Studio: a keyless custom provider streams text.
    /// LM Studio JIT-loads the model on first request, so allow for a cold start.
    ///
    /// Tries each listed model until one answers, because a *listed* model is not
    /// necessarily a *loadable* one: LM Studio's bundled llama.cpp engine can be
    /// older than a GGUF in its library and dies loading it ("exited before
    /// becoming healthy … SIGABRT") — observed with a gemma-4 QAT build that the
    /// standalone llama-server on :8080 serves fine. That is an engine-version
    /// mismatch on the server, not something teemoon can detect from `/v1/models`,
    /// so the test proves the transport works with SOME model rather than pinning
    /// one and going red when the library changes.
    @Test @MainActor func customProviderStreamsFromLMStudio() async throws {
        guard let models = await models(), !models.isEmpty else {
            print("[lmstudio] not running on :1234 — skipping"); return
        }
        var lastError: String?
        for candidate in models {
            let provider = Provider(
                name: "lm studio", endpoint: Self.endpoint, model: candidate.id,
                requiresAPIKey: false, extraParams: ["max_tokens": "16"]
            )
            let model = ConfidentialLanguageModel(
                provider: provider, apiKey: "", priorMessages: [],
                context: nil, events: StreamCallbacks(
                    onSourcesFound: { _ in }, onQueriesFound: { _ in },
                    onToolExecutionEnded: {}, onSuccess: { _ in })
            )
            let session = LanguageModelSession(model: model)

            do {
                var text = ""
                for try await snapshot in session.streamResponse(to: "Reply with exactly one word: pong") {
                    text = snapshot.content
                }
                guard !text.isEmpty else { lastError = "\(candidate.id): empty response"; continue }
                // Only the transport is asserted here. `RequestResult` is delivered
                // from a detached task AFTER the stream ends, so requiring it here
                // is a race — the llama.cpp suite above covers E2EE-off and the
                // absent Authorization header for a keyless provider.
                print("[lmstudio] \(candidate.id) → \(text.prefix(80))")
                return
            } catch {
                // Model wouldn't load — try the next one.
                lastError = "\(candidate.id): \(error.localizedDescription)"
                print("[lmstudio] \(lastError!)")
            }
        }
        Issue.record("no listed LM Studio model could stream — last error: \(lastError ?? "none")")
    }
}

/// Stub with the same `web_search` shape teemoon sends, returning canned XML
/// (no network) so the round-trip is deterministic — used to prove the engine's
/// tool loop works against a local model without needing a real Brave key.
private struct StubWebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information such as weather, recent events, live prices, or anything past your training cutoff."

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        "<source index=\"1\"><url>https://weather.example/paris</url><title>Paris weather today</title><content>Paris today: sunny, 18°C, light breeze.</content></source>"
    }
}

// MARK: - Ollama, including the path a real phone actually takes

/// Ollama had NO end-to-end suite, and the gap had teeth: every local test here
/// used loopback, while a real device reaches Ollama through `tailscale serve`
/// over an HTTPS tailnet name. Those are different code paths on the SERVER —
/// Ollama validates the `Host` header and refuses anything non-local with a
/// bare 403 — so loopback-only coverage reported green while "add provider"
/// failed on the phone with "key rejected" for a server that has no key at all.
///
/// Set `TEEMOON_PROXY_ENDPOINT` to exercise the proxied path (it's per-machine,
/// so there's nothing sensible to hardcode):
///
///   TEEMOON_PROXY_ENDPOINT=https://your-host.tailXXXX.ts.net/v1 \
///     xcodebuild test … -only-testing:teemoonTests/OllamaLiveTests
@Suite("Ollama live")
struct OllamaLiveTests {
    static let loopback = "http://127.0.0.1:11434/v1"

    private func reachable(_ endpoint: String) async -> Bool {
        guard let url = URL(string: endpoint + "/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse) != nil
    }

    /// Skips when the server is up but EMPTY, which is a normal developer state — a
    /// probe of a server with no models legitimately reports `.badResponse`, and
    /// failing the build for it makes "I deleted my models" look like a regression.
    /// Observed 2026-07-30.
    @Test @MainActor func loopbackProbeListsModels() async throws {
        guard await reachable(Self.loopback) else { return }
        let result = await EndpointModelCatalog.probe(baseURL: URL(string: Self.loopback)!)
        guard case .connected(let models) = result else {
            print("[ollama-live] up but serving no models — skipping")
            return
        }
        #expect(!models.isEmpty)
    }

    /// The regression this suite exists for. A proxied Ollama must either work,
    /// or fail with a diagnosis that points at the SERVER — never at a key.
    @Test @MainActor func proxiedEndpointIsUsableOrHonestlyDiagnosed() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_PROXY_ENDPOINT"],
              !endpoint.isEmpty, let url = URL(string: endpoint) else { return }
        guard await reachable(endpoint) else { return }

        let result = await EndpointModelCatalog.probe(baseURL: url)
        switch result {
        case .connected(let models):
            #expect(!models.isEmpty)
        case .failed(.forbidden):
            // Ollama is refusing the forwarded Host. Correct diagnosis, real
            // misconfiguration — fix is OLLAMA_HOST=0.0.0.0, verified live.
            Issue.record("proxied ollama 403s — set OLLAMA_HOST=0.0.0.0 so it accepts the forwarded Host")
        case .failed(let kind):
            // Anything else is teemoon misreading the situation. `.unauthorized`
            // here is the exact bug: a keyless server blamed on a key.
            Issue.record("proxied ollama misdiagnosed as \(kind) — a keyless server cannot have a key problem")
        }
    }

    @Test @MainActor func loopbackStreamsThroughTheRealEngine() async throws {
        guard await reachable(Self.loopback) else { return }
        guard case .connected(let models) = await EndpointModelCatalog.probe(
            baseURL: URL(string: Self.loopback)!), let model = models.first else { return }

        let provider = Provider(name: "ollama", endpoint: Self.loopback, model: model.id,
                                requiresAPIKey: false, extraParams: ["max_tokens": "32"])
        let headers = LockedBox<[String: String]>([:])
        let llm = ConfidentialLanguageModel(
            provider: provider, apiKey: "", priorMessages: [], context: nil,
            events: StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {},
                onSuccess: { r in headers.value = r.requestHeaders ?? [:] }))
        var text = ""
        for try await snapshot in LanguageModelSession(model: llm)
            .streamResponse(to: "Reply with exactly one word: pong") {
            text = snapshot.content
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "empty reply — the `reasoning`-only regression looks exactly like this")
        // A keyless local server must never receive credentials.
        #expect(headers.value["Authorization"] == nil)
    }
}

// MARK: - Failure classification (deterministic, no server needed)

/// The guard that makes the "key rejected" misdiagnosis unrepeatable. These are
/// pure status→kind mappings, so they hold in CI with nothing running.
@Suite("Local server failure classification")
struct LocalServerFailureClassificationTests {

    @Test func keylessForbiddenIsNotBlamedOnTheKey() {
        // Ollama behind `tailscale serve` answers a keyless request with a bare
        // 403 (verified live: same server returns 200 on loopback and 403 when
        // the Host header is the tailnet name). Reporting that as "key rejected"
        // sends the user hunting for a credential Ollama does not have.
        #expect(EndpointModelCatalog.failureKind(forStatus: 403, body: nil, sentKey: false) == .forbidden)
        #expect(EndpointModelCatalog.failureKind(forStatus: 403, body: Data(), sentKey: false) == .forbidden)
    }

    @Test func forbiddenStillMeansUnauthorizedWhenAKeyWasSent() {
        // Some providers do use 403 for a bad key — that reading is only wrong
        // when no key was in play.
        #expect(EndpointModelCatalog.failureKind(forStatus: 403, body: nil, sentKey: true) == .unauthorized)
        #expect(EndpointModelCatalog.failureKind(forStatus: 401, body: nil, sentKey: false) == .unauthorized)
    }

    @Test func otherStatusesAreUnaffectedByTheKeySignal() {
        for sent in [true, false] {
            #expect(EndpointModelCatalog.failureKind(forStatus: 200, sentKey: sent) == nil)
            #expect(EndpointModelCatalog.failureKind(forStatus: 404, sentKey: sent) == .noModelsEndpoint)
            #expect(EndpointModelCatalog.failureKind(forStatus: 402, sentKey: sent) == .paymentRequired)
            #expect(EndpointModelCatalog.failureKind(forStatus: 429, sentKey: sent) == .rateLimited)
        }
    }
}

/// Why `tailscale serve` is currently REQUIRED to reach a local model from the
/// app, and a plain `http://<host>.ts.net:11434` is not enough.
///
/// Measured, not assumed: with no ATS exception in `teemoon/Info.plist`, the
/// app's URLSession refuses cleartext to a Tailscale (100.64/10 CGNAT) address
/// with **URLError -1022**, even though `curl` reaches the same endpoint fine
/// and Ollama answers 200. That single fact is what forces the whole awkward
/// chain: serve must front it for HTTPS, serve forwards the original `Host`,
/// and Ollama 0.32.3 rejects a non-local `Host` with a bare 403.
///
/// If teemoon ever adds an `NSExceptionDomains` entry for `ts.net` (defensible:
/// Tailscale already encrypts every byte with WireGuard, so "cleartext" here is
/// never plaintext on a wire), this test is the one that should flip — and
/// `OLLAMA_HOST=<tailnet-name>` becomes a complete, shim-free answer.
///
///   TEEMOON_TAILNET_HTTP=http://<host>.ts.net:11434/v1 xcodebuild test …
@Suite("Tailnet cleartext reachability")
struct TailnetCleartextATSTests {

    @Test func cleartextToTailnetAddressIsBlockedByATS() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TEEMOON_TAILNET_HTTP"],
              !endpoint.isEmpty, let url = URL(string: endpoint + "/models") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            _ = try await URLSession.shared.data(for: req)
            Issue.record("ATS now ALLOWS cleartext to a tailnet address — if that exception was added deliberately, tailscale serve is no longer required; update the docs.")
        } catch let e as URLError {
            // -1022 is the ATS refusal. Anything else means the server was
            // unreachable, which this test can't distinguish a verdict from.
            #expect(e.code.rawValue == -1022,
                    "expected the ATS refusal, got URLError \(e.code.rawValue)")
        }
    }
}
