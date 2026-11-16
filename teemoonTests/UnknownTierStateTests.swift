//
//  UnknownTierStateTests.swift
//  teemoonTests
//
//  With the near.ai tier still unknown, a session whose every verdict verified must not read .ok: the chip would say
//  "end-to-end encrypted" while the tier could still resolve to third-party (and the send go out plain). It reads
//  .verifying until the tier is known attested.
//

import Foundation
import Testing
@testable import teemoon

@Suite("An unknown tier never reads verified")
@MainActor struct UnknownTierStateTests {

    private func verifiedSession(model: String) -> ConfidentialSession {
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        let session = ConfidentialSession(providers: store)
        session.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.model = model
        session.attestation = record
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        let ok = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")
        var dcap = RecordDCAPVerification()
        dcap.gateway = ok; dcap.model = ok
        session.dcapVerification = dcap
        session.gpuAttestation = .verified
        session.tlsAttestation = .verified
        session.trustScope = TrustScope(binding: .bound, boot: .matches)
        return session
    }

    @Test func everyVerdictVerifiedButTheTierUnknownReadsVerifying() {
        let model = "zai-org/S1-UNKNOWN-TIER-PROBE"
        let session = verifiedSession(model: model)
        NearAIModelCatalog.$tierListSeenOverride.withValue(false) {
            #expect(NearAIModelCatalog.confidentiality(forID: model) == .unknown, "precondition: the tier is unknown")
            // S30: every verdict answered, yet the unknown tier holds the send like a verdict still running.
            #expect(session.pendingKind == .hardware, "an unknown tier does not hold the send")
            #expect(session.attestationState == .verifying, "read \(session.attestationState) with the tier unknown")
        }
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        #expect(session.attestationState == .ok, "the tier resolved attested; \(session.attestationState)")
    }
}
