//
//  ConformanceErrorCopyVectors.swift
//  teemoonTests
//
//  The error card's words, approved by the maintainer on the review page 2026-10-28 (error-card-lowercase,
//  network-error-copy). Before this, a timeout read "An unexpected error occurred with Fireworks. The
//  request timed out.": URLError had no mapping and fell to a catch-all that printed Foundation's text.
//  Lines are declared here, not computed, so a wording change fails this suite and Android runs the
//  same rows from conformance/errorcopy.json. `{provider}` is the provider's (or home server's) name as
//  the app shows it.
//

import Foundation
import Testing
@testable import teemoon

struct ErrorCopyVectors: Encodable {
    struct NetworkRow: Encodable {
        let note: String
        /// NSURLErrorDomain code.
        let urlErrorCode: Int
        /// Some of the answer had already been shown.
        let answerStarted: Bool
        /// The provider is a home server (private host), not a cloud provider.
        let selfHosted: Bool
        let line: String
    }
    struct StatusRow: Encodable {
        let status: Int
        let line: String
    }
    let rule: String
    let network: [NetworkRow]
    let catchAll: String
    let status: [StatusRow]
}

enum ConformanceErrorCopyVectors {
    static let rule = """
        A URLError is classified by its code: timedOut (before any answer) and timedOut after part of \
        the answer was shown are different lines; notConnectedToInternet and dataNotAllowed are \
        offline; networkConnectionLost is a dropped connection; cannotFindHost, cannotConnectToHost \
        and dnsLookupFailed are unreachable, worded for a home server when the provider is self-hosted; \
        secureConnectionFailed and the certificate codes are an insecure connection. Any other failure \
        that is not already a worded error shows the catch-all, with the details on the card below it.
        """

    static let timedOut = "{provider} took too long to answer. try again."
    static let stalled = "{provider} stopped partway through the answer. try again."
    static let offline = "no connection, so nothing was sent. try again when you're online."
    static let dropped = "the connection dropped before {provider} finished. try again."
    static let unreachable = "can't reach {provider}. check your connection and try again."
    static let unreachableHome = "can't reach {provider}. is it on and on this network?"
    static let insecure = "couldn't open a secure connection to {provider}, so nothing was sent."
    static let catchAll = "something went wrong talking to {provider}. the details are below."

    static let network: [ErrorCopyVectors.NetworkRow] = {
        func row(_ note: String, _ code: URLError.Code, started: Bool = false, home: Bool = false,
                 _ line: String) -> ErrorCopyVectors.NetworkRow {
            .init(note: note, urlErrorCode: code.rawValue, answerStarted: started, selfHosted: home, line: line)
        }
        return [
            row("no answer before the request timed out", .timedOut, timedOut),
            row("the stream stalled after text was shown (the stall watchdog)", .timedOut, started: true, stalled),
            row("no internet", .notConnectedToInternet, offline),
            row("mobile data off for the app", .dataNotAllowed, offline),
            row("the connection dropped mid-answer", .networkConnectionLost, started: true, dropped),
            row("the connection dropped before any text", .networkConnectionLost, dropped),
            row("unknown host, cloud", .cannotFindHost, unreachable),
            row("refused, cloud", .cannotConnectToHost, unreachable),
            row("DNS failed, cloud", .dnsLookupFailed, unreachable),
            row("unknown host, home server", .cannotFindHost, home: true, unreachableHome),
            row("refused, home server", .cannotConnectToHost, home: true, unreachableHome),
            row("DNS failed, home server", .dnsLookupFailed, home: true, unreachableHome),
            row("TLS handshake failed", .secureConnectionFailed, insecure),
            row("untrusted certificate", .serverCertificateUntrusted, insecure),
            row("certificate has a bad date", .serverCertificateHasBadDate, insecure),
            row("certificate has an unknown root", .serverCertificateHasUnknownRoot, insecure),
            row("certificate not yet valid", .serverCertificateNotYetValid, insecure),
            row("anything else", .badServerResponse, catchAll),
            row("a timeout on a home server is still a timeout", .timedOut, home: true, timedOut),
        ]
    }()

    static let status: [ErrorCopyVectors.StatusRow] = [
        .init(status: 401, line: "{provider} rejected the request (http 401). your api key may be invalid or missing."),
        .init(status: 402, line: "{provider} has no credits, or the balance is too low (http 402). add credits, then retry."),
        .init(status: 403, line: "{provider} denied access (http 403). your api key may not have permission for this model."),
        .init(status: 404, line: "{provider} endpoint not found (http 404). check the server address in settings → places & keys."),
        .init(status: 422, line: "{provider} rejected the request format (http 422). the model name may be invalid."),
        .init(status: 429, line: "{provider} rate limit reached (http 429). try again in a moment."),
        .init(status: 503, line: "{provider} server error (http 503). the service may be down for a moment."),
        .init(status: 418, line: "{provider} returned an error (http 418)."),
    ]

    static func errorCopy() -> ErrorCopyVectors {
        ErrorCopyVectors(rule: rule, network: network, catchAll: catchAll, status: status)
    }
}

@Suite("Conformance vectors — error copy")
struct ConformanceErrorCopyTests {
    static func cloud(_ name: String = "{provider}") -> Provider {
        var p = Provider.fireworks
        p.name = name
        return p
    }

    static func home(_ name: String = "{provider}") -> Provider {
        var p = Provider.fireworks
        p.name = name
        p.endpoint = "http://192.168.1.20:11434/v1"
        return p
    }

    @Test(arguments: ConformanceErrorCopyVectors.network.indices)
    func everyNetworkFailureGetsItsLine(_ index: Int) {
        let row = ConformanceErrorCopyVectors.network[index]
        let provider = row.selfHosted ? Self.home() : Self.cloud()
        #expect(provider.isSelfHosted == row.selfHosted)
        let error = URLError(URLError.Code(rawValue: row.urlErrorCode))
        #expect(ChatGeneration.cardMessage(for: error, provider: provider, answerStarted: row.answerStarted) == row.line,
                "\(row.note)")
    }

    @Test(arguments: ConformanceErrorCopyVectors.status.indices)
    func everyStatusGetsItsLine(_ index: Int) {
        let row = ConformanceErrorCopyVectors.status[index]
        #expect(LLMError.providerMessage(httpStatus: row.status, provider: "{provider}") == row.line)
    }

    @Test("the name is the one the app shows, unchanged")
    func providerNameIsShownAsIs() {
        #expect(ChatGeneration.cardMessage(for: URLError(.timedOut), provider: Self.cloud("Fireworks"), answerStarted: false)
                == "Fireworks took too long to answer. try again.")
    }

    @Test("a non-network failure that isn't worded shows the catch-all, not Foundation's text")
    func otherErrorsShowTheCatchAll() {
        struct Opaque: Error {}
        #expect(ChatGeneration.cardMessage(for: Opaque(), provider: Self.cloud(), answerStarted: false)
                == ConformanceErrorCopyVectors.catchAll)
    }

    @Test("an on-device failure keeps its own line")
    func onDeviceErrorsKeepTheirLine() {
        let error = LocalInferenceError.insufficientMemory(needMB: 2700, availableMB: 1200)
        #expect(ChatGeneration.cardMessage(for: error, provider: Self.cloud(), answerStarted: false)
                == "not enough free memory to load this model (needs about 2700 mb, 1200 mb free). close some apps, or pick a smaller model.")
    }

    @Test func theCommittedFixtureMatchesTheTable() throws {
        guard TestFixture.sourceTreeAvailable() else { return }
        let url = ConformanceEmitTests.outputDirectory().appendingPathComponent("errorcopy.json")
        let committed = try Data(contentsOf: url)
        let fresh = try ConformanceEncoder.encode(ConformanceDocument(
            kitVersion: ConformanceVectors.kitVersion, fixtureClass: "errorcopy",
            sourceOfTruth: "teemoon-ios", vectors: ConformanceErrorCopyVectors.errorCopy()))
        #expect(committed == fresh, "conformance/errorcopy.json is stale: run make conformance")
    }
}
