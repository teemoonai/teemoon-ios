//
//  HonestyFreezeTests.swift
//  teemoonTests
//
//  Freeze item A, "honesty" (the maintainer, 2026-11-08). Each test pins the CONDITION a line must meet in the
//  state that shows it, not its words: the words go through the review page.
//
//  A1: the TLS probe (TLSAttestationVerifier) is a separate, unauthenticated connection to the model node's
//  direct host. The chat itself goes to near.ai's gateway (ConfidentialLanguageModel uses openAIBaseURL), and that
//  connection is not pinned. A line that says the chat's connection ends inside the enclave overclaims.
//  A2: the GPU row is NVIDIA's verdict; it showed the GPU node's Intel TDX text once NVIDIA passed.
//  A3: "signed" (or "attested") action log only once (a) is bound — d5ebaccf's rule, applied everywhere.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Honesty freeze A (2026-11-08)")
struct HonestyFreezeTests {
    private static func summary(nras: NRASVerification? = nil, tls: TLSAttestation? = nil) -> AttestationSummary {
        var record = AttestationRecord.preview
        record.nvidiaPayload = "{}"
        return AttestationSummary(
            attestation: record, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: true, lastE2EEFailReason: nil, verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false, nrasVerification: nras, tlsAttestation: tls)
    }

    /// Phrases that put the chat's own connection inside the enclave.
    private static let chatConnectionClaims = [
        "connection terminates", "terminates in the enclave", "terminates inside", "your connection",
        "your encrypted connection", "ends inside", "into the enclave",
    ]

    // MARK: A1

    /// A verified probe says what was checked and that the chat travels through near.ai's gateway.
    @Test func theSealedTransportRowNeverClaimsTheChatConnectionIsPinned() throws {
        let row = try #require(Self.summary(tls: .verified).tlsRow)
        #expect(row.state == .done)
        let card = [AttestationSummary.transportTitle, AttestationSummary.transportSubtitle,
                    AttestationSummary.transportLabel, row.detail].joined(separator: " ").lowercased()
        for claim in Self.chatConnectionClaims {
            #expect(!card.contains(claim), "the card claims the chat connection: \(claim)")
        }
        #expect(card.contains("gateway"), "the verified card must say the chat goes through near.ai's gateway")
    }

    /// The verification run's TLS section: same condition, in its "why" and every step it can show.
    @Test func theVerificationRunSaysWhatTheProbeChecked() {
        for tls: TLSAttestation? in [nil, .verified, .failed("x"), .inconclusive("y")] {
            guard let section = Self.summary(tls: tls).verificationRun.first(where: { $0.id == "tls" }) else {
                Issue.record("no tls section for \(String(describing: tls))"); continue
            }
            let text = ([section.why] + section.steps.map { $0.label + " " + $0.detail })
                .joined(separator: " ").lowercased()
            for claim in Self.chatConnectionClaims {
                #expect(!text.contains(claim), "\(String(describing: tls)): \(claim)")
            }
            #expect(section.why.lowercased().contains("gateway"), "the why must name the gateway path")
        }
    }

    /// A probe that failed or couldn't finish is about the model node's key, never the chat's connection.
    @Test @MainActor func aTLSProbeFailureNeverSpeaksOfTheChatConnection() {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestation = .preview
        session.gpuAttestation = .verified
        for tls: TLSAttestation in [.failed("live TLS certificate does not match the attested fingerprint"),
                                    .inconclusive("TLS attestation request failed")] {
            session.tlsAttestation = tls
            let reason = session.e2eeDegradedReason ?? ""
            #expect(!reason.isEmpty, "precondition: \(tls) degrades and says why")
            #expect(!reason.lowercased().contains("connection"), "\(tls): \(reason)")
        }
    }

    // MARK: A2

    /// The GPU row's detail is NVIDIA's result in every NVIDIA state — never the GPU node's Intel TDX line.
    @Test func theGPURowIsNVIDIAsResultInEveryState() {
        let states: [NRASVerification?] = [nil, .verified, .failed("NVIDIA attestation verdict: FAIL"),
                                           .inconclusive("NVIDIA attestation service unreachable")]
        for nras in states {
            let s = Self.summary(nras: nras)
            #expect(s.gpuRowDetail == s.nrasDetail, "\(String(describing: nras)): \(s.gpuRowDetail)")
        }
        // A node that sent no NVIDIA evidence says exactly that; the banner keeps S37's reason line.
        #expect(Self.summary(nras: .inconclusive(NRASVerification.evidenceAbsent)).gpuRowDetail
                == AttestationSummary.noNVIDIAEvidence)
        let passed = Self.summary(nras: .verified).gpuRowDetail.lowercased()
        #expect(!passed.contains("tdx"), "\(passed)")
        #expect(passed.contains("nvidia"), "\(passed)")
    }

    // MARK: A3

    private static let unbound: [ActionLogBinding.Result?] = [nil, .notBound, .unchecked,
                                                              .mismatch(.actionsHash), .mismatch(.quote)]

    private static func claimsSigned(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("signed") || l.contains("attested action log")
    }

    /// The measured-config note, the tag-pinned recipe caption and the no-pin notice: "signed" only once bound.
    @Test func signedOnlyOnceBoundInEveryActionLogCaption() {
        let lines: [(String, (ActionLogBinding.Result?) -> String)] = [
            ("measured-config note", TrustScopeText.measuredBindingNote),
            ("recipe caption", TrustScopeText.recipeDeclaresCaption),
            ("no-pin notice", { _ in TrustScopeText.noActionLogDetail }),
        ]
        for (name, line) in lines {
            for b in Self.unbound {
                #expect(!Self.claimsSigned(line(b)), "\(name) under \(String(describing: b)): \(line(b))")
            }
        }
    }

    /// The recipe hash-mismatch banner follows the same rule as the running-mismatch banner beside it.
    @Test @MainActor func theRecipeMismatchBannerSaysSignedOnlyOnceBound() {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestation = .preview
        session.modelLayerVerification = .hashMismatch
        for b in Self.unbound {
            session.trustScope = b.map { TrustScope(binding: $0, boot: .matches) }
            let reason = session.e2eeDegradedReason ?? ""
            #expect(reason.contains("recipe") || reason == TrustScopeText.actionLogBanner,
                    "precondition: the recipe or the binding names the cause")
            #expect(!Self.claimsSigned(reason), "\(String(describing: b)): \(reason)")
        }
    }
}
