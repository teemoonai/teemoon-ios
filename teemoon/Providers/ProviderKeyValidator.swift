//
//  ProviderKeyValidator.swift
//  teemoon
//
//  Validates provider API keys against their live endpoints during onboarding,
//  and centralizes the provider dashboard / validation URLs.
//

import Foundation

enum ProviderKeyValidator {

    // MARK: - URLs

    // Onboarding sends users to the same console the provider sheet and the
    // 401/402 error card do, so these read the preset rather than restating it —
    // one place to be wrong when a vendor moves its keys page.

    /// near.ai sign-in → cloud dashboard (keys + credits).
    static let nearAIDashboardURL = Provider.nearAI.signupURL ?? "https://cloud.near.ai"
    /// Brave Search API keys UI (unauth → login with redirect).
    static let braveDashboardURL = Provider.braveAnswers.signupURL ?? "https://api-dashboard.search.brave.com"
    /// Cheap authenticated near.ai endpoint used to validate a key.
    static let nearAIModelsURL = "https://cloud-api.near.ai/v1/models"
    /// Brave web-search endpoint used to validate a subscription token.
    static let braveWebSearchURL = "https://api.search.brave.com/res/v1/web/search"

    // MARK: - API

    enum Endpoint {
        case nearAI
        case braveSearch
    }

    enum ValidationResult {
        /// HTTP 200 — the key works.
        case success
        /// HTTP 401 / 403 — the key was rejected.
        case unauthorized
        /// HTTP 402 — the account has no credits.
        case paymentRequired
        /// HTTP 429 — usage cap or rate limit hit.
        case rateLimited
        /// Any other status code, or a transport-level error.
        case otherFailure
    }

    /// Performs a lightweight authenticated request against the given endpoint
    /// and maps the HTTP status to a `ValidationResult`.
    static func validate(key: String, endpoint: Endpoint, http: any HTTPClient = URLSessionHTTP()) async -> ValidationResult {
        var request: URLRequest
        switch endpoint {
        case .nearAI:
            request = URLRequest(url: URL(string: nearAIModelsURL)!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .braveSearch:
            var components = URLComponents(string: braveWebSearchURL)!
            components.queryItems = [URLQueryItem(name: "q", value: "test"), URLQueryItem(name: "count", value: "1")]
            request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        }
        request.timeoutInterval = 10

        do {
            let (_, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch status {
            case 200: return .success
            case 401, 403: return .unauthorized
            case 402: return .paymentRequired
            case 429: return .rateLimited
            default: return .otherFailure
            }
        } catch {
            return .otherFailure
        }
    }
}
