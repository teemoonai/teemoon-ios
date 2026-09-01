//
//  ProviderCatalogValidationTests.swift
//  teemoonTests
//
//  Validation gate for the shipped provider catalog (Provider+Presets). The
//  load-bearing invariant: every near.ai model the app would treat as
//  attestable MUST ship an offline direct TEE host. Without one the attestation
//  path resolves no host, the model-enclave manifest never loads, and E2EE
//  key-binding stalls then fails closed — the GLM-5.2 / DeepSeek-v3.2 class of
//  bug. This turns that silent runtime failure into a build-time test failure.
//
//  Uses `classify` (the pure offline heuristic, no shared cache) so the gate is
//  deterministic and parallel-safe — it validates the shipped fallback exactly
//  as the app resolves it before the live catalog loads.
//

import Foundation
import Testing
@testable import teemoon

@Suite("ProviderCatalogValidation")
struct ProviderCatalogValidationTests {

    /// THE gate: a shipped near.ai own-fleet (teeOwn) model must carry an
    /// offline direct host so it can attest without waiting on the live
    /// directory. teeOwn ⟺ confidential endpoint is the invariant the runtime
    /// no-confidential-endpoint fail-fast also rests on.
    @Test func teeOwnNearAIModelsShipADirectHost() {
        for model in KnownModel.nearAIModels
        where NearAIModelCatalog.classify(model.id) == .teeOwn {
            #expect(model.directBaseURL != nil,
                    "\(model.id) is own-fleet (teeOwn) but ships no directBaseURL — its model-enclave manifest won't load and E2EE will fail closed. Add its https://<slug>.completions.near.ai/v1 host.")
        }
    }

    /// Proxied and attested-3p models have no confidential endpoint, so they
    /// must NOT claim a direct TEE host — a host here would put a non-E2EE
    /// model into every "encrypted models" surface.
    @Test func nonTeeOwnNearAIModelsHaveNoDirectHost() {
        for model in KnownModel.nearAIModels
        where NearAIModelCatalog.classify(model.id) != .teeOwn {
            #expect(model.directBaseURL == nil,
                    "\(model.id) is \(NearAIModelCatalog.classify(model.id)) (no confidential endpoint) but ships a directBaseURL.")
        }
    }

    /// The attested-3p exact-id set (the offline discriminator) must stay
    /// consistent with the shipped catalog: every id in it exists in the list,
    /// and classifies as teeThirdParty.
    @Test func attestedThirdPartySetMatchesCatalog() {
        let ids = Set(KnownModel.nearAIModels.map(\.id))
        for tp in KnownModel.nearAIAttestedThirdPartyIDs {
            #expect(ids.contains(tp), "\(tp) is in the attested-3p set but not the shipped catalog — stale set?")
            #expect(NearAIModelCatalog.classify(tp) == .teeThirdParty)
        }
    }

    /// Every shipped direct host is a well-formed https `/v1` completions base.
    @Test func directHostsAreWellFormed() {
        for model in KnownModel.nearAIModels {
            guard let raw = model.directBaseURL else { continue }
            #expect(URL(string: raw)?.scheme == "https",
                    "\(model.id): directBaseURL must be https — \(raw)")
            #expect(raw.hasSuffix("/v1"),
                    "\(model.id): directBaseURL must end in /v1 — \(raw)")
        }
    }

    /// No duplicate model ids in the one list that is still a full snapshot.
    /// (xAI and Fireworks ship keyed maps now — duplicates are impossible.)
    @Test func noDuplicateModelIDs() {
        let dupes = Dictionary(grouping: KnownModel.nearAIModels.map(\.id), by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "near.ai has duplicate model ids: \(dupes)")
    }

    /// The shrunk snapshots must stay minimal AND well-formed: xAI ships only
    /// names (it serves price, context and recency itself), Fireworks only
    /// prices (the one thing it serves nowhere — verified 2026-07-26).
    @Test func shrunkSnapshotsAreWellFormed() {
        #expect(!KnownModel.grokDisplayNames.isEmpty)
        for (id, name) in KnownModel.grokDisplayNames {
            #expect(!id.isEmpty && !name.isEmpty)
            #expect(id.hasPrefix("grok"), "\(id) is not an xAI id")
        }
        #expect(!KnownModel.fireworksPrices.isEmpty)
        for (id, price) in KnownModel.fireworksPrices {
            #expect(id.hasPrefix("accounts/"), "\(id) is not a Fireworks resource id")
            // "$in/$out" per 1M — the shape the row renders and the sort parses.
            #expect(price.split(separator: "/").count == 2 && price.hasPrefix("$"),
                    "\(id) has a malformed price: \(price)")
        }
    }
}
