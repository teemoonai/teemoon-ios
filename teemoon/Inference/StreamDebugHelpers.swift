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
    guard let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return nil }
    return String(data: pretty, encoding: .utf8)
}

func prettyMessages(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let messages = json["messages"] else { return nil }
    guard let pretty = try? JSONSerialization.data(withJSONObject: messages, options: .prettyPrinted) else { return nil }
    return String(data: pretty, encoding: .utf8)
}

func prettyPrintedJSON(_ string: String) -> String {
    guard let data = string.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
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
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let errorObj = json["error"] as? [String: Any]
    else { return LLMError.providerMessage(httpStatus: httpStatus, provider: provider) }

    var parts: [String] = []
    if let message = errorObj["message"] as? String, !message.isEmpty { parts.append(message) }
    if let detail = errorObj["detail"] as? String, !detail.isEmpty { parts.append(detail) }
    if let meta = errorObj["meta"] as? [String: Any],
       let errors = meta["errors"] as? [[String: Any]] {
        let msgs = errors.compactMap { $0["msg"] as? String }.filter { !$0.isEmpty }
        parts.append(contentsOf: msgs)
    }

    guard !parts.isEmpty else {
        return LLMError.providerMessage(httpStatus: httpStatus, provider: provider)
    }
    return "\(provider) (HTTP \(httpStatus)): \(parts.joined(separator: " — "))"
}
