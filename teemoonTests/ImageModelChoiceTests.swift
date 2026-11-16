//
//  ImageModelChoiceTests.swift
//  teemoonTests
//
//  images-model-marker (the maintainer, review page 2026-11-01): which model the paperclip offers, and its words.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Images — the model that reads them")
@MainActor struct ImageModelChoiceTests {
    private let fast = "accounts/fireworks/models/glm-5p3"
    private let flash = "accounts/fireworks/models/glm-5p3-flash"

    private func fireworks(active: String, equipped: [String]) -> Provider {
        var p = Provider.fireworks
        p.model = active
        p.equippedModels = equipped
        return p
    }

    @Test func aPhoneModelReadsImagesOnlyWhenTheyWorkOnThePhone() {
        let phone = Provider.local(LocalModelCatalog.all[0])
        #expect(ImageModelChoice.reads(phone, modelID: phone.model, capabilities: [.vision]) == LocalModelCatalog.imagesOnDevice)
        #expect(ImageModelChoice.reads(Provider.fireworks, modelID: flash, capabilities: [.vision]))
        #expect(!ImageModelChoice.reads(Provider.fireworks, modelID: fast, capabilities: nil), "unknown is not 'reads'")
    }

    @Test func theMarkerWordsAreTheApprovedOnes() {
        #expect(ImageModelChoice.marker == "reads images")
        #expect(ImageModelChoice.markerGlyph == "eye", "the browser marks image-capable models with an eye")
        #expect(ModelBrowserQuery.Filter.vision.label == ImageModelChoice.marker)
        #expect(WhereProviderPresentation.metadataRun(WhereProviderPresentation.metadataRun("on this device", "warm"),
                                                      ImageModelChoice.captionTag) == "on this device · warm · images")
        #expect(WhereProviderPresentation.metadataRun("fireworks", ImageModelChoice.captionTag) == "fireworks · images")
    }

    @Test func seeingImagesFollowsAModelSwitchFromTheLiveList() throws {
        let store = ProviderStore(inMemory: true)
        var server = fireworks(active: fast, equipped: [fast, flash])
        server.modelCapabilities = nil
        store.addProvider(server)
        defer { store.removeProvider(server) }
        store.adoptCapabilities(from: [KnownModel(id: flash, displayName: flash, vendor: "z.ai", price: "", capabilities: [.tools, .vision]),
                                       KnownModel(id: fast, displayName: fast, vendor: "z.ai", price: "", capabilities: [.tools])],
                                forServer: server.id)

        store.activate(modelID: fast, on: try #require(store.providers.first { $0.id == server.id }))
        #expect(store.activeProvider?.modelSeesImages == false)
        store.activate(modelID: flash, on: try #require(store.providers.first { $0.id == server.id }))
        #expect(store.activeProvider?.modelSeesImages == true)
        store.activate(modelID: fast, on: try #require(store.providers.first { $0.id == server.id }))
        #expect(store.activeProvider?.modelSeesImages == false)
    }
}
