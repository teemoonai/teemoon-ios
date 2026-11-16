import Foundation

// TEEMOON PATCH — this whole file. See ../../../../VENDORING.md (patch 7).
//
// What a code block shows while its tokens are being computed. Never fall back to one plain token when
// a coloured answer for the same code (or a prefix of it) is known: that plain frame is the flicker.

/// Recently tokenized code, by language, so a block that is rebuilt (a streaming block finishing, the
/// reply handing over to its saved row) starts coloured.
final class HighlightTokenCache: @unchecked Sendable {
  static let shared = HighlightTokenCache()

  private struct Entry {
    let language: String
    let code: String
    let tokens: [CodeToken]
  }

  private let lock = NSLock()
  private var entries: [Entry] = []
  private let capacity: Int

  init(capacity: Int = 64) { self.capacity = capacity }

  func store(code: String, language: String, tokens: [CodeToken]) {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll { $0.language == language && $0.code == code }
    entries.append(Entry(language: language, code: code, tokens: tokens))
    if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
  }

  /// The exact entry for `code`, else the longest entry `code` extends, with the rest plain.
  func lookup(code: String, language: String) -> [CodeToken]? {
    lock.lock()
    defer { lock.unlock() }
    var best: Entry?
    for entry in entries where entry.language == language && code.hasPrefix(entry.code) {
      if entry.code.count > (best?.code.count ?? -1) { best = entry }
    }
    guard let best else { return nil }
    return HighlightTokenCache.extend(best.tokens, from: best.code, to: code)
  }

  /// The tokens to show for `code` until its own tokenization lands.
  static func provisionalTokens(
    for code: String,
    language: String?,
    previous: (code: String, tokens: [CodeToken])?,
    cache: HighlightTokenCache = .shared
  ) -> [CodeToken] {
    if let previous, code.hasPrefix(previous.code) {
      return extend(previous.tokens, from: previous.code, to: code)
    }
    if let language, let cached = cache.lookup(code: code, language: language) { return cached }
    return [CodeToken(content: code, type: .plain)]
  }

  static func extend(_ tokens: [CodeToken], from old: String, to new: String) -> [CodeToken] {
    let suffix = String(new.dropFirst(old.count))
    return suffix.isEmpty ? tokens : tokens + [CodeToken(content: suffix, type: .plain)]
  }
}
