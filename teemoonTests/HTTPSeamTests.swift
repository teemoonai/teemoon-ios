//
//  HTTPSeamTests.swift
//  teemoonTests
//
//  Offline coverage for the three fetches that used to sit on URLSession.shared:
//  attestation, Brave key check, provider-key validation.
//

import Foundation
import Testing
@testable import teemoon

private struct StubHTTP: HTTPClient {
    var status: Int = 200
    var body: Data = Data()
    var error: (any Error)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error { throw error }
        let url = request.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

@Suite("Attestation fetch is offline-testable")
struct AttestationFetchTests {

    @Test func plantedGatewayJSONBecomesARecord() async throws {
        let body = Data("""
        {"gateway_attestation":{"intel_quote":"","signing_address":"0xabc",\
        "info":{"compose_hash":"hash-compose","os_image_hash":"hash-os",\
        "tcb_info":{"mrtd":"hash-mrtd","app_compose":"services: {}"}}}}
        """.utf8)
        let http = StubHTTP(body: body)
        let id = UUID()
        let record = try await AttestationService.fetch(
            baseURL: URL(string: "https://cloud-api.near.ai/v1")!,
            apiKey: "sk-test",
            model: "",
            providerID: id,
            http: http
        )
        #expect(record.composeHash == "hash-compose")
        #expect(record.osImageHash == "hash-os")
        #expect(record.mrtd == "hash-mrtd")
        #expect(record.signingAddress == "0xabc")
        #expect(record.providerID == id)
        #expect(record.composeManifest == "services: {}")
    }
}

@Suite("Brave key check is offline-testable")
struct BraveKeyCheckTests {

    @Test func http200IsValid() async {
        let result = await BraveWebSearchTool.checkKey("sk-real", http: StubHTTP(status: 200))
        #expect(result == .valid)
    }

    @Test func http401IsRejected() async {
        let result = await BraveWebSearchTool.checkKey("sk-bad", http: StubHTTP(status: 401))
        #expect(result == .rejected)
    }

    @Test func emptyKeyIsRejectedWithoutARequest() async {
        let result = await BraveWebSearchTool.checkKey("   ", http: StubHTTP(status: 200))
        #expect(result == .rejected)
    }

    /// Brave answers a key it cannot parse (a 16-character one, say) with HTTP
    /// 422 and SUBSCRIPTION_TOKEN_INVALID in the body — not a 401. Treating
    /// that as "Brave unavailable" saved the bad key with a shrug.
    @Test func http422WithInvalidTokenIsRejected() async {
        let body = Data(#"{"error":{"code":"SUBSCRIPTION_TOKEN_INVALID","detail":"The provided subscription token is invalid.","meta":{"component":"authentication"}}}"#.utf8)
        let result = await BraveWebSearchTool.checkKey("short-key", http: StubHTTP(status: 422, body: body))
        #expect(result == .rejected)
    }

    /// Any other 422 is still Brave's problem, not the key's.
    @Test func http422WithAnotherCodeIsUnavailable() async {
        let body = Data(#"{"error":{"code":"VALIDATION","detail":"q is required"}}"#.utf8)
        let result = await BraveWebSearchTool.checkKey("sk-real", http: StubHTTP(status: 422, body: body))
        #expect(result == .braveUnavailable(status: 422))
    }
}

@Suite("Provider key validation is offline-testable")
struct ProviderKeyValidatorTests {

    @Test func http200IsSuccess() async {
        let result = await ProviderKeyValidator.validate(
            key: "sk-ok", endpoint: .nearAI, http: StubHTTP(status: 200)
        )
        #expect(result == .success)
    }

    @Test func http401IsUnauthorized() async {
        let result = await ProviderKeyValidator.validate(
            key: "sk-bad", endpoint: .braveSearch, http: StubHTTP(status: 401)
        )
        #expect(result == .unauthorized)
    }

    @Test func transportErrorIsOtherFailure() async {
        struct Boom: Error {}
        let result = await ProviderKeyValidator.validate(
            key: "sk", endpoint: .nearAI, http: StubHTTP(error: Boom())
        )
        #expect(result == .otherFailure)
    }
}
