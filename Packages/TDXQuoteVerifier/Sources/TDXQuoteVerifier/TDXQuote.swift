//
//  TDXQuote.swift
//  TDXQuoteVerifier
//
//  Intel TDX Quote v4 binary structure definitions and parser.
//
//  Reference: Intel SGX DCAP Quote Generation & Verification Library
//  https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/

import Foundation

// MARK: - Quote structures

/// Parsed Intel TDX Quote v4.
public struct TDXQuote: Sendable {
    public let header: Header
    public let body: TDReportBody
    public let signature: SignatureData

    public init(header: Header, body: TDReportBody, signature: SignatureData) {
        self.header = header; self.body = body; self.signature = signature
    }

    /// 48-byte quote header.
    public struct Header: Sendable {
        public let version: UInt16
        public let attestationKeyType: UInt16
        public let teeType: UInt32
        public let qeVendorID: Data    // 16 bytes
        public let userData: Data       // 20 bytes

        public var isTDX: Bool { teeType == 0x00000081 }
        public var isECDSA256: Bool { attestationKeyType == 2 }

        public init(version: UInt16, attestationKeyType: UInt16, teeType: UInt32, qeVendorID: Data, userData: Data) {
            self.version = version; self.attestationKeyType = attestationKeyType; self.teeType = teeType
            self.qeVendorID = qeVendorID; self.userData = userData
        }
    }

    /// 584-byte TD Report Body containing TEE measurements.
    public struct TDReportBody: Sendable {
        public let teeTcbSvn: Data      // 16 bytes
        public let mrSeam: Data         // 48 bytes
        public let mrSignerSeam: Data   // 48 bytes
        public let seamAttributes: Data // 8 bytes
        public let tdAttributes: Data   // 8 bytes
        public let xfam: Data           // 8 bytes
        public let mrtd: Data           // 48 bytes — primary TEE measurement
        public let mrConfigID: Data     // 48 bytes
        public let mrOwner: Data        // 48 bytes
        public let mrOwnerConfig: Data  // 48 bytes
        public let rtmr0: Data          // 48 bytes
        public let rtmr1: Data          // 48 bytes
        public let rtmr2: Data          // 48 bytes
        public let rtmr3: Data          // 48 bytes
        public let reportData: Data     // 64 bytes

        public init(teeTcbSvn: Data, mrSeam: Data, mrSignerSeam: Data, seamAttributes: Data,
                    tdAttributes: Data, xfam: Data, mrtd: Data, mrConfigID: Data, mrOwner: Data,
                    mrOwnerConfig: Data, rtmr0: Data, rtmr1: Data, rtmr2: Data, rtmr3: Data, reportData: Data) {
            self.teeTcbSvn = teeTcbSvn; self.mrSeam = mrSeam; self.mrSignerSeam = mrSignerSeam
            self.seamAttributes = seamAttributes; self.tdAttributes = tdAttributes; self.xfam = xfam
            self.mrtd = mrtd; self.mrConfigID = mrConfigID; self.mrOwner = mrOwner
            self.mrOwnerConfig = mrOwnerConfig; self.rtmr0 = rtmr0; self.rtmr1 = rtmr1
            self.rtmr2 = rtmr2; self.rtmr3 = rtmr3; self.reportData = reportData
        }
    }

    /// Signature section following the quote body.
    public struct SignatureData: Sendable {
        /// ECDSA P-256 signature over (header || body): r || s, 64 bytes.
        public let ecdsaSignature: Data
        /// ECDSA attestation public key: x || y, 64 bytes (uncompressed P-256).
        public let attestationPublicKey: Data
        /// PEM-encoded certificate chain extracted from certification data.
        /// Typically: [PCK cert, Platform CA cert, Root CA cert].
        public let certificateChainPEM: [String]
        /// Raw certification data bytes (for advanced inspection).
        public let rawCertificationData: Data

        public init(ecdsaSignature: Data, attestationPublicKey: Data, certificateChainPEM: [String], rawCertificationData: Data) {
            self.ecdsaSignature = ecdsaSignature; self.attestationPublicKey = attestationPublicKey
            self.certificateChainPEM = certificateChainPEM; self.rawCertificationData = rawCertificationData
        }
    }
}

// MARK: - Measurements (convenience accessor)

/// Human-readable measurement summary extracted from a TDX quote.
public struct TDXMeasurements: Sendable {
    public let mrtd: Data
    public let mrSeam: Data
    public let mrConfigID: Data
    public let mrOwner: Data
    public let rtmr0: Data
    public let rtmr1: Data
    public let rtmr2: Data
    public let rtmr3: Data
    public let reportData: Data

    public init(mrtd: Data, mrSeam: Data, mrConfigID: Data, mrOwner: Data,
                rtmr0: Data, rtmr1: Data, rtmr2: Data, rtmr3: Data, reportData: Data) {
        self.mrtd = mrtd; self.mrSeam = mrSeam; self.mrConfigID = mrConfigID; self.mrOwner = mrOwner
        self.rtmr0 = rtmr0; self.rtmr1 = rtmr1; self.rtmr2 = rtmr2; self.rtmr3 = rtmr3
        self.reportData = reportData
    }

    public init(from body: TDXQuote.TDReportBody) {
        self.mrtd = body.mrtd
        self.mrSeam = body.mrSeam
        self.mrConfigID = body.mrConfigID
        self.mrOwner = body.mrOwner
        self.rtmr0 = body.rtmr0
        self.rtmr1 = body.rtmr1
        self.rtmr2 = body.rtmr2
        self.rtmr3 = body.rtmr3
        self.reportData = body.reportData
    }

    /// Hex-encoded MRTD for display/comparison.
    public var mrtdHex: String { mrtd.hexString }
    public var reportDataHex: String { reportData.hexString }
}

// MARK: - Parser

public enum QuoteParseError: Error, Sendable {
    case dataTooShort(expected: Int, got: Int)
    case unsupportedVersion(UInt16)
    case unsupportedTEEType(UInt32)
    case invalidSignatureDataSize
    case noCertificateChainFound
}

/// Header: 48 bytes, TD Report Body: 584 bytes
private let headerSize = 48
private let tdReportBodySize = 584
private let minQuoteSize = headerSize + tdReportBodySize + 4 // + sig_data_size field

public enum QuoteParser {

    /// Parses a TDX Quote v4 from raw binary data.
    public static func parse(_ data: Data) throws -> TDXQuote {
        guard data.count >= minQuoteSize else {
            throw QuoteParseError.dataTooShort(expected: minQuoteSize, got: data.count)
        }

        let header = parseHeader(data)
        guard header.version == 4 else {
            throw QuoteParseError.unsupportedVersion(header.version)
        }
        guard header.isTDX else {
            throw QuoteParseError.unsupportedTEEType(header.teeType)
        }

        let body = parseTDReportBody(data, offset: headerSize)
        let signature = try parseSignatureData(data, offset: headerSize + tdReportBodySize)

        return TDXQuote(header: header, body: body, signature: signature)
    }

    /// Parses from a hex-encoded quote string (as returned by attestation endpoints).
    public static func parse(hex: String) throws -> TDXQuote {
        guard let data = Data(hexString: hex) else {
            throw QuoteParseError.dataTooShort(expected: minQuoteSize, got: 0)
        }
        return try parse(data)
    }

    // MARK: - Private

    private static func parseHeader(_ data: Data) -> TDXQuote.Header {
        TDXQuote.Header(
            version:            data.uint16(at: 0),
            attestationKeyType: data.uint16(at: 2),
            teeType:            data.uint32(at: 4),
            qeVendorID:         data.subdata(in: 12..<28),
            userData:           data.subdata(in: 28..<48)
        )
    }

    private static func parseTDReportBody(_ data: Data, offset o: Int) -> TDXQuote.TDReportBody {
        var p = o
        func read(_ n: Int) -> Data {
            defer { p += n }
            return data.subdata(in: p..<(p + n))
        }
        return TDXQuote.TDReportBody(
            teeTcbSvn:      read(16),
            mrSeam:         read(48),
            mrSignerSeam:   read(48),
            seamAttributes: read(8),
            tdAttributes:   read(8),
            xfam:           read(8),
            mrtd:           read(48),
            mrConfigID:     read(48),
            mrOwner:        read(48),
            mrOwnerConfig:  read(48),
            rtmr0:          read(48),
            rtmr1:          read(48),
            rtmr2:          read(48),
            rtmr3:          read(48),
            reportData:     read(64)
        )
    }

    private static func parseSignatureData(_ data: Data, offset o: Int) throws -> TDXQuote.SignatureData {
        guard data.count >= o + 4 else {
            throw QuoteParseError.invalidSignatureDataSize
        }
        let sigDataSize = Int(data.uint32(at: o))
        let sigStart = o + 4
        guard data.count >= sigStart + sigDataSize, sigDataSize >= 128 else {
            throw QuoteParseError.invalidSignatureDataSize
        }

        let ecdsaSig = data.subdata(in: sigStart..<(sigStart + 64))
        let attestKey = data.subdata(in: (sigStart + 64)..<(sigStart + 128))

        // After sig(64) + key(64), the ECDSA Quote Signature Data contains:
        //   QE Certification Data:
        //     uint16 type
        //     uint32 size
        //     variable data
        //
        // If type == 6 (QE Report Certification Data), the data contains:
        //     QE Report (384 bytes)
        //     QE Report Signature (64 bytes)
        //     QE Auth Data: uint16 size + variable data
        //     Nested Certification Data: uint16 type + uint32 size + data (PEM certs when type=5)
        let remaining = data.subdata(in: (sigStart + 128)..<(sigStart + sigDataSize))
        var certData = remaining
        var pemCerts: [String] = []

        if remaining.count >= 6 {
            let outerType = remaining.uint16(at: 0)
            let outerSize = Int(remaining.uint32(at: 2))
            let outerPayloadStart = 6

            if outerType == 5, outerPayloadStart + outerSize <= remaining.count {
                // Type 5: PEM cert chain directly
                let payload = remaining.subdata(in: outerPayloadStart..<(outerPayloadStart + outerSize))
                pemCerts = extractPEMCertificates(from: payload)
                certData = payload
            } else if outerType == 6, outerPayloadStart + outerSize <= remaining.count {
                // Type 6: QE Report + nested cert data
                let inner = remaining.subdata(in: outerPayloadStart..<(outerPayloadStart + outerSize))
                let qeReportSize = 384
                let qeReportSigSize = 64
                var p = qeReportSize + qeReportSigSize
                if p + 2 <= inner.count {
                    let authDataSize = Int(inner.uint16(at: p))
                    p += 2 + authDataSize
                    // Nested Certification Data
                    if p + 6 <= inner.count {
                        let nestedType = inner.uint16(at: p)
                        p += 2
                        let nestedSize = Int(inner.uint32(at: p))
                        p += 4
                        if p + nestedSize <= inner.count {
                            let nestedPayload = inner.subdata(in: p..<(p + nestedSize))
                            if nestedType == 5 {
                                pemCerts = extractPEMCertificates(from: nestedPayload)
                            } else {
                                pemCerts = extractPEMCertificates(from: nestedPayload)
                            }
                            certData = nestedPayload
                        }
                    }
                }
            }
        }

        // Fallback: scan the entire remaining data for PEM certs
        if pemCerts.isEmpty {
            pemCerts = extractPEMCertificates(from: remaining)
        }

        return TDXQuote.SignatureData(
            ecdsaSignature: ecdsaSig,
            attestationPublicKey: attestKey,
            certificateChainPEM: pemCerts,
            rawCertificationData: certData
        )
    }

    /// Scans raw bytes for PEM certificate blocks.
    private static func extractPEMCertificates(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return []
        }
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        var certs: [String] = []
        var searchRange = text.startIndex..<text.endIndex

        while let beginRange = text.range(of: beginMarker, range: searchRange) {
            guard let endRange = text.range(of: endMarker, range: beginRange.upperBound..<text.endIndex) else { break }
            let pem = String(text[beginRange.lowerBound...endRange.upperBound])
            certs.append(pem.trimmingCharacters(in: .whitespacesAndNewlines))
            searchRange = endRange.upperBound..<text.endIndex
        }
        return certs
    }
}

// MARK: - Data helpers

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) |
        UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[startIndex + offset]) |
        UInt32(self[startIndex + offset + 1]) << 8 |
        UInt32(self[startIndex + offset + 2]) << 16 |
        UInt32(self[startIndex + offset + 3]) << 24
    }

    /// Hex-encoded string (lowercase, no prefix).
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from a hex string.
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
