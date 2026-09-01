//
//  LocalInferenceOracle.swift
//  teemoonTests
//
//  Decides whether a local model actually answered.
//
//  The whole smoke suite rests on this call, so it is deliberately paranoid.
//  "Non-empty" is not an answer: teemoon's own error strings are non-empty, and
//  so is the reply a model gives when it has lost the thread ("I'm ready to
//  assist you…"). Both have been observed passing an emptiness check on device.
//
//  The load-bearing idea is the NONCE. Each run generates a token that did not
//  exist when any model shipped and cannot be in any fixture or cache, and the
//  reply has to contain it. That proves the answer is a function of THIS
//  request — which is exactly what a smoke test should prove, and what every
//  other check here can only approximate.
//
//  Deliberately a copy task, not a transform. This suite must fail when teemoon
//  is broken and pass when teemoon works, EVEN IF the model is weak. Asking a
//  2-bit 8B for arithmetic would measure the model and make the suite flaky
//  about the wrong thing.
//

import Foundation

// MARK: - Nonce

/// A per-run token plus the prompt that asks for it back.
struct InferenceNonce: Sendable, Equatable {
    let token: String

    /// Blunt on purpose — a small model should not have to infer the task.
    var prompt: String {
        "Reply with exactly this token and nothing else: \(token)"
    }

    /// Letters and digits in short groups: unguessable, survives tokenisation,
    /// and stays recognisable if the model wraps it in punctuation.
    static func make() -> InferenceNonce {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        func group(_ n: Int) -> String { String((0..<n).map { _ in alphabet.randomElement()! }) }
        return InferenceNonce(token: "\(group(4))-\(group(4))")
    }
}

// MARK: - Verdicts

enum InferenceVerdict: Equatable, CustomStringConvertible {
    case ok
    /// Nothing, or nothing but whitespace.
    case empty
    /// teemoon's own failure text, surfaced where an answer should be.
    case errorSurface(String)
    /// The model handed the prompt back instead of answering it.
    case echoedPrompt
    /// "How can I help?" — fluent, non-empty, and not an answer.
    case boilerplate(String)
    /// Answered something, but not THIS request.
    case missingNonce(expected: String)

    var passed: Bool { self == .ok }

    var description: String {
        switch self {
        case .ok:                     return "ok"
        case .empty:                  return "empty reply"
        case .errorSurface(let s):    return "teemoon error text, not an answer — \(s.prefix(80))"
        case .echoedPrompt:           return "echoed the prompt back"
        case .boilerplate(let s):     return "generic assistant boilerplate — \(s.prefix(80))"
        case .missingNonce(let n):    return "never said the nonce \"\(n)\""
        }
    }
}

enum ToolUseVerdict: Equatable, CustomStringConvertible {
    case ok(matched: String)
    case noToolCall
    case toolReturnedNothing
    /// The exact on-device failure the provider sweep documents: the tool ran,
    /// and the model then said nothing about it.
    case boilerplateAfterTool(String)
    /// An answer that shares no distinctive term with what the tool returned —
    /// i.e. answered from memory, not from the sources.
    case ignoredTheSources

    var passed: Bool { if case .ok = self { return true }; return false }

    var description: String {
        switch self {
        case .ok(let m):                  return "ok (grounded on \"\(m)\")"
        case .noToolCall:                 return "the model never called the tool"
        case .toolReturnedNothing:        return "the tool ran but returned no sources"
        case .boilerplateAfterTool(let s): return "tool ran, then boilerplate — \(s.prefix(80))"
        case .ignoredTheSources:          return "answer shares nothing with the sources"
        }
    }
}

// MARK: - Oracle

enum LocalInferenceOracle {

    /// Fragments of teemoon's own error copy. A reply containing one of these is
    /// teemoon talking, not the model.
    ///
    /// Kept honest by `errorSurfaceCatalogCoversEverySourceLiteral` in the tests,
    /// which reads the app sources and fails when a new `userMessage:` appears
    /// that this list would not catch — otherwise a newly-added error string
    /// would silently start scoring as a successful inference.
    static let errorFragments: [String] = [
        "web search failed",
        "returned no results",
        "unexpected response format",
        "check your network connection",
        "invalid endpoint url",
        "invalid url",
        "could not reach",
        "no api key",
        "api key",
        "rate limit",
        "timed out",
        "cancelled",
        "failed to decode",
        "unauthorized",
        "not found",
        // The E2EE decrypt failure. Caught by the catalogue test on its first
        // run: unlike the others this one is plain prose in the assistant's own
        // position, so it reads as a model reply rather than as an error.
        "could not be decrypted",
        "re-verify the connection",
    ]

    /// The reply a model gives when it has lost the thread. Non-empty, fluent,
    /// and worthless — so it has to be named and failed explicitly.
    static let boilerplateFragments: [String] = [
        "i am ready to assist", "i'm ready to assist",
        "how can i help", "how may i assist", "how can i assist",
        "what would you like", "let me know what topic",
        "i'm here to help", "i am here to help",
        "please let me know", "feel free to ask",
    ]

    /// Order matters. An echoed prompt CONTAINS the nonce, so the echo check has
    /// to run before the nonce check or a parroting model scores a pass.
    static func judge(reply: String, prompt: String, nonce: String?) -> InferenceVerdict {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let lower = trimmed.lowercased()

        if let hit = errorFragments.first(where: { lower.contains($0) }) {
            return .errorSurface(hit)
        }
        if isEcho(reply: trimmed, prompt: prompt) { return .echoedPrompt }
        if let hit = boilerplateFragments.first(where: { lower.contains($0) }) {
            return .boilerplate(hit)
        }
        if let nonce, !lower.contains(nonce.lowercased()) {
            return .missingNonce(expected: nonce)
        }
        return .ok
    }

    /// True when the reply is the prompt handed back rather than answered.
    ///
    /// The failure this guards against is TEEMOON echoing the request — a
    /// plumbing bug, which produces a verbatim copy — so the test is near-exact
    /// equality on collapsed whitespace and trimmed punctuation.
    ///
    /// It deliberately does NOT fire on a reply that merely restates the
    /// instruction. A reasoning model narrates ("The user wants me to reply with
    /// a specific string: `9g54-w53t`…") and that is a real, live answer that
    /// happens to think out loud. A broader rule failed exactly that on the
    /// first smoke run, against a model that had done nothing wrong.
    static func isEcho(reply: String, prompt: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: ".,:;!?\"'`*- \t\n")
        let r = normalise(reply).trimmingCharacters(in: punctuation)
        let p = normalise(prompt).trimmingCharacters(in: punctuation)
        return r == p
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Tool use

    /// Everything observed during one grounded turn. The sources are captured
    /// IN THE SAME RUN — never a hardcoded expectation, because the whole point
    /// is to prove the answer came from what the tool actually returned.
    struct ToolUseEvidence {
        let toolWasCalled: Bool
        let sourceTexts: [String]
        let reply: String
        /// The user's question, excluded from overlap so echoing it can't pass.
        let prompt: String
    }

    static func judgeToolUse(_ e: ToolUseEvidence) -> ToolUseVerdict {
        guard e.toolWasCalled else { return .noToolCall }
        guard !e.sourceTexts.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .toolReturnedNothing
        }
        let lower = e.reply.lowercased()
        if let hit = boilerplateFragments.first(where: { lower.contains($0) }) {
            return .boilerplateAfterTool(hit)
        }
        let candidates = distinctiveTokens(in: e.sourceTexts.joined(separator: " "),
                                           excluding: e.prompt)
        guard let matched = candidates.first(where: { lower.contains($0.lowercased()) }) else {
            return .ignoredTheSources
        }
        return .ok(matched: matched)
    }

    /// Terms distinctive enough that finding one in the answer means the answer
    /// used the sources: numbers, capitalised words, and **alphanumeric codes**
    /// — minus anything already in the question and minus common English.
    ///
    /// The code class was missing at first and the smoke run caught it: a model
    /// quoted a planted access code back verbatim ("fj48-yqoa") and this scored
    /// it as ignoring the sources, because the pieces are neither all-digit nor
    /// proper-case. Identifiers, part numbers and prices all look like that.
    static func distinctiveTokens(in text: String, excluding prompt: String) -> [String] {
        let promptWords = Set(prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "from",
                                 "there", "their", "what", "when", "your", "have",
                                 "will", "find", "about", "https", "http", "www", "com"]

        // Split on WHITESPACE, not on every non-alphanumeric, then trim the
        // punctuation around each word. Splitting on punctuation shattered
        // hyphenated identifiers into fragments: an all-letter code like
        // "sebv-qdng" became "sebv" + "qdng", neither of which matches any class,
        // so a correctly-grounded answer scored as ignoring the sources. It
        // depended on whether the run's random token happened to contain a digit,
        // which made the check quietly flaky.
        let edges = CharacterSet(charactersIn: ".,:;!?\"'`*()[]{}<>“”‘’ \t\n")
        var seen = Set<String>()
        var out: [String] = []
        for word in text.components(separatedBy: .whitespacesAndNewlines) {
            let raw = word.trimmingCharacters(in: edges)
            guard raw.count >= 4 else { continue }
            let lower = raw.lowercased()
            guard !promptWords.contains(lower), !stop.contains(lower), !seen.contains(lower)
            else { continue }

            let isNumber = raw.allSatisfy(\.isNumber)
            let isProper = raw.first?.isUppercase == true && raw.dropFirst().contains(where: \.isLowercase)
            let isCode   = raw.contains(where: \.isNumber) && raw.contains(where: \.isLetter)
            // An identifier held together by - _ . or / — access codes, quant
            // names (Q4_K_M), model ids. Distinctive regardless of its letters.
            let joiners  = CharacterSet(charactersIn: "-_./:")
            let isJoined = raw.count >= 6
                && raw.rangeOfCharacter(from: joiners) != nil
                && raw.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil

            guard isNumber || isProper || isCode || isJoined else { continue }
            seen.insert(lower)
            out.append(raw)
        }
        return out
    }
}
