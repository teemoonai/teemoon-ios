//
//  LocalInferenceOracleTests.swift
//  teemoonTests
//
//  The oracle decides whether every other local smoke check passed, so it is
//  itself tested against the replies that have actually fooled a naive check.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Local inference oracle")
struct LocalInferenceOracleTests {

    private let nonce = InferenceNonce(token: "zq7f-4821")

    // MARK: The pass

    @Test func aBareNonceIsTheOnlyThingThatPasses() {
        let v = LocalInferenceOracle.judge(reply: "zq7f-4821", prompt: nonce.prompt, nonce: nonce.token)
        #expect(v == .ok)
    }

    /// Models wrap tokens in punctuation, whitespace and the odd flourish. That
    /// is still a pass — the point is that the token came back at all.
    @Test func decorationAroundTheNonceStillPasses() {
        for reply in ["zq7f-4821.", "  ZQ7F-4821  ", "`zq7f-4821`", "Sure: zq7f-4821"] {
            let v = LocalInferenceOracle.judge(reply: reply, prompt: nonce.prompt, nonce: nonce.token)
            #expect(v == .ok, "should pass: \(reply)")
        }
    }

    // MARK: The failures that look like passes

    @Test func emptyAndWhitespaceFail() {
        #expect(LocalInferenceOracle.judge(reply: "", prompt: nonce.prompt, nonce: nonce.token) == .empty)
        #expect(LocalInferenceOracle.judge(reply: "   \n ", prompt: nonce.prompt, nonce: nonce.token) == .empty)
    }

    /// The failure this whole file exists for: fluent, non-empty, not an answer.
    @Test func boilerplateFails() {
        let v = LocalInferenceOracle.judge(reply: "I'm ready to assist you with factual information. How can I help?",
                                           prompt: nonce.prompt, nonce: nonce.token)
        guard case .boilerplate = v else { Issue.record("expected boilerplate, got \(v)"); return }
    }

    /// teemoon's own error copy rendered where an answer belongs.
    @Test func teemoonsOwnErrorTextFails() {
        let v = LocalInferenceOracle.judge(reply: "Brave web search failed — check your network connection.",
                                           prompt: nonce.prompt, nonce: nonce.token)
        guard case .errorSurface = v else { Issue.record("expected errorSurface, got \(v)"); return }
    }

    /// A parroting model returns the prompt — which CONTAINS the nonce. If the
    /// echo check ran after the nonce check this would score a pass.
    @Test func echoingThePromptFailsEvenThoughItContainsTheNonce() {
        #expect(nonce.prompt.contains(nonce.token))   // the trap is real
        let v = LocalInferenceOracle.judge(reply: nonce.prompt, prompt: nonce.prompt, nonce: nonce.token)
        #expect(v == .echoedPrompt)
    }

    /// REGRESSION: a reasoning model narrates the task before doing it. That is
    /// a live answer thinking out loud, not an echo — an over-broad echo rule
    /// failed `gemma4:e2b-it-qat` on the first smoke run for nothing.
    @Test func narratingTheTaskIsNotAnEcho() {
        let reply = "Thinking Process: The user wants me to reply with a specific string: `zq7f-4821`. I must ensure my entire response is exactly that token."
        let v = LocalInferenceOracle.judge(reply: reply, prompt: nonce.prompt, nonce: nonce.token)
        #expect(v == .ok, "\(v)")
    }

    /// A confident, well-formed answer to a DIFFERENT request. This is what a
    /// cached or canned reply looks like, and only the nonce catches it.
    @Test func aPlausibleAnswerWithoutTheNonceFails() {
        let v = LocalInferenceOracle.judge(reply: "The capital of France is Paris.",
                                           prompt: nonce.prompt, nonce: nonce.token)
        #expect(v == .missingNonce(expected: nonce.token))
    }

    @Test func nonceIsUnguessableEnoughToBeUnique() {
        let tokens = Set((0..<200).map { _ in InferenceNonce.make().token })
        #expect(tokens.count == 200)                     // no collisions
        #expect(tokens.allSatisfy { $0.count == 9 })     // 4 + dash + 4
    }

    // MARK: Tool use

    private func evidence(reply: String,
                          called: Bool = true,
                          sources: [String] = ["ShopRite of New York is open until 2200 daily."])
    -> LocalInferenceOracle.ToolUseEvidence {
        .init(toolWasCalled: called, sourceTexts: sources, reply: reply,
              prompt: "Best grocery stores around new york ny")
    }

    @Test func groundedAnswerPasses() {
        let v = LocalInferenceOracle.judgeToolUse(evidence(reply: "ShopRite is a good option nearby."))
        #expect(v.passed, "\(v)")
    }

    @Test func noToolCallFails() {
        #expect(LocalInferenceOracle.judgeToolUse(evidence(reply: "ShopRite.", called: false)) == .noToolCall)
    }

    @Test func toolRanButReturnedNothingFails() {
        #expect(LocalInferenceOracle.judgeToolUse(evidence(reply: "ShopRite.", sources: ["  "]))
                == .toolReturnedNothing)
    }

    /// Documented on-device failure: the tool ran, the model then greeted.
    @Test func boilerplateAfterAToolCallFails() {
        let v = LocalInferenceOracle.judgeToolUse(evidence(reply: "How can I help you today?"))
        guard case .boilerplateAfterTool = v else { Issue.record("expected boilerplateAfterTool, got \(v)"); return }
    }

    /// Answered from memory. Fluent, on-topic, shares nothing with the sources —
    /// and echoing the question's own words must not rescue it.
    @Test func answeringFromMemoryFails() {
        let v = LocalInferenceOracle.judgeToolUse(
            evidence(reply: "There are many grocery stores around new york ny to choose from."))
        #expect(v == .ignoredTheSources, "\(v)")
    }

    /// REGRESSION: the first smoke run scored a correct, tool-grounded answer as
    /// ignoring the sources. The model had quoted a planted code back verbatim,
    /// but the code's pieces are neither all-digit nor proper-case, so nothing
    /// recognised them. Identifiers, part numbers and prices all look like this.
    @Test func alphanumericCodesCountAsDistinctive() {
        let e = LocalInferenceOracle.ToolUseEvidence(
            toolWasCalled: true,
            sourceTexts: ["The New York depot access code is fj48-yqoa."],
            reply: "The access code for the New York depot is fj48-yqoa.",
            prompt: "What is the access code for the New York depot?")
        #expect(LocalInferenceOracle.judgeToolUse(e).passed, "\(LocalInferenceOracle.judgeToolUse(e))")
    }

    /// REGRESSION, and the nastier kind — this one was FLAKY. Whether the check
    /// passed depended on whether the run's random token happened to contain a
    /// digit: "fj48-yqoa" was recognised, "sebv-qdng" was not, because splitting
    /// on punctuation shattered it into two unremarkable letter fragments.
    /// Markdown emphasis around it must not matter either.
    @Test func anAllLetterCodeInMarkdownStillCounts() {
        let e = LocalInferenceOracle.ToolUseEvidence(
            toolWasCalled: true,
            sourceTexts: ["The New York depot access code is sebv-qdng. It was reissued this morning."],
            reply: "The access code for the New York depot is **sebv-qdng**.",
            prompt: "What is the access code for the New York depot? Use the search tool.")
        #expect(LocalInferenceOracle.judgeToolUse(e).passed, "\(LocalInferenceOracle.judgeToolUse(e))")
    }

    /// Every nonce the generator can produce must be recognisable as distinctive,
    /// or the smoke suite stays a coin flip.
    @Test func everyGeneratedNonceIsADistinctiveToken() {
        for _ in 0..<200 {
            let token = InferenceNonce.make().token
            let toks = LocalInferenceOracle.distinctiveTokens(
                in: "the code is \(token) and nothing else", excluding: "what is the code")
            #expect(toks.contains(token), "nonce \(token) is not recognised as distinctive")
        }
    }

    @Test func distinctiveTokensExcludeThePromptAndCommonWords() {
        let toks = LocalInferenceOracle.distinctiveTokens(
            in: "Wegmans and ShopRite serve New York with 1200 items",
            excluding: "grocery stores around new york ny")
        #expect(toks.contains("Wegmans"))
        #expect(toks.contains("1200"))
        #expect(!toks.contains(where: { $0.lowercased() == "york" }))  // in the prompt
    }

    // MARK: Keeping the error catalogue honest

    /// Reads the app's own sources and asserts the oracle would recognise every
    /// literal `userMessage:` as teemoon's voice rather than a model's answer.
    ///
    /// Without this, adding a new error string quietly turns it into something
    /// the smoke suite scores as a successful inference.
    @Test(.enabled(if: TestFixture.sourceTreeAvailable()))
    func errorSurfaceCatalogCoversEverySourceLiteral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // teemoonTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("teemoon")

        var literals: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        // `userMessage: "…"` — interpolated ones are skipped: their literal part
        // is only a fragment and would make this assertion meaningless.
        let re = try NSRegularExpression(pattern: #"userMessage:\s*"([^"\\]+)""#)
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                literals.append(ns.substring(with: m.range(at: 1)))
            }
        }

        #expect(!literals.isEmpty, "found no userMessage: literals — the scan is broken, not the app")

        for literal in Set(literals) {
            let verdict = LocalInferenceOracle.judge(reply: literal, prompt: "irrelevant", nonce: nil)
            guard case .errorSurface = verdict else {
                Issue.record("""
                    teemoon error text the oracle would score as a real answer:
                      "\(literal)"
                    Add a distinguishing fragment to LocalInferenceOracle.errorFragments.
                    """)
                continue
            }
        }
    }
}
