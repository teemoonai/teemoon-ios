//
//  ProviderCatalogValidationTests.swift
//  teemoonTests
//
//  teemoon ships no model catalogue: a provider's models are whatever its
//  `/models` answers with. What it still ships is the data no API serves —
//  Fireworks' prices and near.ai's attested-3p id set — plus the invariant
//  those lists exist to protect: an own-fleet near.ai model has a confidential
//  host, and nothing else does. Both captured lists are real responses, so the
//  gate holds offline and deterministically.
//

import Foundation
import Testing
@testable import teemoon

@Suite("ProviderCatalogValidation")
struct ProviderCatalogValidationTests {

    private func liveModels(file: String = #filePath) throws -> [NearAIModelCatalog.ModelsResponse.Model] {
        let data = try TestFixture.data("nearai_models.json", file: file)
        return try JSONDecoder().decode(NearAIModelCatalog.ModelsResponse.self, from: data).data
    }

    private func directory(file: String = #filePath) throws -> [String: String] {
        let data = try TestFixture.data("nearai_endpoints_directory.json", file: file)
        return try #require(EndpointDirectory.parseDirectory(data))
    }

    /// THE gate, now against the two live lists rather than a compiled copy:
    /// every model near.ai runs itself publishes a direct host. Without one the
    /// model-enclave manifest never loads and E2EE stalls, which is why a
    /// missing host degrades the session instead of reading as "ordinary".
    @Test func everyOwnFleetModelHasAConfidentialHost() throws {
        let hosts = try directory()
        for model in try liveModels()
        where model.owned_by == "nearai" && !NearAIModelCatalog.isNonChat(model.id) {
            #expect(hosts[model.id.lowercased()] != nil,
                    "\(model.id) is own-fleet but near.ai publishes no direct host for it")
        }
    }

    /// And nothing else claims one: a host on a proxied or third-party model
    /// would put a model teemoon cannot seal into every "encrypted" surface.
    @Test func noOtherTierHasAConfidentialHost() throws {
        let hosts = try directory()
        for model in try liveModels() where model.owned_by != "nearai" {
            #expect(hosts[model.id.lowercased()] == nil,
                    "\(model.id) is \(model.owned_by ?? "untiered") yet has a direct host")
        }
    }

    /// The offline discriminator must agree with what near.ai says: every id in
    /// the shipped attested-3p set that is still served is labelled that way.
    /// Stale ids stay in the set on purpose — a user can still have one equipped.
    @Test func theAttestedThirdPartySetMatchesTheLiveTiers() throws {
        let live = Dictionary(try liveModels().map { ($0.id.lowercased(), $0.owned_by) },
                              uniquingKeysWith: { first, _ in first })
        for id in KnownModel.nearAIAttestedThirdPartyIDs {
            #expect(NearAIModelCatalog.classify(id) == .teeThirdParty)
            if let owner = live[id.lowercased()] {
                #expect(owner == "attested 3p",
                        "\(id) is in the attested-3p set but near.ai now calls it \(owner ?? "nothing")")
            }
        }
    }

    /// Every published host is an https near.ai `/v1` base. The directory picks
    /// where sealed prompts go, so a row that is anything else is dropped.
    @Test func directHostsAreWellFormed() throws {
        for (id, raw) in try directory() {
            let url = URL(string: raw)
            #expect(url?.scheme == "https", "\(id): \(raw) is not https")
            #expect(raw.hasSuffix("/v1"), "\(id): \(raw) does not end in /v1")
            #expect(Provider.isNearAIHost(url?.host), "\(id): \(raw) is not a near.ai host")
        }
    }

    /// Fireworks prices are the one table that stays: no Fireworks API serves a
    /// price (verified 2026-07-26), so a stale entry is the only way a row can
    /// lie about cost.
    @Test func fireworksPricesAreWellFormed() {
        #expect(!KnownModel.fireworksPrices.isEmpty)
        for (id, price) in KnownModel.fireworksPrices {
            #expect(id.hasPrefix("accounts/"), "\(id) is not a Fireworks resource id")
            // "$in/$out" per 1M — the shape the row renders and the sort parses.
            #expect(price.split(separator: "/").count == 2 && price.hasPrefix("$"),
                    "\(id) has a malformed price: \(price)")
        }
    }
}
