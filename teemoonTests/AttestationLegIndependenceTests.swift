//
//  AttestationLegIndependenceTests.swift
//  teemoonTests
//
//  AttestationService.fetch gathers three independent claims — the gateway's
//  own quote, the model node's Ed25519 key + quote, the GPU node's evidence.
//  These pin that one leg's failure never discards another leg's success, and
//  what each class of gateway failure costs in requests.
//
//  Incident (the 2026-09-04 key-orphan incident): with the near.ai API key
//  orphaned, the gateway answered HTTP 401 `{"error":{…}}`. The direct
//  completions host had already served a valid Ed25519 key, but fetch()
//  decoded the 401 body as a Report, threw DecodingError.keyNotFound, and the
//  key went with it — "End-to-end encryption could not be established". The
//  partial-record fallback existed but keyed on a THROWN transport error; an
//  answered 401 walked past it.
//

import Foundation
import Testing
@testable import teemoon

/// Which of fetch()'s three legs a request belongs to, read off its URL.
private enum Leg: Hashable {
    case gateway, model, gpu

    init(_ request: URLRequest) {
        let url = request.url!
        if url.host == Fixture.gpuNode.host { self = .gpu; return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        self = items.contains { $0.name == "signing_algo" && $0.value == "ed25519" } ? .model : .gateway
    }
}

private actor RequestLog {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
    func count(_ leg: Leg) -> Int { requests.filter { Leg($0) == leg }.count }
    func nonces(_ leg: Leg) -> [String] {
        requests.filter { Leg($0) == leg }.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "nonce" }?.value
        }
    }
}

private struct RoutedHTTP: HTTPClient {
    let log = RequestLog()
    let route: @Sendable (Leg, URLRequest) throws -> (status: Int, body: Data)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await log.record(request)
        let (status, body) = try route(Leg(request), request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private enum Fixture {
    static let nearAI = URL(string: "https://cloud-api.near.ai/v1")!
    static let gpuNode = URL(string: "https://gpu-node.example/v1")!
    /// Has a shipped direct host, so the model leg resolves a direct source
    /// even when the endpoints directory is unreachable from the test host.
    static let model = "zai-org/GLM-5.1-FP8"

    static let keyHex = String(repeating: "ab", count: 32)
    static let keyBytes = Data(repeating: 0xab, count: 32)

    /// The incident's gateway answer, verbatim.
    static let missingAuthorization = Data(#"{"error":{"message":"Missing authorization header"}}"#.utf8)
    static let notJSON = Data("<html><body>502 Bad Gateway</body></html>".utf8)

    static let gatewayReport = Data("""
    {"gateway_attestation":{"intel_quote":"","signing_address":"0xgateway",\
    "info":{"compose_hash":"hash-compose","os_image_hash":"hash-os",\
    "tcb_info":{"mrtd":"hash-mrtd","app_compose":"services: {}"}}}}
    """.utf8)
    static let ed25519Report = Data(
        #"{"signing_public_key":"\#(keyHex)","nvidia_payload":"{\"arch\":\"HOPPER\"}","info":{"os_image_hash":"hash-model-os"}}"#.utf8)
    static let gpuReport = Data(
        #"{"signing_address":"0xgpu","nvidia_payload":"{\"arch\":\"AMPERE\"}","info":{"compose_hash":"gpu-compose"}}"#.utf8)
}

@Suite("Attestation legs are independent")
struct AttestationLegIndependenceTests {

    /// The incident: gateway 401s (auth is the gateway's problem alone), the
    /// direct host serves the key. The key must survive, and nothing the
    /// gateway did not serve may appear as evidence.
    @Test func gateway401DoesNotDiscardTheModelKey() async throws {
        let http = RoutedHTTP { leg, request in
            // Mirror the incident: everything on the gateway host is 401,
            // including the model leg's gateway source; only direct hosts answer.
            if request.url?.host == Fixture.nearAI.host { return (401, Fixture.missingAuthorization) }
            #expect(leg == .model)
            return (200, Fixture.ed25519Report)
        }
        let id = UUID()
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "", model: Fixture.model, providerID: id, http: http)

        #expect(record.modelEd25519PubKey == Fixture.keyBytes)
        #expect(record.modelNonce != nil)
        #expect(record.modelOSImageHash == "hash-model-os")
        #expect(record.gpuArch == "HOPPER")
        #expect(record.providerID == id)
        #expect(record.model == Fixture.model)

        #expect(record.signingAddress == nil)
        #expect(record.gatewayNonce == nil)
        #expect(record.quoteVerification == nil)
        #expect(record.intelQuote == "")
        #expect(record.composeHash == "")
        #expect(record.mrtd == "")
        #expect(record.osImageHash == "")
        #expect(record.composeManifest == nil)
        #expect(record.gpuSigningAddress == nil)

        #expect(await http.log.count(.gateway) == 1, "a 401 cannot succeed on retry")
    }

    @Test func undecodableGatewayBodyLeavesGatewayFieldsEmpty() async throws {
        let http = RoutedHTTP { leg, _ in
            leg == .model ? (200, Fixture.ed25519Report) : (200, Fixture.notJSON)
        }
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: Fixture.model, providerID: UUID(), http: http)

        #expect(record.modelEd25519PubKey == Fixture.keyBytes)
        #expect(record.signingAddress == nil)
        #expect(record.gatewayNonce == nil)
        #expect(record.quoteVerification == nil)
        #expect(record.intelQuote == "")
        #expect(await http.log.count(.gateway) == 1, "a malformed body is not transient")
    }

    @Test func gpuEvidenceAloneIsARecord() async throws {
        let http = RoutedHTTP { leg, _ in
            leg == .gpu ? (200, Fixture.gpuReport) : (404, Fixture.missingAuthorization)
        }
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: "", providerID: UUID(),
            gpuNodeURL: Fixture.gpuNode, http: http)

        #expect(record.gpuSigningAddress == "0xgpu")
        #expect(record.gpuArch == "AMPERE")
        #expect(record.gpuNodeComposeHash == "gpu-compose")
        #expect(record.gpuNonce != nil)
        #expect(record.signingAddress == nil)
        #expect(record.quoteVerification == nil)
        #expect(record.modelEd25519PubKey == nil)
        #expect(await http.log.count(.gateway) == 1)
    }

    @Test func totalBlackoutThrowsAfterOneGatewayRequestFor4xx() async {
        let http = RoutedHTTP { _, _ in (401, Fixture.missingAuthorization) }
        do {
            _ = try await AttestationService.fetch(
                baseURL: Fixture.nearAI, apiKey: "", model: "", providerID: UUID(), http: http)
            Issue.record("fetch returned a record with no evidence from any leg")
        } catch {
            #expect((error as NSError).domain == "AttestationService")
        }
        #expect(await http.log.count(.gateway) == 1)
    }

    /// 503 twice, then the real report: the third attempt must win (~3s of
    /// backoff — the one slow test here, by design).
    @Test func gateway5xxIsRetriedAndRecovers() async throws {
        let flaky = FlakyLeg(leg: .gateway, failuresBeforeSuccess: 2, success: Fixture.gatewayReport)
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: "", providerID: UUID(), http: flaky)

        #expect(record.signingAddress == "0xgateway")
        #expect(record.composeHash == "hash-compose")
        #expect(await flaky.log.count(.gateway) == 3)
    }

    /// A complete fetch: every field lands, and the gateway nonce the record
    /// reports is the one actually sent on the wire.
    @Test func allLegsSucceedFieldForField() async throws {
        let http = RoutedHTTP { leg, _ in
            switch leg {
            case .gateway: return (200, Fixture.gatewayReport)
            case .model:   return (200, Fixture.ed25519Report)
            case .gpu:     return (200, Fixture.gpuReport)
            }
        }
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: Fixture.model, providerID: UUID(),
            gpuNodeURL: Fixture.gpuNode, http: http)

        #expect(record.composeHash == "hash-compose")
        #expect(record.mrtd == "hash-mrtd")
        #expect(record.osImageHash == "hash-os")
        #expect(record.composeManifest == "services: {}")
        #expect(record.signingAddress == "0xgateway")
        #expect(record.intelQuote == "")
        #expect(record.quoteVerification == nil, "an empty quote verifies to nothing, not to a failure")
        #expect(record.modelEd25519PubKey == Fixture.keyBytes)
        #expect(record.modelOSImageHash == "hash-model-os")
        #expect(record.gpuArch == "HOPPER", "the model node's own arch wins over the GPU node fetch")
        #expect(record.gpuSigningAddress == "0xgpu")
        #expect(record.gpuNodeComposeHash == "gpu-compose")
        #expect(record.modelNonce != nil)
        #expect(record.gpuNonce != nil)

        let sent = await http.log.nonces(.gateway)
        #expect(sent.count == 1)
        #expect(record.gatewayNonce != nil)
        #expect(record.gatewayNonce == sent.first)
    }
}

/// One leg that answers 503 `failuresBeforeSuccess` times, then `success`.
/// Every other leg gets the same 503s.
private struct FlakyLeg: HTTPClient {
    let log = RequestLog()
    let leg: Leg
    let failuresBeforeSuccess: Int
    let success: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await log.record(request)
        let attempt = await log.count(leg)
        let status = Leg(request) == leg && attempt > failuresBeforeSuccess ? 200 : 503
        let body = status == 200 ? success : Fixture.notJSON
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// What each class of answer costs a leg in requests. The three legs share
/// one taxonomy: a thrown transport error or a 5xx is retried, a 4xx is final.
///
/// Incident, defect 3: the model leg classed only `status >= 500` as an
/// error. A 401 body decoded into the all-optional Ed25519Report, tripped
/// the missing-key guard and was retried — 8 backed-off attempts, ~46s, for
/// a status that cannot succeed on retry. The GPU leg was worse: its report
/// is all-optional too, so a 401 body decoded into an EMPTY record that
/// counted as evidence.
@Suite("Attestation leg retry taxonomy")
struct AttestationLegRetryTaxonomyTests {

    @Test(arguments: [401, 403, 404]) func modelLeg4xxIsFinal(status: Int) async {
        let http = RoutedHTTP { _, _ in (status, Fixture.missingAuthorization) }
        let result = await AttestationService.fetchModelAttestation(
            from: Fixture.nearAI, includeModelParam: true, expectedModel: Fixture.model,
            apiKey: "", maxAttempts: 8, label: "gateway", http: http)
        #expect(result == nil)
        #expect(await http.log.count(.model) == 1, "HTTP \(status) cannot succeed on retry")
    }

    /// 503 once, then the key: the second attempt wins (~2s of backoff).
    @Test func modelLeg5xxIsRetriedAndRecovers() async {
        let http = FlakyLeg(leg: .model, failuresBeforeSuccess: 1, success: Fixture.ed25519Report)
        let result = await AttestationService.fetchModelAttestation(
            from: Fixture.nearAI, includeModelParam: true, expectedModel: Fixture.model,
            apiKey: "sk", maxAttempts: 8, label: "gateway", http: http)
        #expect(result?.ed25519PubKey == Fixture.keyBytes)
        #expect(await http.log.count(.model) == 2)
    }

    /// A 200 with no key yet is a TEE still starting: transient, so retried
    /// up to the budget (~2s of backoff for the second attempt).
    @Test func modelLeg200WithoutKeyStaysTransient() async {
        let http = RoutedHTTP { _, _ in (200, Data("{}".utf8)) }
        let result = await AttestationService.fetchModelAttestation(
            from: Fixture.nearAI, includeModelParam: true, expectedModel: Fixture.model,
            apiKey: "sk", maxAttempts: 2, label: "gateway", http: http)
        #expect(result == nil)
        #expect(await http.log.count(.model) == 2)
    }

    /// The incident's shape with a model set: every source of the model leg
    /// asks once and the whole fetch fails in seconds, not after draining
    /// 8 backed-off attempts per source.
    @Test func blackoutWithModelLegAsksEachSourceOnce() async {
        let http = RoutedHTTP { _, _ in (401, Fixture.missingAuthorization) }
        let sources = await AttestationService.directSources(forModel: Fixture.model).count + 1
        let started = ContinuousClock.now
        do {
            _ = try await AttestationService.fetch(
                baseURL: Fixture.nearAI, apiKey: "", model: Fixture.model, providerID: UUID(), http: http)
            Issue.record("fetch returned a record with no evidence from any leg")
        } catch {
            #expect((error as NSError).domain == "AttestationService")
        }
        #expect(await http.log.count(.gateway) == 1)
        #expect(await http.log.count(.model) == sources, "direct host(s) + gateway, once each")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A 401 body is not GPU evidence: nothing from that leg lands, and it
    /// is not retried.
    @Test func gpuLeg401IsNeitherEvidenceNorRetried() async throws {
        let http = RoutedHTTP { leg, _ in
            leg == .gpu ? (401, Fixture.missingAuthorization) : (200, Fixture.gatewayReport)
        }
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: "", providerID: UUID(),
            gpuNodeURL: Fixture.gpuNode, http: http)
        #expect(record.signingAddress == "0xgateway")
        #expect(record.gpuNonce == nil, "an empty decoded report must not count as a GPU answer")
        #expect(record.gpuSigningAddress == nil)
        #expect(record.gpuArch == nil)
        #expect(record.gpuNodeComposeHash == nil)
        #expect(await http.log.count(.gpu) == 1)
    }

    /// GPU 503 once, then the real report (~1s of backoff).
    @Test func gpuLeg5xxIsRetriedAndRecovers() async throws {
        let http = FlakyLeg(leg: .gpu, failuresBeforeSuccess: 1, success: Fixture.gpuReport)
        let record = try await AttestationService.fetch(
            baseURL: Fixture.nearAI, apiKey: "sk", model: "", providerID: UUID(),
            gpuNodeURL: Fixture.gpuNode, http: http)
        #expect(record.gpuSigningAddress == "0xgpu")
        #expect(await http.log.count(.gpu) == 2)
    }
}
