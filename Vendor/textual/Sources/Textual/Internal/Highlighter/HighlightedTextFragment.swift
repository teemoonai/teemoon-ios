import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code using a two-phase approach.
// Tokenization runs asynchronously and is keyed by content, while highlighting runs
// synchronously on token or environment changes (theme, color scheme, dynamic type).
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.textEnvironment) private var textEnvironment

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    // TEEMOON PATCH (7): a rebuilt block draws from the token cache, not plain.
    TextFragment(model.highlightedCode ?? firstFrame)
      .foregroundStyle(theme.foregroundColor)
      .task(id: content) {
        await model.tokenize(
          content: content,
          languageHint: languageHint
        )
      }
      .onChange(of: Tuple(model.tokens, textEnvironment)) { _, newValue in
        model.highlight(
          tokens: newValue.values.0,
          presentationIntent: content.presentationIntent,
          using: theme,
          environment: newValue.values.1
        )
      }
  }
}

extension HighlightedTextFragment {
  private var firstFrame: AttributedString {
    let code = String(content.characters[...])
    let tokens = HighlightTokenCache.provisionalTokens(for: code, language: languageHint, previous: nil)
    guard tokens.count > 1 || tokens.first?.type != .plain else { return AttributedString(content) }
    return Model.render(
      tokens: tokens, presentationIntent: content.presentationIntent, using: theme, environment: textEnvironment)
  }

  @MainActor @Observable final class Model {
    var tokens: [CodeToken] = []
    var highlightedCode: AttributedString?
    @ObservationIgnored private var tokenized: (code: String, tokens: [CodeToken])?

    // TEEMOON PATCH (7): upstream reset to one plain token here on every change; keep the last colours.
    func tokenize(content: AttributedSubstring, languageHint: String?) async {
      let code = String(content.characters[...])
      let provisional = HighlightTokenCache.provisionalTokens(
        for: code, language: languageHint, previous: tokenized)
      if provisional != tokens { tokens = provisional }

      if let tokenizer = CodeTokenizer.shared, let languageHint {
        let result = await tokenizer.tokenize(code: code, language: languageHint)
        guard !Task.isCancelled else { return }
        HighlightTokenCache.shared.store(code: code, language: languageHint, tokens: result)
        tokenized = (code, result)
        tokens = result
      }
    }

    func highlight(
      tokens: [CodeToken],
      presentationIntent: PresentationIntent?,
      using theme: StructuredText.HighlighterTheme,
      environment: TextEnvironmentValues
    ) {
      self.highlightedCode = Self.render(
        tokens: tokens, presentationIntent: presentationIntent, using: theme, environment: environment)
    }

    static func render(
      tokens: [CodeToken],
      presentationIntent: PresentationIntent?,
      using theme: StructuredText.HighlighterTheme,
      environment: TextEnvironmentValues
    ) -> AttributedString {
      var attributes = AttributeContainer()
      // Re-apply the presentation intent for pasteboard formatters
      attributes.presentationIntent = presentationIntent
      ForegroundColorProperty(theme.foregroundColor)
        .apply(in: &attributes, environment: environment)
      var highlightedCode = AttributedString()

      for token in tokens {
        var content = AttributedString(token.content)
        var tokenAttributes = attributes

        if let tokenProperties = theme.tokenProperties[token.type] {
          tokenProperties.apply(in: &tokenAttributes, environment: environment)
        }

        content.mergeAttributes(tokenAttributes)
        highlightedCode.append(content)
      }

      return highlightedCode
    }
  }
}
