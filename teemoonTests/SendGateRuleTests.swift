//
//  SendGateRuleTests.swift
//  teemoonTests
//
//  near-send-gate-rule (the maintainer 2026-11-06), run from conformance/sendgate.json so android holds the same table:
//  outages (Intel PCS, NVIDIA, the TLS probe, GitHub, near.ai) ask or pass, never block; every evidence case
//  blocks; a seal-holding soft state never reaches "send without encryption"; the audits index never gates.
//

import Foundation
import Testing
import TDXQuoteVerifier
@testable import teemoon

@Suite("The send gate blocks only on evidence")
@MainActor
struct SendGateRuleTests {
    struct Vectors: Decodable {
        struct Vector: Decodable { let name: String; let change: [String: String]; let policy: String; let alert: String; let reasonLine: String? }
        struct Timeout: Decodable { let name: String; let sealed: Bool; let accepted: Bool; let outcome: String }
        struct PCSStatus: Decodable { let endpoint: String; let status: Int; let `class`: String }
        struct NRASTLSCase: Decodable { let check: String; let `case`: String; let `class`: String }
        let vectors: [Vector]
        let settleTimeout: [Timeout]
        struct Scope: Decodable {
            struct Key: Decodable, Equatable { let record: String; let reason: String }
            struct Gate: Decodable { let record: String; let reason: String; let policy: String; let pending: Bool; let sealed: Bool }
            let name: String; let confirmed: Key; let gate: Gate; let outcome: String
        }
        let confirmScope: [Scope]
        struct PendingSource: Decodable { let name: String; let pending: [String]; let ask: String; let confirmReason: String }
        let pendingSources: [PendingSource]
        let pcsStatus: [PCSStatus]
        let nrasTlsCases: [NRASTLSCase]
    }

    static func vectors(file: String = #filePath) throws -> Vectors? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/sendgate.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    /// The path each kit endpoint name stands for, as URL.path gives it.
    static let pcsPath = ["tcb": "/tdx/certification/v4/tcb", "pckcrl": "/sgx/certification/v4/pckcrl",
                          "qeIdentity": "/tdx/certification/v4/qe/identity", "rootCrl": "/IntelSGXRootCA.der"]
    static let pcsURLMark = ["tcb": "/tcb?", "pckcrl": "/pckcrl?", "qeIdentity": "/qe/identity", "rootCrl": "RootCA.der"]

    static let upToDate = DCAPVerification.verified(tcbStatus: .upToDate, mrConfigIdHex: "", reportDataHex: "")

    /// The baseline, then the vector's one change.
    private func session(_ change: [String: String]) -> ConfidentialSession {
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.attestation = .preview
        session.lastRequestUsedE2EE = true
        session.imageProvenance = .allVerified(verified: [], thirdParty: [])
        session.provenanceSettled = true
        var dcap = RecordDCAPVerification()
        dcap.gateway = Self.upToDate; dcap.model = Self.upToDate
        session.gpuAttestation = .verified
        session.tlsAttestation = .verified
        var scope = TrustScope(binding: .bound, boot: .matches)
        let src = ActionLogReading.Source(commit: "c", file: "f", fileSHA256: "s")
        let svc = ActionLogReading.RunningService(service: "proxy", source: src, tag: nil, since: nil)
        for (key, value) in change {
            switch (key, value) {
            case ("dcap", "unchecked"): dcap.model = .unchecked("collateral: pcs unreachable")
            case ("dcap", "failed"): dcap.model = .failed("signature invalid")
            case ("pcs", let answer):
                let parts = answer.split(separator: ":").map(String.init)
                let error = CollateralHTTPError(status: Int(parts[1])!, host: "api.trustedservices.intel.com",
                                                path: Self.pcsPath[parts[0]]!)
                dcap.model = DCAPVerifier.couldntCheck(error) ? .unchecked("collateral: \(error)") : .failed("collateral: \(error)")
            case ("listedDcap", "failed"): dcap.listed = [Self.upToDate, .failed("signature invalid")]
            case ("listedDcap", "unchecked"): dcap.listed = [Self.upToDate, .unchecked("collateral: pcs unreachable")]
            case ("dcap", "revoked"): dcap.model = .verified(tcbStatus: .revoked, mrConfigIdHex: "", reportDataHex: "")
            case ("nras", "inconclusive"): session.gpuAttestation = .inconclusive("NRAS unreachable")
            case ("nras", "failed"): session.gpuAttestation = .failed("NVIDIA rejected the evidence")
            case ("nras", "malformed"): session.gpuAttestation = .failed("GPU evidence payload unparseable")
            case ("nras", "teemoon"): session.gpuAttestation = .inconclusive(NRASVerification.teemoonFault)
            case ("tls", "inconclusive"): session.tlsAttestation = .inconclusive("probe unreachable")
            case ("tls", "failed"): session.tlsAttestation = .failed("fingerprint mismatch")
            case ("tls", "malformed"): session.tlsAttestation = .failed("attestation response missing TLS fields")
            case ("tls", "teemoon"): session.tlsAttestation = .inconclusive(NRASVerification.teemoonFault)
            case ("binding", "unchecked"): scope.binding = .unchecked
            case ("binding", "mismatch"): scope.binding = .mismatch(.actionsHash)
            case ("boot", "mismatch"): scope.boot = .mismatch(.rtmr3)
            case ("running", let outcome):
                scope.running = [.init(service: svc, outcome: RunningPairCheck.Outcome(rawValue: outcome)!)]
            case ("refetch", "failedStale"):
                session.attestationFetchFailed = true
                let fetched = AttestationRecord.preview.fetchedAt
                session.now = { fetched.addingTimeInterval(ConfidentialSession.attestationMaxAge + 1) }
            case ("image", "unpublished"):
                let ref = ProvenanceService.ImageRef(image: "nearaidev/compose-manager-launcher", digest: String(repeating: "a", count: 64))
                session.imageProvenance = .incomplete(verified: [], failures: [.init(ref: ref, reason: .unverified(.fetchFailed("HTTP 404")))],
                                                      thirdParty: [])
            case ("image", "inconclusive"):
                session.imageProvenance = nil
                session.provenanceInconclusive = true
            case ("recipe", "mismatch"): session.modelLayerVerification = .hashMismatch
            // S37: each through the check itself, on today's glm-5.3-flash quotes.
            case ("quote", "debug"):
                let quote = (try! LiveGLM53Reports.load()).model["intel_quote"] as! String
                dcap.model = .failed(QuoteChecks.failure(quoteHex: LiveGLM53Reports.withDebugBit(quote))!)
            case ("reportData", "mismatch"):
                let gw = (try! LiveGLM53Reports.load()).gatewayLeg
                dcap.gateway = .failed(QuoteChecks.failure(quoteHex: gw["intel_quote"] as! String,
                                                           advertisedReportData: LiveGLM53Reports.flipped(gw["report_data"] as! String))!)
            case ("modelMrConfig", "mismatch"):
                var record = AttestationRecord.preview
                record.modelComposeManifest = "services: {}"
                session.attestation = record
            case ("modelQuote", "absent"):
                session.attestation = Self.keyWithNoQuote()
            case ("nras", "absent"):
                var record = AttestationRecord.preview
                record.modelIntelQuote = "aa"
                record.nvidiaPayload = nil
                session.attestation = record
                session.verifyGPU(for: record)
            // C3: the listed enclaves (ModelCandidatesTests runs the checks themselves on the live list).
            case ("candidates", let kind):
                var record = AttestationRecord.preview
                if kind == "listFailed" { record.modelCandidatesListFailed = true } else {
                    let bad = ModelCandidates.Mismatch(rawValue: kind) ?? .mrConfig   // "mismatch": any check
                    record.modelCandidates = ModelCandidatesGateTests.listed([.clean, .mismatch(bad), .clean])
                }
                session.attestation = record
            // A4: a listed enclave's trust scope (ListedTrustScopeTests runs TrustScope.run on the live list).
            case ("listedScope", let kind):
                let bad: TrustScope? = switch kind {
                case "bindingMismatch": TrustScope(binding: .mismatch(.actionsHash), boot: .matches)
                case "bootMismatch": TrustScope(binding: .bound, boot: .mismatch(.rtmr3))
                case "bindingUnchecked": TrustScope(binding: .unchecked, boot: .matches)
                case "bootAbsent": TrustScope(binding: .bound, boot: .absent)
                default: nil
                }
                if bad == nil { Issue.record("unknown listedScope \(kind)") }
                session.listedTrustScopes = [TrustScope(binding: .bound, boot: .matches)] + (bad.map { [$0] } ?? [])
            case ("audit", "leaks"): break   // nothing in the gate reads the audits index: see below
            default: Issue.record("unknown change \(key)=\(value)")
            }
        }
        session.dcapVerification = dcap
        session.trustScope = scope
        return session
    }

    private func alert(_ s: ConfidentialSession) -> String {
        switch s.sendPolicy {
        case .allow: "none"
        case .block: "blocked"
        case .confirm: s.provenanceUncheckedAsks ? "provenanceUnchecked" : s.softButSealed ? "stillChecking" : "unavailable"
        }
    }

    /// The preview record with its model key kept and no model quote: what a report with a key and no readable quote parses to.
    static func keyWithNoQuote() -> AttestationRecord {
        var record = AttestationRecord.preview
        record.modelQuoteVerification = nil
        record.modelIntelQuote = nil
        return record
    }

    /// Audit v1.1.0-6c5f7a2 LOW: a key no quote proves blocks, and is never the "still checking" ask with send anyway.
    @Test func aModelKeyWithNoQuoteBlocks() {
        let s = session(["modelQuote": "absent"])
        #expect(s.attestation?.modelEd25519PubKey?.count == 32)
        #expect(s.degradeIsHardFailure)
        #expect(s.sendPolicy == .block)
        #expect(s.e2eeDegradedReason == "the encryption key isn't bound to verified hardware.")
    }

    /// Audit 1.1.1: a listed enclave whose quote is signed by a key it carries itself blocks the send, through the gate.
    @Test func aForgedListedEnclaveBlocks() throws {
        let f = try ForgedSibling.load()
        let s = session([:])
        #expect(s.sendPolicy == .allow)
        var record = s.attestation!
        record.modelCandidates = ModelCandidates.enclaves(body: f.listBody, nonce: f.nonce, sealedKey: f.sealedKey)
        s.attestation = record
        #expect(s.sendPolicy == .block)
        #expect(s.degradeIsHardFailure)
    }

    /// Audit 1.1.1: a listed enclave's DCAP verdict gates like the model leg's: failure blocks, couldn't-check asks.
    @Test func aListedEnclavesDCAPGatesLikeTheModelLegs() {
        let failed = session(["listedDcap": "failed"])
        #expect(failed.sendPolicy == .block)
        #expect(failed.degradeIsHardFailure)
        let unchecked = session(["listedDcap": "unchecked"])
        #expect(unchecked.sendPolicy == session(["dcap": "unchecked"]).sendPolicy)
        #expect(!unchecked.degradeIsHardFailure)
    }

    /// Audit 1.1.1 / release handoff (b): the forged quote as the read enclave's own, Intel unreachable. The local
    /// parse must refuse it, so the send blocks instead of asking "still checking" with send anyway.
    @Test func aForgedFirstEnclaveBlocksWhileIntelCannotBeReached() throws {
        let f = try ForgedSibling.load()
        let s = session(["dcap": "unchecked"])
        #expect(s.sendPolicy != .block)   // Intel unreachable alone asks
        let p = AttestationRecord.preview
        var record = AttestationRecord(
            composeHash: p.composeHash, mrtd: p.mrtd, osImageHash: p.osImageHash, modelOSImageHash: p.modelOSImageHash,
            intelQuote: p.intelQuote, composeManifest: p.composeManifest, gpuArch: p.gpuArch,
            gpuNodeComposeHash: p.gpuNodeComposeHash, gpuNodeComposeManifest: p.gpuNodeComposeManifest,
            modelFileHash: p.modelFileHash, modelComposePath: p.modelComposePath, modelComposeCommit: p.modelComposeCommit,
            modelComposeTag: p.modelComposeTag, modelDeployedAt: p.modelDeployedAt,
            modelPreviouslyDeployedAt: p.modelPreviouslyDeployedAt, signingAddress: p.signingAddress,
            gpuSigningAddress: p.gpuSigningAddress, modelEd25519PubKey: f.sealedKey,
            quoteVerification: p.quoteVerification, gpuQuoteVerification: p.gpuQuoteVerification,
            modelQuoteVerification: try TDXQuoteVerifier.verify(quoteHex: f.quoteHex),
            fetchedAt: p.fetchedAt, providerID: p.providerID, model: p.model)
        record.modelIntelQuote = f.quoteHex
        // The forged quote carries the record's own key and our nonce: only the QE binding can refuse it.
        #expect(record.e2eeKeyInModelReportData == true)
        s.attestation = record
        #expect(record.e2eeKeyBoundToModelTEE == false)
        #expect(s.sendPolicy == .block)
        #expect(s.degradeIsHardFailure)
    }

    @Test func everyVectorGivesItsPolicyAndAlert() throws {
        guard let v = try Self.vectors() else { return }
        #expect(v.vectors.count >= 16)
        for vector in v.vectors {
            let s = session(vector.change)
            let policy: String = switch s.sendPolicy { case .allow: "allow"; case .confirm: "confirm"; case .block: "block" }
            #expect(policy == vector.policy, "\(vector.name): \(policy)")
            #expect(alert(s) == vector.alert, "\(vector.name): \(alert(s))")
            if let line = vector.reasonLine { #expect(s.e2eeDegradedReason == line, "\(vector.name): \(s.e2eeDegradedReason ?? "nil")") }
        }
    }

    @Test func aSealHoldingSoftStateNeverOffersSendUnencrypted() throws {
        guard let v = try Self.vectors() else { return }
        for vector in v.vectors where vector.policy == "confirm" {
            let s = session(vector.change)
            #expect(s.currentTEEContext()?.e2eePeer != nil, "\(vector.name): precondition, the send would be sealed")
            #expect(alert(s) != "unavailable", "\(vector.name) reached 'end-to-end encryption unavailable · send without encryption'")
        }
    }

    /// F4: a confirmation counts only for the (record, reason) the gate reads after prepareTurn.
    @Test func aConfirmationIsScopedToItsRecordAndReason() throws {
        guard let v = try Self.vectors() else { return }
        #expect(v.confirmScope.count >= 6)
        for row in v.confirmScope {
            let accepted = row.confirmed == .init(record: row.gate.record, reason: row.gate.reason)
            let policy: TrustSendPolicy = switch row.gate.policy { case "block": .block; case "confirm": .confirm; default: .allow }
            let got = ChatViewModel.postPrepare(policy: policy, acceptedDegrade: accepted,
                                                verdictsPending: row.gate.pending, sealed: row.gate.sealed)
            let name: String = switch got { case .proceed: "proceed"; case .confirmPending: "confirmPending"; case .refuse: "refuse" }
            #expect(name == row.outcome, "\(row.name): \(name)")
        }
    }

    /// S30 (sendgate.json 0.6.0 pendingSources): each pending kind holds the send; provenance alone asks its own
    /// question and is confirmed as "provenancePending", any hardware kind as "pending".
    @Test func everyPendingSourceHoldsTheSendAndAsksItsQuestion() async throws {
        guard let v = try Self.vectors() else { return }
        #expect(v.pendingSources.count >= 4)
        for source in v.pendingSources {
            let model = "zai-org/S30-PENDING-\(source.name)"
            var provider = Provider.nearAI
            provider.model = model
            let store = ProviderStore(inMemory: true)
            store.addProvider(provider)
            store.currentProviderID = provider.id.uuidString
            let tierKnown = !source.pending.contains("tier")
            if tierKnown { NearAIModelCatalog.recordTiers([model: .teeOwn]) }
            let live = ConfidentialSession(providers: store)
            live.attestationTask?.cancel()
            var record = AttestationRecord.preview
            record.model = model
            live.attestation = record
            live.lastRequestUsedE2EE = true
            live.imageProvenance = .allVerified(verified: [], thirdParty: [])
            live.provenanceSettled = true
            var dcap = RecordDCAPVerification()
            dcap.gateway = Self.upToDate; dcap.model = Self.upToDate
            live.dcapVerification = dcap
            live.gpuAttestation = .verified
            live.tlsAttestation = .verified
            live.trustScope = TrustScope(binding: .bound, boot: .matches)
            var held: [Task<Void, Never>] = []
            defer { held.forEach { $0.cancel() } }
            for kind in source.pending {
                switch kind {
                case "hardware":
                    live.tlsAttestation = nil
                    let t = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
                    held.append(t); live.tlsTask = t
                case "staleRefetch":
                    let fetched = record.fetchedAt
                    live.now = { fetched.addingTimeInterval(ConfidentialSession.attestationMaxAge + 1) }
                    let t = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
                    held.append(t); live.attestationTask = t
                    live.attestationFetchInFlight = true
                case "provenance":
                    live.imageProvenance = nil
                    live.provenanceSettled = false
                    let t = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
                    held.append(t); live.provenanceTask = t
                case "tier": break
                default: Issue.record("unknown pending kind \(kind)")
                }
            }
            NearAIModelCatalog.$tierListSeenOverride.withValue(tierKnown ? nil : false) {
                #expect(live.sendPending, "\(source.name): nothing reads pending")
                let ask = E2EEAsk.make(hardFailure: false, pendingAsk: live.pendingKind, provenanceUnchecked: false,
                                       softButSealed: live.softButSealed, provenanceBlocked: false, cause: nil)
                let askName = ask.title == E2EESendChoice.provenancePendingTitle ? "provenancePending"
                    : ask.title == E2EESendChoice.stillCheckingTitle ? "stillChecking" : ask.title
                #expect(askName == source.ask, "\(source.name): asked \(askName)")
                #expect(ask.choices.map(\.label) == ["send anyway", "wait"], "\(source.name)")
                live.rememberConfirmation(pending: true, answering: .verification)
                let key = live.confirmationKey(pending: true) ?? ""
                #expect(key.hasSuffix("|\(source.confirmReason)"), "\(source.name): confirmed as \(key)")
                #expect(live.hasConfirmed(pending: true))
            }
        }
    }

    @Test func theSettleTimeoutAsksOnlyWhenTheSendWouldBeSealed() throws {
        guard let v = try Self.vectors() else { return }
        for t in v.settleTimeout {
            let got = ChatViewModel.postPrepare(policy: .allow, acceptedDegrade: t.accepted, verdictsPending: true, sealed: t.sealed)
            let name: String = switch got { case .proceed: "proceed"; case .confirmPending: "confirmPending"; case .refuse: "refuse" }
            #expect(name == t.outcome, "\(t.name): \(name)")
        }
        #expect(ChatViewModel.postPrepare(policy: .block, acceptedDegrade: true, verdictsPending: true, sealed: true) != .proceed,
                "evidence still blocks at the timeout")
    }

    /// The maintainer 2026-11-06 "yes block": Intel's 404 for a platform it doesn't know is evidence, so a forged quote
    /// with an unregistered FMSPC never reaches "send anyway". Every status is pinned so android agrees.
    @Test func everyIntelStatusHasItsClass() async throws {
        guard let v = try Self.vectors() else { return }
        let snapshot = try CollateralServiceTests.loadSnapshot()
        /// The snapshot answers every request except the one endpoint, which gets the status.
        struct OneFails: CollateralHTTPClient {
            let ok: CollateralServiceTests.StubHTTP
            let mark: String
            let status: Int
            func get(_ url: URL) async throws -> (body: Data, headers: [String: String]) {
                guard url.absoluteString.contains(mark) else { return try await ok.get(url) }
                if status < 0 { throw URLError(.timedOut) }
                throw CollateralHTTPError(status: status, host: url.host ?? "", path: url.path)
            }
        }
        #expect(v.pcsStatus.contains { $0.endpoint == "tcb" && $0.status == 404 && $0.class == "hard" })
        for row in v.pcsStatus {
            let http = OneFails(ok: .init(responses: snapshot.responses), mark: Self.pcsURLMark[row.endpoint]!, status: row.status)
            let verifier = DCAPVerifier(collateral: IntelPCSCollateralProvider(http: http))
            let result = await verifier.verify(quoteHex: snapshot.quoteHex, nowSecs: snapshot.nowSecs)
            let got = result.isUnchecked ? "unchecked" : result.isHardFailure ? "hard" : "\(result)"
            #expect(got == row.class, "\(row.endpoint) \(row.status): \(got)")
        }
    }

    /// near-gate-nvidia-tls-split (the maintainer 2026-11-06): each case run through the real verifier lands in its class.
    /// outage = soft with its own reason, evidence = hard, teemoon = soft with the approved fault line.
    @Test func everyNVIDIAAndTLSCaseHasItsClass() async throws {
        guard let v = try Self.vectors() else { return }
        let nras = try NRASServiceTests.loadFixture()
        let tls = try TLSAttestationVerifierTests.load()
        func nrasResult(_ name: String) async -> NRASVerification? {
            switch name {
            case "nras-unreachable":
                return await nras.service(response: nil).verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nras.requestNonce)
            case "jwks-unreachable":
                let when = Date(timeIntervalSince1970: nras.verifiedAt)
                return await NRASService(http: NRASServiceTests.StubHTTP(response: nras.responseData),
                                         keys: NRASServiceTests.StaticKeys(data: nil), now: { when })
                    .verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nras.requestNonce)
            case "payload-unparseable":
                return await nras.service(response: nras.responseData).verify(payloadJSON: "not json", expectedNonceHex: nras.requestNonce)
            case "response-unrecognised":
                return await nras.service(response: Data("{}".utf8)).verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nras.requestNonce)
            case "token-unrecognised":
                return await nras.service(response: Data(#"[["JWT","not-a-token"],{}]"#.utf8))
                    .verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nras.requestNonce)
            case "signing-key-unknown-after-refetch":
                let when = Date(timeIntervalSince1970: nras.verifiedAt)
                let keys = CountingKeys(data: Data(#"{"keys":[]}"#.utf8))
                let r = await NRASService(http: NRASServiceTests.StubHTTP(response: nras.responseData), keys: keys, now: { when })
                    .verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nras.requestNonce)
                #expect(keys.refreshes.value == 1, "NVIDIA's key set is refetched once before giving up")
                return r
            case "nonce-not-recorded":
                return await nras.service(response: nras.responseData).verify(payloadJSON: nras.nvidiaPayload, expectedNonceHex: nil)
            case "payload-absent":
                var record = AttestationRecord.preview
                record.modelIntelQuote = "aa"
                record.nvidiaPayload = nil
                let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
                session.attestationTask?.cancel()
                session.verifyGPU(for: record)
                return session.gpuAttestation
            default: return nil
            }
        }
        func tlsResult(_ name: String) -> TLSAttestation? {
            switch name {
            case "response-missing-fields":
                return TLSAttestationVerifier.verifyResponse(Data(#"{"signing_address":"0x00"}"#.utf8), liveCertDER: tls.certDER, nonceHex: tls.nonce).0
            case "quote-unparseable":
                return TLSAttestationVerifier.verifyBindings(quoteHex: "00", signingAddress: tls.signingAddress, signingAlgo: tls.signingAlgo,
                                                             tlsCertFingerprintHex: tls.tlsCertFingerprint, liveCertDER: tls.certDER, nonceHex: tls.nonce)
            case "address-or-fingerprint-encoding":
                return TLSAttestationVerifier.verifyBindings(quoteHex: tls.intelQuote, signingAddress: "0xzz", signingAlgo: tls.signingAlgo,
                                                             tlsCertFingerprintHex: tls.tlsCertFingerprint, liveCertDER: tls.certDER, nonceHex: tls.nonce)
            case "certificate-not-captured":
                return TLSAttestationVerifier.verifyResponse(Data("{}".utf8), liveCertDER: nil, nonceHex: tls.nonce).0
            case "certificate-malformed":
                return TLSAttestationVerifier.verifyBindings(quoteHex: tls.intelQuote, signingAddress: tls.signingAddress, signingAlgo: tls.signingAlgo,
                                                             tlsCertFingerprintHex: tls.tlsCertFingerprint, liveCertDER: Data([0x30, 0x03, 0x02]), nonceHex: tls.nonce)
            case "quote-unchecked":
                return TLSAttestationVerifier.withQuoteCheck(.verified, dcap: .unchecked("collateral: pcs unreachable"))
            default: return nil
            }
        }
        func klass(hard: Bool, reason: String?) -> String {
            hard ? "evidence" : reason == NRASVerification.teemoonFault ? "teemoon" : "outage"
        }
        #expect(v.nrasTlsCases.count >= 13)
        for row in v.nrasTlsCases {
            let got: String
            if row.check == "nras", let r = await nrasResult(row.case) {
                #expect(!r.isVerified, "\(row.case)")
                got = klass(hard: r.isHardFailure, reason: r.reason)
            } else if row.check == "tls", let r = tlsResult(row.case) {
                #expect(r.isUnverified, "\(row.case)")
                got = klass(hard: r.isHardFailure, reason: r.reason)
            } else {
                Issue.record("no driver for \(row.check)/\(row.case)"); continue
            }
            #expect(got == row.class, "\(row.check)/\(row.case): \(got)")
        }
    }

    final class CountingKeys: NRASKeySource, @unchecked Sendable {
        let data: Data
        let refreshes = LockedBox(0)
        init(data: Data) { self.data = data }
        func jwks(refresh: Bool) async throws -> Data { if refresh { refreshes.value += 1 }; return data }
    }

    /// trust-caption-sealed (the maintainer 2026-11-06): a seal-holding soft state titles "encrypted · hardware not
    /// confirmed" with the closed lock; a hard break and a missing key keep their own words.
    @Test func aSealHoldingSoftStateTitlesEncryptedHardwareNotConfirmed() throws {
        guard let v = try Self.vectors() else { return }
        for vector in v.vectors {
            let s = session(vector.change)
            #expect(s.sealedButHardwareUnconfirmed == (vector.alert == "stillChecking"), "\(vector.name)")
        }
        #expect(TrustVerdict.chipCaption(mode: .softDegrade, state: .degraded, hardwareUnconfirmedButSealed: true)
                == "encrypted · hardware not confirmed")
        #expect(TrustVerdict.chipCaption(mode: .softDegrade, state: .degraded) == "not end-to-end encrypted")
        #expect(TrustVerdict.chipCaption(mode: .hardBlock, state: .degraded, hardwareUnconfirmedButSealed: true)
                == "verification failed — sending blocked")
        let unsent = session(["dcap": "unchecked"])
        unsent.lastRequestUsedE2EE = false
        #expect(!unsent.sealedButHardwareUnconfirmed, "a request that went out plain is never titled encrypted")
    }

    @Test func aConfirmIsAskedOncePerRecordAndReason() {
        let s = session(["dcap": "unchecked"])
        #expect(s.sendPolicyAfterConfirmations == .confirm)
        s.rememberConfirmation(pending: false, answering: .verification)
        #expect(s.sendPolicyAfterConfirmations == .allow, "the same record and reason don't ask again")
        s.gpuAttestation = .inconclusive("NRAS unreachable")
        s.dcapVerification = { var d = RecordDCAPVerification(); d.model = Self.upToDate; return d }()
        #expect(s.sendPolicyAfterConfirmations == .confirm, "a different reason asks again")
    }

    /// The maintainer asked whether the audits could block sends: they can't, and this keeps it so. The gate's code
    /// never names the audits index; a tripwire on the source, like the one that keeps ImageIO out.
    @Test func theGateNeverReadsTheAuditsIndex() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["teemoon/Confidential/ConfidentialSession+Verdict.swift", "teemoon/Chat/ChatViewModel.swift",
                     "teemoon/Presentation/SendChoices.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("AuditIndex") && !source.contains("auditState") && !source.contains("verdictClass"),
                    "\(path) reads the audits index")
        }
    }
}
