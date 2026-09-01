//
//  LocalProviderTests.swift
//  teemoonTests
//
//  A local model becomes an ordinary `Provider`, which means every assumption
//  the rest of the app makes about a provider now has to hold for one that has
//  no server: no scheme, no host, no key, nothing to attest.
//
//  These are the checks for equipping a downloaded local model — the moment
//  a local provider is registered and made active.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Local provider")
struct LocalProviderTests {

    private var model: LocalModel { LocalModelCatalog.all[0] }

    @Test func localProviderIsValidAndMarkedLocal() throws {
        let provider = Provider.local(model)
        #expect(provider.isLocal)
        #expect(provider.localModelID == model.id)
        #expect(provider.model == model.id)
        #expect(provider.requiresAPIKey == false)
        // `isValid` gates saving. A local provider must pass it, or it can never
        // be registered at all.
        #expect(provider.isValid, "local provider failed isValid — it can't be saved")
    }

    /// The endpoint is a placeholder, but half the app calls `openAIBaseURL`
    /// and friends on whatever is active. None of it may trap.
    @Test func urlDerivationsDoNotTrapOnTheLocalPlaceholder() throws {
        let provider = Provider.local(model)
        let base = try #require(provider.openAIBaseURL, "openAIBaseURL was nil — callers guard on this")
        _ = base.appendingPathComponent("chat/completions")
        _ = provider.isSelfHosted          // reads .host, must tolerate nil
        _ = provider.capabilities          // computed; reads endpoint
        _ = provider.effectiveMaxMessages
        _ = provider.effectiveOmitSystemPrompt
        _ = provider.modelSupportsTools
    }

    /// A local model has no enclave and no server: claiming attestation or E2EE
    /// for it would be an overclaim of exactly the kind the trust UI exists to
    /// prevent.
    @Test func localProviderClaimsNoAttestationOrEncryption() throws {
        let provider = Provider.local(model)
        #expect(!provider.capabilities.contains(.attestation))
        #expect(!provider.capabilities.contains(.endToEndEncryption))
        #expect(!provider.capabilities.contains(.modelBrowsing))
    }

    /// Reproduces the "use" button: register, make active, and let the store's
    /// active-provider side effects run.
    @Test @MainActor func registeringAndActivatingALocalProviderIsSafe() throws {
        let store = ProviderStore(inMemory: true)
        let session = ConfidentialSession(providers: store)
        store.onActiveProviderChanged = { [weak session] _ in
            session?.refreshAttestation()
        }

        let provider = Provider.local(model)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString

        #expect(store.activeProvider?.id == provider.id)
        #expect(store.activeProvider?.isLocal == true)
        // Nothing to attest, so no attestation record may be invented.
        #expect(session.attestation == nil)
    }

    /// Round-trips through the same Codable path `ProviderStore` persists with:
    /// a provider that decodes without its `localModelID` silently becomes a
    /// remote provider pointing at a placeholder endpoint, which would try to
    /// dial "on-device" over HTTP.
    @Test func localModelIDSurvivesCodableRoundTrip() throws {
        let provider = Provider.local(model)
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded.localModelID == model.id)
        #expect(decoded.isLocal)
    }

    /// Providers saved before on-device existed must stay remote.
    @Test func providersWithoutTheFieldDecodeAsRemote() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"near.ai","endpoint":"https://api.near.ai/v1",
         "model":"gpt","requiresAPIKey":true,"supportsModelBrowsing":true,
         "extraParams":{},"hasBuiltInGrounding":false,"omitSystemPrompt":false}
        """
        let decoded = try JSONDecoder().decode(Provider.self, from: Data(json.utf8))
        #expect(decoded.localModelID == nil)
        #expect(!decoded.isLocal)
    }
}
