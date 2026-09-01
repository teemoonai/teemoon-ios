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
        case 401: return "\(provider) rejected the request (HTTP 401). Your API key may be invalid or missing."
        case 402: return "\(provider) has no credits (or the balance is too low) (HTTP 402). Add credits, then retry."
        case 403: return "\(provider) denied access (HTTP 403). Your API key may not have permission for this model."
        case 404: return "\(provider) endpoint not found (HTTP 404). Check the provider URL in Settings."
        case 422: return "\(provider) rejected the request format (HTTP 422). The model name may be invalid."
        case 429: return "\(provider) rate limit reached (HTTP 429). Try again in a moment."
        case 500...599: return "\(provider) server error (HTTP \(httpStatus)). The service may be temporarily unavailable."
        default: return "\(provider) returned an error (HTTP \(httpStatus))."
        }
    }

    static func groundingMessage(httpStatus: Int) -> String {
        switch httpStatus {
        case 401: return "Brave web search failed (HTTP 401). Check your Brave API key in Settings → Search."
        case 402: return "Brave web search failed (HTTP 402). Your Brave API subscription has run out of credits."
        case 403: return "Brave web search denied (HTTP 403). Your API key may not have access to this endpoint."
        case 429: return "Brave web search rate limit reached (HTTP 429). Try again in a moment."
        default: return "Brave web search returned an error (HTTP \(httpStatus))."
        }
    }
}

/// Without this, `localizedDescription` is Foundation's generic
/// "The operation couldn't be completed. (teemoon.LLMError error 1.)" —
/// which is what users saw anywhere an LLMError was interpolated through
/// `localizedDescription` (e.g. ChatGeneration's unexpected-error wrapper),
/// and why ProviderSmokeTests' skip-on-unreachable matching could never fire.
extension LLMError: LocalizedError {
    var errorDescription: String? { userMessage }
}
