//
//  TDXQuoteVerifier.swift
//  TDXQuoteVerifier
//
//  On-device Intel TDX quote verification.
//
//  Verifies that a TDX quote was produced by a genuine Intel TDX TEE by:
//  1. Parsing the quote binary structure (header, TD report body, signature)
//  2. Verifying the ECDSA P-256 signature over (header || body)
//  3. Verifying the PCK certificate chain back to Intel's SGX Root CA
//
//  This is a minimal verifier focused on cryptographic proof of TEE authenticity.
//  It does NOT perform full TCB status checking (requires fetching Intel PCS collateral).
//
//  Dependencies: CryptoKit (P-256 ECDSA), Security (X.509 cert chain via SecTrust)

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - Verification result

public struct TDXVerificationResult: Sendable {
    /// The parsed quote (always present if parsing succeeded).
    public let quote: TDXQuote
    /// Extracted measurements for comparison against expected values.
    public let measurements: TDXMeasurements
    /// Whether the ECDSA signature over the quote is valid.
    public let signatureValid: Bool
    /// Whether the PCK cert chain is valid and chains to Intel's Root CA.
    public let certChainValid: Bool
    /// Human-readable description of any verification failure.
    public let certChainError: String?

    /// True only if both signature and cert chain are cryptographically verified.
    public var isVerified: Bool { signatureValid && certChainValid }

    public init(quote: TDXQuote, measurements: TDXMeasurements, signatureValid: Bool, certChainValid: Bool, certChainError: String?) {
        self.quote = quote; self.measurements = measurements
        self.signatureValid = signatureValid; self.certChainValid = certChainValid
        self.certChainError = certChainError
    }
}

public enum TDXVerificationError: Error, Sendable {
    case parseError(QuoteParseError)
    case signatureVerificationFailed(String)
    case certChainVerificationFailed(String)
    case platformNotSupported
}

// MARK: - Verifier

public enum TDXQuoteVerifier {

    /// Verifies a TDX quote from raw binary data.
    ///
    /// - Returns: Verification result with measurements, signature validity, and cert chain validity.
    /// - Throws: `TDXVerificationError` if the quote cannot be parsed.
    public static func verify(quoteData: Data) throws -> TDXVerificationResult {
        let quote: TDXQuote
        do {
            quote = try QuoteParser.parse(quoteData)
        } catch let error as QuoteParseError {
            throw TDXVerificationError.parseError(error)
        }

        let measurements = TDXMeasurements(from: quote.body)

        // 1. Verify ECDSA signature over (header || body)
        let signedData = quoteData.prefix(48 + 584) // header + body
        let sigValid = verifyECDSASignature(
            signature: quote.signature.ecdsaSignature,
            publicKey: quote.signature.attestationPublicKey,
            message: signedData
        )

        // 2. Verify certificate chain
        let (certValid, certError) = verifyCertificateChain(pemCerts: quote.signature.certificateChainPEM)

        return TDXVerificationResult(
            quote: quote,
            measurements: measurements,
            signatureValid: sigValid,
            certChainValid: certValid,
            certChainError: certError
        )
    }

    /// Verifies a TDX quote from a hex-encoded string.
    public static func verify(quoteHex: String) throws -> TDXVerificationResult {
        guard let data = Data(hexString: quoteHex) else {
            throw TDXVerificationError.parseError(.dataTooShort(expected: 636, got: 0))
        }
        return try verify(quoteData: data)
    }

    // MARK: - ECDSA signature verification

    /// Verifies a raw ECDSA P-256 signature (r||s, 64 bytes) over a message
    /// using a raw public key (x||y, 64 bytes).
    private static func verifyECDSASignature(signature: Data, publicKey: Data, message: Data) -> Bool {
        guard signature.count == 64, publicKey.count == 64 else { return false }

        // CryptoKit expects the uncompressed point format: 0x04 || x || y
        var uncompressedKey = Data([0x04])
        uncompressedKey.append(publicKey)

        guard let p256Key = try? P256.Signing.PublicKey(x963Representation: uncompressedKey) else {
            return false
        }

        // Convert raw r||s to DER-encoded ECDSA signature
        guard let derSig = ecdsaRawToDER(signature) else { return false }
        guard let p256Sig = try? P256.Signing.ECDSASignature(derRepresentation: derSig) else {
            return false
        }

        return p256Key.isValidSignature(p256Sig, for: SHA256.hash(data: message))
    }

    /// Converts a raw ECDSA signature (r || s, each 32 bytes) to DER encoding.
    ///
    /// DER format: SEQUENCE { INTEGER r, INTEGER s }
    /// Integers need a leading 0x00 byte if their high bit is set (positive sign).
    private static func ecdsaRawToDER(_ raw: Data) -> Data? {
        guard raw.count == 64 else { return nil }
        let r = raw.prefix(32)
        let s = raw.suffix(32)

        func derInteger(_ bytes: Data) -> Data {
            // Strip leading zeros but keep at least one byte
            var trimmed = bytes.drop(while: { $0 == 0 })
            if trimmed.isEmpty { trimmed = Data([0]) }
            // Add leading 0x00 if high bit set (ASN.1 positive integer)
            let needsPad = trimmed.first! & 0x80 != 0
            var result = Data()
            result.append(0x02) // INTEGER tag
            result.append(UInt8(trimmed.count + (needsPad ? 1 : 0)))
            if needsPad { result.append(0x00) }
            result.append(contentsOf: trimmed)
            return result
        }

        let derR = derInteger(r)
        let derS = derInteger(s)

        var sequence = Data()
        sequence.append(0x30) // SEQUENCE tag
        let totalLen = derR.count + derS.count
        if totalLen < 128 {
            sequence.append(UInt8(totalLen))
        } else {
            sequence.append(0x81)
            sequence.append(UInt8(totalLen))
        }
        sequence.append(derR)
        sequence.append(derS)
        return sequence
    }

    // MARK: - Certificate chain verification

    /// Verifies the PCK certificate chain against Intel's SGX Root CA.
    /// Returns (isValid, errorDescription).
    private static func verifyCertificateChain(pemCerts: [String]) -> (Bool, String?) {
        #if canImport(Security)
        guard !pemCerts.isEmpty else {
            return (false, "No certificates found in quote")
        }

        // Parse PEM certs into SecCertificate objects
        var secCerts: [SecCertificate] = []
        for pem in pemCerts {
            guard let cert = secCertificateFromPEM(pem) else {
                return (false, "Failed to parse PEM certificate")
            }
            secCerts.append(cert)
        }

        // Parse Intel Root CA
        guard let rootCA = secCertificateFromPEM(intelSGXRootCAPEM) else {
            return (false, "Failed to parse Intel SGX Root CA")
        }

        // Build trust chain: leaf cert evaluated against the full chain + root anchor
        guard let leaf = secCerts.first else {
            return (false, "No leaf certificate")
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates(
            [leaf] + Array(secCerts.dropFirst()) as CFArray,
            policy,
            &trust
        )
        guard status == errSecSuccess, let trust else {
            return (false, "SecTrustCreateWithCertificates failed: \(status)")
        }

        // Set Intel Root CA as the only trusted anchor
        SecTrustSetAnchorCertificates(trust, [rootCA] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        let valid = SecTrustEvaluateWithError(trust, &error)
        if valid {
            return (true, nil)
        } else {
            let desc = error.map { CFErrorCopyDescription($0) as String? ?? "Unknown error" } ?? "Evaluation failed"
            return (false, desc)
        }
        #else
        return (false, "Certificate chain verification requires Security framework (Apple platforms only)")
        #endif
    }

    #if canImport(Security)
    /// Converts a PEM-encoded certificate string to a SecCertificate.
    private static func secCertificateFromPEM(_ pem: String) -> SecCertificate? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let data = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }
    #endif
}
