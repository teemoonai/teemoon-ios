//
//  TLSAttestationVerifier.swift
//  teemoon
//
//  TLS attestation of the model node: a separate probe connection to its direct
//  host whose certificate key must be bound into the node's quote. The chat goes
//  through near.ai's gateway on another, unpinned connection: never claim this covers it.
//
//  near.ai's documented flow (docs.near.ai/cloud/verification/tls), validated
//  live against a real endpoint:
//   1. Request `…/attestation/report?include_tls_fingerprint=true` from the
//      model's direct host, capturing the live server certificate over the
//      SAME TLS connection (a second connection could hit a different backend
//      and mismatch). CA validation is intentionally skipped — the enclave
//      self-signs; trust comes from the hardware attestation, not a CA.
//   2. With the flag, `report_data[0:32] == SHA256(signing_address ‖ tls_cert_fingerprint)`,
//      where `tls_cert_fingerprint` = SHA256(cert SubjectPublicKeyInfo), and
//      `report_data[32:64] == nonce`.
//   3. The live certificate's own SPKI hash must equal the attested
//      `tls_cert_fingerprint` — that's what proves the connection ends in the TEE.
//
//  Because the flag changes the report_data[0:32] layout, this runs as a
//  SEPARATE attestation request, independent of the main (address-in-
//  report_data) attestation flow.
//

import CryptoKit
import DcapQvl
import Foundation
import Security
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "tls-attest")

enum TLSAttestation: Equatable, Sendable {
    /// The probe connection's certificate key is bound into the model node's quote.
    case verified
    /// The live certificate doesn't match the attested binding, or near.ai's evidence is malformed. HARD: blocks.
    case failed(String)
    /// An outage, or teemoon's own fault. Malformed evidence is `.failed` (near-gate-nvidia-tls-split).
    case inconclusive(String)
    /// Not attempted (no direct host to verify against).
    case notPerformed

    var isVerified: Bool { self == .verified }
    /// Drives the red, blocking tier. `.inconclusive` is soft (confirm-to-proceed), never hard.
    var isHardFailure: Bool { if case .failed = self { return true }; return false }
    /// Attempted and did not verify (either hard or inconclusive) — both degrade.
    var isUnverified: Bool {
        switch self { case .failed, .inconclusive: return true; default: return false }
    }
    var reason: String? {
        switch self {
        case .failed(let s), .inconclusive(let s): return s
        default: return nil
        }
    }
}

struct TLSAttestationVerifier {

    /// The probe quote goes through DCAP like the record's quotes: a quote that
    /// is only parsed binds a fingerprint anyone could have written.
    var quoteCheck: @Sendable (String) async -> DCAPVerification = { hex in
        await DCAPVerifier(collateral: IntelPCSCollateralProvider())
            .verify(quoteHex: hex, nowSecs: UInt64(Date().timeIntervalSince1970))
    }

    /// Fetches attestation with `include_tls_fingerprint=true` over a fresh
    /// TLS connection to `directBaseURL`, captures that connection's server
    /// certificate, and verifies the TLS-termination bindings.
    func verify(directBaseURL: URL) async -> TLSAttestation {
        let nonce = Self.randomNonce()
        guard var components = URLComponents(url: directBaseURL.appendingPathComponent("attestation/report"),
                                             resolvingAgainstBaseURL: false) else {
            return .inconclusive(NRASVerification.teemoonFault)
        }
        components.queryItems = [
            URLQueryItem(name: "include_tls_fingerprint", value: "true"),
            URLQueryItem(name: "signing_algo", value: "ecdsa"),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        guard let url = components.url else { return .inconclusive(NRASVerification.teemoonFault) }

        // A dedicated session so accepting the enclave's self-signed cert is
        // scoped to THIS request and never affects the app's other traffic.
        let capture = CertCapturingDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let request = Self.makeProbeRequest(url: url)

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return .inconclusive("TLS attestation request failed")
        }
        let (result, quote) = Self.verifyResponse(data, liveCertDER: capture.certificateDER, nonceHex: nonce)
        if case .failed(let why) = result { logger.warning("[tls] \(why, privacy: .public)") }
        guard result == .verified, let quote else { return result }
        let verdict = Self.withQuoteCheck(result, dcap: await quoteCheck(quote))
        if case .failed(let why) = verdict { logger.warning("[tls] \(why, privacy: .public)") }
        return verdict
    }

    /// Bindings first, then DCAP on the same quote. A DCAP hard failure (bad
    /// quote, collateral unreachable, TCB outside the allow-list) fails the
    /// check, as it does for the record's quotes.
    static func withQuoteCheck(_ bindings: TLSAttestation, dcap: DCAPVerification) -> TLSAttestation {
        guard bindings == .verified else { return bindings }
        // Not hard is not verified: a quote Intel couldn't check proves nothing about the connection.
        if case .unchecked(let reason) = dcap { return .inconclusive("TLS attestation quote couldn't be checked (\(reason))") }
        guard dcap.isHardFailure else { return .verified }
        switch dcap {
        case .unchecked(let reason): return .inconclusive(reason)
        case .failed(let reason): return .failed("TLS attestation quote failed DCAP verification (\(reason))")
        case .verified(let tcb, _, _): return .failed("TLS attestation quote TCB status \(tcb.rawValue) is not accepted")
        }
    }

    /// Builds the probe request. DELIBERATELY UNAUTHENTICATED — no
    /// Authorization header, ever. The attestation report is public evidence
    /// (the bundled self-verify script fetches the identical URL with no
    /// credential), and this request rides a session whose delegate accepts
    /// ANY server trust *before* the fingerprint binding is checked — so a
    /// bearer token attached here would be handed to whoever answers,
    /// including an on-path attacker. Internal (not private) so the test can
    /// pin the no-auth property.
    static func makeProbeRequest(url: URL) -> URLRequest {
        URLRequest(url: url, timeoutInterval: 20)
    }

    private struct TLSReport: Decodable {
        let signingAddress: String?
        let signingAlgo: String?
        let tlsCertFingerprint: String?
        let intelQuote: String?
        enum CodingKeys: String, CodingKey {
            case signingAddress = "signing_address"
            case signingAlgo = "signing_algo"
            case tlsCertFingerprint = "tls_cert_fingerprint"
            case intelQuote = "intel_quote"
        }
    }

    // MARK: - Pure verification (testable offline against a captured fixture)

    /// The probe's 200 body against the live certificate; the quote comes back for the DCAP step.
    static func verifyResponse(_ data: Data, liveCertDER: Data?, nonceHex: String) -> (TLSAttestation, quote: String?) {
        // Not captured is our capture or the connection: soft. A captured certificate that won't parse is evidence.
        guard let liveCertDER else { return (.inconclusive("no server certificate captured"), nil) }
        guard let report = try? JSONDecoder().decode(TLSReport.self, from: data),
              let quote = report.intelQuote, let address = report.signingAddress,
              let fingerprint = report.tlsCertFingerprint else {
            return (.failed("attestation response missing TLS fields"), nil)
        }
        return (verifyBindings(quoteHex: quote, signingAddress: address, signingAlgo: report.signingAlgo ?? "ecdsa",
                               tlsCertFingerprintHex: fingerprint, liveCertDER: liveCertDER, nonceHex: nonceHex), quote)
    }

    /// Verifies the three TLS-attestation bindings. Pure — no network.
    static func verifyBindings(
        quoteHex: String, signingAddress: String, signingAlgo: String,
        tlsCertFingerprintHex: String, liveCertDER: Data, nonceHex: String
    ) -> TLSAttestation {
        // 1. The live certificate's SPKI hash must equal the attested value —
        //    this ties the probe connection's key to the TEE.
        //    The hash covers the whole SPKI whatever its key type, so nil here is malformed DER, never "unsupported".
        guard let liveSPKI = spkiSHA256(certDER: liveCertDER) else {
            return .failed("could not read the TLS certificate’s public key")
        }
        guard liveSPKI.caseInsensitiveCompare(tlsCertFingerprintHex) == .orderedSame else {
            return .failed("live TLS certificate does not match the attested fingerprint")
        }
        // 2. report_data[0:32] == SHA256(signing_address ‖ tls_cert_fingerprint)
        guard let raw = try? Data(hexString: quoteHex),
              let quote = try? DcapQvl.parseQuote(rawQuote: raw) else {
            return .failed("could not parse the attestation quote")
        }
        let reportData: Data
        switch quote.report {
        case .td10(let r): reportData = r.reportData
        case .td15(let r): reportData = r.base.reportData
        case .sgx(let r):  reportData = r.reportData
        }
        guard reportData.count >= 64 else { return .failed("unexpected report_data length") }

        let addrHex = signingAlgo.lowercased() == "ecdsa" && signingAddress.hasPrefix("0x")
            ? String(signingAddress.dropFirst(2)) : signingAddress
        guard let addrBytes = try? Data(hexString: addrHex),
              let fpBytes = try? Data(hexString: tlsCertFingerprintHex) else {
            return .failed("bad signing address or fingerprint encoding")
        }
        let expected = Data(SHA256.hash(data: addrBytes + fpBytes))
        guard reportData.prefix(32) == expected else {
            return .failed("report_data does not bind the signing key + TLS certificate")
        }
        // 3. report_data[32:64] == nonce (freshness)
        guard let nonceBytes = try? Data(hexString: nonceHex),
              reportData.dropFirst(32).prefix(32) == nonceBytes else {
            return .failed("report_data nonce mismatch (possible replay)")
        }
        return .verified
    }

    /// SHA-256 of the certificate's SubjectPublicKeyInfo, hex. iOS has no
    /// direct SPKI accessor, so walk the DER: Certificate → tbsCertificate →
    /// skip [0]version?, serial, sigAlg, issuer, validity, subject → SPKI.
    static func spkiSHA256(certDER: Data) -> String? {
        let b = [UInt8](certDER)
        guard let cert = readTLV(b, 0),
              let tbs = readTLV(b, cert.contentStart) else { return nil }
        var i = tbs.contentStart
        guard let first = readTLV(b, i) else { return nil }
        if first.tag == 0xA0 { i = first.next }   // optional explicit version [0]
        for _ in 0..<5 {                           // serial, sigAlg, issuer, validity, subject
            guard let e = readTLV(b, i) else { return nil }
            i = e.next
        }
        guard let spki = readTLV(b, i), spki.next <= b.count else { return nil }
        return Data(SHA256.hash(data: Data(b[i..<spki.next]))).hexString
    }

    /// Reads one DER TLV at `i`: (tag, contentStart, contentLen, nextIndex).
    private static func readTLV(_ b: [UInt8], _ i: Int) -> (tag: UInt8, contentStart: Int, contentLen: Int, next: Int)? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var j = i + 1
        var len = Int(b[j]); j += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, j + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(b[j + k]) }
            j += n
        }
        guard j + len <= b.count else { return nil }
        return (tag, j, len, j + len)
    }

    private static func randomNonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Captures the server certificate of a request's TLS connection and accepts
/// the enclave's self-signed certificate (trust comes from the hardware
/// attestation + SPKI-in-report_data binding, not from a CA). Scoped to the
/// dedicated TLS-attestation session only.
private final class CertCapturingDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var certificateDER: Data?

    /// Never follow redirects. The probe's evidence only means anything on the
    /// ORIGINAL connection (the captured certificate must belong to the host
    /// that answered), and a session that accepts any server trust must not be
    /// steerable to a different host.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            certificateDER = SecCertificateCopyData(leaf) as Data
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
