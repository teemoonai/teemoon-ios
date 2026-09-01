//
//  DebugComponents.swift
//  teemoon

import SwiftUI

// MARK: - EncryptedBodyDebugRow

/// Collapsible request body row for E2EE requests.
///
/// Shows BOTH bodies when both are known: the plaintext the request was built
/// from, and the sealed bytes that actually left the device. Showing only one
/// is what made this row misleading — it printed the plaintext under a green
/// "encrypted" label, which is the worst available outcome for the one surface
/// whose job is to prove the claim.
///
/// `sealed` defaults to a compact view that truncates hex ciphertext with byte
/// counts; a toggle switches it to the full raw hex.
struct EncryptedBodyDebugRow: View {
    /// The plaintext the request was assembled from.
    let content: String
    /// The bytes that went on the wire. nil when sealing did not change them.
    var sealed: String?
    var initiallyExpanded: Bool = false
    @State private var expanded: Bool
    @State private var showFull = false

    init(content: String, sealed: String? = nil, initiallyExpanded: Bool = false) {
        self.content = content
        self.sealed = sealed
        self.initiallyExpanded = initiallyExpanded
        self._expanded = State(initialValue: initiallyExpanded)
    }

    @ViewBuilder
    private func pane(_ caption: String, _ text: String, tint: Color) -> some View {
        Text(caption)
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.top, 2)
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    var body: some View {
        Divider().padding(.leading, 12)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                Text("request body")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("encrypted")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)

        if expanded {
            HStack(spacing: 0) {
                Button { showFull = false } label: {
                    Text("compact")
                        .font(.system(.caption2, design: .monospaced, weight: showFull ? .regular : .semibold))
                        .foregroundStyle(showFull ? .tertiary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(showFull ? .clear : Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                Button { showFull = true } label: {
                    Text("full")
                        .font(.system(.caption2, design: .monospaced, weight: showFull ? .semibold : .regular))
                        .foregroundStyle(showFull ? .secondary : .tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(showFull ? Color.secondary.opacity(0.12) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            // Wire first, then plaintext. The order is the argument: what
            // anyone in the middle gets, and only then what it was made from.
            if let sealed {
                pane("on the wire", showFull ? sealed : compactRequestBody(sealed), tint: .green)
                pane("on this device — never sent in this form", content, tint: .orange)
            } else {
                Text(showFull ? content : compactRequestBody(content))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - ToolCallDebugRow

/// A collapsible row for a single tool call. When expanded it shows two nested
/// subsections: the raw JSON representation and the text sent to the LLM.
struct ToolCallDebugRow: View {
    let label: String
    let subtitle: String?
    let rawJSON: String?
    let processedForLLM: String
    @State private var expanded: Bool
    @State private var rawExpanded = false
    @State private var llmExpanded = false

    init(label: String, subtitle: String? = nil, rawJSON: String?, processedForLLM: String, initiallyExpanded: Bool = false) {
        self.label = label
        self.subtitle = subtitle
        self.rawJSON = rawJSON
        self.processedForLLM = processedForLLM
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        Divider().padding(.leading, 12)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)

        if let subtitle {
            Text(subtitle)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
        }

        if expanded {
            if let rawJSON {
                Divider().padding(.leading, 24)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { rawExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: rawExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                        Text("raw json")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                if rawExpanded {
                    Text(rawJSON)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                        .padding(.trailing, 12)
                        .padding(.bottom, 6)
                }
            }
            Divider().padding(.leading, 24)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { llmExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: llmExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                    Text("processed for llm")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.leading, 24)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            if llmExpanded {
                Text(processedForLLM)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - InlineDebugRow

struct InlineDebugRow: View {
    let label: String
    let value: String
    var scrollable: Bool = false

    var body: some View {
        Divider().padding(.leading, 12)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            if scrollable {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(value)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            } else {
                Text(value)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - CollapsibleDebugRow

struct CollapsibleDebugRow: View {
    let label: String
    let content: String
    @State private var expanded: Bool

    init(label: String, content: String, initiallyExpanded: Bool = false) {
        self.label = label
        self.content = content
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        Divider().padding(.leading, 12)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)

        if expanded {
            Text(content)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Previews

#Preview("E2EE Compact Body") {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            EncryptedBodyDebugRow(
                content: """
                {
                  "messages" : [
                    {
                      "content" : "437bcbd1e9b1889d28c468fe75bd5fff838953bd4f02cedaa5befa29fcf4c018e61af95ba7465764a56c27af92591ae050c4ea428d350ecb3c87df019ddbc29bad23486942f6b96d20bf67af4daa20d205d79a511f04cc6d86c3055bf5b9e18be45c61c9188442522e5d6c459bbafbaca",
                      "role" : "system"
                    },
                    {
                      "content" : "cec2c588a87e71889ee2dc89da572b8590ac69ef2094fb89349765a1670ce23d1d378234fdf39ea4791b941050b6ffe62ebe3cad74fd2352c89ae81a088729f03",
                      "role" : "user"
                    },
                    {
                      "content" : "",
                      "role" : "assistant",
                      "tool_calls" : [
                        {
                          "type" : "function",
                          "function" : {
                            "name" : "891ab5883d36cb984f0fb8110808cfb8c6d2d45678db1e5ef049208b5e58050bdc4c79154138d711f9d0e6f332f8f7c88472757c4cd81c406d9d83e2fe061b38de5f8ee09fd24e14ae87477d62be3f41c464",
                            "arguments" : "d3b9a03a316d9e2846841869cd5dee6b74fab7f1a27ce313919651cddb35b75124af8e0e9d2db3391a8f88e2bddd3a528ca618efb67b7fc978594f15b1b217b603651d4dec08c0689389ce445d8a51736f7243b9b49dd995bbe77c8fe6d053f0aacebcc179b78dbe388d5dbad65a170cee"
                          }
                        }
                      ]
                    }
                  ]
                }
                """,
                initiallyExpanded: true
            )
        }
        .fontDesign(.monospaced)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .padding()
    }
}

#Preview("Tool Row Expanded") {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("OpenAI")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("HTTP 200")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ToolCallDebugRow(
                label: "tool: web_search · fresh:pd · n:10 -> 2",
                subtitle: "\"weather today San Francisco\"",
                rawJSON: """
                {
                  "grounding" : {
                    "generic" : [
                      { "url" : "https://sfgate.com/weather", "title" : "SF Weather", "snippet" : "62°F, partly cloudy skies in San Francisco." },
                      { "url" : "https://weather.com/sf",     "title" : "Weather.com SF", "snippet" : "Expect partly cloudy skies with a high of 65°F." }
                    ]
                  }
                }
                """,
                processedForLLM: "SOURCE sfgate.com | https://sfgate.com/weather\nSF Weather\n62°F, partly cloudy skies in San Francisco.\n\n---\n\nSOURCE weather.com | https://weather.com/sf\nWeather.com SF\nExpect partly cloudy skies with a high of 65°F.",
                initiallyExpanded: true
            )
        }
        .fontDesign(.monospaced)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .padding()
    }
}
