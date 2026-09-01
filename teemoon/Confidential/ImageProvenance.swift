//
//  ImageProvenance.swift
//  teemoon
//
//  Verifies that a container image running inside the enclave was built and
//  signed by near.ai's published GitHub workflow — the "running code traces
//  to published source" guarantee that Phase 1's manifest↔quote binding does
//  not itself provide.
//
//  Input is a GitHub Artifact Attestation (a Sigstore bundle) fetched for an
//  image digest. Verification (all against the fixture in tests):
//    1. DSSE signature over the in-toto payload, ECDSA-P256-SHA256, under the
//       bundle's leaf certificate's public key.
//    2. Leaf certificate chains to the pinned Sigstore/Fulcio roots.
//    3. The leaf's SAN identity (the GitHub workflow URI) matches a pinned
//       near.ai repository policy — this binds the signature to near.ai's
//       source, not merely to "some Fulcio-issued cert."
//    4. The signed SLSA subject digest equals the running image digest.
//    5. Rekor transparency-log inclusion: the entry's signed entry timestamp
//       (SET) verifies under the pinned Rekor key, that key's ID matches the
//       entry's logId, and the logged entry is bound to THIS attestation by
//       payloadHash == SHA256(our DSSE payload). Surfaced as
//       `transparencyLogChecked`.
//
//  Scope note: (5) verifies the inclusion *promise* (SET) — the standard
//  Sigstore client check — not a Merkle inclusion *proof* against a fetched
//  checkpoint.
//

import CryptoKit
import Foundation
import Security

// MARK: - Policy

/// A trusted build identity: the signing certificate's SAN workflow URI must
/// name a workflow of a repository directly under `organizationURL`.
///
/// The org is pinned (not per-repo, and not per-digest) because it is the
/// stable trust anchor: near.ai adds build repositories and rotates images
/// freely (a pinned repo list fail-closed the day `dstack-vpc-client`
/// appeared in the live compose), while forging an accepted identity still
/// requires a Fulcio-issued certificate for a workflow inside near.ai's
/// GitHub organization.
struct BuildIdentityPolicy: Sendable, Equatable {
    /// e.g. "https://github.com/nearai"
    let organizationURL: String

    /// The repository URL this identity belongs to, when it is a workflow of
    /// a repo directly under the pinned org (…/<repo>/.github/workflows/…);
    /// nil otherwise.
    func repository(forIdentity identity: String) -> String? {
        let orgPrefix = organizationURL + "/"
        guard identity.hasPrefix(orgPrefix) else { return nil }
        let rest = identity.dropFirst(orgPrefix.count)
        guard let workflows = rest.range(of: "/.github/workflows/") else { return nil }
        let repo = rest[..<workflows.lowerBound]
        guard !repo.isEmpty, !repo.contains("/") else { return nil }
        return orgPrefix + repo
    }

    static let nearAI: [BuildIdentityPolicy] = [
        BuildIdentityPolicy(organizationURL: "https://github.com/nearai"),
    ]
}

// MARK: - Result

enum ImageProvenance: Sendable, Equatable {
    /// The image digest was signed by a pinned near.ai workflow.
    /// `sourceRef` (e.g. "refs/tags/v0.5.1") and `sourceCommit` come from the
    /// signed SLSA payload — attested build claims, surfaced so the user can
    /// open the exact source; the digest match remains the hard guarantee.
    /// `transparencyLogChecked` reflects Rekor SET verification (see the file header).
    case verified(repositoryURL: String, workflowIdentity: String,
                  sourceRef: String?, sourceCommit: String?,
                  transparencyLogChecked: Bool)
    case unverified(Reason)

    enum Reason: Sendable, Equatable {
        case malformedBundle(String)
        case signatureInvalid
        case certificateChainInvalid(String)
        case identityNotTrusted(got: String)
        case digestMismatch(expected: String, got: String)
        /// Definitive: the attestation was fetched and is absent/wrong (e.g.
        /// HTTP 404 — no attestation exists for this digest). Fail-closed.
        case fetchFailed(String)
        /// Transient: rate limit, network error, server error — no evidence
        /// either way. Callers should treat the check as inconclusive rather
        /// than failed.
        case fetchTransient(String)
    }

    var isVerified: Bool { if case .verified = self { return true }; return false }

    /// A short, plain-language reason this image is not verified — so the UI
    /// can say *why* a specific image failed rather than only counting it.
    /// nil when verified.
    var failureReason: String? {
        guard case .unverified(let reason) = self else { return nil }
        switch reason {
        case .fetchFailed:
            return "no published attestation (GitHub 404)"
        case .fetchTransient:
            return "couldn\u{2019}t reach GitHub (rate-limited or offline)"
        case .signatureInvalid:
            return "signature didn\u{2019}t verify"
        case .certificateChainInvalid:
            return "certificate didn\u{2019}t chain to Sigstore\u{2019}s roots"
        case .identityNotTrusted:
            return "signed by an identity outside near.ai\u{2019}s org"
        case .digestMismatch:
            return "signed digest doesn\u{2019}t match the running image"
        case .malformedBundle:
            return "attestation bundle was malformed"
        }
    }
}

// MARK: - Verifier

struct ProvenanceVerifier {
    let policies: [BuildIdentityPolicy]

    init(policies: [BuildIdentityPolicy] = BuildIdentityPolicy.nearAI) {
        self.policies = policies
    }

    /// Verifies a GitHub Artifact Attestation bundle against `expectedDigest`
    /// (hex sha256, no prefix). Pure/offline — the caller fetches the bundle.
    func verify(attestationJSON: Data, expectedDigest: String) -> ImageProvenance {
        // Parse the GitHub response envelope → the first bundle.
        guard let response = try? JSONDecoder().decode(AttestationResponse.self, from: attestationJSON),
              let bundle = response.attestations.first?.bundle else {
            return .unverified(.malformedBundle("no attestation bundle"))
        }
        let env = bundle.dsseEnvelope
        guard let payload = Data(base64Encoded: env.payload),
              let signature = Data(base64Encoded: env.signatures.first?.sig ?? ""),
              let certDER = Data(base64Encoded: bundle.verificationMaterial.certificate.rawBytes) else {
            return .unverified(.malformedBundle("payload/signature/certificate not decodable"))
        }

        // 1. DSSE signature (ECDSA-P256-SHA256 over the PAE) under the leaf key.
        guard let leaf = SecCertificateCreateWithData(nil, certDER as CFData),
              let publicKey = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let p256 = try? P256.Signing.PublicKey(x963Representation: keyData) else {
            return .unverified(.malformedBundle("leaf certificate public key unreadable"))
        }
        let pae = Self.preAuthEncoding(payloadType: env.payloadType, payload: payload)
        guard let ecdsaSig = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              p256.isValidSignature(ecdsaSig, for: pae) else {
            return .unverified(.signatureInvalid)
        }

        // 2. Leaf chains to the pinned Sigstore roots, evaluated AS OF the
        //    signing time. Fulcio leaf certs live ~10 minutes and are expected
        //    to be expired at verification time, so we evaluate against the
        //    Rekor-logged `integratedTime` rather than "now". That time is
        //    taken from the bundle; step 5's Rekor SET verification
        //    (transparencyLogChecked) is what makes it authoritative — chain
        //    validity is evaluated first, against the claimed time.
        let signingTime = bundle.verificationMaterial.tlogEntries.first
            .flatMap { TimeInterval($0.integratedTime) }
            .map { Date(timeIntervalSince1970: $0) }
        if let chainError = Self.chainError(leaf: leaf, verifyDate: signingTime) {
            return .unverified(.certificateChainInvalid(chainError))
        }

        // 3. SAN identity matches a pinned near.ai workflow.
        guard let identity = Self.subjectAltNameURI(certDER: certDER) else {
            return .unverified(.malformedBundle("no SAN URI in leaf certificate"))
        }
        guard let repositoryURL = policies.lazy
            .compactMap({ $0.repository(forIdentity: identity) }).first else {
            return .unverified(.identityNotTrusted(got: identity))
        }

        // 4. Signed subject digest equals the running image digest.
        guard let statement = try? JSONDecoder().decode(InTotoStatement.self, from: payload),
              let subjectDigest = statement.subject.first?.digest.sha256 else {
            return .unverified(.malformedBundle("no subject digest in statement"))
        }
        guard subjectDigest.lowercased() == expectedDigest.lowercased() else {
            return .unverified(.digestMismatch(expected: expectedDigest, got: subjectDigest))
        }

        // 5. Rekor transparency-log inclusion: prove the entry was publicly
        //    logged, and that the logged entry is THIS attestation.
        let tlogVerified = Self.transparencyLogVerified(
            tlogEntry: bundle.verificationMaterial.tlogEntries.first,
            dssePayload: payload)

        return .verified(repositoryURL: repositoryURL,
                         workflowIdentity: identity,
                         sourceRef: statement.workflowRef,
                         sourceCommit: statement.sourceCommit,
                         transparencyLogChecked: tlogVerified)
    }

    // MARK: Rekor transparency log

    /// Verifies the Rekor entry's signed entry timestamp (SET) under the pinned
    /// Rekor key, and binds it to our attestation via the entry's payloadHash.
    /// Returns true only when both hold.
    private static func transparencyLogVerified(tlogEntry: SigstoreBundle.VerificationMaterial.TlogEntry?, dssePayload: Data) -> Bool {
        guard let entry = tlogEntry,
              let setSig = Data(base64Encoded: entry.inclusionPromise.signedEntryTimestamp),
              let bodyData = Data(base64Encoded: entry.canonicalizedBody),
              let integratedTime = Int(entry.integratedTime),
              let logIndex = Int(entry.logIndex),
              let keyIdData = Data(base64Encoded: entry.logId.keyId) else { return false }

        // Pinned Rekor key, and its identity must match the entry's logId
        // (keyId is SHA256 of the key's DER SubjectPublicKeyInfo).
        guard let rekorKey = Self.rekorPublicKey(),
              let rekorDER = Self.rekorPublicKeyDER(),
              Data(SHA256.hash(data: rekorDER)) == keyIdData else { return false }

        // Bind the logged entry to THIS attestation: its payloadHash must equal
        // SHA256(our DSSE payload).
        guard let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let spec = body["spec"] as? [String: Any],
              let payloadHash = spec["payloadHash"] as? [String: Any],
              let hashValue = payloadHash["value"] as? String,
              SHA256.hash(data: dssePayload).map({ String(format: "%02x", $0) }).joined() == hashValue.lowercased()
        else { return false }

        // Verify the SET signature over the canonical {body,integratedTime,logIndex,logID}.
        let logIDHex = keyIdData.map { String(format: "%02x", $0) }.joined()
        let canonical = Self.rekorSETCanonicalJSON(
            body: entry.canonicalizedBody, integratedTime: integratedTime,
            logIndex: logIndex, logID: logIDHex)
        guard let ecdsaSig = try? P256.Signing.ECDSASignature(derRepresentation: setSig) else { return false }
        return rekorKey.isValidSignature(ecdsaSig, for: canonical)
    }

    /// Rekor's canonical SET message: JSON with lexicographically sorted keys
    /// and no whitespace. Sorted order is body, integratedTime, logID, logIndex
    /// ("logID" < "logIndex" since 'D' < 'n').
    static func rekorSETCanonicalJSON(body: String, integratedTime: Int, logIndex: Int, logID: String) -> Data {
        let json = "{\"body\":\"\(body)\",\"integratedTime\":\(integratedTime),\"logID\":\"\(logID)\",\"logIndex\":\(logIndex)}"
        return Data(json.utf8)
    }

    private static func rekorPublicKeyDER() -> Data? {
        let base64 = SigstoreTrustRoot.rekorPublicKeyPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return Data(base64Encoded: base64)
    }

    private static func rekorPublicKey() -> P256.Signing.PublicKey? {
        guard let der = rekorPublicKeyDER() else { return nil }
        return try? P256.Signing.PublicKey(derRepresentation: der)
    }

    // MARK: DSSE PAE (v1)

    /// `DSSEv1 SP len(type) SP type SP len(payload) SP payload`, payload raw bytes.
    static func preAuthEncoding(payloadType: String, payload: Data) -> Data {
        var pae = Data("DSSEv1 \(payloadType.utf8.count) \(payloadType) \(payload.count) ".utf8)
        pae.append(payload)
        return pae
    }

    // MARK: Certificate chain

    /// Returns nil when `leaf` chains to the pinned Sigstore roots, else an error string.
    /// `verifyDate` should be the signing time (Fulcio leaves are short-lived);
    /// nil falls back to "now", which will reject any real (expired) Fulcio leaf.
    static func chainError(leaf: SecCertificate, verifyDate: Date?) -> String? {
        guard let intermediate = pinnedCertificate(SigstoreTrustRoot.intermediatePEM),
              let root = pinnedCertificate(SigstoreTrustRoot.rootPEM) else {
            return "pinned Sigstore roots not loadable"
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates([leaf, intermediate] as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else { return "trust creation failed (\(status))" }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if let verifyDate { SecTrustSetVerifyDate(trust, verifyDate as CFDate) }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (error.map { CFErrorCopyDescription($0) as String }) ?? "chain evaluation failed"
        }
        return nil
    }

    private static func pinnedCertificate(_ pem: String) -> SecCertificate? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    // MARK: SAN extraction (minimal DER walk)

    /// Extracts the first URI (context tag [6]) from the certificate's
    /// SubjectAltName extension (OID 2.5.29.17). iOS lacks
    /// `SecCertificateCopyValues`, so we walk the DER directly.
    static func subjectAltNameURI(certDER: Data) -> String? {
        let bytes = [UInt8](certDER)
        // OID 2.5.29.17 = 55 1D 11.
        let sanOID: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x11]
        guard let oidIdx = firstRange(of: sanOID, in: bytes) else { return nil }
        var i = oidIdx + sanOID.count
        // Optional BOOLEAN "critical" (01 01 FF).
        if i < bytes.count, bytes[i] == 0x01 { i += 3 }
        // OCTET STRING wrapper.
        guard i < bytes.count, bytes[i] == 0x04 else { return nil }
        i += 1
        guard let (octetLen, afterLen) = derLength(bytes, i) else { return nil }
        i = afterLen
        let octetEnd = min(i + octetLen, bytes.count)
        // Inside: SEQUENCE of GeneralNames.
        guard i < octetEnd, bytes[i] == 0x30 else { return nil }
        i += 1
        guard let (_, afterSeqLen) = derLength(bytes, i) else { return nil }
        i = afterSeqLen
        // Scan GeneralName entries for context tag [6] (URI) = 0x86.
        while i < octetEnd {
            let tag = bytes[i]; i += 1
            guard let (len, afterL) = derLength(bytes, i) else { return nil }
            i = afterL
            let end = min(i + len, octetEnd)
            if tag == 0x86, let uri = String(bytes: bytes[i..<end], encoding: .utf8) {
                return uri
            }
            i = end
        }
        return nil
    }

    /// Parses a DER length at `idx`; returns (length, indexAfterLengthBytes).
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
        for start in 0...(bytes.count - pattern.count) where Array(bytes[start..<start+pattern.count]) == pattern {
            return start
        }
        return nil
    }
}

// MARK: - Bundle model (GitHub attestations API → Sigstore bundle subset)

private struct AttestationResponse: Decodable {
    let attestations: [Attestation]
    struct Attestation: Decodable { let bundle: SigstoreBundle }
}

private struct SigstoreBundle: Decodable {
    let dsseEnvelope: DSSEEnvelope
    let verificationMaterial: VerificationMaterial

    struct DSSEEnvelope: Decodable {
        let payload: String
        let payloadType: String
        let signatures: [Signature]
        struct Signature: Decodable { let sig: String }
    }
    struct VerificationMaterial: Decodable {
        let certificate: Certificate
        let tlogEntries: [TlogEntry]
        struct Certificate: Decodable { let rawBytes: String }
        /// GitHub encodes `integratedTime` and `logIndex` as strings.
        struct TlogEntry: Decodable {
            let integratedTime: String
            let logIndex: String
            let logId: LogId
            let inclusionPromise: InclusionPromise
            let canonicalizedBody: String
            struct LogId: Decodable { let keyId: String }
            struct InclusionPromise: Decodable { let signedEntryTimestamp: String }
        }
    }
}

private struct InTotoStatement: Decodable {
    let subject: [Subject]
    /// SLSA v1 provenance predicate (GitHub Artifact Attestations). Optional
    /// at every level: a payload without it still verifies — the digest match
    /// is the requirement; ref/commit are extra attested claims.
    let predicate: Predicate?

    struct Subject: Decodable {
        let name: String
        let digest: Digest
        struct Digest: Decodable { let sha256: String }
    }

    struct Predicate: Decodable {
        let buildDefinition: BuildDefinition?
        struct BuildDefinition: Decodable {
            let externalParameters: ExternalParameters?
            let resolvedDependencies: [ResolvedDependency]?
            struct ExternalParameters: Decodable {
                let workflow: Workflow?
                struct Workflow: Decodable { let ref: String? }
            }
            struct ResolvedDependency: Decodable {
                let digest: Digest?
                struct Digest: Decodable { let gitCommit: String? }
            }
        }
    }

    /// The git ref the workflow ran on (e.g. "refs/tags/v0.5.1").
    var workflowRef: String? {
        predicate?.buildDefinition?.externalParameters?.workflow?.ref
    }

    /// The exact source commit the build resolved.
    var sourceCommit: String? {
        predicate?.buildDefinition?.resolvedDependencies?
            .compactMap { $0.digest?.gitCommit }.first
    }
}
