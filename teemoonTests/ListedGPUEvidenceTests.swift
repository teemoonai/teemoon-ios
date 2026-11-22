//
//  ListedGPUEvidenceTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A3: every enclave near.ai lists holds the sealed key, so each one's GPU evidence goes to NRAS against
//  the list's nonce, through the session's own GPU check, and the record's GPU verdict is the worst of them.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Every listed enclave's GPU evidence (A3)")
@MainActor
struct ListedGPUEvidenceTests {

    static func enclave(_ payload: String?) -> ModelCandidates.Enclave {
        ModelCandidates.Enclave(instanceID: "i", composeHash: "c", appID: "a", keyProviderID: nil, mrKMS: nil,
                                result: .clean, nvidiaPayload: payload)
    }

    /// The model leg verified (real NVIDIA answer replayed), then `listed` checked against `listNonce`.
    func gpuVerdict(listed: [String?], listNonce: String?, modelPayload: Bool = true,
                    service: NRASService? = nil) async throws -> NRASVerification? {
        let fixture = try NRASServiceTests.loadFixture()
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord(),
                                          nrasService: service ?? fixture.service(response: fixture.responseData))
        session.attestationTask?.cancel()
        var record = AttestationRecord.preview
        record.modelIntelQuote = "04"
        record.nvidiaPayload = modelPayload ? fixture.nvidiaPayload : nil
        record.modelNonce = fixture.requestNonce
        record.modelCandidates = ModelCandidates.Listed(enclaves: listed.map(Self.enclave), nonce: listNonce)
        session.verifyGPU(for: record)
        await session.nrasTask?.value
        return session.gpuAttestation
    }

    @Test func listedEvidenceThatEchoesTheListsNonceVerifies() async throws {
        let f = try NRASServiceTests.loadFixture()
        #expect(try await gpuVerdict(listed: [f.nvidiaPayload, f.nvidiaPayload], listNonce: f.requestNonce) == .verified)
    }

    @Test func aListedEnclavesRejectedEvidenceFailsTheRecord() async throws {
        let f = try NRASServiceTests.loadFixture()
        let verdict = try await gpuVerdict(listed: [f.nvidiaPayload, f.nvidiaPayload], listNonce: String(repeating: "00", count: 32))
        #expect(verdict?.isHardFailure == true, "\(String(describing: verdict))")
        // Audit 1.1.1 A10: the rejection names the listed enclave, in the GPU row and in the reason line.
        #expect(verdict?.reason == "another enclave near.ai lists for this model failed verification.")
        let s = ModelCandidatesGateTests.session(ModelCandidatesGateTests.listed([.clean, .clean]))
        s.gpuAttestation = verdict
        #expect(s.e2eeDegradedReason == "another enclave near.ai lists for this model failed verification.")
        s.gpuAttestation = .failed("NVIDIA rejected the evidence")
        #expect(s.e2eeDegradedReason == "nvidia gpu attestation failed verification.", "the read enclave's own line is unchanged")
    }

    /// Audit 1.1.1 A10: 976543da stored a listed enclave's NVIDIA rejection as the A10 line alone, so NVIDIA's own
    /// reason for that enclave was lost. Only the expert GPU row adds it back; every other line stays the A10 line.
    @Test func theExpertGPURowKeepsNVIDIAsReasonBesideAListedEnclavesLine() async throws {
        let f = try NRASServiceTests.loadFixture()
        let badNonce = String(repeating: "00", count: 32)
        let nvidia = await f.service(response: f.responseData).verify(payloadJSON: f.nvidiaPayload, expectedNonceHex: badNonce)
        let nvidiaReason = try #require(nvidia.reason)
        #expect(nvidia.isHardFailure, "\(nvidia)")
        let a10 = "another enclave near.ai lists for this model failed verification."
        let verdict = try #require(try await gpuVerdict(listed: [f.nvidiaPayload], listNonce: badNonce))
        #expect(verdict.isHardFailure)
        #expect(verdict.reason == a10, "the verdict's reason stays the A10 line")

        let s = ModelCandidatesGateTests.session(ModelCandidatesGateTests.listed([.clean]))
        s.gpuAttestation = verdict
        #expect(s.e2eeDegradedReason == a10, "the everyday reason line is exactly the A10 line")

        var record = AttestationRecord.preview
        record.nvidiaPayload = "{}"
        func summary(_ nras: NRASVerification) -> AttestationSummary {
            AttestationSummary(
                attestation: record, state: .degraded, timedOut: false, provider: .nearAI,
                lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
                attestationFetchFailed: false, nrasVerification: nras)
        }
        let listed = summary(verdict)
        #expect(listed.nrasState == .stuck)
        #expect(listed.gpuRowDetail.contains(a10), "\(listed.gpuRowDetail)")
        #expect(listed.gpuRowDetail.contains(nvidiaReason), "expert keeps NVIDIA's reason: \(listed.gpuRowDetail)")
        #expect(listed.nrasDetail == a10, "outside the expert GPU row the line is the A10 line alone")

        // The read enclave's own GPU failure is unchanged.
        let own = summary(nvidia)
        #expect(own.gpuRowDetail == nvidiaReason)
        s.gpuAttestation = nvidia
        #expect(s.e2eeDegradedReason == "nvidia gpu attestation failed verification.")
    }

    @Test func aListedEnclaveWithNoEvidenceCouldNotBeChecked() async throws {
        let f = try NRASServiceTests.loadFixture()
        let verdict = try await gpuVerdict(listed: [f.nvidiaPayload, nil], listNonce: f.requestNonce)
        #expect(verdict == .listedInconclusive(nvidia: NRASVerification.evidenceAbsent))
        #expect(verdict?.reason == Self.unfinished, "never the read enclave's evidence-absent line")
    }

    static let unfinished = "teemoon couldn't finish checking the enclaves near.ai listed."
    static let unreachable = "NVIDIA attestation service unreachable"

    /// NVIDIA answers the read enclave's evidence and is unreachable for the listed one's (marked by a leading space).
    struct ListedLegUnreachable: NRASHTTPClient {
        let response: Data
        func post(_ url: URL, body: Data) async throws -> Data {
            if body.first == UInt8(ascii: " ") { throw NRASServiceTests.StubHTTP.Unreachable() }
            return response
        }
    }

    /// Audit 1.1.1 A10 (2026-11-20): a listed enclave's unreachable NVIDIA check read exactly like the read enclave's
    /// ("nvidia gpu attestation couldn't be completed (service unreachable)."). It names the listed enclaves (A7's
    /// unfinished line), asks, and only the expert GPU row adds NVIDIA's reason.
    @Test func aListedEnclavesUnreachableNVIDIANamesTheListedEnclaves() async throws {
        let f = try NRASServiceTests.loadFixture()
        let when = Date(timeIntervalSince1970: f.verifiedAt)
        let service = NRASService(http: ListedLegUnreachable(response: f.responseData),
                                  keys: NRASServiceTests.StaticKeys(data: f.jwksData), now: { when })
        let verdict = try #require(try await gpuVerdict(listed: [" " + f.nvidiaPayload], listNonce: f.requestNonce, service: service))
        #expect(!verdict.isHardFailure && !verdict.isVerified && verdict.isUnverified, "\(verdict)")
        #expect(verdict.reason == Self.unfinished, "\(verdict)")

        let s = ModelCandidatesGateTests.session(ModelCandidatesGateTests.listed([.clean]))
        s.gpuAttestation = verdict
        #expect(s.e2eeDegradedReason == Self.unfinished)
        #expect(s.sendPolicy == .confirm, "soft: asks, never blocks")
        #expect(!s.degradeIsHardFailure)

        var record = AttestationRecord.preview
        record.nvidiaPayload = "{}"
        let summary = AttestationSummary(
            attestation: record, state: .degraded, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false, nrasVerification: verdict)
        #expect(summary.nrasState == .unchecked)
        #expect(summary.nrasDetail == Self.unfinished, "outside the expert GPU row the line is the A7 line alone")
        #expect(summary.gpuRowDetail == "\(Self.unfinished) \(Self.unreachable)", "\(summary.gpuRowDetail)")

        // The read enclave's own unreachable NVIDIA keeps its line, and wins a tie with a listed one's.
        s.gpuAttestation = .inconclusive(Self.unreachable)
        #expect(s.e2eeDegradedReason == "nvidia gpu attestation couldn't be completed (service unreachable).")
        #expect(s.sendPolicy == .confirm)
        #expect(try await gpuVerdict(listed: [f.nvidiaPayload], listNonce: f.requestNonce, service: f.service(response: nil))
                == .inconclusive(Self.unreachable))
    }

    @Test func listedEvidenceDoesNotStandInForTheModelLegs() async throws {
        let f = try NRASServiceTests.loadFixture()
        #expect(try await gpuVerdict(listed: [f.nvidiaPayload], listNonce: f.requestNonce, modelPayload: false)
                == .inconclusive(NRASVerification.evidenceAbsent))
    }

    @Test func theWorstVerdictWins() {
        #expect(NRASVerification.worst([.verified, .inconclusive("a"), .failed("b")]) == .failed("b"))
        #expect(NRASVerification.worst([.verified, .inconclusive("a")]) == .inconclusive("a"))
        #expect(NRASVerification.worst([.verified, .verified]) == .verified)
        #expect(NRASVerification.worst([]) == nil)
        // A listed couldn't-check is soft: any failure beats it, and the read enclave's own couldn't-check wins the tie.
        let listedSoft = NRASVerification.listedInconclusive(nvidia: "x")
        #expect(NRASVerification.worst([.verified, listedSoft]) == listedSoft)
        #expect(NRASVerification.worst([listedSoft, .listedFailed(nvidia: "y")]) == .listedFailed(nvidia: "y"))
        #expect(NRASVerification.worst([listedSoft, .failed("b")]) == .failed("b"))
        #expect(NRASVerification.worst([listedSoft, .inconclusive("a")]) == .inconclusive("a"))
    }
}
