//
//  EnclaveListAskTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A8 (card trust-copy-sweep-111 v4): when near.ai's list of enclaves failed and nothing is in flight, the
//  send asks to re-verify the list — not "still checking … wait", which waited on nothing — and re-verify asks for it.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("The failed enclave-list ask (A8)")
struct EnclaveListAskTests {

    /// The ask exactly as ChatView builds it, with no settle-timeout ask up.
    static func ask(_ s: ConfidentialSession) -> E2EEAsk {
        E2EEAsk.make(hardFailure: s.degradeIsHardFailure, pendingAsk: nil, provenanceUnchecked: s.provenanceUncheckedAsks,
                     softButSealed: s.softButSealed, provenanceBlocked: s.provenanceBlockedButE2EEIntact,
                     cause: s.e2eeDegradedReason, deadlinePassed: s.deadlinePassed,
                     enclaveListFailed: s.enclaveListFailedAsks)
    }

    /// The gate's verified session on a model of its own whose near.ai tier is known: an unknown tier is itself a
    /// check in flight, and a tier recorded for the shared preview model would leak into other suites.
    static func session(_ candidates: ModelCandidates.Listed?, listFailed: Bool = false) -> ConfidentialSession {
        let model = "zai-org/A8-LIST-PROBE"
        var provider = Provider.nearAI
        provider.model = model
        provider.requiresAPIKey = false
        let store = ProviderStore(inMemory: true)
        store.addProvider(provider)
        store.currentProviderID = provider.id.uuidString
        NearAIModelCatalog.recordTiers([model: .teeOwn])
        let s = ConfidentialSession(providers: store)
        s.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.model = model
        record.modelCandidates = candidates
        record.modelCandidatesListFailed = listFailed
        s.attestation = record
        s.lastRequestUsedE2EE = true
        s.imageProvenance = .allVerified(verified: [], thirdParty: [])
        s.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = SendGateRuleTests.upToDate; dcap.model = SendGateRuleTests.upToDate
        s.dcapVerification = dcap
        s.gpuAttestation = .verified
        s.tlsAttestation = .verified
        s.trustScope = TrustScope(binding: .bound, boot: .matches)
        return s
    }

    @Test func aFailedListAsksToReverifyWithTheExistingButtons() {
        let s = Self.session(nil, listFailed: true)
        #expect(!s.verdictsPending)
        #expect(s.e2eeDegradedReason == "teemoon couldn't load near.ai's list of enclaves for this model.")
        #expect(s.enclaveListFailedAsks, "in flight: \(s.attestationFetchInFlight), sealed: \(s.softButSealed)")
        #expect(s.sendPolicy == .confirm)
        let ask = Self.ask(s)
        #expect(ask.title == "couldn't load near.ai's list of enclaves")
        #expect(ask.message == "your message would still be sealed to the model's key, but teemoon couldn't check the other enclaves near.ai lists for this model, which hold the same key. retry verification to ask near.ai for the list again.")
        #expect(ask.choices == [.retryVerification, .sendSealedUnconfirmed, .dontSend])
        #expect(ask.choices.map(\.label) == ["retry verification", "send anyway", "don't send"])
    }

    /// Something still in flight, or a worse soft cause named first: the existing asks, unchanged.
    @Test func otherwiseTheExistingAsksStand() {
        let pending = Self.session(nil, listFailed: true)
        pending.gpuAttestation = nil
        pending.nrasTask = Task { try? await Task.sleep(for: .seconds(30)) }
        #expect(pending.verdictsPending)
        defer { pending.nrasTask?.cancel() }
        #expect(!pending.enclaveListFailedAsks)
        #expect(Self.ask(pending).title == E2EESendChoice.stillCheckingTitle)

        let intel = Self.session(nil, listFailed: true)
        intel.dcapVerification?.model = .unchecked("collateral: pcs unreachable")
        #expect(!intel.enclaveListFailedAsks)
        #expect(Self.ask(intel).title == E2EESendChoice.stillCheckingTitle)

        let refetching = Self.session(nil, listFailed: true)
        refetching.attestationFetchInFlight = true
        refetching.attestationTask = Task { try? await Task.sleep(for: .seconds(30)) }
        defer { refetching.attestationTask?.cancel() }
        #expect(!refetching.enclaveListFailedAsks, "a re-verify in flight is something to wait for")

        let clean = Self.session(ModelCandidatesGateTests.listed([.clean]))
        #expect(!clean.enclaveListFailedAsks)
    }

    /// Re-verify (`refreshAttestation`, what "retry verification" runs) fetches the record again, and the record fetch
    /// asks near.ai for the list again: counted on the wire.
    @Test func reverifyAsksNearAIForTheListAgain() async throws {
        let wire = CandidateListFetchTests.Stub { n in n == 1 ? (404, Data()) : (200, CandidateListFetchTests.body(entries: 1)) }
        let s = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord(),
                                    dcapService: DCAPService(collateral: Offline()),
                                    nrasService: NRASService(http: Offline()))
        s.attestationTask?.cancel()
        s.freezeAttestationFixtures = true
        s.directBase = { _ in nil }
        s.fetchRecord = { provider, base, apiKey in
            var record = AttestationRecord.preview
            // AttestationService.fetch's list step, through the same calls.
            if let (body, nonce) = await AttestationService.candidateList(baseURL: base, model: provider.model,
                                                                          apiKey: apiKey, http: wire) {
                record.modelCandidates = AttestationService.adoptCandidates(body: body, nonce: nonce,
                                                                            sealedKey: record.modelEd25519PubKey ?? Data())
            }
            record.modelCandidatesListFailed = record.modelCandidates == nil
            return record
        }
        s.refreshAttestation()
        #expect(try await Self.until { s.attestation?.modelCandidatesListFailed == true })
        #expect(wire.requests.count == 1)

        s.refreshAttestation()
        #expect(try await Self.until { s.attestation?.modelCandidatesListFailed == false })
        #expect(wire.requests.count == 2, "re-verify did not ask for the list again")
        s.clearDerivedState(resetCounts: true)
    }

    /// The verifiers the adopted record starts stay off the network.
    struct Offline: CollateralProvider, NRASHTTPClient {
        func collateralJSON(forQuote rawQuote: Data) async throws -> Data { throw URLError(.notConnectedToInternet) }
        func post(_ url: URL, body: Data) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    static func until(_ seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
