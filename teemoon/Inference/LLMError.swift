//
//  LLMError.swift
//  teemoon
//
//  Structured error from one generation: a user-facing line plus the
//  request/response context the debug card shows.
//

import Foundation

/// Structured error carrying both a user-friendly message and full debugging context.
struct LLMError: Error {
    enum Source {
        case provider(name: String)
        case braveGrounding
    }
    let source: Source
    let userMessage: String
    let httpStatus: Int?
    let url: URL?
    let requestHeaders: [String: String]?
    let requestBodyJSON: String?
    let messageHistory: String?
    let responseBody: String?
    let underlyingError: Error?

    static func providerMessage(httpStatus: Int, provider: String) -> String {
        switch httpStatus {
        case 401: return "\(provider) rejected the request (http 401). your api key may be invalid or missing."
        case 402: return "\(provider) has no credits, or the balance is too low (http 402). add credits, then retry."
        case 403: return "\(provider) denied access (http 403). your api key may not have permission for this model."
        case 404: return "\(provider) endpoint not found (http 404). check the server address in settings → places & keys."
        case 422: return "\(provider) rejected the request format (http 422). the model name may be invalid."
        case 429: return "\(provider) rate limit reached (http 429). try again in a moment."
        case 500...599: return "\(provider) server error (http \(httpStatus)). the service may be down for a moment."
        default: return "\(provider) returned an error (http \(httpStatus))."
        }
    }

    /// Brave's error body: `{"error":{"code":"…","detail":"…"}}`. A key it
    /// cannot parse answers HTTP 422 with code SUBSCRIPTION_TOKEN_INVALID —
    /// not a 401 — so the status alone does not say "bad key".
    struct BraveErrorEnvelope: Equatable {
        static let invalidToken = "SUBSCRIPTION_TOKEN_INVALID"
        let code: String
        let detail: String?

        static func parse(_ body: String?) -> BraveErrorEnvelope? {
            guard let body, let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = json["error"] as? [String: Any],
                  let code = error["code"] as? String else { return nil }
            return BraveErrorEnvelope(code: code, detail: error["detail"] as? String)
        }

        var isInvalidToken: Bool { code == Self.invalidToken }
    }

    /// True when the key itself was refused: 401/402/403, or Brave's 422
    /// with SUBSCRIPTION_TOKEN_INVALID. The tool loop must stop on these —
    /// a rephrased query cannot fix a key.
    var isKeyRejection: Bool {
        guard let httpStatus else { return false }
        if httpStatus == 401 || httpStatus == 402 || httpStatus == 403 { return true }
        return httpStatus == 422 && BraveErrorEnvelope.parse(responseBody)?.isInvalidToken == true
    }

    static func groundingMessage(httpStatus: Int, responseBody: String? = nil) -> String {
        let envelope = BraveErrorEnvelope.parse(responseBody)
        if envelope?.isInvalidToken == true {
            return "brave web search rejected the api key (http \(httpStatus)): "
                + (envelope?.detail ?? "the key isn't valid.")
                + " check your brave api key in settings → search."
        }
        switch httpStatus {
        case 401: return "brave web search failed (http 401). check your brave api key in settings → search."
        case 402: return "brave web search failed (http 402). your brave api subscription has run out of credits."
        case 403: return "brave web search denied (http 403). your api key may not have access to this endpoint."
        case 429: return "brave web search rate limit reached (http 429). try again in a moment."
        default:
            if let detail = envelope?.detail, !detail.isEmpty {
                return "brave web search returned an error (http \(httpStatus)): \(detail)"
            }
            return "brave web search returned an error (http \(httpStatus))."
        }
    }
}

/// A transport failure as the error card's line. The words are conformance/errorcopy.json; change them
/// only through `ConformanceErrorCopyVectors`, which Android runs too.
enum NetworkFailure: Equatable {
    case timedOut, stalled, offline, dropped, unreachable, unreachableHome, insecure, other

    init(_ code: URLError.Code, answerStarted: Bool, selfHosted: Bool) {
        switch code {
        case .timedOut: self = answerStarted ? .stalled : .timedOut
        case .notConnectedToInternet, .dataNotAllowed: self = .offline
        case .networkConnectionLost: self = .dropped
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: self = selfHosted ? .unreachableHome : .unreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: self = .insecure
        default: self = .other
        }
    }

    func message(provider: String) -> String {
        switch self {
        case .timedOut: "\(provider) took too long to answer. try again."
        case .stalled: "\(provider) stopped partway through the answer. try again."
        case .offline: "no connection, so nothing was sent. try again when you're online."
        case .dropped: "the connection dropped before \(provider) finished. try again."
        case .unreachable: "can't reach \(provider). check your connection and try again."
        case .unreachableHome: "can't reach \(provider). is it on and on this network?"
        case .insecure: "couldn't open a secure connection to \(provider), so nothing was sent."
        case .other: "something went wrong talking to \(provider). the details are below."
        }
    }
}

/// Without this, `localizedDescription` is Foundation's generic
/// "The operation couldn't be completed. (teemoon.LLMError error 1.)" —
/// which is what users saw anywhere an LLMError was interpolated through
/// `localizedDescription`, and why ProviderSmokeTests' skip-on-unreachable matching could never fire.
extension LLMError: LocalizedError {
    var errorDescription: String? { userMessage }
}
