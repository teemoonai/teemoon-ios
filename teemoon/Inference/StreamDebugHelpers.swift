//
//  StreamDebugHelpers.swift
//  teemoon
//
//  JSON formatting utilities used by ConfidentialLanguageModel and RequestDebugView.
//

import Foundation

func prettyJSON(from data: Data, excludingKey key: String) -> String? {
    guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    json.removeValue(forKey: key)
    guard let pretty = try? JSONSerialization.data(withJSONObject: WireImageSummary.summarized(json), options: .prettyPrinted)
    else { return nil }
    return String(data: pretty, encoding: .utf8)
}

func prettyMessages(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let messages = json["messages"] else { return nil }
    guard let pretty = try? JSONSerialization.data(withJSONObject: WireImageSummary.summarized(messages), options: .prettyPrinted)
    else { return nil }
    return String(data: pretty, encoding: .utf8)
}

/// Images in a shown or copied body read as `image · jpeg · 412 KB · 1536×2048`, never base64 (IMAGES.md §4).
enum WireImageSummary {
    /// Sizes of images put on the wire, keyed by their data URL's length and head (no decoding needed).
    private static let sizes = LockedBox<[String: (Int, Int)]>([:])

    private static func key(_ dataURL: String) -> String { "\(dataURL.utf8.count)#\(dataURL.prefix(160))" }

    static func register(_ image: WireImage, dataURL: String) {
        sizes.value[key(dataURL)] = (image.width, image.height)
        if sizes.value.count > 64 { sizes.value.removeAll() }
    }

    static func describe(_ string: String) -> String? {
        guard string.hasPrefix("data:image/"), let comma = string.firstIndex(of: ","),
              string[..<comma].hasSuffix(";base64") else { return nil }
        let type = string.dropFirst("data:image/".count).prefix { $0 != ";" }
        let bytes = string[string.index(after: comma)...].utf8.count * 3 / 4
        let size = bytes >= 1024 * 1024 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
        var out = "image · \(type) · \(size)"
        if let (w, h) = sizes.value[key(string)] { out += " · \(w)×\(h)" }
        return out
    }

    /// The JSON value with every image data URL replaced by its description.
    static func summarized(_ value: Any) -> Any {
        switch value {
        case let s as String: return describe(s) ?? s
        case let a as [Any]: return a.map(summarized)
        case let d as [String: Any]: return d.mapValues(summarized)
        default: return value
        }
    }
}

func prettyPrintedJSON(_ string: String) -> String {
    guard let data = string.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: WireImageSummary.summarized(obj), options: .prettyPrinted),
          let result = String(data: pretty, encoding: .utf8)
    else { return string }
    return result
}

// MARK: - ErrorDrainer

struct ErrorDrainer {
    let status: Int
    let providerName: String
    let requestURL: URL
    let requestHeaders: [String: String]
    let requestBody: Data
    private(set) var bodyBuffer = Data()

    init(status: Int, providerName: String, requestURL: URL, requestHeaders: [String: String], requestBody: Data) {
        self.status = status
        self.providerName = providerName
        self.requestURL = requestURL
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
    }

    mutating func append(_ data: Data) {
        bodyBuffer.append(data)
    }

    func makeLLMError(underlyingError: Error?) -> LLMError {
        let rawResponse = String(data: bodyBuffer, encoding: .utf8) ?? ""
        return LLMError(
            source: .provider(name: providerName),
            userMessage: apiErrorMessage(from: rawResponse, httpStatus: status, provider: providerName),
            httpStatus: status,
            url: requestURL,
            requestHeaders: requestHeaders,
            requestBodyJSON: prettyJSON(from: requestBody, excludingKey: "messages"),
            messageHistory: prettyMessages(from: requestBody),
            responseBody: prettyPrintedJSON(rawResponse),
            underlyingError: underlyingError
        )
    }
}

// MARK: - Error message formatting

func apiErrorMessage(from responseBody: String, httpStatus: Int, provider: String) -> String {
    guard let data = responseBody.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return LLMError.providerMessage(httpStatus: httpStatus, provider: provider) }
    if let problem = ProblemDetails.message(json: json, httpStatus: httpStatus, provider: provider) {
        return problem
    }
    guard let errorObj = json["error"] as? [String: Any]
    else { return LLMError.providerMessage(httpStatus: httpStatus, provider: provider) }

    var parts: [String] = []
    if let message = errorObj["message"] as? String, !message.isEmpty { parts.append(message) }
    if let detail = errorObj["detail"] as? String, !detail.isEmpty { parts.append(detail) }
    if let meta = errorObj["meta"] as? [String: Any],
       let errors = meta["errors"] as? [[String: Any]] {
        // `msg` alone is "Field required" — WHICH field is in `loc`, and
        // without it a missing auth header reads as a malformed body.
        let msgs = errors.compactMap { error -> String? in
            guard let msg = error["msg"] as? String, !msg.isEmpty else { return nil }
            let loc = (error["loc"] as? [Any] ?? []).map { "\($0)" }
            guard !loc.isEmpty else { return msg }
            let field = loc.first == "header"
                ? "header " + loc.dropFirst().joined(separator: ".")
                : loc.joined(separator: ".")
            return "\(msg) (\(field))"
        }
        parts.append(contentsOf: msgs)
    }

    guard !parts.isEmpty else {
        return LLMError.providerMessage(httpStatus: httpStatus, provider: provider)
    }
    return "\(provider) (http \(httpStatus)): \(parts.joined(separator: " — "))"
}

/// A body with a top-level `detail` and no `error` envelope — NVIDIA's:
/// `{"status":404,"title":"Not Found","detail":"Function '…': Not found for
/// account '…'"}`. Their catalog lists models the account cannot call (20 of
/// 28 sampled, 2026-09-18), and that 404 is the MODEL, not the URL: the
/// generic 404 line sent the user to check a provider URL that was fine.
/// The function id and account id in the detail are not repeated.
enum ProblemDetails {
    static func message(json: [String: Any], httpStatus: Int, provider: String) -> String? {
        guard json["error"] == nil, let detail = json["detail"] as? String, !detail.isEmpty else { return nil }
        if httpStatus == 404, detail.hasPrefix("Function ") {
            return "\(provider) doesn't serve this model on your account (http 404). pick another model in where."
        }
        return "\(provider) (http \(httpStatus)): \(detail)"
    }
}
