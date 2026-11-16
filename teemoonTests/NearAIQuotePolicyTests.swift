//
//  NearAIQuotePolicyTests.swift
//  teemoonTests
//
//  Four checks from near.ai's inference-sdk ff591054 policies (freeze item B, the maintainer 2026-11-08), run
//  through the real fetch on today's glm-5.3-flash reports (captured 2026-11-08T14:51-14:55Z, public attestation
//  output, event logs / app certs / action lists trimmed; nothing the four checks read):
//  B1 a TD whose TDATTRIBUTES debug bit (byte 0, bit 0, TUD.DEBUG) is set is evidence, on every quote, decided by
//     teemoon itself (dcap-qvl 0.5.2 rejects it too, verify.rs:969, but the outcome must not hang on that);
//  B2 an advertised `report_data` that is not the quote's is evidence;
//  B3 a model node's mr_config must be 0x01 ‖ sha256(app_compose) of the compose it served, as the gateway's;
//  B4 a near.ai model node that sent no `nvidia_payload` couldn't be checked: soft (asks), never verified.
//  Intel is unreachable in every test here, so a passing quote reads `.unchecked`, never `.failed`.
//

import Foundation
import TDXQuoteVerifier
import Testing
@testable import teemoon

/// One captured report per leg, editable before it is served.
struct LiveGLM53Reports {
    static let model = "z-ai/glm-5.3-flash"
    static let gateway = URL(string: "https://cloud-api.near.ai/v1")!
    static let node = URL(string: "https://glm-5-3-flash.completions.near.ai/v1")!

    var gateway: [String: Any]
    var model: [String: Any]
    var gpu: [String: Any]

    static func load() throws -> LiveGLM53Reports {
        func json(_ leg: String) throws -> [String: Any] {
            let data = try TestFixture.data("nearai_live_glm53flash_20261108_\(leg).json")
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        return LiveGLM53Reports(gateway: try json("gateway"), model: try json("model"), gpu: try json("gpu"))
    }

    var gatewayLeg: [String: Any] {
        get { gateway["gateway_attestation"] as! [String: Any] }
        set { gateway["gateway_attestation"] = newValue }
    }

    /// The record `AttestationService.fetch` builds from these reports.
    func fetch() async throws -> AttestationRecord {
        let bodies = try [gateway, model, gpu].map { try JSONSerialization.data(withJSONObject: $0) }
        let http = LegRouter(gateway: bodies[0], model: bodies[1], gpu: bodies[2])
        return try await AttestationService.fetch(baseURL: Self.gateway, apiKey: "", model: Self.model,
                                                  providerID: UUID(), gpuNodeURL: Self.node, http: http)
    }

    /// The quote hex with TDATTRIBUTES byte 0 bit 0 (TUD.DEBUG) set: header 48 + body offset 120.
    static func withDebugBit(_ quoteHex: String) -> String {
        var bytes = Array(try! Data(hexString: quoteHex))
        bytes[168] |= 0x01
        return Data(bytes).hexString
    }

    /// One hex digit of `hex` changed.
    static func flipped(_ hex: String) -> String {
        hex.first == "0" ? "1" + hex.dropFirst() : "0" + hex.dropFirst()
    }
}

/// Serves each leg its report: ed25519 is the model leg, ecdsa on the gateway host the gateway, the rest the GPU node.
private struct LegRouter: HTTPClient {
    let gateway: Data, model: Data, gpu: Data
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let algo = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "signing_algo" }?.value
        let body = algo == "ed25519" ? model : url.host == LiveGLM53Reports.gateway.host ? gateway : gpu
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Intel PCS unreachable: a quote teemoon's own checks pass reads `.unchecked`.
struct IntelUnreachable: CollateralProvider {
    func collateralJSON(forQuote rawQuote: Data) async throws -> Data { throw URLError(.notConnectedToInternet) }
}

@Suite("near.ai quote policy: debug TD, advertised report_data, model mr_config, GPU evidence")
struct NearAIQuotePolicyTests {
    let dcap = DCAPService(collateral: IntelUnreachable())

    private func isFailed(_ v: DCAPVerification?) -> Bool { if case .failed = v { return true }; return false }

    // MARK: B1

    /// TDATTRIBUTES is little-endian: byte 0 is TUD, bit 0 DEBUG. Today's quotes carry 0x10 in byte 3 (SEPT_VE_DISABLE).
    @Test func theDebugBitIsTUDBitZero() {
        #expect(QuoteChecks.debugEnabled(tdAttributes: Data([0x01, 0, 0, 0x10, 0, 0, 0, 0])))
        #expect(!QuoteChecks.debugEnabled(tdAttributes: Data([0, 0, 0, 0x10, 0, 0, 0, 0])))
        #expect(!QuoteChecks.debugEnabled(tdAttributes: Data([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])))
        #expect(QuoteChecks.debugEnabled(tdAttributes: Data()), "an unreadable field is never read as off")
    }

    @Test func aDebugTDIsEvidenceOnTheGatewayModelAndGPUQuotes() async throws {
        let live = try LiveGLM53Reports.load()
        for leg in ["gateway", "model", "gpu"] {
            var reports = live
            switch leg {
            case "gateway": reports.gatewayLeg["intel_quote"] = LiveGLM53Reports.withDebugBit(reports.gatewayLeg["intel_quote"] as! String)
            case "model": reports.model["intel_quote"] = LiveGLM53Reports.withDebugBit(reports.model["intel_quote"] as! String)
            default: reports.gpu["intel_quote"] = LiveGLM53Reports.withDebugBit(reports.gpu["intel_quote"] as! String)
            }
            let result = await dcap.verify(record: try await reports.fetch())
            let outcome = leg == "gateway" ? result.gateway : leg == "model" ? result.model : result.gpu
            #expect(isFailed(outcome), "\(leg): \(String(describing: outcome))")
            #expect(result.hasHardFailure, "\(leg)")
        }
    }

    @Test func aDebugTDIsEvidenceOnTheComposeManagerQuote() async throws {
        let live = try LiveGLM53Reports.load()
        let cm = try #require(live.gpu["compose_manager_attestation"] as? [String: Any])
        let quote = try #require(cm["quote"] as? String)
        let outcome = await dcap.verify(quoteHex: LiveGLM53Reports.withDebugBit(quote), label: "compose-manager", nowSecs: 0)
        #expect(isFailed(outcome), "\(String(describing: outcome))")
        #expect(TrustScope.hardware(outcome) == .failed)
    }

    // MARK: B2

    @Test func anAdvertisedReportDataThatIsNotTheGatewayQuotesIsEvidence() async throws {
        var reports = try LiveGLM53Reports.load()
        reports.gatewayLeg["report_data"] = LiveGLM53Reports.flipped(reports.gatewayLeg["report_data"] as! String)
        let result = await dcap.verify(record: try await reports.fetch())
        #expect(isFailed(result.gateway), "\(String(describing: result.gateway))")
        #expect(result.hasHardFailure)
    }

    @Test func anAdvertisedReportDataThatIsNotTheModelQuotesIsEvidence() async throws {
        var reports = try LiveGLM53Reports.load()
        let quote = try QuoteParser.parse(hex: reports.model["intel_quote"] as! String)
        reports.model["report_data"] = LiveGLM53Reports.flipped(quote.body.reportData.hexString)
        let result = await dcap.verify(record: try await reports.fetch())
        #expect(isFailed(result.model), "\(String(describing: result.model))")
    }

    @Test func aModelNodeAdvertisingItsQuotesOwnReportDataPasses() async throws {
        var reports = try LiveGLM53Reports.load()
        let quote = try QuoteParser.parse(hex: reports.model["intel_quote"] as! String)
        reports.model["report_data"] = quote.body.reportData.hexString.uppercased()
        let record = try await reports.fetch()
        #expect(record.modelAdvertisedReportData != nil)
        #expect(await dcap.verify(record: record).model?.isUnchecked == true)
    }

    /// With Intel answering, the advertised value is held to the quote dcap-qvl authenticated.
    @Test func anAuthenticatedQuoteIsHeldToItsAdvertisedReportData() async throws {
        let snapshot = try CollateralServiceTests.loadSnapshot()
        let parse = try TDXQuoteVerifier.verify(quoteHex: snapshot.quoteHex)
        let service = DCAPService(collateral: CollateralServiceTests.provider(snapshot))
        var record = DCAPServiceTests.record(from: snapshot, swiftParse: parse)
        record.gatewayAdvertisedReportData = parse.measurements.reportData.hexString
        #expect(await service.verify(record: record).gateway?.isVerified == true)
        record.gatewayAdvertisedReportData = LiveGLM53Reports.flipped(parse.measurements.reportData.hexString)
        let result = await service.verify(record: record)
        #expect(result.gateway == .failed(QuoteChecks.reportDataDisagrees))
        #expect(result.failureReason == "gateway quote — \(QuoteChecks.reportDataDisagrees)")
    }

    // MARK: B3

    @Test func aGPUNodeWhoseMrConfigIsNotItsComposeIsCodeIdentityEvidence() async throws {
        var reports = try LiveGLM53Reports.load()
        var info = reports.gpu["info"] as! [String: Any]
        var tcb = info["tcb_info"] as! [String: Any]
        tcb["app_compose"] = (tcb["app_compose"] as! String) + " "
        info["tcb_info"] = tcb
        reports.gpu["info"] = info
        let record = try await reports.fetch()
        #expect(record.codeIdentityVerified == false)
        #expect(record.modelNodesBootedTheirCompose == false)
    }

    @Test func aModelLegWhoseMrConfigIsNotItsComposeIsCodeIdentityEvidence() async throws {
        var reports = try LiveGLM53Reports.load()
        var info = reports.model["info"] as! [String: Any]
        var tcb = info["tcb_info"] as! [String: Any]
        tcb["app_compose"] = (tcb["app_compose"] as! String).replacingOccurrences(of: "dstack-nvidia", with: "dstack-nvidiA")
        info["tcb_info"] = tcb
        reports.model["info"] = info
        let record = try await reports.fetch()
        #expect(record.modelComposeManifest?.contains("dstack-nvidiA") == true)
        #expect(record.codeIdentityVerified == false)
    }

    // MARK: B4

    @Test @MainActor func aModelNodeThatSentNoGPUEvidenceCouldntBeChecked() async throws {
        var reports = try LiveGLM53Reports.load()
        reports.model["nvidia_payload"] = nil
        let record = try await reports.fetch()
        #expect(record.nvidiaPayload == nil && record.modelIntelQuote?.isEmpty == false)
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord())
        session.attestationTask?.cancel()
        session.verifyGPU(for: record)
        #expect(session.nrasTask == nil, "nothing left pending")
        guard case .inconclusive? = session.gpuAttestation else {
            Issue.record("expected couldn't-check, got \(String(describing: session.gpuAttestation))")
            return
        }
        #expect(session.gpuAttestation?.isHardFailure == false)
        #expect(session.gpuAttestation == .inconclusive(NRASVerification.evidenceAbsent))
    }

    /// The GPU row shows the couldn't-check with no payload behind it (freeze A2's words), never "unreachable".
    @Test func theGPURowAndReasonSayTheEvidenceIsUnavailable() {
        var record = AttestationRecord.preview
        record.nvidiaPayload = nil
        let summary = AttestationSummary(attestation: record, state: .degraded, timedOut: false, provider: .nearAI,
                                         lastRequestUsedE2EE: nil, lastE2EEFailReason: nil, verifiedResponseCount: 0,
                                         mismatchedResponseCount: 0, attestationFetchFailed: false,
                                         nrasVerification: .inconclusive(NRASVerification.evidenceAbsent))
        #expect(summary.nrasState == .unchecked)
        #expect(summary.gpuRowDetail == "no nvidia evidence in this attestation")
    }

    // MARK: today's record

    /// near.ai's SDK passed all four on these hosts at 13:39Z; teemoon must not block the same record.
    @Test @MainActor func todaysGLM53FlashRecordPassesAllFour() async throws {
        let reports = try LiveGLM53Reports.load()
        let record = try await reports.fetch()
        let result = await dcap.verify(record: record)
        for (leg, outcome) in [("gateway", result.gateway), ("model", result.model), ("gpu", result.gpu)] {
            #expect(outcome?.isUnchecked == true, "\(leg): \(String(describing: outcome))")
        }
        let cm = try #require(reports.gpu["compose_manager_attestation"] as? [String: Any])
        let cmOutcome = await dcap.verify(quoteHex: try #require(cm["quote"] as? String), label: "compose-manager", nowSecs: 0)
        #expect(cmOutcome?.isUnchecked == true, "\(String(describing: cmOutcome))")
        #expect(record.codeIdentityVerified == true)
        #expect(record.modelNodesBootedTheirCompose == true, "both model-node quotes were compared")
        #expect(record.nvidiaPayload?.isEmpty == false)
        let session = ConfidentialSession(providers: ConfidentialSessionTests.storeMatchingPreviewRecord(),
                                          nrasService: NRASService(http: NRASUnreachable()))
        session.attestationTask?.cancel()
        session.verifyGPU(for: record)
        #expect(session.nrasTask != nil, "the evidence goes to NVIDIA")
        session.nrasTask?.cancel()
    }
}

private struct NRASUnreachable: NRASHTTPClient {
    func post(_ url: URL, body: Data) async throws -> Data { throw URLError(.notConnectedToInternet) }
}
