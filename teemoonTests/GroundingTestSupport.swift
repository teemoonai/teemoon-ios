//
//  GroundingTestSupport.swift
//  teemoonTests
//
//  Shared plumbing + the OBJECTIVE scorer for every grounding experiment.
//
//  The scorer lives in one place on purpose. Three separate prose-matching
//  scorers were written during this investigation and all three were wrong:
//  matching the location accepted refusals that echoed the question back
//  ("I don't have data for New York NY 10001" scored as an answer), and a
//  refusal-phrase list then rejected correct answers that added a hedge
//  afterwards. Both errors came from judging VOCABULARY. The only honest
//  question is whether the reply states a figure that appears in the payload
//  the model was actually given — which it cannot do by paraphrasing.
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

enum GroundingTestSupport {

    // MARK: - Objective scoring

    /// Distinctive numbers in a text: multi-digit, comma/decimal aware, with
    /// anything already present in the QUESTION removed so a model never scores
    /// for echoing the prompt. Single digits are dropped — a bare "1" collides
    /// by chance far too often to count as evidence.
    static func distinctiveFigures(in text: String, excluding question: String) -> Set<String> {
        func figures(_ s: String) -> Set<String> {
            let matches = s.matches(of: #/\d[\d,]*(?:\.\d+)?/#)
            var out = Set<String>()
            for m in matches {
                let raw: String = String(m.output)
                let cleaned: String = raw.replacingOccurrences(of: ",", with: "")
                if cleaned.count >= 2 { out.insert(cleaned) }
            }
            return out
        }
        return figures(text).subtracting(figures(question))
    }

    /// Did the reply state a figure it could only have obtained from the payload?
    static func citesRetrievedFigure(reply: String, payload: String, question: String) -> Bool {
        !distinctiveFigures(in: reply, excluding: question)
            .intersection(distinctiveFigures(in: payload, excluding: question))
            .isEmpty
    }

    /// Secondary metric: how much the model equivocates instead of answering.
    static func hedgeCount(_ text: String) -> Int {
        let t = text.lowercased()
        return ["varies", "may not be", "depending on the source", "different dates",
                "not be perfectly", "can change rapidly", "various sources",
                "may not reflect", "historically", "recommend checking",
                "i don't have", "i do not have", "unable to"]
            .filter { t.contains($0) }.count
    }

    // MARK: - Plumbing

    /// Fetches and decodes one real grounding response, so an experiment can
    /// render the SAME payload several ways / feed it to several models.
    static func fetchGrounding(query: String, key: String,
                               maxTokens: Int = 4096, maxURLs: Int = 10) async throws -> BraveGroundingResponse {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/llm/context")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maximum_number_of_tokens", value: String(maxTokens)),
            URLQueryItem(name: "maximum_number_of_urls", value: String(maxURLs)),
        ]
        // An explicit timeout, for the same reason `BraveWebSearchTool` needs
        // one: `URLRequest`'s 60 s default is an IDLE timeout and
        // `timeoutIntervalForResource` defaults to seven days, so a stalled
        // connection hangs a whole experiment with no error. An experiment that
        // can hang forever is one whose silence cannot be interpreted.
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(BraveGroundingResponse.self, from: data)
    }

    /// One generation through the real engine with a fixed grounding payload.
    ///
    /// No `max_tokens`: production sends none, and a cap truncates a model
    /// mid-reasoning, which reads as a content failure that isn't one (measured
    /// — capping at 512 took one arm from 2/4 to 0/4).
    @MainActor
    static func ask(provider: Provider, apiKey: String, payload: String, prompt: String) async -> String {
        var provider = provider
        provider.modelCapabilities = .tools
        provider.extraParams.removeValue(forKey: "max_tokens")
        let persona = ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        let llm = ConfidentialLanguageModel(
            provider: provider, apiKey: apiKey,
            priorMessages: [WireMessage(role: "system", content: persona)],
            context: nil, events: StreamCallbacks(
                onSourcesFound: { _ in }, onQueriesFound: { _ in },
                onToolExecutionEnded: {}, onSuccess: { _ in }))
        let session = LanguageModelSession(model: llm, tools: [CannedGroundingTool(payload: payload)])
        var text = ""
        do {
            for try await s in session.streamResponse(to: prompt) { text = s.content }
        } catch {
            return "error: \(error.localizedDescription)"
        }
        return text
    }

    static func ollama(model: String) -> Provider {
        Provider(name: "ollama", endpoint: "http://127.0.0.1:11434/v1",
                 model: model, requiresAPIKey: false)
    }

    static func ollamaIsUp() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1/models")!)
        req.timeoutInterval = 4
        guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
        return (r as? HTTPURLResponse)?.statusCode == 200
    }
}

/// Serves a fixed, pre-rendered grounding payload so an experiment varies
/// exactly one thing. Shaped like the real `web_search` so the model's decision
/// to call it is unchanged.
struct CannedGroundingTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information such as weather, recent events, live prices, or anything past your training cutoff."
    let payload: String

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String { payload }
}

// MARK: - Scorer tests
//
// The scorer has been wrong four times in one investigation. It is the
// instrument every grounding claim rests on, so it gets its own tests.

@Suite("Grounding scorer")
struct GroundingScorerTests {

    @Test func doesNotScoreForEchoingTheQuestion() {
        // The first bug: "I don't have data for New York NY 10001" counted
        // as a successful answer because it contained the ZIP — from the prompt.
        let q = "What is the weather in New York NY 10001 right now?"
        let payload = "<content>Feels like 42°F, humidity 93%</content>"
        #expect(!GroundingTestSupport.citesRetrievedFigure(
            reply: "I do not have current weather data for New York NY 10001.",
            payload: payload, question: q))
    }

    @Test func catchesLatexFormattedFigures() {
        // The fourth bug: gemma4 writes temperatures as LaTeX, so a unit-anchored
        // regex saw no figures at all and scored real answers as failures.
        let q = "What is the weather in New York NY 10001 right now?"
        let payload = "<content>Temperature 48, dew point 31</content>"
        #expect(GroundingTestSupport.citesRetrievedFigure(
            reply: #"**Temperature:** $48^\circ\text{F}$ **Feels Like:** $48^\circ\text{F}$"#,
            payload: payload, question: q))
    }

    @Test func acceptsPlainAndUnicodeDegreeForms() {
        let q = "weather?"
        let payload = "<content>42°F and 93% humidity</content>"
        for reply in ["It is 42°F right now.", "It is 42 degrees Fahrenheit.", "Currently 42F."] {
            #expect(GroundingTestSupport.citesRetrievedFigure(reply: reply, payload: payload, question: q))
        }
    }

    @Test func rejectsFiguresTheModelInvented() {
        let q = "weather?"
        #expect(!GroundingTestSupport.citesRetrievedFigure(
            reply: "It is about 71°F.", payload: "<content>42°F, 93% humidity</content>", question: q))
    }

    @Test func singleDigitsAreTooCoincidentalToCount() {
        #expect(GroundingTestSupport.distinctiveFigures(in: "about 7 things", excluding: "").isEmpty)
        #expect(GroundingTestSupport.distinctiveFigures(in: "about 71 things", excluding: "") == ["71"])
    }

    @Test func commaSeparatedFiguresNormalise() {
        // A price answer: "$118,432" in the reply must match "118432" logic-side.
        #expect(GroundingTestSupport.citesRetrievedFigure(
            reply: "Bitcoin is trading around $118,432 today.",
            payload: "<content>BTC 118,432 USD</content>", question: "bitcoin price?"))
    }
}
