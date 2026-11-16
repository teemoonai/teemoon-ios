//
//  ConformanceRedactionVectors.swift
//  teemoonTests
//
//  What a copied debug card may carry: no stored key, under any header name, in the
//  URL, or anywhere in its free text. A provider that echoes the key in a 401 body put
//  it on the clipboard, and a provider's own auth header name was copied in full
//  (gardener 2026-10-25). Each expected value is declared, not computed, and Android
//  runs the same rows from conformance/redaction.json.
//

import Foundation
import Testing
@testable import teemoon

struct RedactionVectors: Encodable {
    struct Case: Encodable {
        let note: String
        /// "header" (name + input), "url" or "text".
        let kind: String
        let name: String?
        let input: String
        let expected: String
    }
    let rule: String
    /// Set as the app's stored keys for every case.
    let storedSecrets: [String]
    /// Set as the providers' configured auth header names for every case.
    let authHeaderNames: [String]
    let cases: [Case]
}

enum ConformanceRedactionVectors {
    static let key = "sk-live-abcdef1234567890wxyz"
    static let brave = "BSAbrave0000000000keyQ1"

    static let rule = """
        On the copy path a credential keeps its scheme and its last four characters: "Bearer ••••…wxyz"; a \
        secret under 8 characters is "••••". A header is a credential when its name is authorization, \
        x-subscription-token, x-api-key or api-key, when its name is a provider's configured auth header name, \
        or when its value contains a stored key. A URL query value is masked when its name is credential-shaped \
        or it contains a stored key. All copied text has every stored key (8+ characters, longest first) \
        replaced by its mask.
        """

    static let cases: [RedactionVectors.Case] = [
        .init(note: "a standard header", kind: "header", name: "Authorization", input: "Bearer \(key)",
              expected: "Bearer ••••…wxyz"),
        .init(note: "a provider's own auth header name, value not a stored key", kind: "header", name: "X-Portkey-Key",
              input: "pk-custom-9999999999zzzz", expected: "••••…zzzz"),
        .init(note: "an unknown header whose value carries a stored key", kind: "header", name: "x-echo",
              input: "contains \(key)", expected: "contains ••••…wxyz"),
        .init(note: "an ordinary header", kind: "header", name: "Content-Type", input: "application/json",
              expected: "application/json"),
        .init(note: "a query value carrying a stored key under an ordinary name", kind: "url", name: nil,
              input: "https://api.example.com/v1/models?q=1&tok=\(key)", expected: "https://api.example.com/v1/models?q=1&tok=••••…wxyz"),
        .init(note: "a 401 body that echoes the key", kind: "text", name: nil,
              input: #"{"error":{"message":"Incorrect API key provided: \#(key)","code":"invalid_api_key"}}"#,
              expected: #"{"error":{"message":"Incorrect API key provided: ••••…wxyz","code":"invalid_api_key"}}"#),
        .init(note: "the Brave key in a tool result, twice", kind: "text", name: nil,
              input: "token \(brave) and again \(brave).", expected: "token ••••…eyQ1 and again ••••…eyQ1."),
        .init(note: "text with no key is unchanged", kind: "text", name: nil,
              input: "HTTP 401 unauthorized", expected: "HTTP 401 unauthorized"),
    ]

    static func redaction() -> RedactionVectors {
        RedactionVectors(rule: rule, storedSecrets: [key, brave, "short"], authHeaderNames: ["x-portkey-key"], cases: cases)
    }

    static func run(_ c: RedactionVectors.Case) -> String {
        switch c.kind {
        case "header": DebugHeaderRedaction.copyValue(c.input, for: c.name ?? "")
        case "url": DebugHeaderRedaction.copyURLString(c.input)
        default: DebugHeaderRedaction.scrubStoredSecrets(c.input)
        }
    }
}

@Suite("Conformance vectors — copy redaction", .serialized)
struct ConformanceRedactionTests {

    @Test func everyCaseCopiesAsDeclared() {
        let v = ConformanceRedactionVectors.redaction()
        let (secrets, names) = (DebugHeaderRedaction.storedSecrets, DebugHeaderRedaction.credentialHeaderNames)
        DebugHeaderRedaction.storedSecrets = { v.storedSecrets }
        DebugHeaderRedaction.credentialHeaderNames = { Set(v.authHeaderNames) }
        defer { (DebugHeaderRedaction.storedSecrets, DebugHeaderRedaction.credentialHeaderNames) = (secrets, names) }
        for c in v.cases {
            #expect(ConformanceRedactionVectors.run(c) == c.expected, "\(c.note)")
        }
    }

    /// The card a 401 makes: its whole copied text carries the key nowhere.
    @Test @MainActor func aCopied401CardCarriesNoKey() {
        let v = ConformanceRedactionVectors.redaction()
        let (secrets, names) = (DebugHeaderRedaction.storedSecrets, DebugHeaderRedaction.credentialHeaderNames)
        DebugHeaderRedaction.storedSecrets = { v.storedSecrets }
        DebugHeaderRedaction.credentialHeaderNames = { Set(v.authHeaderNames) }
        defer { (DebugHeaderRedaction.storedSecrets, DebugHeaderRedaction.credentialHeaderNames) = (secrets, names) }
        let key = ConformanceRedactionVectors.key
        let error = LLMError(
            source: .provider(name: "custom"),
            userMessage: "invalid key \(key)",
            httpStatus: 401,
            url: URL(string: "https://api.example.com/v1/chat/completions?k=\(key)"),
            requestHeaders: ["X-Portkey-Key": "pk-custom-9999999999zzzz", "Authorization": "Bearer \(key)"],
            requestBodyJSON: "{}",
            messageHistory: nil,
            responseBody: #"{"error":"Incorrect API key provided: \#(key)"}"#,
            underlyingError: nil
        )
        let copied = ErrorMessageView(error: error).debugText
        #expect(!copied.contains(key))
        #expect(!copied.contains("pk-custom-9999999999zzzz"))
        #expect(copied.contains("••••…wxyz"))
    }

    @Test func theCommittedFixtureMatchesTheTable() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("redaction.json")
        let fresh = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "redaction",
            sourceOfTruth: "teemoon-ios", vectors: ConformanceRedactionVectors.redaction()))
        #expect(try Data(contentsOf: url) == fresh, "conformance/redaction.json is stale: run make conformance")
    }
}
