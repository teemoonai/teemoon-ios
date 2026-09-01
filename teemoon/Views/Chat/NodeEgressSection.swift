//
//  NodeEgressSection.swift
//  teemoon
//

import SwiftUI

/// The per-node plaintext-egress rollup — the machine-read findings of every
/// review this attestation keys into, unioned and severity-sorted: live at the
/// deployed flags first (the part a reader must see), latent paths second,
/// informational notes collapsed behind a disclosure. Every row deep-links to
/// the finding's own evidence section (file:line citations). Expert rung only;
/// all severities, states and titles are the reviewers' own machine-read
/// headings — no client-side judgment.
struct NodeEgressSection: View {
    let findings: [NodeFinding]

    var body: some View {
        let split = splitNodeFindings(findings)
        let sources = Set(findings.map(\.source)).count
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("plaintext egress · this node")
                    .font(.caption).fontWeight(.semibold)
                Text("what \(sources == 1 ? "the published review" : "the \(sources) published reviews") found at this attestation's exact identities — live at deployed flags first.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !split.live.isEmpty {
                sectionLabel("live at deployed flags", tint: .red)
                ForEach(split.live) { row($0) }
            }
            if !split.latent.isEmpty {
                sectionLabel("latent — off, armed, or opt-in", tint: .secondary)
                ForEach(split.latent) { row($0) }
            }
            if !split.info.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(split.info) { row($0) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(split.info.count) informational finding\(split.info.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(PlatformColors.separator, lineWidth: 0.5))
        .padding(.top, 3)
    }

    private func sectionLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.top, 2)
    }

    private func row(_ f: NodeFinding) -> some View {
        Link(destination: f.url) {
            HStack(alignment: .top, spacing: 8) {
                // Outlined, not filled: the filled register belongs to the
                // verdict badge — one card never shouts twice.
                Text(f.severity == "medium" ? "med" : f.severity)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .textCase(.uppercase)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(severityColor(f.severity), lineWidth: 0.8))
                    .foregroundStyle(severityColor(f.severity))
                    .frame(minWidth: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(f.qualifier.map { "\(f.source) · \($0)" } ?? f.source)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "critical": return .red
        case "high":     return .orange
        case "medium":
            // Amber that stays legible on both grounds — bare .yellow washes
            // out on the light card.
            return PlatformColors.dynamic(light: (0.69, 0.53, 0.00),
                                          dark:  (1.00, 0.84, 0.04))
        case "low":      return .blue
        default:         return .gray
        }
    }
}
