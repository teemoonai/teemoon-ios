import Foundation
import Testing
@testable import teemoon

@Suite("BraveWebSearchTool parsing")
struct BraveWebSearchToolTests {

    // MARK: - parseSources

    @Test func parseSources_validXML() {
        let xml = """
        <source index="1">
        <url>https://example.com/page1</url>
        <title>Example Page</title>
        <content>Some content about the topic.</content>
        </source>
        <source index="2">
        <url>https://other.com/page2</url>
        <title>Other Page</title>
        <content>More content here.</content>
        </source>
        """
        let sources = BraveWebSearchTool.parseSources(from: xml)
        #expect(sources.count == 2)
        #expect(sources[0].url == "https://example.com/page1")
        #expect(sources[0].title == "Example Page")
        #expect(sources[0].snippet == "Some content about the topic.")
        #expect(sources[0].domain == "example.com")
        #expect(sources[1].url == "https://other.com/page2")
    }

    @Test func parseSources_emptyString() {
        let sources = BraveWebSearchTool.parseSources(from: "")
        #expect(sources.isEmpty)
    }

    @Test func parseSources_noMatchingTags() {
        let sources = BraveWebSearchTool.parseSources(from: "Just some plain text.")
        #expect(sources.isEmpty)
    }

    @Test func parseSources_toleratesPublishedElement() {
        // `contextXML` emits <published> between <title> and <content> when Brave
        // reports a date; the reader must not lose the source because of it.
        let xml = """
        <source index="1">
        <url>https://example.com/news</url>
        <title>Some News</title>
        <published>Saturday, July 25, 2026</published>
        <content>The news itself.</content>
        </source>
        """
        let sources = BraveWebSearchTool.parseSources(from: xml)
        #expect(sources.count == 1)
        #expect(sources[0].title == "Some News")
        #expect(sources[0].snippet == "The news itself.")
    }

    @Test func parseSources_multilineContent() {
        let xml = """
        <source index="1">
        <url>https://example.com</url>
        <title>Test</title>
        <content>Line one.
        Line two.
        Line three.</content>
        </source>
        """
        let sources = BraveWebSearchTool.parseSources(from: xml)
        #expect(sources.count == 1)
        #expect(sources[0].snippet.contains("Line one."))
        #expect(sources[0].snippet.contains("Line three."))
    }

    // MARK: - parseMarkdownLinks

    @Test func parseMarkdownLinks_validLinks() {
        let text = """
        According to [Example](https://example.com/page), the answer is yes.
        Also see [Other Site](https://other.com/info).
        """
        let sources = BraveWebSearchTool.parseMarkdownLinks(from: text)
        #expect(sources.count == 2)
        #expect(sources[0].url == "https://example.com/page")
        #expect(sources[0].title == "Example")
        #expect(sources[1].url == "https://other.com/info")
    }

    @Test func parseMarkdownLinks_deduplicatesURLs() {
        let text = """
        See [First](https://example.com) and [Second](https://example.com).
        """
        let sources = BraveWebSearchTool.parseMarkdownLinks(from: text)
        #expect(sources.count == 1)
        #expect(sources[0].title == "First")
    }

    @Test func parseMarkdownLinks_noLinks() {
        let sources = BraveWebSearchTool.parseMarkdownLinks(from: "No links here.")
        #expect(sources.isEmpty)
    }

    @Test func parseMarkdownLinks_httpAndHttps() {
        let text = "[Secure](https://s.com) and [Insecure](http://i.com)"
        let sources = BraveWebSearchTool.parseMarkdownLinks(from: text)
        #expect(sources.count == 2)
    }

    // MARK: - GroundingSource Codable

    @Test func groundingSource_codable_roundtrip() throws {
        let source = GroundingSource(url: "https://test.com", domain: "test.com", title: "Test", snippet: "A snippet")
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(GroundingSource.self, from: data)
        #expect(decoded.url == source.url)
        #expect(decoded.domain == source.domain)
        #expect(decoded.title == source.title)
        #expect(decoded.snippet == source.snippet)
    }

    @Test func groundingSource_decodable_missingSnippet_defaultsToEmpty() throws {
        let json = """
        {"url": "https://test.com", "domain": "test.com", "title": "Test"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GroundingSource.self, from: json)
        #expect(decoded.snippet == "")
    }

    @Test func groundingSource_id_isURL() {
        let source = GroundingSource(url: "https://unique.com", domain: "unique.com", title: "T")
        #expect(source.id == "https://unique.com")
    }

    // MARK: - Live response decoding
    //
    // Fixtures are verbatim `GET /res/v1/llm/context` responses:
    //   brave_llm_context.json      — "weather 10001", every source's `age` empty
    //   brave_llm_context_news.json — "AI news this week"&freshness=pw, `age` populated

    private func loadResponse(_ name: String, file: String = #filePath) throws -> BraveGroundingResponse {
        let data = try TestFixture.data(name, file: file)
        return try JSONDecoder().decode(BraveGroundingResponse.self, from: data)
    }

    @Test func decodesLiveResponse_groundingAndSources() throws {
        let r = try loadResponse("brave_llm_context.json")
        #expect(r.grounding.generic.count == 3)
        #expect(r.grounding.map?.isEmpty == true)
        // The top-level map is keyed by the same URL `generic` uses — that pairing
        // is the whole reason we can enrich passages with page metadata.
        for page in r.grounding.generic {
            #expect(r.sources?[page.url] != nil)
        }
        let first = try #require(r.sources?[r.grounding.generic[0].url])
        #expect(first.hostname == "www.weatherusa.net")
        #expect(first.displayDate == nil)   // `age` is [] when Brave has no date
    }

    @Test func decodesLiveResponse_ageIsThreeRenderings() throws {
        let r = try loadResponse("brave_llm_context_news.json")
        let dated = try #require(r.sources?.values.first { ($0.age?.count ?? 0) == 3 })
        let age = try #require(dated.age)
        #expect(age[1].hasPrefix("2026-"))          // ISO date
        #expect(age[2].hasSuffix("days ago"))       // relative
        #expect(dated.displayDate == age[0])        // human-readable is what we emit
    }

    @Test func contextXML_carriesPublishedDateFromTopLevelSources() throws {
        let xml = BraveWebSearchTool.contextXML(from: try loadResponse("brave_llm_context_news.json"))
        #expect(xml.contains("<published>"))
        // …and round-trips back out through the reader the app uses.
        #expect(BraveWebSearchTool.parseSources(from: xml).count == 3)
    }

    // MARK: - JSON-LD passages reaching the model
    //
    // Brave returns some passages as JSON-LD rather than prose. The citation UI
    // hides those (`displaySnippet`), but the model was handed the blob verbatim
    // — and in the captured "weather 10001" response the entire forecast lives
    // inside one, so the model had to parse JSON to read a temperature.

    @Test func readableSnippet_unpacksTheWeatherTableIntoProse() {
        let blob = #"{"title":"Forecast for New York","table":[{"DEWPOINT":"40°"},{"HUMIDITY":"93%"}]}"#
        let out = GroundingSource.readableSnippet(blob)
        #expect(out.contains("DEWPOINT: 40°"))
        #expect(out.contains("HUMIDITY: 93%"))
        // The syntax itself is gone.
        #expect(!out.contains("{"))
        #expect(!out.contains("\""))
    }

    @Test func readableSnippet_leavesProseAlone() {
        let prose = "New York will be cloudy with a high near 52."
        #expect(GroundingSource.readableSnippet(prose) == prose)
    }

    @Test func readableSnippet_isDeterministicAcrossRuns() {
        // Swift dictionaries have no stable order; the same passage must not
        // render differently between runs or the prompt changes under us.
        let blob = #"{"a":"1","b":"2","c":"3","d":"4","e":"5"}"#
        let renders = Set((0..<25).map { _ in GroundingSource.readableSnippet(blob) })
        #expect(renders.count == 1)
    }

    @Test func readableSnippet_salvagesTruncatedJSON() {
        // Brave cuts passages mid-object, so this will not parse as JSON.
        let cut = #"{"@type":"NewsArticle","headline":"Nvidia unveils Korea AI push","articleBody":"The chipmaker said"#
        let out = GroundingSource.readableSnippet(cut)
        #expect(out.contains("Nvidia unveils Korea AI push"))
        #expect(!out.contains("@type"))
    }

    @Test func readableSnippet_emptyWhenNothingSurvives() {
        #expect(GroundingSource.readableSnippet("{}").isEmpty)
        #expect(GroundingSource.readableSnippet("   ").isEmpty)
    }

    @Test func contextXML_sendsTheModelFactsNotJSON() throws {
        let xml = BraveWebSearchTool.contextXML(from: try loadResponse("brave_llm_context.json"))
        // The forecast values are readable...
        #expect(xml.contains("DEWPOINT: 40°"))
        // ...and no passage still carries raw JSON-LD syntax.
        for source in BraveWebSearchTool.parseSources(from: xml) {
            #expect(!GroundingSource.isStructuredData(source.snippet),
                    "a JSON-LD blob reached the model: \(source.snippet.prefix(80))")
        }
    }

    @Test func contextXML_omitsPublishedWhenBraveHasNoDate() throws {
        let xml = BraveWebSearchTool.contextXML(from: try loadResponse("brave_llm_context.json"))
        #expect(!xml.contains("<published>"))
        let sources = BraveWebSearchTool.parseSources(from: xml)
        #expect(sources.count == 3)
        #expect(sources[0].domain == "www.weatherusa.net")
        #expect(sources.allSatisfy { !$0.snippet.isEmpty })
    }

    @Test func contextXML_fallsBackToTopLevelSnippetWhenNoPassages() throws {
        // Brave sometimes returns a page with no `snippets`. Before the top-level
        // `sources` map was read, such a page was dropped from the context entirely
        // (the old fallback keyed off a `description` field that never appears).
        let json = """
        {"grounding": {"generic": [{"url": "https://a.com/p", "title": "", "snippets": []}], "map": []},
         "sources": {"https://a.com/p": {"title": "Page A", "hostname": "a.com", "age": [], "snippet": "Summary of page A."}}}
        """.data(using: .utf8)!
        let xml = BraveWebSearchTool.contextXML(from: try JSONDecoder().decode(BraveGroundingResponse.self, from: json))
        let sources = BraveWebSearchTool.parseSources(from: xml)
        #expect(sources.count == 1)
        #expect(sources[0].title == "Page A")          // title also filled from `sources`
        #expect(sources[0].snippet == "Summary of page A.")
    }

    @Test func contextXML_dropsPagesWithNoContentAnywhere() throws {
        let json = """
        {"grounding": {"generic": [{"url": "https://a.com/p", "title": "A", "snippets": []}], "map": []},
         "sources": {}}
        """.data(using: .utf8)!
        let xml = BraveWebSearchTool.contextXML(from: try JSONDecoder().decode(BraveGroundingResponse.self, from: json))
        #expect(xml.isEmpty)
    }

    // MARK: - GroundingBudget

    @Test func theBudgetScalesWithQueryBreadth() {
        // Measured on "weather 10001": 4096 tokens × 10 urls → ~2,600 prompt
        // tokens. Small lookups shouldn't reserve 8k for pages they won't get.
        #expect(GroundingBudget.maxTokens(forCount: 3) < GroundingBudget.maxTokens(forCount: 50))
        #expect(GroundingBudget.maxTokens(forCount: 3) == 2048)
        #expect(GroundingBudget.maxTokens(forCount: 10) == 4096)
        #expect(GroundingBudget.urlCap(forCount: 10) == 10)
    }

    @Test func theBudgetNeverExceedsTheModelsRequestedCount() {
        // The model asks for `count` pages; the budget may shrink that, never
        // grow it — asking Brave for more pages than the model wanted spends
        // context on results it didn't request.
        for count in [1, 2, 5, 20, 50] {
            #expect(GroundingBudget.urlCap(forCount: count) <= count)
        }
        // ...and it caps at 10 however many are asked for.
        #expect(GroundingBudget.urlCap(forCount: 50) == 10)
    }

    @Test func everyProviderGetsTheFullBudget() {
        // Inverted from `selfHostedProvidersGetTheCompactBudget`, which pinned
        // the opposite and was correct until it was measured. Self-hosted
        // endpoints no longer get `.compact`: prefill turned out to be free
        // (0.02s for 538 vs 4038 input tokens on gemma4:e2b), Brave bills per
        // query rather than per source, and `.full` won 6 of 6 accuracy cells.
        // See the comment at the call site in `ChatGeneration`.
        let local = Provider(name: "Local", endpoint: "http://localhost:11434/v1", model: "m")
        let cloud = Provider(name: "Cloud", endpoint: "https://api.example.com/v1", model: "m")
        #expect(local.isSelfHosted)
        #expect(!cloud.isSelfHosted)
        // There is no per-provider budget left to assert: `BraveWebSearchTool`
        // takes no budget argument at all, so both of these get the same payload
        // by construction rather than by policy. That IS the change.
        #expect(BraveWebSearchTool(apiKey: "k").name == "web_search")
    }

    @Test func selfHostedClassificationStillHolds() {
        // `isSelfHosted` no longer selects a grounding budget, but it still
        // gates E2EE, attestation and the local-provider UI — so the tailnet
        // case stays pinned. On a real phone this is THE local path: loopback
        // only ever appears in the simulator, and the device reaches Ollama
        // through `tailscale serve` as an HTTPS tailnet name.
        let tailnet = Provider(name: "ringzero",
                               endpoint: "https://ringzero.tailnet-name.ts.net/v1",
                               model: "gemma4:e2b-it-qat", requiresAPIKey: false)
        #expect(tailnet.isSelfHosted)
        // The CGNAT literal is the same host by IP, and must agree.
        let byIP = Provider(name: "ringzero", endpoint: "http://100.100.0.39:11434/v1",
                            model: "m", requiresAPIKey: false)
        #expect(byIP.isSelfHosted)
    }

}
