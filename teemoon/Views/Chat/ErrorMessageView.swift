//
//  ErrorMessageView.swift
//  teemoon

import SwiftUI

// MARK: - ErrorMessageView

/// Shown in the conversation when generation ends with an LLMError.
/// Presents a user-friendly summary at the top with collapsible debug sections
/// (URL, headers including API key, request body, message history, response body) below.
struct ErrorMessageView: View {
    let error: LLMError
    /// When set, shows a one-tap recovery button. Supplied by the parent only when
    /// the failure looks tool-related (a provider 400 with web-search attached) —
    /// tapping disables web-search grounding and retries. nil → no button.
    var onDisableWebSearch: (() -> Void)? = nil
    /// Cloud vendor console for 401 (key) / 402 (credits). Resolved by the parent
    /// from the active provider / request host — nil for custom & self-hosted.
    var consoleRecovery: (url: URL, displayName: String)? = nil

    var sourceLabel: String {
        switch error.source {
        case .provider(let name): return name
        case .braveGrounding: return "Brave Search"
        }
    }

    /// Contextual outbound action for auth / billing failures only.
    private var consoleAction: (title: String, url: URL)? {
        guard let recovery = consoleRecovery, let status = error.httpStatus else { return nil }
        let name = recovery.displayName
        switch status {
        case 401: return ("manage api key at \(name)", recovery.url)
        case 402: return ("add credits at \(name)", recovery.url)
        default: return nil
        }
    }

    var messageCount: Int {
        guard let history = error.messageHistory,
              let data = history.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }
        return arr.count
    }

    /// Full debug dump copied to the clipboard on long press.
    ///
    /// Credentials are redacted here and NOT on screen — see
    /// `DebugHeaderRedaction.copyValue`. The panel is read by its owner; the
    /// pasteboard is where the dump leaves the device.
    var debugText: String {
        var parts: [String] = []
        parts.append("=== \(sourceLabel) Error ===")
        if let status = error.httpStatus { parts.append("HTTP \(status)") }
        parts.append(error.userMessage)
        if let url = error.url {
            parts.append("\n--- URL ---\n\(DebugHeaderRedaction.copyURLString(url.absoluteString))")
        }
        if let headers = error.requestHeaders, !headers.isEmpty {
            parts.append("\n--- Headers ---\n\(DebugHeaderRedaction.copyHeaderBlock(headers))")
        }
        if let body = error.requestBodyJSON { parts.append("\n--- Request Body ---\n\(body)") }
        if let history = error.messageHistory { parts.append("\n--- Message History ---\n\(history)") }
        if let response = error.responseBody, !response.isEmpty { parts.append("\n--- Response ---\n\(response)") }
        if let underlying = error.underlyingError { parts.append("\n--- Underlying Error ---\n\(underlying)") }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(sourceLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if let status = error.httpStatus {
                    Text("HTTP \(status)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // User-friendly message
            Text(error.userMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            // 401 / 402 → vendor console (keys or credits). Same destinations as
            // provider detail; only shown when the failure makes them relevant.
            //
            // No retry button here: the last user message already grows one when
            // `hasError` (ConversationView → MessageView's arrow.clockwise), and
            // that is the same condition this link appears under. A second one
            // would just be a second way to do the thing that is already there.
            //
            // The url is shown, not hidden behind a gesture. These pages sit behind
            // a login, and the browser holding the vendor's cookies is often not the
            // one a tap opens — so the destination is readable, selectable and
            // copyable, to be pasted where the session already lives. A `contextMenu`
            // on the `Link` was tried first and never appeared: the system's own
            // long-press handling for links swallows it.
            if let action = consoleAction {
                VStack(alignment: .leading, spacing: 8) {
                    Link(destination: action.url) {
                        Label(action.title, systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.medium))
                            .textCase(.lowercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #if os(iOS)
                    // Same pill the attestation rows use, so "copy" behaves the
                    // same way everywhere: middle-truncated display, full value
                    // on the pasteboard, checkmark on success.
                    ValuePill(value: action.url.absoluteString)
                    #endif
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
            }

            // One-tap recovery for a tool-related failure: this model can't use
            // the web-search tool, so turn grounding off and retry without it.
            if let onDisableWebSearch {
                Button(action: onDisableWebSearch) {
                    Label("this model can't search the web — turn off & retry",
                          systemImage: "magnifyingglass")
                        .font(.footnote.weight(.medium))
                        .textCase(.lowercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .tint(.orange)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
                Divider()
            }

            // Debug sections
            if let url = error.url {
                InlineDebugRow(label: "url", value: url.absoluteString)
            }
            if let headers = error.requestHeaders, !headers.isEmpty {
                let formatted = headers
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \(DebugHeaderRedaction.value($0.value, for: $0.key))" }
                    .joined(separator: "\n")
                CollapsibleDebugRow(label: "headers (\(headers.count))", content: formatted)
            }
            if let body = error.requestBodyJSON {
                CollapsibleDebugRow(label: "request body", content: body)
            }
            if let history = error.messageHistory {
                let count = messageCount
                CollapsibleDebugRow(
                    label: "message history\(count > 0 ? " (\(count))" : "")",
                    content: history
                )
            }
            if let response = error.responseBody, !response.isEmpty {
                CollapsibleDebugRow(label: "response", content: response)
            }
        }
        .debugCardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityIdentifier("chat.error")
        .contextMenu {
            Button {
                #if os(iOS) || os(visionOS)
                UIPasteboard.general.string = debugText
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(debugText, forType: .string)
                #endif
            } label: {
                Label("Copy Debug Info", systemImage: "square.on.square")
            }
        }
    }
}

// MARK: - Preview

#Preview("Error View — 401 key") {
    ScrollView {
        ErrorMessageView(
            error: LLMError(
                source: .provider(name: "near.ai glm 5.2"),
                userMessage: LLMError.providerMessage(httpStatus: 401, provider: "near.ai"),
                httpStatus: 401,
                url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
                requestHeaders: [
                    "Authorization": "Bearer sk-abc123def456",
                    "Content-Type": "application/json"
                ],
                requestBodyJSON: "{\n  \"model\" : \"z-ai/glm-5.2\",\n  \"stream\" : true\n}",
                messageHistory: nil,
                responseBody: "{\"error\": {\"message\": \"Invalid API key\", \"type\": \"authentication_error\"}}",
                underlyingError: nil
            ),
            consoleRecovery: Provider.consoleRecovery(
                for: LLMError(
                    source: .provider(name: "near.ai glm 5.2"),
                    userMessage: "",
                    httpStatus: 401,
                    url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
                    requestHeaders: nil, requestBodyJSON: nil, messageHistory: nil,
                    responseBody: nil, underlyingError: nil
                ),
                activeProvider: nil
            )
        )
        .padding()
    }
}

#Preview("Error View — 402 credits") {
    ScrollView {
        let err = LLMError(
            source: .provider(name: "near.ai glm 5.2"),
            userMessage: LLMError.providerMessage(httpStatus: 402, provider: "near.ai"),
            httpStatus: 402,
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
            requestHeaders: nil,
            requestBodyJSON: nil,
            messageHistory: nil,
            responseBody: "{\"error\":{\"message\":\"Insufficient balance\"}}",
            underlyingError: nil
        )
        ErrorMessageView(
            error: err,
            consoleRecovery: Provider.consoleRecovery(for: err, activeProvider: nil)
        )
        .padding()
    }
}

#Preview("Error View — E2EE not established") {
    ScrollView {
        // The card a send now raises instead of silently transmitting plaintext
        // when an attested provider's E2EE peer can't be established (fail-closed
        // guard in ChatViewModel.generateResponse / HTTPTransport.e2eeSealedBody).
        let err = LLMError(
            source: .provider(name: "near.ai glm 5.2"),
            userMessage: "End-to-end encryption could not be established, so nothing was sent. Try again — if this keeps happening, re-verify the connection from the lock icon.",
            httpStatus: nil,
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
            requestHeaders: nil,
            requestBodyJSON: nil,
            messageHistory: nil,
            responseBody: nil,
            underlyingError: E2EEError.encryptionFailed
        )
        ErrorMessageView(
            error: err,
            consoleRecovery: Provider.consoleRecovery(for: err, activeProvider: nil)
        )
        .padding()
    }
}
