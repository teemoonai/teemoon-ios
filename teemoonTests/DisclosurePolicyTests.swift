//
//  DisclosurePolicyTests.swift
//  teemoonTests
//
//  What a request says about the person, per destination tier (docs/DISCLOSURE.md), run from
//  conformance/disclosure.json, which Android runs too. the maintainer 2026-11-12: the time stops leaking zone and language.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Disclosure policy")
struct DisclosurePolicyTests {

    struct Fixture: Decodable {
        struct Decide: Decodable { let place: String, sealed: Bool, tier: String }
        struct Cell: Decodable { let zone: String, tier: String, dateLine: String, toolDay: String, sentAt: String }
        let decide: [Decide]
        let instant: String
        let cells: [Cell]
    }

    static func fixture(file: String = #filePath) throws -> Fixture? {
        guard TestFixture.sourceTreeAvailable() else { return nil }
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/disclosure.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func everyDestinationGetsItsTier() throws {
        guard let f = try Self.fixture() else { return }
        for d in f.decide {
            let place = try #require(WhereLocality(rawValue: d.place))
            #expect(DisclosurePolicy.destinationTier(place: place, sealed: d.sealed).rawValue == d.tier, "\(d.place) sealed \(d.sealed)")
        }
    }

    @Test func everyCellRendersAsTheFixtureSays() throws {
        guard let f = try Self.fixture() else { return }
        let instant = try #require(ISO8601DateFormatter().date(from: f.instant))
        for c in f.cells {
            let policy = DisclosurePolicy(tier: try #require(DisclosurePolicy.Tier(rawValue: c.tier)),
                                          zone: try #require(TimeZone(identifier: c.zone)))
            #expect(policy.dateLine(instant) == c.dateLine, "\(c.tier) \(c.zone)")
            #expect(policy.toolDay(instant) == c.toolDay, "\(c.tier) \(c.zone)")
            #expect(policy.sentAt(instant) == c.sentAt, "\(c.tier) \(c.zone)")
        }
    }

    /// The transcript asks the policy: a chat moved to a cloud sends UTC for every earlier turn too.
    @Test func historyTurnsRenderByTheCurrentRequestsTier() throws {
        let context = try ImageSendTests.store()
        let messages = try ImageSendTests.thread(context, turns: 2, imagesPerTurn: 0)
        let policy = DisclosurePolicy(tier: .minimised, zone: TimeZone(identifier: "America/Toronto")!)
        let t = ChatGeneration.buildTranscript(from: messages, systemPrompt: "s", maxMessages: nil, timeNotes: true,
                                               disclosure: policy)
        let users = t.messages.filter { $0.role == "user" }
        #expect(!users.isEmpty)
        #expect(users.allSatisfy { $0.content.hasSuffix(" UTC]") }, "\(users.map(\.content))")
    }
}
