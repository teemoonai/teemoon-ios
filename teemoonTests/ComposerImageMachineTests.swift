//
//  ComposerImageMachineTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4d (the maintainer 2026-11-11): every state × event cell of conformance/composerimages.json, which Android
//  runs too, and the two invariants over the whole table.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Composer images — the machine")
struct ComposerImageMachineTests {

    struct Fixture: Decodable {
        let cells: [String: Cell]
        struct Cell: Decodable { let to: String; let effects: [String] }
    }

    static func fixture(file: String = #filePath) throws -> Fixture? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/composerimages.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func everyCellMatchesTheFixture() throws {
        guard let fixture = try Self.fixture() else { return }
        #expect(fixture.cells.count == ComposerImageMachine.State.allCases.count * ComposerImageMachine.Event.allCases.count,
                "the fixture and the machine name different cells")
        for (key, want) in fixture.cells {
            let parts = key.components(separatedBy: " + ")
            let state = try #require(ComposerImageMachine.State(rawValue: parts[0]), "\(key)")
            let event = try #require(ComposerImageMachine.Event(rawValue: parts[1]), "\(key)")
            let (to, effects) = ComposerImageMachine.next(state, event)
            #expect(to.rawValue == want.to, "\(key): to")
            #expect(effects.map(\.rawValue) == want.effects, "\(key): effects")
        }
    }

    @Test func imagesLeaveOnlyByRemoveOrASendAndGoOnlyToAModelThatSees() {
        for event in ComposerImageMachine.Event.allCases {
            let (to, effects) = ComposerImageMachine.next(.attached, event)
            if to == .empty {
                #expect([.removeLast, .sendSees, .sendWithoutImages].contains(event), "\(event) dropped the images")
            }
            if effects.contains(.sendImages) { #expect(event == .sendSees, "\(event) sent images") }
            #expect(ComposerImageMachine.next(.attached, .modelSwitched).0 == .attached)
        }
    }
}
