//
//  ImportFileScanner.swift
//  teemoon
//
//  Finds each top-level element of an export's JSON array as a byte range, so a
//  large file is decoded one chat at a time. The rules (docs/IMPORT_NEAR.md §4) are
//  shared with Android and pinned by conformance/import/near/cases.json: keep them
//  in step with conformance/import/tools/reference_import.py `scan`.
//

import Foundation

struct ImportFileScanner {

    static let maxElementBytes = 64 * 1024 * 1024
    static let maxDepth = 64

    enum Element: Equatable {
        /// One whole element that parses: its bytes and nesting depth (an object or array is 1).
        case element(Data, depth: Int)
        /// Over 64 MiB of JSON text or deeper than 64: skipped unparsed, and the read goes on.
        case overCap
        /// Cut off, not JSON, not UTF-8, or a bad separator. Nothing after it is read.
        case broken
    }

    /// The file is not a JSON array whose first element within the caps is whole.
    struct Rejected: Error {}

    private let bytes: [UInt8]
    private var i = 0
    private var started = false
    private var first = true
    private var done = false
    private var brokenNext = false

    init(data: Data) {
        var b = [UInt8](data)
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { b.removeFirst(3) }
        bytes = b
    }

    /// The next element, nil at the end. Throws `Rejected` only before the first element is returned.
    mutating func next() throws -> Element? {
        if done { return nil }
        if brokenNext { done = true; return .broken }
        let n = bytes.count
        if !started {
            started = true
            skipSpace()
            guard i < n, bytes[i] == UInt8(ascii: "[") else { throw Rejected() }
            i += 1
            skipSpace()
            if i < n, bytes[i] == UInt8(ascii: "]") { done = true; return nil }
        }
        skipSpace()
        if i >= n {                                          // cut off between elements
            done = true
            if first { throw Rejected() }
            return nil
        }
        let start = i
        if let (end, depth) = elementEnd(from: start), end - start > Self.maxElementBytes || depth > Self.maxDepth {
            i = end
            skipSpace()
            if i < n, bytes[i] == UInt8(ascii: ",") { i += 1 }
            else if i < n, bytes[i] == UInt8(ascii: "]") { done = true }
            else if i >= n { done = true; if first { throw Rejected() } }
            else { brokenNext = true }
            return .overCap
        }
        guard let (end, depth) = elementEnd(from: start), Self.parses(bytes[start..<end]) else {
            done = true
            if first { throw Rejected() }
            return .broken
        }
        first = false
        i = end
        skipSpace()
        if i < n, bytes[i] == UInt8(ascii: ",") { i += 1 }
        else if i >= n || bytes[i] == UInt8(ascii: "]") { done = true }   // bytes after ']' are ignored
        else { brokenNext = true }
        return .element(Data(bytes[start..<end]), depth: depth)
    }

    /// Every element. Throws `Rejected` as `next()` does.
    static func elements(of data: Data) throws -> [Element] {
        var scanner = ImportFileScanner(data: data)
        var out: [Element] = []
        while let e = try scanner.next() { out.append(e) }
        return out
    }

    private mutating func skipSpace() {
        while i < bytes.count, Self.isSpace(bytes[i]) { i += 1 }
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

    private func elementEnd(from start: Int) -> (Int, Int)? {
        let n = bytes.count
        var i = start
        let c = bytes[i]
        if c == 0x5B || c == 0x7B {
            var depth = 0, maxDepth = 0, inString = false, escaped = false
            while i < n {
                let c = bytes[i]
                if inString {
                    if escaped { escaped = false }
                    else if c == 0x5C { escaped = true }
                    else if c == 0x22 { inString = false }
                } else if c == 0x22 { inString = true }
                else if c == 0x5B || c == 0x7B { depth += 1; maxDepth = max(maxDepth, depth) }
                else if c == 0x5D || c == 0x7D {
                    depth -= 1
                    if depth == 0 { return (i + 1, maxDepth) }
                }
                i += 1
            }
            return nil
        }
        if c == 0x22 {
            i += 1
            var escaped = false
            while i < n {
                if escaped { escaped = false }
                else if bytes[i] == 0x5C { escaped = true }
                else if bytes[i] == 0x22 { return (i + 1, 0) }
                i += 1
            }
            return nil
        }
        while i < n, bytes[i] != 0x2C, bytes[i] != 0x5D, !Self.isSpace(bytes[i]) { i += 1 }
        return i < n ? (i, 0) : nil
    }

    private static func parses(_ slice: ArraySlice<UInt8>) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(slice), options: .fragmentsAllowed)) != nil
    }
}
