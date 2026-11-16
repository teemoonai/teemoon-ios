//
//  WhereFilterCarryTests.swift
//  teemoonTests
//
//  docs/IMAGES.md §4e (the maintainer 2026-11-11): every way from the where sheet into a provider's models carries the
//  sheet's filters. He saw them drop at the provider form; Android found the browser drops one its list wouldn't
//  offer (every row reads images, or none is encrypted).
//

import Foundation
import Testing
@testable import teemoon

@Suite("Where — filters carried into a provider's models")
struct WhereFilterCarryTests {

    private func model(_ id: String, _ caps: ModelCapabilities?) -> KnownModel {
        KnownModel(id: id, displayName: id, vendor: "v", price: "", contextWindow: "", capabilities: caps)
    }

    @Test func aCarriedFilterStaysOnWhenTheListWouldNotOfferIt() {
        let allSee = [model("a", [.vision]), model("b", [.vision])]
        let images = ModelBrowserListing(models: allSee, query: ModelBrowserQuery(filters: [.vision]),
                                         tiered: false, carried: [.vision])
        #expect(images.filters.contains(.vision), "the menu still offers it, so it can be cleared")
        #expect(images.activeSummary == "images")
        #expect(images.countLabel == "2 models")

        let encrypted = ModelBrowserListing(models: allSee, query: ModelBrowserQuery(filters: [.encrypted]),
                                            tiered: false, carried: [.encrypted])
        #expect(encrypted.shown == 0, "nothing on a plain list is end-to-end encrypted")
        #expect(encrypted.activeSummary == "e2ee")

        // Not carried: the browser's own rule, as today.
        let own = ModelBrowserListing(models: allSee, query: ModelBrowserQuery(filters: [.encrypted]), tiered: false)
        #expect(own.shown == 2)
        #expect(own.activeSummary == nil)
    }

    @MainActor @Test func theProviderFormsRowsFollowTheCarriedFilter() {
        let form = AddEditProviderModel(mode: .add)
        form.fetchedModels = [model("t", [.tools]), model("v1", [.vision]), model("x", nil), model("v2", [.vision, .tools])]
        #expect(form.recommendedModels.map(\.id) == ["t", "v1", "x"])
        form.browseFilters = [.vision]
        #expect(form.recommendedModels.map(\.id) == ["v1", "v2"])
    }

    @Test func ollamaLinksCarryReadsImagesWhereTheSiteCanFilter() {
        #expect(OllamaBrowseLinks.ollama([]) == "https://ollama.com/search")
        #expect(OllamaBrowseLinks.ollama([.vision]) == "https://ollama.com/search?c=vision")
        #expect(OllamaBrowseLinks.huggingFace([]) == "https://huggingface.co/models?library=gguf&sort=trending")
        #expect(OllamaBrowseLinks.huggingFace([.vision])
                == "https://huggingface.co/models?library=gguf&pipeline_tag=image-text-to-text&sort=trending")
    }
}
