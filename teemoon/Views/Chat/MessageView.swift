//
//  MessageView.swift
//  teemoon

import SwiftUI
import Textual

// MARK: - TimeInterval formatting

extension TimeInterval {
    var formatted: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    /// One-decimal-place format for debug panels: "0.82s", "4.1s", "66.5s"
    var debugFormatted: String {
        String(format: "%.1fs", self)
    }
}

// MARK: - NSCache value wrapper

final class CacheEntry<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - MessageView

/// The words for a reply row's marker and mark (approved 2026-11-06). Ids live in reply-machine.json.
enum ReplyMarkerWords {
    static func marker(of message: Message) -> ReplyMarker? {
        guard message.role == .assistant else { return nil }
        return ReplyStatus.reloadMarker(message.statusRaw.flatMap(ReplyStatus.init(rawValue:)))
    }

    static func line(_ marker: ReplyMarker) -> String {
        switch marker {
        case .didntFinish: "this reply didn't finish."
        case .stopped: "you stopped this reply."
        case .cutShort: "this reply was cut short."
        case .decryptFailed: "this reply couldn't be decrypted, so it isn't shown."
        }
    }

    static func line(_ mark: SentBeforeConfirmed.Mark) -> String {
        switch mark {
        case .sentWhileChecking: "sent while near.ai's hardware was still being checked"
        case .checkFailedAfterSend: "near.ai's hardware failed its check after this was sent. treat this reply as not private."
        }
    }

    /// The failed-after-send mark is a hard failure: the trust screens' red. Everything else stays secondary.
    static func color(of mark: SentBeforeConfirmed.Mark) -> Color {
        mark == .checkFailedAfterSend ? .red : .secondary
    }

    /// The answer text to draw, or nil when there is none (a row that keeps no text draws no empty block).
    static func answerToDraw(_ answer: String?) -> String? {
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return answer
    }

    /// The retry control's word, in the accent colour after the didn't-finish line (as Android has it).
    static let retry = "retry"

    /// Retry is offered only on a didn't-finish marker, and only on the newest reply.
    static func offersRetry(_ message: Message, isNewest: Bool) -> Bool {
        isNewest && marker(of: message) == .didntFinish
    }
}

struct MessageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = true
    let message: Message
    let isLLMRunning: Bool
    var onRetry: (() -> Void)? = nil
    /// Long-press "Think Harder" on a reply: the same question again at high effort.
    var onThinkHarder: (() -> Void)? = nil
    var thinkHarderAvailable: () -> Bool = { true }

    // MARK: - Cached thinking-content parse
    //
    // Once per message text, not per appearance. A reply row is saved empty at turn start and can be drawn then, so
    // a hit counts only while the text it parsed is still the message's text (ReplyParseCacheTests).

    struct ThinkParse {
        /// The text this was parsed from.
        let source: String
        let thinking: String?
        let answer: String?
        /// True when the `<think>` block was never closed. Folded in here so
        /// the body doesn't rescan the whole message for `</think>` on every
        /// evaluation.
        let isThinking: Bool
        /// Whether each half needs Textual's block renderer. Same reason:
        /// `needsStructuredText` runs ten `contains` passes over the content,
        /// which is not something to repeat per body evaluation.
        let thinkingNeedsStructuredText: Bool
    }

    private static let _thinkCache: NSCache<NSString, CacheEntry<ThinkParse>> = {
        let cache = NSCache<NSString, CacheEntry<ThinkParse>>()
        cache.countLimit = 400
        return cache
    }()

    private var thinkParse: ThinkParse { Self.thinkParse(id: message.id, content: message.content) }

    static func thinkParse(id: UUID, content: String) -> ThinkParse {
        let key = id.uuidString as NSString
        if let hit = _thinkCache.object(forKey: key), hit.value.source == content { return hit.value }
        let (t, a) = ThinkingContentParser.parse(content)
        let parsed = ThinkParse(
            source: content,
            thinking: t,
            answer: a,
            isThinking: !content.contains("</think>"),
            thinkingNeedsStructuredText: t.map(needsStructuredText) ?? false)
        _thinkCache.setObject(CacheEntry(parsed), forKey: key)
        return parsed
    }

    // MARK: - Disclosure state that survives leaving the viewport
    //
    // `collapsed` is @State, and a LazyVStack destroys a row's state when it
    // scrolls out of view. Without this, expanding a reasoning block, scrolling
    // down and scrolling back would find it collapsed again — the row is a new
    // view struct with a fresh `true`. Held outside the view, keyed on message
    // id, so the disclosure is a property of the MESSAGE rather than of the
    // row that happens to be showing it.
    //
    // Grows only by explicit taps, so it is bounded by what a person can do
    // with a thumb; nothing here justifies an eviction policy.
    @MainActor
    final class DisclosureState {
        static let shared = DisclosureState()
        private var expanded: Set<UUID> = []
        func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
        func setExpanded(_ id: UUID, _ value: Bool) {
            if value { expanded.insert(id) } else { expanded.remove(id) }
        }
    }

    // MARK: - Fast-path rendering
    //
    // The ANSWER is always Textual: it streamed through Textual, and a plain
    // `Text` lays out the same paragraphs 25pt taller, so the reply reflows
    // the moment it lands (`testAPlainReplyMeasuresTheSameStreamingAndPersisted`).
    // The parse is cached per distinct string (`StructuredText.cached`), so
    // the cost this path once avoided is gone. The plain path stays for the
    // thinking block, which never streams through the same renderer.

    static let _attrCache: NSCache<NSString, CacheEntry<AttributedString>> = {
        let cache = NSCache<NSString, CacheEntry<AttributedString>>()
        cache.countLimit = 200
        return cache
    }()
    private static let _parseOpts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)

    /// Escapes lone `~` characters (not part of `~~`) so they don't trigger
    /// false strikethrough rendering in Apple's markdown parser.
    private static func escapeLoneTildes(_ markdown: String) -> String {
        let chars = Array(markdown)
        var result = ""
        result.reserveCapacity(markdown.count)
        for i in chars.indices {
            if chars[i] == "~" {
                let prevIsTilde = i > 0 && chars[i - 1] == "~"
                let nextIsTilde = i + 1 < chars.count && chars[i + 1] == "~"
                if !prevIsTilde && !nextIsTilde {
                    result += "\\~"
                    continue
                }
            }
            result.append(chars[i])
        }
        return result
    }

    static func cachedAttr(_ markdown: String, key: String) -> AttributedString {
        let nsKey = key as NSString
        if let hit = _attrCache.object(forKey: nsKey) { return hit.value }
        let escaped = escapeLoneTildes(markdown)
        let result = (try? AttributedString(markdown: escaped, options: _parseOpts))
            ?? AttributedString(markdown)
        _attrCache.setObject(CacheEntry(result), forKey: nsKey)
        return result
    }

    /// Returns true for content requiring StructuredText's block-level rendering.
    static func needsStructuredText(_ markdown: String) -> Bool {
        // Code fences
        if markdown.contains("```") || markdown.contains("~~~") { return true }
        // Tables
        if markdown.contains("| ") && markdown.contains("|--") { return true }
        // Headings
        if markdown.hasPrefix("#") || markdown.contains("\n#") { return true }
        // Unordered lists
        if markdown.hasPrefix("- ") || markdown.contains("\n- ") { return true }
        if markdown.hasPrefix("* ") || markdown.contains("\n* ") { return true }
        if markdown.hasPrefix("+ ") || markdown.contains("\n+ ") { return true }
        // Ordered lists
        if markdown.hasPrefix("1. ") || markdown.contains("\n1. ") { return true }
        // Blockquotes
        if markdown.hasPrefix("> ") || markdown.contains("\n> ") { return true }
        return false
    }

    /// Fills empty markdown table cells with a non-breaking space so Textual
    /// doesn't collapse them and shift columns.
    static func fixEmptyTableCells(_ markdown: String) -> String {
        guard markdown.contains("|") else { return markdown }
        return markdown
            .replacingOccurrences(of: "| |", with: "| \u{00A0} |")
            .replacingOccurrences(of: "||", with: "| \u{00A0} |")
    }

    @ViewBuilder
    func renderedAssistantText(_ markdown: String, cacheKeySuffix: String, structured: Bool) -> some View {
        // On iOS a long-press is the reply's menu (`ReplyActionsMenu`); double-tap selects.
        #if os(iOS)
        if structured {
            StructuredText.cached(markdown)
                .textual.textSelection(.enabled)
        } else {
            Text(MessageView.cachedAttr(markdown, key: message.id.uuidString + cacheKeySuffix))
        }
        #else
        if structured {
            StructuredText.cached(markdown)
                .textual.textSelection(.enabled)
        } else {
            Text(MessageView.cachedAttr(markdown, key: message.id.uuidString + cacheKeySuffix))
                .textSelection(.enabled)
        }
        #endif
    }

    static func processThinkingContent(_ content: String) -> (String?, String?) {
        let result = ThinkingContentParser.parse(content)
        return (result.thinking, result.answer)
    }

    var time: String {
        if let generatingTime = message.generatingTime {
            return "\(generatingTime.formatted)"
        }
        return "0s"
    }

    private func thinkingLabel(isThinking: Bool) -> some View {
        HStack {
            Button {
                toggleCollapsed()
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .scaledFont(size: 12)
                    .fontWeight(.medium)
            }

            Text("\(isThinking ? "thinking…" : "thought for") \(time)")
                .italic()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func toggleCollapsed() {
        collapsed.toggle()
        DisclosureState.shared.setExpanded(message.id, !collapsed)
    }

    /// Think Harder (newest reply only), then copy, which copies the whole reply.
    private func replyActions(copyText: String) -> [ReplyAction] {
        var actions: [ReplyAction] = []
        if let onThinkHarder {
            actions.append(ReplyAction(id: "chat.thinkHarder", title: "think harder", systemImage: "brain",
                                       isAvailable: thinkHarderAvailable, perform: onThinkHarder))
        }
        actions.append(ReplyAction(id: "chat.copyReply", title: "copy", systemImage: "square.on.square") {
            #if os(iOS) || os(visionOS)
            UIPasteboard.general.string = copyText
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
            #endif
        })
        return actions
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            if message.role == .assistant {
                let parse = thinkParse
                let thinking = parse.thinking
                let afterThink = parse.answer
                VStack(alignment: .leading, spacing: 16) {

                    if let thinking {
                        VStack(alignment: .leading, spacing: 12) {
                            thinkingLabel(isThinking: parse.isThinking)
                            if !collapsed {
                                if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 12) {
                                        Capsule()
                                            .frame(width: 2)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(.fill)
                                        renderedAssistantText(thinking, cacheKeySuffix: "t",
                                                              structured: parse.thinkingNeedsStructuredText)
                                            .foregroundStyle(.secondary)
                                    }
                                    // The Capsule takes any height offered; without this the text centres in it.
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 5)
                                }
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            toggleCollapsed()
                        }
                    }

                    let sources = message.groundingSources
                    if let afterThink = ReplyMarkerWords.answerToDraw(afterThink) {
                        let hasSources = !sources.isEmpty
                        renderedAssistantText(afterThink, cacheKeySuffix: "c", structured: true)
                            .padding(.bottom, hasSources ? 12 : 0)
                    }

                    if !sources.isEmpty {
                        // Fades and grows in when sources arrive (motion audit #8). The animation rides the transition:
                        // not on appear (a recycled cell replays it), not on the body (that moved the text). RM: fade.
                        SourceStackChipView(sources: sources)
                            .transition(Motion.grow(from: 0.95, anchor: .leading, reduceMotion: reduceMotion)
                                .animation(Motion.fade))
                    }

                    if let marker = ReplyMarkerWords.marker(of: message) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(ReplyMarkerWords.line(marker))
                                .accessibilityIdentifier("chat.replyMarker")
                            if marker == .didntFinish, let onRetry {
                                Button(action: onRetry) {
                                    // Scales with the line; the frame keeps a 44 pt target at every text size.
                                    Text(ReplyMarkerWords.retry)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("retry")
                                .accessibilityIdentifier("chat.replyRetry")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let mark = SentBeforeConfirmed.mark(message.sentBeforeConfirmed) {
                        Text(ReplyMarkerWords.line(mark))
                            .font(.footnote)
                            .foregroundStyle(ReplyMarkerWords.color(of: mark))
                            .accessibilityIdentifier("chat.replyMark")
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                .modifier(ReplyActionsMenu(actions: replyActions(copyText: afterThink ?? message.content)))
                #else
                .contextMenu {
                    ForEach(replyActions(copyText: afterThink ?? message.content).filter { $0.isAvailable() }) { action in
                        Button(action: action.perform) { Label(action.title, systemImage: action.systemImage) }
                            .accessibilityIdentifier(action.id)
                    }
                }
                #endif
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                let images = ImageAttachment.images(of: message)
                if !images.isEmpty {
                    MessageImagesRow(images: images)
                        .padding(.leading, 48)
                }
                if !message.content.isEmpty {
                Text(message.content)
                #if os(iOS) || os(visionOS)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                #else
                    .padding(.horizontal, 16 * 2 / 3)
                    .padding(.vertical, 8)
                #endif
                    .background(Self.platformBackgroundColor)
                #if os(iOS) || os(visionOS)
                    .mask(RoundedRectangle(cornerRadius: 24))
                #elseif os(macOS)
                    .mask(RoundedRectangle(cornerRadius: 16))
                #endif
                    .overlay(alignment: .bottomTrailing) {
                        if onRetry != nil {
                            Button { onRetry?() } label: {
                                Image(systemName: "arrow.clockwise")
                                    .scaledFont(size: 8, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(.secondary)
                                    .glyphColumn(16, relativeTo: .caption2, square: true)
                                    .background(Self.platformBackgroundColor, in: Circle())
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("retry")
                            .accessibilityIdentifier("chat.retry")
                            .padding(.trailing, 10)
                            .offset(y: 8)
                            .transition(.opacity)
                        }
                    }
                    // Ease-out: an entrance decelerates (motion audit #6; it was ease-in 0.4).
                    .animation(Motion.fade, value: onRetry != nil)
                    .contextMenu {
                        Button {
                            #if os(iOS) || os(visionOS)
                            UIPasteboard.general.string = message.content
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            #endif
                        } label: {
                            Label("copy", systemImage: "square.on.square")
                        }
                    }
                    .padding(.leading, 48)
                }
                }
            }
        }
        .onAppear {
            // Restore a disclosure the user opened before this row was recycled
            // out of the lazy stack — see DisclosureState.
            if DisclosureState.shared.isExpanded(message.id) {
                collapsed = false
            } else if isLLMRunning {
                // `isLLMRunning` is now scoped by the caller to the turn in
                // flight, so this expands the reasoning of the message being
                // worked on and nothing else. It used to be true for EVERY row
                // whenever the thread had a generation running, which opened
                // every historic reasoning block on a mid-generation thread
                // open — and, under a lazy stack, would have fired again on
                // each scroll-in.
                collapsed = false
            }
        }
    }

    static let platformBackgroundColor = PlatformColors.secondaryBackground
}

// MARK: - Previews

#Preview("User Message Bubble") {
    VStack(spacing: 0) {
        MessageView(message: Message(role: .user, content: "What's the weather like today?"), isLLMRunning: false)
            .padding()
        MessageView(message: Message(role: .user, content: "Tell me a short story about a robot learning to paint."), isLLMRunning: false)
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("MessageView tok/s") {
    let sources = try! JSONEncoder().encode([
        GroundingSource(url: "https://techcrunch.com", domain: "techcrunch.com", title: "TechCrunch"),
        GroundingSource(url: "https://forbes.com", domain: "forbes.com", title: "Forbes")
    ])
    let msg = Message(role: .assistant,
                      content: "Fireworks AI is a private inference platform backed by Sequoia Capital. It focuses on fast, low-latency LLM serving.",
                      generatingTime: 2.8,
                      sourcesJSON: String(data: sources, encoding: .utf8))
    ScrollView {
        MessageView(message: msg, isLLMRunning: false)
            .padding()
    }
}
