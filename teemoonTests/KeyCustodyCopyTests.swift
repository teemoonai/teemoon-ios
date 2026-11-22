//
//  KeyCustodyCopyTests.swift
//  teemoonTests
//
//  The key-custody copy (card key-custody-copy, the maintainer 2026-11-18): near.ai's key service derives the model key from
//  the app id and decides which sealed chips get it (dstack kms derive_k256_key), and one listed holder serves other
//  models too. So no shipping string may say the key "never comes out" / "never leaves" a chip, or that only one
//  sealed chip holds it.
//
//  Card trust-copy-sweep-111 v4 (audit 1.1.1 A9, the maintainer 2026-11-19) widened it: no string may claim only the model can
//  open the chat, that no one else can read it, that the key was generated in or lives in an enclave, or that the
//  gateway cannot decrypt. Over-claims it caught on 2026-11-20: the hero tail "only it can read this", the subtitles
//  "only you and <model>'s sealed hardware can read this chat" / "only you and the attested TEE hardware…", the row
//  "sealed so only <model> can open it", the ladder intro "with no one else able to read them", the expert tail
//  "the gateway can't decrypt", the check rows "The key was generated inside that enclave" / "…lives in the enclave",
//  "…this specific enclave — only it can read them", and the can't-seal ask "…so only the model can read it".
//
//  Reads teemoon's own source — every string literal (single-line, multi-line, raw, interpolated), never a comment.
//  Host-only, skips on a device.
//

import Foundation
import Testing

@Suite("Key-custody copy tripwire")
struct KeyCustodyCopyTests {

    /// Card trust-copy-sweep-111 v4, verbatim.
    static let banned = ["only it can", "only you and", "no one else", "nobody else", "sealed so only", "so only",
                         "can't decrypt", "cannot decrypt", "generated inside", "lives in the enclave",
                         "can't read", "cannot read"]

    /// Permanent, narrow exceptions: (file, exact normalized sentence), cut out of that file's literals before the check.
    /// The glossary's TEE sentence (card tee-glossary-111) claims memory isolation, which the checks verify; its next
    /// sentence points to the reviews for what the software does. Any other hit, or any edit to the sentence, fails.
    static let allowed: [(file: String, phrase: String)] = [
        ("VerificationRunView.swift", "your messages are processed inside a **sealed region of the chip** (a tee) whose memory the machine's operator can't read from outside."),
    ]

    /// Card key-custody-copy (2026-11-18).
    static let bannedCustody = ["never comes out", "never leaves", "sealed chip holds", "sealed chip can make",
                                "no one else holds the key"]

    static func appSources(file: String = #filePath) -> [URL] {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("teemoon")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Every string literal in Swift source with the line it opens on: `"…"`, `"""…"""`, `#"…"#`, interpolations kept
    /// as their source text (`\(model)`), comments (`//`, nested `/* */`) skipped.
    static func literals(inSource source: String) -> [(line: Int, text: String)] {
        let c = Array(source.unicodeScalars)
        var out: [(Int, String)] = []
        var i = 0, line = 1

        func at(_ k: Int) -> Unicode.Scalar? { k < c.count ? c[k] : nil }
        func starts(_ s: String, _ k: Int) -> Bool {
            for (o, u) in s.unicodeScalars.enumerated() where at(k + o) != u { return false }
            return true
        }
        func skipBlockComment(_ k: inout Int) {
            var depth = 0
            repeat {
                if starts("/*", k) { depth += 1; k += 2 }
                else if starts("*/", k) { depth -= 1; k += 2 }
                else { if c[k] == "\n" { line += 1 }; k += 1 }
            } while depth > 0 && k < c.count
        }
        /// At a string's opening (after any `#`s at `k`), reads it and returns its raw body.
        func readString(_ k: inout Int) -> String {
            var hashes = 0
            while at(k) == "#" { hashes += 1; k += 1 }
            let multi = starts("\"\"\"", k)
            k += multi ? 3 : 1
            let close = (multi ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            var body = String.UnicodeScalarView()
            while k < c.count {
                if starts(close, k) { k += close.unicodeScalars.count; break }
                if starts(escape + "(", k) {
                    // Interpolation: keep its source, skip nested strings and parens.
                    let n = escape.unicodeScalars.count + 1
                    body.append(contentsOf: c[k..<(k + n)]); k += n
                    var depth = 1
                    while k < c.count, depth > 0 {
                        if c[k] == "\"" || (c[k] == "#" && (at(k + 1) == "\"" || at(k + 1) == "#")) {
                            let s = k
                            _ = readString(&k)
                            body.append(contentsOf: c[s..<k]); continue
                        }
                        if c[k] == "(" { depth += 1 } else if c[k] == ")" { depth -= 1 }
                        if c[k] == "\n" { line += 1 }
                        body.append(c[k]); k += 1
                    }
                    continue
                }
                if starts(escape, k) {
                    let n = escape.unicodeScalars.count
                    body.append(contentsOf: c[k..<min(c.count, k + n + 1)]); k += n + 1
                    continue
                }
                if c[k] == "\n" { line += 1 }
                body.append(c[k]); k += 1
            }
            return String(body)
        }

        while i < c.count {
            if starts("//", i) {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if starts("/*", i) {
                skipBlockComment(&i)
            } else if c[i] == "\"" || (c[i] == "#" && starts("#\"", i) || starts("##\"", i)) {
                let opens = line
                out.append((opens, readString(&i)))
            } else {
                if c[i] == "\n" { line += 1 }
                i += 1
            }
        }
        return out
    }

    /// A literal as a reader sees it: `\u{2019}` decoded, curly apostrophes straight, line breaks and indentation one
    /// space, lowercased.
    static func normalized(_ literal: String) -> String {
        var s = literal
        while let r = s.range(of: #"\\u\{([0-9a-fA-F]+)\}"#, options: .regularExpression) {
            let hex = s[r].dropFirst(3).dropLast()
            let ch = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            s.replaceSubrange(r, with: ch)
        }
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.lowercased()
    }

    static func hits(in files: [URL]) throws -> [String] {
        var hits: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (line, literal) in literals(inSource: text) {
                let l = allowed.filter { $0.file == url.lastPathComponent }
                    .reduce(normalized(literal)) { $0.replacingOccurrences(of: $1.phrase, with: "") }
                let onlyHolds = l.contains("only ") && l.contains("holds the key")
                let onlySealedChip = l.contains("only \\(") && l.contains("sealed chip")
                if onlyHolds || onlySealedChip || (banned + bannedCustody).contains(where: { l.contains($0) }) {
                    hits.append("\(url.lastPathComponent):\(line): \(literal.prefix(110))")
                }
            }
        }
        return hits.sorted()
    }

    @Test func noShippingStringOverClaimsKeyCustody() throws {
        let files = Self.appSources()
        guard !files.isEmpty else { return }   // on a device: no source to read
        let hits = try Self.hits(in: files)
        #expect(hits.isEmpty, "\(hits.count) over-claims:\n\(hits.joined(separator: "\n"))")
    }

    @Test func theLexerReadsEveryLiteralShapeAndNoComment() {
        let src = #"""
        // "so only a comment" is not a literal
        /* "no one else" in a block /* nested "nobody else" */ still comment */
        let a = "x — only it can read this"
        let b = "only you and \(model.name("q")) can read"
        let c = """
            sealed so
              only the model
            """
        let d = #"the gateway can't decrypt "quoted""#
        let e = "it can\u{2019}t decrypt"
        let url = "https://example.com" // "generated inside" trailing comment
        """#
        let found = Self.literals(inSource: src).map { (line: $0.line, text: Self.normalized($0.text)) }
        let flagged = found.filter { l in Self.banned.contains { l.text.contains($0) } }.map(\.line)
        #expect(flagged == [3, 4, 5, 9, 10], "\(found)")
        #expect(found.contains { $0.text == "https://example.com" })
    }
}
