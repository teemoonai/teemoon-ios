//
//  CodeBlock.swift
//  teemoon
//
//  Recessed, copyable code well for insetGrouped list rows: a pinned header
//  bar (icon · label · copy) and a scrolling code area on one surface. For
//  multi-line code the user is expected to copy or run — key/value
//  diagnostics belong in the Debug Panel style instead.
//

import SwiftUI

#if os(iOS)

struct CodeBlock: View {
    let label: String
    let code: String

    @State private var copied = false
    @ScaledMetric(relativeTo: .caption2) private var viewportHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(dimmedCode)
                    .font(.system(.caption2, design: .monospaced))
                    // shields against the app-wide user font design override
                    // (ContentView applies .fontDesign globally) — same
                    // defense as the debug views
                    .fontDesign(.monospaced)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: viewportHeight)
        }
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal").font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? teeVerified : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "copied" : "copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One pass, line-based: comment lines (#) render .secondary, all else .primary.
    private var dimmedCode: AttributedString {
        var out = AttributedString()
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            var run = AttributedString(String(line) + "\n")
            if line.drop(while: { $0 == " " || $0 == "\t" }).first == "#" {
                run.foregroundColor = .secondary
            }
            out += run
        }
        return out
    }

    private func copy() {
        UIPasteboard.general.string = code
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) { copied = false }
            }
        }
    }
}

/// Wrapped in the app-wide user font design override (ContentView applies
/// `.fontDesign(...)` globally) — the code must stay monospaced through it.
#Preview {
    List {
        Section("verify it yourself") {
            CodeBlock(
                label: "paste into your terminal",
                code: "#!/bin/sh\n# re-run near.ai verification locally\nset -euo pipefail\npython3 verify.py --quote \"$QUOTE_B64\""
            )
        }
    }
    .listStyle(.insetGrouped)
    .fontDesign(.serif)
}

#endif
