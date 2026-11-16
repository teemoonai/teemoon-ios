import Foundation
import Testing

@testable import Textual

// TEEMOON PATCH (7). Upstream showed one plain token whenever a code block's content changed, until the
// async tokenizer answered: while a reply streams, every new line blanked the colours for a frame or more,
// and the hand-off to the saved row (a new view) started plain again. Filmed on the stream rig,
// pm/evidence/1.1-ui/ios/stream/3-code-block-20tps.mp4.
struct HighlightTokenCacheTests {
  let coloured: [CodeToken] = [
    .init(content: "let", type: .keyword),
    .init(content: " a ", type: .plain),
    .init(content: "=", type: .operator),
    .init(content: " 1", type: .plain),
  ]

  @Test
  func aGrowingBlockKeepsItsColoursAndAddsTheNewTextPlain() {
    let tokens = HighlightTokenCache.provisionalTokens(
      for: "let a = 1\nlet b", language: "swift",
      previous: ("let a = 1", coloured), cache: HighlightTokenCache())
    #expect(tokens == coloured + [.init(content: "\nlet b", type: .plain)])
  }

  @Test
  func aRebuiltBlockStartsFromTheCache() {
    let cache = HighlightTokenCache()
    cache.store(code: "let a = 1", language: "swift", tokens: coloured)
    #expect(
      HighlightTokenCache.provisionalTokens(for: "let a = 1", language: "swift", previous: nil, cache: cache)
        == coloured)
    // The saved row can hold more than the last tokenized stream frame.
    #expect(
      HighlightTokenCache.provisionalTokens(for: "let a = 1\n", language: "swift", previous: nil, cache: cache)
        == coloured + [.init(content: "\n", type: .plain)])
  }

  @Test
  func unrelatedOrOtherLanguageCodeIsPlain() {
    let cache = HighlightTokenCache()
    cache.store(code: "let a = 1", language: "swift", tokens: coloured)
    for (code, language) in [("var x", "swift"), ("let a = 1", "python")] {
      #expect(
        HighlightTokenCache.provisionalTokens(for: code, language: language, previous: nil, cache: cache)
          == [.init(content: code, type: .plain)])
    }
  }

  @Test
  func theCacheIsBounded() {
    let cache = HighlightTokenCache(capacity: 2)
    for i in 0..<3 { cache.store(code: "x\(i)", language: "swift", tokens: [.init(content: "x\(i)", type: .keyword)]) }
    #expect(cache.lookup(code: "x0", language: "swift") == nil)
    #expect(cache.lookup(code: "x2", language: "swift") != nil)
  }
}
