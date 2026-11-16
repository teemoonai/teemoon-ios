//
//  EquippedCapabilityRefreshTests.swift
//  teemoonTests
//
//  The maintainer 2026-10-28: "Fireworks 5.3 flash says can't use images" after an upgrade. An equipped model's
//  capabilities were copied when it was equipped and never read again, so a model the vendor later lists
//  with image input stayed "can't see images" for good. A fresh /models answer now rewrites them.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Equipped capabilities follow the live list")
@MainActor
struct EquippedCapabilityRefreshTests {
    static let flash = "accounts/fireworks/models/glm-5p3-flash"

    static func row(_ id: String, _ caps: ModelCapabilities?) -> KnownModel {
        KnownModel(id: id, displayName: id, vendor: "z.ai", price: "", capabilities: caps)
    }

    /// The 1.0.6-era state: GLM 5.3 Flash equipped and active, saved as tools-only.
    static func storeWithStaleFlash() -> (ProviderStore, Provider) {
        let store = ProviderStore(inMemory: true)
        var fireworks = Provider.fireworks
        fireworks.model = flash
        fireworks.modelCapabilities = [.tools]
        store.addProvider(fireworks)
        store.activate(modelID: flash, on: fireworks)
        return (store, fireworks)
    }

    @Test("a fresh list that says the active model takes images makes it see images")
    func freshListAddsVision() throws {
        let (store, fireworks) = Self.storeWithStaleFlash()
        defer { store.removeProvider(fireworks) }
        #expect(store.activeProvider?.modelSeesImages == false)

        store.adoptCapabilities(from: [Self.row(Self.flash, [.tools, .vision])], forServer: fireworks.id)

        let active = try #require(store.activeProvider)
        #expect(active.modelSeesImages)
        #expect(store.capabilities(ofModel: Self.flash, on: fireworks.id) == [.tools, .vision])
    }

    @Test("a row the list does not describe keeps what it knew")
    func unknownCapabilitiesKeepTheSavedOnes() {
        let (store, fireworks) = Self.storeWithStaleFlash()
        defer { store.removeProvider(fireworks) }

        store.adoptCapabilities(from: [Self.row(Self.flash, nil), Self.row("other", [.vision])], forServer: fireworks.id)

        #expect(store.capabilities(ofModel: Self.flash, on: fireworks.id) == [.tools])
    }

    @Test("recording a list in the catalogue store reaches the provider store")
    func catalogueRecordIsAdopted() throws {
        let (store, fireworks) = Self.storeWithStaleFlash()
        defer { store.removeProvider(fireworks) }
        let dir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let catalogue = LiveCatalogStore(directory: dir)
        catalogue.onRecorded = { provider, models in store.adoptCapabilities(from: models, forServer: provider.id) }

        catalogue.record([Self.row(Self.flash, [.tools, .vision])], for: fireworks, apiKey: "fw-key")

        #expect(try #require(store.activeProvider).modelSeesImages)
    }

    @Test("at launch, a list saved before the rows were healed is adopted")
    func savedListIsAdoptedAtLaunch() throws {
        let (store, fireworks) = Self.storeWithStaleFlash()
        defer { store.removeProvider(fireworks) }
        try store.setCredential("fw-key", forProviderID: fireworks.id)
        let catalogue = LiveCatalogStore(directory: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString))
        catalogue.record([Self.row(Self.flash, [.tools, .vision])], for: fireworks, apiKey: "fw-key")
        #expect(store.activeProvider?.modelSeesImages == false)

        store.followCapabilities(of: catalogue)

        #expect(try #require(store.activeProvider).modelSeesImages)
    }
}
