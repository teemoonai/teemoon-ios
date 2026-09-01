//
//  TrustLadder.swift
//  teemoon
//
//  Reusable presentation pieces for the "who can read this?" trust-ladder
//  redesign (Direction D): a two-rung detail ladder (everyday / expert)
//  and a connected-rail chain that renders "how your plaintext reaches only
//  <model>" as one spine of evidence — each node carrying a status, a
//  plain-language claim, the literal attested value, and the links that back
//  it. A broken link (failed check) dashes the spine below it and dims every
//  node downstream, so the chain visibly stops where the proof stops.
//
//  Data-independent by design: the data-bound screen builds `[ChainNode]` from
//  the live session and hands it here. See TrustLadderView for the binding.
//

import SwiftUI

// UN-GATED. This screen is the product's central claim; it was iOS-only
// for four platform-specific calls, not for its design.

/// Detail level for the trust-ladder presentation. Two poles: `everyday` is
/// plain language with no jargon, values, or links — the default front door;
/// `expert` exposes the technical names, the attested values, and the links you
/// follow to re-verify. Same verdict at both — only how much proof is shown.
enum TrustRung: String, CaseIterable, Identifiable {
    case everyday, expert
    var id: String { rawValue }
    var label: String { rawValue }

    /// Whether this rung reveals the literal attested values + re-verify links.
    var showsValues: Bool { self == .expert }
    var showsLinks: Bool { self == .expert }
}

/// One node in the plaintext→model chain.
struct ChainNode: Identifiable {
    enum Status { case origin, ok, alert, info, fail, pending }
    let id: String
    let status: Status
    let title: String
    /// Plain sentence; backtick-marked spans are literal attested tokens and
    /// render monospaced (see `proofText`).
    let detail: String
    /// A copyable attested value shown at expert (e.g. "ed25519:9f8e…").
    var value: String? = nil
    /// The FULL value the copy button yields (display stays truncated).
    var copyValue: String? = nil
    /// Re-verify destinations shown at expert (source, sigstore, egress…).
    var links: [RunLink] = []
    /// An in-view jump (e.g. "provenance ↓") to another section; expert only
    /// unless `jumpAtEveryday` opts the node in.
    var jumpTitle: String? = nil
    /// Scroll target for the jump when it differs from the button label
    /// (`jumpTitle` doubles as both by default).
    var jumpTarget: String? = nil
    /// Everyday hides links and jumps by contract — EXCEPT a jump that goes UP
    /// the ladder (the handler flips the rung to expert, then scrolls): that's
    /// proof-one-tap-away, not an external link. Only the audit node opts in.
    var jumpAtEveryday: Bool = false
    /// True for nodes downstream of a broken link — rendered dimmed.
    var dimmed: Bool = false
    /// Plain-language rewrites for the `everyday` rung — no jargon, no acronyms.
    /// Fall back to `title`/`detail` when nil. This is what makes the ladder
    /// lower the *reading level*, not just hide the values.
    var everydayTitle: String? = nil
    var everydayDetail: String? = nil
}

// MARK: - Rung picker

/// "show me the proof as…" — the ladder selector.
struct RungPicker: View {
    @Binding var rung: TrustRung
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("show me the proof as…")
                .font(.caption).foregroundStyle(.secondary)
            Picker("show me the proof as", selection: $rung) {
                ForEach(TrustRung.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            #if os(macOS)
            // 22pt, per the Mac control-metrics table. It rendered at the phone's
            // 26 — the exact drift the Mac pass exists to catch, arriving inside
            // a component the pass had not touched.
            .controlSize(.small)
            #endif
            .labelsHidden()
        }
        // Tagged so a UI test can assert its ABSENCE: the self-hosted sheet has
        // no proof to go deeper into, so it deliberately omits the rung picker.
        .accessibilityIdentifier("attestation.rungPicker")
    }
}

// MARK: - Chain rail

/// Vertical connected-rail rendering of the chain. Give it the nodes and the
/// current rung; it draws the spine, colors each segment by continuity, and
/// discloses values/links per rung.
struct ChainRailView: View {
    let nodes: [ChainNode]
    let rung: TrustRung
    /// Optional handler for a node's in-view jump (e.g. scroll to known-code).
    var onJump: ((ChainNode) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                ChainRow(node: node, rung: rung,
                         isLast: index == nodes.count - 1,
                         onJump: onJump)
            }
        }
    }
}

private struct ChainRow: View {
    let node: ChainNode
    let rung: TrustRung
    let isLast: Bool
    var onJump: ((ChainNode) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            spine
            content
                .padding(.bottom, isLast ? 2 : 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The status node plus the connecting segment down to the next node.
    private var spine: some View {
        VStack(spacing: 0) {
            statusIcon
                .frame(width: 26, height: 26)
            if !isLast {
                Group {
                    if node.status == .fail {
                        // the chain breaks here: dashed, red, and everything
                        // below is dimmed
                        VLine().stroke(Color.red,
                                       style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                    } else {
                        Rectangle().fill(segmentColor)
                    }
                }
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var shownTitle: String {
        rung == .everyday ? (node.everydayTitle ?? node.title) : node.title
    }
    private var shownDetail: String {
        rung == .everyday ? (node.everydayDetail ?? node.detail) : node.detail
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(shownTitle)
                .font(.callout).fontWeight(.semibold)
                .foregroundStyle(titleColor)
            proofText(shownDetail)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(node.dimmed ? 0.55 : 1)
            if rung.showsValues, let value = node.value {
                ValuePill(value: value, fullValue: node.copyValue)
                    .opacity(node.dimmed ? 0.55 : 1)
            }
            if (rung.showsLinks && !node.links.isEmpty)
                || (node.jumpTitle != nil && (rung.showsLinks || node.jumpAtEveryday)) {
                linksRow
            }
        }
    }

    private var linksRow: some View {
        HStack(spacing: 14) {
            if let jump = node.jumpTitle, rung.showsLinks || node.jumpAtEveryday {
                Button { onJump?(node) } label: {
                    HStack(spacing: 3) {
                        Text(jump)
                        Image(systemName: "arrow.down")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            // External links stay expert-only even when an everyday jump
            // brought this row into view.
            if rung.showsLinks {
                ForEach(node.links) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            HStack(spacing: 3) {
                                Text(link.title)
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.caption2.weight(.medium))
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: node styling

    @ViewBuilder private var statusIcon: some View {
        switch node.status {
        case .origin:
            ZStack {
                Circle().fill(Color(.tertiarySystemFill))
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(node.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(teeVerified))
        case .alert:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body).foregroundStyle(.orange)
        case .info:
            // Informational, not a break — grey so it never reads as a warning
            // (the chain stays green above and below it).
            Image(systemName: "info.circle.fill")
                .font(.title3).foregroundStyle(.secondary)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .font(.title3).foregroundStyle(.red)
        case .pending:
            ProgressView().controlSize(.small)
        }
    }

    /// `Color(.separator)` is a UIKit colour. On macOS `.separator` resolves to
    /// `SeparatorShapeStyle`, which is not a `Color` — so this one initialiser
    /// was the last thing keeping the chain view off the Mac.
    private static var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(.separator)
        #endif
    }

    private var segmentColor: Color {
        if node.dimmed { return Self.separator }
        switch node.status {
        case .ok, .origin, .info: return teeVerified.opacity(0.55)
        case .alert:              return .orange.opacity(0.55)
        case .fail:               return .red
        case .pending:            return Self.separator
        }
    }

    private var titleColor: Color {
        if node.dimmed { return .secondary }
        switch node.status {
        case .fail:  return .red
        case .alert: return .orange
        default:     return .primary
        }
    }
}

/// A monospaced attested value with a copy affordance. `fullValue` is what
/// the copy button actually copies — the complete hash/key/digest a reader
/// pastes into a terminal or compares against the self-verify script — while
/// `value` stays the truncated display string. Copying a truncated display
/// string is worse than useless (it looks like data and verifies nothing),
/// so callers should always pass the full value when one exists.
struct ValuePill: View {
    let value: String
    var fullValue: String? = nil
    @State private var copied = false
    var body: some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                Clipboard.copy(fullValue ?? value)
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) { copied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    await MainActor.run { withAnimation { copied = false } }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? teeVerified : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A vertical line, for the dashed "broken chain" segment.
private struct VLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: 0))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.height))
        return p
    }
}

// MARK: - Preview (sample data — the data-bound screen lives in TrustLadderView)

#Preview("chain · verified") {
    ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            RungPicker(rung: .constant(.expert))
            Text("how your plaintext reaches only GLM-5.1")
                .font(.subheadline).fontWeight(.semibold)
            ChainRailView(nodes: ChainNode.sampleVerified, rung: .expert)
        }
        .padding()
    }
}

#Preview("chain · failed") {
    ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            RungPicker(rung: .constant(.expert))
            Text("how your plaintext reaches only GLM-5.1")
                .font(.subheadline).fontWeight(.semibold)
            ChainRailView(nodes: ChainNode.sampleFailed, rung: .expert)
        }
        .padding()
    }
}

extension ChainNode {
    static var sampleVerified: [ChainNode] {
        [
            ChainNode(id: "msg", status: .origin, title: "your message",
                      detail: "plaintext, on your device"),
            ChainNode(id: "target", status: .ok, title: "encryption target · Ed25519 public key",
                      detail: "your device seals this chat to GLM-5.1's public key before it ever leaves your phone.",
                      value: "ed25519:9f8e7d6c5b4a…"),
            ChainNode(id: "bound", status: .ok, title: "key bound in the model's TDX quote",
                      detail: "that public key sits in `report_data` of GLM-5.1's hardware quote — the private half never leaves the enclave. no one else (gateway, operator, near.ai) can decrypt.",
                      value: "d41de5f2c9a7…"),
            ChainNode(id: "compose", status: .ok, title: "the same quote measures the booted compose",
                      detail: "GLM-5.1's quote carries an `mr_config` that measures exactly what the enclave booted.",
                      value: "e5f2d41d8cd9…"),
            ChainNode(id: "yaml", status: .ok, title: "model-layer YAML pins the image",
                      detail: "the inner glm-5.1.yaml pins the weights by immutable revision.",
                      value: "2025-07-01 → e5f2a19",
                      links: [RunLink(title: "yaml source", url: "https://github.com/nearai/cvm-compose-files")]),
            ChainNode(id: "source", status: .ok, title: "model image → public source",
                      detail: "GLM-5.1's image digest traces to near.ai's open source, release and public attestation.",
                      value: "sha256:7a3f9c2e1b8d…",
                      links: [RunLink(title: "v0.4.2 → a1b2c3d", url: "https://github.com/nearai/private-ml-sdk"),
                              RunLink(title: "sigstore", url: "https://search.sigstore.dev"),
                              RunLink(title: "egress review", url: "https://example.com")]),
            ChainNode(id: "plaintext", status: .ok, title: "who sees plaintext · vllm-proxy-rs + sglang",
                      detail: "only these two ever see your message decrypted. everything else only touches ciphertext.",
                      jumpTitle: "provenance"),
            ChainNode(id: "decrypt", status: .ok, title: "only GLM-5.1 can decrypt",
                      detail: "no one else holds the key"),
        ]
    }

    static var sampleFailed: [ChainNode] {
        [
            ChainNode(id: "msg", status: .origin, title: "your message",
                      detail: "plaintext, on your device"),
            ChainNode(id: "target", status: .ok, title: "encryption target · Ed25519 public key",
                      detail: "your device seals this chat to GLM-5.1's public key before it ever leaves your phone.",
                      value: "ed25519:9f8e7d6c5b4a…"),
            ChainNode(id: "bound", status: .fail, title: "key binding · could not be established",
                      detail: "the encryption key was NOT found in GLM-5.1's `report_data` — end-to-end encryption isn't established.",
                      value: "nonce b7f3…a19c"),
            ChainNode(id: "compose", status: .ok, title: "the same quote measures the booted compose",
                      detail: "GLM-5.1's quote carries an `mr_config` that measures exactly what the enclave booted.",
                      dimmed: true),
            ChainNode(id: "decrypt", status: .ok, title: "only GLM-5.1 can decrypt",
                      detail: "no one else holds the key", dimmed: true),
        ]
    }
}


