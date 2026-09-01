//
//  SelfVerifyScriptCard.swift
//  teemoon
//

import SwiftUI

/// The self-verify script as a dark terminal card: a header bar with a copy
/// pill, then the whole source with a pinned line-number gutter.
///
/// This is its own `View` type deliberately. Inlined into TrustLadderView's
/// expert sections, adding any modifier to the inner horizontal `ScrollView`
/// crashed the app on device (`tuple_initializeWithCopy` → `swift_retain`).
/// Do not fold it back into an `extension TrustLadderView`.
struct SelfVerifyScriptCard: View {
    let script: String

    @State private var copied = false

    // A real code look: a dark terminal panel with a monospaced code font and
    // light syntax highlighting.
    static let codeBG = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let codeBarBG = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let codeFG = Color(red: 0.85, green: 0.87, blue: 0.91)

    var body: some View {
        // SF Mono via the system monospaced design — matching the design
        // mockup (`ui-monospace`). The `.fontDesign(.monospaced)` on each Text
        // shields against ContentView's app-wide user font-design override
        // (same proven defense as CodeBlock and the debug views).
        let mono = Font.system(.caption2, design: .monospaced)
        let render = Self.render(for: script)
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.black.opacity(0.5))
            source(render, mono: mono)
        }
        .background(Self.codeBG, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// Filename · language tag · filled copy pill (green when copied).
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal").font(.caption2)
            Text("teemoon_verify.py")
                .font(.system(.caption, design: .monospaced))
                .fontDesign(.monospaced)
                // A filename never wraps: one line, middle-truncated if the
                // bar gets tight, and it wins space over the language tag.
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text("shell · python")
                .font(.caption2.weight(.medium))
                // Never wraps: the tag stays whole and the (middle-
                // truncating) filename yields space instead.
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Color(red: 0.60, green: 0.64, blue: 0.71))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: Capsule())
            Spacer(minLength: 8)
            copyButton
        }
        .foregroundStyle(Color(red: 0.68, green: 0.71, blue: 0.77))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Self.codeBarBG)
    }

    private var copyButton: some View {
        Button {
            Clipboard.copy(script)
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                await MainActor.run { withAnimation { copied = false } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "copied" : "copy")
                    // Never wraps either: the filename outranks this pill
                    // (layoutPriority 1), so unprotected it breaks to "cop/y".
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(copied ? teeVerified.opacity(0.22) : Color.white.opacity(0.10),
                        in: Capsule())
            .foregroundStyle(copied ? teeVerified : Color(red: 0.55, green: 0.72, blue: 1.0))
        }
        .buttonStyle(.plain)
    }

    /// The full script shown directly (never collapsed — nothing hidden), with
    /// a pinned non-selectable line-number gutter and the source in a
    /// horizontal scroll so long hash lines don't wrap. Capped + scrolls.
    private func source(_ render: ScriptRender, mono: Font) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 10) {
                Text(render.gutter)
                    .font(mono)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color(red: 0.36, green: 0.40, blue: 0.46))
                    .lineSpacing(3)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .textSelection(.disabled)
                ScrollView(.horizontal) {
                    Text(render.text)
                        .font(mono)
                        .fontDesign(.monospaced)
                        .lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 300)
        .defaultScrollAnchor(.topLeading)
        // Faint right-edge fade: signals the source scrolls sideways without
        // an always-visible scrollbar.
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [Self.codeBG.opacity(0), Self.codeBG],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 26)
                .allowsHitTesting(false)
        }
    }

    // MARK: - render

    /// Memoized render of the self-verify script: the syntax-highlighted
    /// AttributedString + line-number gutter, keyed on the script text. The
    /// script only changes when the attestation record changes, but the sheet
    /// re-renders on every `@Observable` session mutation while verification
    /// checks land — rebuilding + re-laying-out the block each time cost
    /// ~22 ms per mutation at the expert rung (measured). Same NSCache
    /// pattern as MessageView's parsed-markdown cache; safe to populate during
    /// body evaluation (unlike @State).
    final class ScriptRender {
        let text: AttributedString
        let gutter: String
        init(text: AttributedString, gutter: String) { self.text = text; self.gutter = gutter }
    }
    static let renderCache = NSCache<NSString, ScriptRender>()

    static func render(for script: String) -> ScriptRender {
        let key = script as NSString
        if let hit = renderCache.object(forKey: key) { return hit }
        let render = ScriptRender(text: highlighted(script), gutter: lineNumbers(for: script))
        renderCache.setObject(render, forKey: key)
        return render
    }

    /// "1\n2\n…\nN" for the line-number gutter — N = the script's line count.
    static func lineNumbers(for code: String) -> String {
        let n = max(1, code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) })
        return (1...n).map(String.init).joined(separator: "\n")
    }

    /// Lightweight shell/python syntax highlighting — a single-pass state machine
    /// (a string opens before a `#`, so a `#` inside a string is not a comment).
    /// Same-color runs are batched so it stays O(n) rather than per-character.
    static func highlighted(_ code: String) -> AttributedString {
        enum Tok: Equatable { case base, comment, string }
        func color(_ t: Tok) -> Color {
            switch t {
            case .base:    return Self.codeFG
            case .comment: return Color(red: 0.44, green: 0.50, blue: 0.57)
            case .string:  return Color(red: 0.56, green: 0.79, blue: 0.53)
            }
        }
        enum Mode: Equatable { case normal, string(Character), comment }
        var mode: Mode = .normal
        var out = AttributedString()
        var buffer = ""
        var bufTok: Tok = .base
        func flush() {
            guard !buffer.isEmpty else { return }
            var a = AttributedString(buffer); a.foregroundColor = color(bufTok)
            out += a; buffer = ""
        }
        func emit(_ ch: Character, _ tok: Tok) {
            if tok != bufTok { flush(); bufTok = tok }
            buffer.append(ch)
        }
        for ch in code {
            switch mode {
            case .normal:
                if ch == "#" { mode = .comment; emit(ch, .comment) }
                else if ch == "\"" || ch == "'" { mode = .string(ch); emit(ch, .string) }
                else { emit(ch, .base) }
            case .string(let q):
                emit(ch, .string)
                if ch == q || ch == "\n" { mode = .normal }
            case .comment:
                emit(ch, .comment)
                if ch == "\n" { mode = .normal }
            }
        }
        flush()
        return out
    }
}
