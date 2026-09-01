//
//  CollateralService.swift
//  teemoon
//
//  Fetches Intel PCS collateral for a DCAP quote and assembles the JSON
//  dcap-qvl's verify() expects — a Swift port of the fetch recipe in
//  dcap_qvl::collateral::CollateralClient, validated end-to-end against a
//  real near.ai quote.
//
//  Two correctness traps the port preserves (both silently break
//  verification if violated):
//  - `tcb_info` / `qe_identity` must be the BYTE-EXACT sub-object from the
//    PCS response body — the Intel signature covers those exact bytes, so
//    they are extracted as raw substrings, never parsed-and-re-serialized.
//  - Collateral is time-varying (fresh issueDate/nextUpdate per fetch), so
//    verify(nowSecs:) must be given a time inside the returned window.
//
//  Fail-closed: any fetch or parse failure yields nil collateral, which
//  DCAPVerifier reports as an explicit verification failure.
//

import DcapQvl
import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "collateral")

/// Minimal HTTP seam so tests can stub the PCS responses.
protocol CollateralHTTPClient: Sendable {
    /// GETs `url`; returns the body and response headers for HTTP 2xx, throws otherwise.
    func get(_ url: URL) async throws -> (body: Data, headers: [String: String])
}

struct URLSessionCollateralHTTP: CollateralHTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func get(_ url: URL) async throws -> (body: Data, headers: [String: String]) {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw CollateralHTTPError(status: -1, host: url.host ?? url.absoluteString, path: url.path)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CollateralHTTPError(status: http.statusCode, host: url.host ?? "", path: url.path)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return (data, headers)
    }
}

/// A non-2xx (or missing) response from a collateral endpoint, carrying the
/// status + which host/path failed so the reason survives to the UI.
struct CollateralHTTPError: Error, CustomStringConvertible {
    let status: Int
    let host: String
    let path: String
    var description: String {
        let resource = path.split(separator: "/").last.map(String.init) ?? path
        return status < 0 ? "no response from \(host)" : "HTTP \(status) from \(host) (\(resource))"
    }
}

/// Fetches PCCS collateral from Intel PCS (the collateral authority itself —
/// no third-party PCCS in the trust path) and assembles dcap-qvl's
/// `QuoteCollateralV3` JSON.
///
/// An actor because it caches the per-FMSPC collateral (TCB info, QE identity,
/// CRLs — identical for every machine of the same CPU SKU) so a record's
/// gateway/model/GPU quotes cost one PCS round trip, not three. Crucially the
/// PCK certificate chain is NOT part of that cache: it is machine-specific
/// (two machines share an FMSPC but not a PCK cert), so it is taken from each
/// quote individually. Caching it — as the previous JSON-level cache did —
/// served one machine's PCK chain for another's quote, which dcap-qvl rejects
/// as "Signature is invalid for qe_report in quote".
actor IntelPCSCollateralProvider: CollateralProvider {
    let http: CollateralHTTPClient
    /// PCS base URL, e.g. `https://api.trustedservices.intel.com`.
    let baseURL: String

    /// Per-FMSPC collateral fields (everything except pck_certificate_chain),
    /// keyed by "tee|fmspc|ca". Long PCS validity windows make session-lived
    /// caching safe and it also keeps well clear of Intel PCS rate limits.
    private var fmspcCache: [String: [String: Any]] = [:]

    static let intelPCS = "https://api.trustedservices.intel.com"

    init(http: CollateralHTTPClient = URLSessionCollateralHTTP(),
         baseURL: String = IntelPCSCollateralProvider.intelPCS) {
        self.http = http
        self.baseURL = baseURL
    }

    func collateralJSON(forQuote rawQuote: Data) async throws -> Data {
        do {
            return try await assemble(rawQuote: rawQuote)
        } catch {
            logger.error("[collateral] fetch/assembly failed: \(error)")
            throw error
        }
    }

    enum CollateralError: Error, CustomStringConvertible {
        case quoteMissingPCKChain
        case missingHeader(String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .quoteMissingPCKChain:
                return "quote does not embed a PCK certificate chain (cert_type != 5)"
            case .missingHeader(let name): return "PCS response missing header \(name)"
            case .malformedResponse(let what): return "malformed PCS response: \(what)"
            }
        }
    }

    private func assemble(rawQuote: Data) async throws -> Data {
        let quote = try DcapQvl.parseQuote(rawQuote: rawQuote)
        // near.ai quotes embed the PCK chain (cert_type 5); the encrypted-PPID
        // PCK lookup path is deliberately unsupported (fail-closed).
        guard let pckChain = quote.certChainPem, let fmspc = quote.fmspc, let ca = quote.ca else {
            throw CollateralError.quoteMissingPCKChain
        }
        let tee = quote.kind == .sgx ? "sgx" : "tdx"

        // Shared per-FMSPC fields (cached), then this quote's own PCK chain.
        var collateral = try await fmspcFields(fmspc: fmspc, ca: ca, tee: tee)
        collateral["pck_certificate_chain"] = pckChain
        return try JSONSerialization.data(withJSONObject: collateral)
    }

    /// The eight collateral fields that are identical for every machine of the
    /// same FMSPC (TCB info, QE identity, PCK CRL, root CA CRL + their issuer
    /// chains/signatures). Fetched once per FMSPC and cached; the machine-
    /// specific `pck_certificate_chain` is added by the caller, never here.
    private func fmspcFields(fmspc: String, ca: String, tee: String) async throws -> [String: Any] {
        let key = "\(tee)|\(fmspc.lowercased())|\(ca)"
        if let cached = fmspcCache[key] { return cached }

        // TCB info (tee-specific, by FMSPC).
        let tcb = try await get("\(baseURL)/\(tee)/certification/v4/tcb?fmspc=\(fmspc.lowercased())")
        let tcbIssuerChain = try issuerChain(tcb.headers, "TCB-Info-Issuer-Chain", "SGX-TCB-Info-Issuer-Chain")
        let (tcbInfo, tcbSignature) = try signedBody(tcb.body, key: "tcbInfo", what: "TCB info")

        // QE identity (tee-specific).
        let qe = try await get("\(baseURL)/\(tee)/certification/v4/qe/identity?update=standard")
        let qeIssuerChain = try issuerChain(qe.headers, "SGX-Enclave-Identity-Issuer-Chain")
        let (qeIdentity, qeSignature) = try signedBody(qe.body, key: "enclaveIdentity", what: "QE identity")

        // PCK CRL (always under /sgx/, DER body).
        let pckCRL = try await get("\(baseURL)/sgx/certification/v4/pckcrl?ca=\(ca)&encoding=der")
        let pckCRLIssuerChain = try issuerChain(pckCRL.headers, "SGX-PCK-CRL-Issuer-Chain")

        // Root CA CRL. Intel PCS has no /rootcacrl endpoint — the CRL lives at
        // the distribution point named by the (pinned-root-validated) root
        // cert of the QE identity issuer chain. Non-Intel PCCS bases serve it
        // hex-encoded at /rootcacrl; fall back to the distribution point.
        let rootCACRL = try await fetchRootCACRL(qeIssuerChain: qeIssuerChain)

        // Byte fields are hex strings: dcap-qvl's collateral serde uses the
        // serde-human-bytes crate, which is hex in human-readable formats.
        let fields: [String: Any] = [
            "pck_crl_issuer_chain": pckCRLIssuerChain,
            "root_ca_crl": rootCACRL.hexString,
            "pck_crl": pckCRL.body.hexString,
            "tcb_info_issuer_chain": tcbIssuerChain,
            "tcb_info": tcbInfo,
            "tcb_info_signature": tcbSignature.hexString,
            "qe_identity_issuer_chain": qeIssuerChain,
            "qe_identity": qeIdentity,
            "qe_identity_signature": qeSignature.hexString,
        ]
        fmspcCache[key] = fields
        return fields
    }

    private func get(_ url: String) async throws -> (body: Data, headers: [String: String]) {
        guard let url = URL(string: url) else {
            throw CollateralError.malformedResponse("bad URL \(url)")
        }
        return try await http.get(url)
    }

    /// Returns the first present issuer-chain header, URL-decoded to PEM.
    private func issuerChain(_ headers: [String: String], _ names: String...) throws -> String {
        for name in names {
            guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
            else { continue }
            guard let pem = raw.removingPercentEncoding else {
                throw CollateralError.malformedResponse("undecodable header \(name)")
            }
            return pem
        }
        throw CollateralError.missingHeader(names[0])
    }

    /// Splits a signed PCS body `{"<key>":{…},"signature":"hex"}` into the
    /// byte-exact raw sub-object (the signature covers those exact bytes)
    /// and the decoded signature.
    private func signedBody(_ body: Data, key: String, what: String) throws -> (raw: String, signature: Data) {
        guard let raw = Self.rawJSONObject(forKey: key, in: body) else {
            throw CollateralError.malformedResponse("\(what) missing \"\(key)\" object")
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let signatureHex = envelope["signature"] as? String,
              let signature = try? Data(hexString: signatureHex) else {
            throw CollateralError.malformedResponse("\(what) missing signature")
        }
        return (raw, signature)
    }

    private func fetchRootCACRL(qeIssuerChain: String) async throws -> Data {
        if baseURL != Self.intelPCS,
           let (body, _) = try? await get("\(baseURL)/sgx/certification/v4/rootcacrl"),
           let hex = String(data: body, encoding: .utf8),
           let der = try? Data(hexString: hex) {
            return der
        }
        guard let rootDER = Self.pemCertificatesDER(qeIssuerChain).last,
              let crlURL = Self.crlDistributionPointURI(certDER: rootDER) else {
            throw CollateralError.malformedResponse("no CRL distribution point in root CA cert")
        }
        return try await get(crlURL).body
    }

    // MARK: - Byte-exact JSON sub-object extraction

    /// Returns the raw `{…}` object following `"key":` in `body`, byte-exact
    /// (brace-balanced, string- and escape-aware). UTF-8 decoding is lossless
    /// here, so the returned String re-encodes to the identical bytes.
    static func rawJSONObject(forKey key: String, in body: Data) -> String? {
        let bytes = [UInt8](body)
        let pattern = [UInt8]("\"\(key)\"".utf8)
        guard var i = firstRange(of: pattern, in: bytes).map({ $0 + pattern.count }) else { return nil }
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
        let start = i
        var depth = 0
        var inString = false
        var escaped = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if b == UInt8(ascii: "\\") { escaped = true }
                else if b == UInt8(ascii: "\"") { inString = false }
            } else {
                switch b {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 {
                        return String(bytes: bytes[start...i], encoding: .utf8)
                    }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Root CA CRL distribution point (minimal DER walk)

    /// Extracts the first http(s) URI from the certificate's CRL Distribution
    /// Points extension (OID 2.5.29.31). Same minimal-DER-walk approach as
    /// ProvenanceVerifier.subjectAltNameURI — iOS lacks SecCertificateCopyValues.
    static func crlDistributionPointURI(certDER: Data) -> String? {
        let bytes = [UInt8](certDER)
        // OID 2.5.29.31 = 55 1D 1F.
        let crlOID: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x1F]
        guard let oidIdx = firstRange(of: crlOID, in: bytes) else { return nil }
        var i = oidIdx + crlOID.count
        // Optional BOOLEAN "critical" (01 01 FF).
        if i < bytes.count, bytes[i] == 0x01 { i += 3 }
        // OCTET STRING wrapper around the DistributionPoints SEQUENCE.
        guard i < bytes.count, bytes[i] == 0x04 else { return nil }
        i += 1
        guard let (octetLen, afterLen) = derLength(bytes, i) else { return nil }
        i = afterLen
        let octetEnd = min(i + octetLen, bytes.count)
        // Inside: nested SEQUENCE / [0] / [0] wrappers around GeneralNames;
        // scan for the URI tag [6] (0x86) whose value is an http(s) URL.
        while i < octetEnd {
            if bytes[i] == 0x86, let (len, after) = derLength(bytes, i + 1), after + len <= octetEnd,
               let uri = String(bytes: bytes[after..<after + len], encoding: .utf8),
               uri.hasPrefix("http") {
                return uri
            }
            i += 1
        }
        return nil
    }

    /// Extracts the DER bytes of each PEM certificate in `pem`, in order.
    static func pemCertificatesDER(_ pem: String) -> [Data] {
        var certs: [Data] = []
        var rest = Substring(pem)
        while let begin = rest.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = rest.range(of: "-----END CERTIFICATE-----") {
            let base64 = rest[begin.upperBound..<end.lowerBound]
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            if let der = Data(base64Encoded: base64) { certs.append(der) }
            rest = rest[end.upperBound...]
        }
        return certs
    }

    private static func derLength(_ bytes: [UInt8], _ idx: Int) -> (Int, Int)? {
        guard idx < bytes.count else { return nil }
        let first = bytes[idx]
        if first & 0x80 == 0 { return (Int(first), idx + 1) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, idx + count < bytes.count else { return nil }
        var len = 0
        for j in 0..<count { len = (len << 8) | Int(bytes[idx + 1 + j]) }
        return (len, idx + 1 + count)
    }

    private static func firstRange(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count)
        where Array(bytes[start..<start + pattern.count]) == pattern {
            return start
        }
        return nil
    }
}
