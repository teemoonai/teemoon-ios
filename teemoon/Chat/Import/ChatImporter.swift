//
//  ChatImporter.swift
//  teemoon
//
//  Scan → detect → parse → write (docs/IMPORT_NEAR.md §0). A file whose elements are
//  chats is written one chat at a time as it is scanned, so memory follows the largest
//  chat, not the file. No network: nothing here opens a connection or resolves a URL.
//

import Foundation
import SwiftData

enum ChatImporter {

    static let sources: [any ChatImportSource] = [NearImportSource()]

    /// The file is not an export any source reads.
    struct WrongFile: Error {}

    /// Imports `data` into `context`. `progress` gets the number of chats read so far.
    static func run(_ data: Data, into context: ModelContext,
                    sources: [any ChatImportSource] = sources,
                    dryRun: Bool = false,
                    afterSave: ((Int) throws -> Void)? = nil,
                    progress: (Int) -> Void = { _ in }) throws -> ImportSummary {
        var scanner = ImportFileScanner(data: data)
        // Detect by the first element within the caps; over-cap elements before it are held.
        var leadingOverCaps = 0
        var first: (data: Data, depth: Int)?
        do {
            while first == nil, let e = try scanner.next() {
                switch e {
                case .overCap: leadingOverCaps += 1
                case .element(let bytes, let depth): first = (bytes, depth)
                case .broken: throw WrongFile()
                }
            }
        } catch { throw WrongFile() }
        guard let first else {
            if leadingOverCaps > 0 { throw WrongFile() }               // nothing to detect by
            return ImportSummary()                                       // `[]`
        }
        guard let firstValue = try? JSONSerialization.jsonObject(with: first.data, options: .fragmentsAllowed),
              let (source, kind) = sources.lazy.compactMap({ s in s.detect(first: firstValue).map { (s, $0) } }).first
        else { throw WrongFile() }

        var writer = ChatImportWriter(source: source.name, context: context)
        writer.afterSave = afterSave
        writer.dryRun = dryRun
        var read = 0
        switch kind {
        case .chatPerElement:
            writer.countSkipped(leadingOverCaps)
            var next: ImportFileScanner.Element? = .element(first.data, depth: first.depth)
            read = leadingOverCaps
            while let element = next {
                switch element {
                case .broken, .overCap:
                    writer.countSkipped(1)
                case .element(let bytes, let depth):
                    if let chat = source.chat(element: bytes, depth: depth) { try writer.write(chat) }
                    else { writer.countSkipped(1) }
                }
                read += 1
                progress(read)
                next = try scanner.next()
            }
        case .singleChat:
            var items: [(data: Data, depth: Int)] = [first]
            var cutOff = false
            var overCap = leadingOverCaps > 0
            while let element = try scanner.next() {
                switch element {
                case .broken: cutOff = true
                case .overCap: overCap = true
                case .element(let bytes, let depth): items.append((bytes, depth))
                }
            }
            if !overCap, let chat = source.chat(items: items, cutOff: cutOff, fileBytes: data.count) { try writer.write(chat) }
            else { writer.countSkipped(1) }
            read = 1
            progress(1)
        }
        var summary = writer.summary
        summary.elementsRead = read
        return summary
    }
}
