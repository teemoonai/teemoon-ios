import Foundation
import Testing
@testable import teemoon

@Suite("Provider")
struct ProviderTests {

    /// THE SAME SERVER, SPELLED DIFFERENTLY, IS THE SAME SERVER.
    ///
    /// Reported from the device: the Where sheet showed "browse grok · add key"
    /// for a grok setup that had a key and equipped models — drilling in showed
    /// both. The row matched its preset with a raw `==` while the key lookup
    /// (`credential(forEndpoint:)`) trimmed and lowercased, so the row asked one
    /// question with two rules and disagreed with itself. `keyed` is gated on
    /// `configured != nil`, so finding the key could not rescue it.
    ///
    /// `openAIBaseURL` already accepts an endpoint with or without the trailing
    /// `/chat/completions`, which is exactly why both spellings exist in saved
    /// records.
    @Test func anEndpointMatchesItsPresetHoweverItIsSpelled() {
        let preset = Provider.grok                       // …/v1/chat/completions
        func saved(_ endpoint: String) -> Provider {
            var p = Provider.grok
            p.id = UUID()                                 // a save mints a fresh id
            p.endpoint = endpoint
            return p
        }
        #expect(saved("https://api.x.ai/v1/chat/completions").sameEndpoint(as: preset))
        #expect(saved("https://api.x.ai/v1").sameEndpoint(as: preset))
        #expect(saved("https://api.x.ai/v1/").sameEndpoint(as: preset))
        #expect(saved("  https://API.X.AI/v1/chat/completions  ").sameEndpoint(as: preset))

        // A DIFFERENT server must stay different — the normalisation must not
        // collapse to the host, since presets can share one and differ by path.
        #expect(!saved("https://api.x.ai/v2").sameEndpoint(as: preset))
        #expect(!saved("https://api.openai.com/v1").sameEndpoint(as: preset))
        #expect(!Provider.nearAI.sameEndpoint(as: preset))
    }

    // MARK: - openAIBaseURL

    @Test func openAIBaseURL_stripsTrailingChatCompletions() {
        let provider = Provider(name: "test", endpoint: "https://api.example.com/v1/chat/completions", model: "gpt-4")
        #expect(provider.openAIBaseURL?.absoluteString == "https://api.example.com/v1")
    }

    @Test func openAIBaseURL_preservesEndpointWithoutChatCompletions() {
        let provider = Provider(name: "test", endpoint: "https://api.example.com/v1", model: "gpt-4")
        #expect(provider.openAIBaseURL?.absoluteString == "https://api.example.com/v1")
    }

    @Test func openAIBaseURL_nilForEmptyEndpoint() {
        let provider = Provider(name: "test", endpoint: "", model: "gpt-4")
        #expect(provider.openAIBaseURL == nil)
    }

    @Test func openAIBaseURL_schemelessFails() {
        let provider = Provider(name: "test", endpoint: "192.168.1.1:8080/v1", model: "test")
        #expect(provider.openAIBaseURL == nil)
    }

    @Test func openAIBaseURL_httpScheme() {
        let provider = Provider(name: "test", endpoint: "http://192.168.1.1:8080/v1", model: "test")
        #expect(provider.openAIBaseURL != nil)
        #expect(provider.openAIBaseURL?.scheme == "http")
    }

    // MARK: - isValid

    @Test func isValid_trueForProperProvider() {
        let provider = Provider(name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-4")
        #expect(provider.isValid)
    }

    @Test func isValid_falseForEmptyName() {
        let provider = Provider(name: "", endpoint: "https://api.openai.com/v1", model: "gpt-4")
        #expect(!provider.isValid)
    }

    @Test func isValid_falseForWhitespaceOnlyName() {
        let provider = Provider(name: "   ", endpoint: "https://api.openai.com/v1", model: "gpt-4")
        #expect(!provider.isValid)
    }

    @Test func isValid_falseForEmptyEndpoint() {
        let provider = Provider(name: "test", endpoint: "", model: "gpt-4")
        #expect(!provider.isValid)
    }

    @Test func isValid_falseForEmptyModel() {
        let provider = Provider(name: "test", endpoint: "https://api.openai.com/v1", model: "")
        #expect(!provider.isValid)
    }

    // MARK: - console recovery (401/402 deep-links)

    @Test func consoleURL_matchesPresetEndpoint() {
        let saved = Provider(id: UUID(), name: "near.ai glm 5.2",
                             endpoint: Provider.nearAI.endpoint, model: "z-ai/glm-5.2")
        #expect(saved.consoleURL?.absoluteString == Provider.nearAI.signupURL)
        #expect(saved.consoleDisplayName == "near.ai")
    }

    @Test func consoleURL_nilForCustomHost() {
        let p = Provider(name: "lab", endpoint: "http://192.168.1.9:11434/v1", model: "llama")
        #expect(p.consoleURL == nil)
    }

    @Test func consoleRecovery_byRequestHost() {
        let err = LLMError(
            source: .provider(name: "my near label"),
            userMessage: "",
            httpStatus: 402,
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
            requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
            responseBody: nil, underlyingError: nil
        )
        let recovery = Provider.consoleRecovery(for: err, activeProvider: nil)
        #expect(recovery?.displayName == "near.ai")
        #expect(recovery?.url.absoluteString == Provider.nearAI.signupURL)
    }

    @Test func consoleRecovery_directNearAICompletionHost() {
        // Direct TEE host still maps to near.ai console, not a dead end.
        let err = LLMError(
            source: .provider(name: "near.ai glm 5.2"),
            userMessage: "",
            httpStatus: 402,
            url: URL(string: "https://glm-5-2.completions.near.ai/v1/chat/completions"),
            requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
            responseBody: nil, underlyingError: nil
        )
        let recovery = Provider.consoleRecovery(for: err, activeProvider: nil)
        #expect(recovery?.displayName == "near.ai")
        #expect(recovery?.url != nil)
    }

    @Test func consoleRecovery_braveGrounding() {
        let err = LLMError(
            source: .braveGrounding,
            userMessage: LLMError.groundingMessage(httpStatus: 402),
            httpStatus: 402,
            url: URL(string: "https://api.search.brave.com/res/v1/web/search"),
            requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
            responseBody: nil, underlyingError: nil
        )
        let recovery = Provider.consoleRecovery(for: err, activeProvider: nil)
        #expect(recovery?.displayName == "Brave Answers")
        #expect(recovery?.url.absoluteString == Provider.braveAnswers.signupURL)
    }

    /// A host that merely CONTAINS a preset's domain is a different vendor.
    /// "phoenix.ai" contains "x.ai", so substring matching sent someone
    /// self-hosting there to xAI's billing page on a 401.
    @Test func consoleRecovery_nilForHostContainingPresetDomain() {
        for host in ["llm.phoenix.ai", "matrix.ai", "notbrave.com", "myfireworks.ai"] {
            let err = LLMError(
                source: .provider(name: "self-hosted"),
                userMessage: "",
                httpStatus: 401,
                url: URL(string: "https://\(host)/v1/chat/completions"),
                requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
                responseBody: nil, underlyingError: nil
            )
            #expect(Provider.consoleRecovery(for: err, activeProvider: nil) == nil,
                    "\(host) is not a preset vendor")
        }
    }

    /// The subdomains that DO belong to a preset still resolve.
    @Test func consoleRecovery_matchesVendorSubdomains() {
        let cases = [
            ("glm-5-2.completions.near.ai", "near.ai"),
            ("cloud-api.near.ai",           "near.ai"),
            ("app.fireworks.ai",            "Fireworks"),
        ]
        for (host, expected) in cases {
            let err = LLMError(
                source: .provider(name: "renamed"),
                userMessage: "",
                httpStatus: 402,
                url: URL(string: "https://\(host)/v1/chat/completions"),
                requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
                responseBody: nil, underlyingError: nil
            )
            #expect(Provider.consoleRecovery(for: err, activeProvider: nil)?.displayName == expected,
                    "\(host) should resolve to \(expected)")
        }
    }

    @Test func consoleRecovery_nilForUnknownHost() {
        let err = LLMError(
            source: .provider(name: "lab"),
            userMessage: "",
            httpStatus: 402,
            url: URL(string: "http://192.168.1.9:11434/v1/chat/completions"),
            requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
            responseBody: nil, underlyingError: nil
        )
        #expect(Provider.consoleRecovery(for: err, activeProvider: nil) == nil)
    }

    // MARK: - capabilities

    @Test func capabilities_trueForNearAI() {
        let provider = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "test")
        #expect(provider.capabilities.contains(.attestation))
    }

    @Test func capabilities_nearAIConfidentialModelIsAttested() {
        NearAIModelCatalog.resetTierCache()
        let p = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1/chat/completions",
                         model: "zai-org/GLM-5.1-FP8")
        #expect(p.capabilities.contains(.attestation))
        #expect(p.capabilities.contains(.endToEndEncryption))
    }

    @Test func capabilities_nearAIProxiedModelIsNotAttested() {
        // near.ai proxies closed frontier models with no enclave — teemoon must
        // not imply attestation/E2EE for them (correctness: no false proof).
        NearAIModelCatalog.resetTierCache()
        for proxied in ["anthropic/claude-opus-4-6", "openai/gpt-5.2", "google/gemini-2.5-pro"] {
            let p = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1/chat/completions", model: proxied)
            #expect(!p.capabilities.contains(.attestation), "\(proxied) is proxied — no attestation")
            #expect(!p.capabilities.contains(.endToEndEncryption), "\(proxied) is proxied — no E2EE")
        }
    }

    @Test func capabilities_nearAIGptOssAttestedButGpt5NotWithinSameVendor() {
        NearAIModelCatalog.resetTierCache()
        let oss = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "openai/gpt-oss-120b")
        let gpt5 = Provider(name: "near.ai", endpoint: "https://cloud-api.near.ai/v1", model: "openai/gpt-5.2")
        #expect(oss.capabilities.contains(.attestation))
        #expect(!gpt5.capabilities.contains(.attestation))
    }

    @Test func capabilities_falseForOtherEndpoints() {
        let provider = Provider(name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-4")
        #expect(!provider.capabilities.contains(.attestation))
    }

    @Test func capabilities_reflectStoredFlags() {
        var provider = Provider(name: "test", endpoint: "https://api.example.com/v1", model: "m",
                                supportsModelBrowsing: true, hasBuiltInGrounding: true)
        #expect(provider.capabilities.contains([.modelBrowsing, .builtInGrounding]))
        provider.supportsModelBrowsing = false
        provider.hasBuiltInGrounding = false
        #expect(provider.capabilities.isDisjoint(with: [.modelBrowsing, .builtInGrounding]))
    }

    // MARK: - Codable roundtrip

    @Test func codable_roundtrip() throws {
        let original = Provider(
            name: "Test Provider",
            endpoint: "https://api.test.com/v1",
            model: "gpt-4",
            authHeaderName: "X-Custom-Auth",
            requiresAPIKey: true,
            extraParams: ["temperature": "0.7"],
            maxMessages: 10,
            hasBuiltInGrounding: true,
            omitSystemPrompt: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.endpoint == original.endpoint)
        #expect(decoded.model == original.model)
        #expect(decoded.authHeaderName == original.authHeaderName)
        #expect(decoded.requiresAPIKey == original.requiresAPIKey)
        #expect(decoded.extraParams == original.extraParams)
        #expect(decoded.maxMessages == original.maxMessages)
        #expect(decoded.hasBuiltInGrounding == original.hasBuiltInGrounding)
        #expect(decoded.omitSystemPrompt == original.omitSystemPrompt)
    }

    @Test func codable_multipleProviders_roundtrip() throws {
        let providers = [
            Provider(name: "A", endpoint: "https://a.com/v1", model: "m1"),
            Provider(name: "B", endpoint: "https://b.com/v1", model: "m2", authHeaderName: "X-Key"),
        ]
        let data = try JSONEncoder().encode(providers)
        let decoded = try JSONDecoder().decode([Provider].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].name == "A")
        #expect(decoded[1].authHeaderName == "X-Key")
    }

    // MARK: - Equatable

    @Test func equatable_sameID_areEqual() {
        let id = UUID()
        let a = Provider(id: id, name: "A", endpoint: "https://a.com", model: "m1")
        let b = Provider(id: id, name: "A", endpoint: "https://a.com", model: "m1")
        #expect(a == b)
    }

    @Test func equatable_differentID_areNotEqual() {
        let a = Provider(name: "A", endpoint: "https://a.com", model: "m1")
        let b = Provider(name: "A", endpoint: "https://a.com", model: "m1")
        #expect(a != b)
    }

    // MARK: - KnownModel.deprecationDate, parsed at the boundary

    @Test func deprecationDate_parsesBothShapesFireworksSends() {
        // Plain date — what the control plane actually returns today.
        let plain = KnownModel.deprecationDate(fromProvider: "2026-12-01")
        #expect(plain != nil)
        // Full ISO8601 with time, in case it ever tightens.
        let iso = KnownModel.deprecationDate(fromProvider: "2026-12-01T00:00:00Z")
        #expect(iso != nil)
        #expect(plain == iso)   // same instant, both spellings
    }

    @Test func deprecationDate_isNilForNothingAndForGarbage() {
        #expect(KnownModel.deprecationDate(fromProvider: nil) == nil)
        #expect(KnownModel.deprecationDate(fromProvider: "") == nil)
        #expect(KnownModel.deprecationDate(fromProvider: "   ") == nil)
        // Unparseable merges into "the provider published nothing", rather than
        // being echoed raw into a sentence the user is asked to act on.
        #expect(KnownModel.deprecationDate(fromProvider: "Q4 2026") == nil)
    }

    /// The `en_US_POSIX` rule, which the old inline parser did not follow.
    ///
    /// A fixed-format `DateFormatter` without it takes the CALENDAR from the
    /// user's locale, so under Buddhist or Japanese — both one tap away in iOS
    /// Settings — "2026-12-01" parses to a different year or not at all. This
    /// pins the parse to a known absolute instant, which is only stable if the
    /// formatter is locale-independent.
    @Test func deprecationDate_isLocaleIndependent() {
        let parsed = try! #require(KnownModel.deprecationDate(fromProvider: "2026-12-01"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: parsed)
        #expect(parts.year == 2026)
        #expect(parts.month == 12)
        #expect(parts.day == 1)
    }

    @Test func deprecationLabel_readsAsRetiredOnlyOncePast() {
        let past = KnownModel(id: "m", displayName: "M", vendor: "V", price: "",
                              deprecationDate: Date().addingTimeInterval(-86_400))
        #expect(past.deprecationLabel == "retired")
        #expect(past.isRetiring)

        let future = KnownModel(id: "m", displayName: "M", vendor: "V", price: "",
                                deprecationDate: Date().addingTimeInterval(86_400 * 120))
        #expect(future.deprecationLabel?.hasPrefix("retiring") == true)
        #expect(future.deprecationLabel != "retired")

        let silent = KnownModel(id: "m", displayName: "M", vendor: "V", price: "")
        #expect(silent.deprecationLabel == nil)
        #expect(!silent.isRetiring)
    }
}
