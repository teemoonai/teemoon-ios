//
//  HomeCapabilityRefreshTests.swift
//  teemoonTests
//
//  A model on the user's own Ollama machine that reads images never got the "· images" marker on iOS
//  (Android showed it): the where sheet's probe saved model ids only, and the catalogue store keys cloud
//  servers only. The sheet now reads the machine's capabilities after its probe, at most once an hour.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Home models keep what they can do")
@MainActor
struct HomeCapabilityRefreshTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func box(_ models: [String]) -> Provider {
        var p = Provider(name: "box", endpoint: "http://box.local:11434/v1/chat/completions", model: models[0])
        p.equippedModels = models
        return p
    }

    private func row(_ id: String, _ caps: ModelCapabilities) -> KnownModel {
        KnownModel(id: id, displayName: id, vendor: "", price: "", capabilities: caps)
    }

    @Test func anOllamaModelThatReadsImagesIsMarked() async throws {
        let store = ProviderStore(inMemory: true)
        let home = box(["llama3", "llava"])
        store.addProvider(home)
        defer { store.removeProvider(home) }
        #expect(!ImageModelChoice.reads(home, modelID: "llava", capabilities: store.capabilities(ofModel: "llava", on: home.id)),
                "before: nothing known about the machine's models")

        let refresh = HomeCapabilityRefresh(list: { _ in [self.row("llama3", [.completion]), self.row("llava", [.completion, .vision])] })
        await refresh.refresh(store.providers, kind: { _ in .ollama },
                              adopt: { store.adoptCapabilities(from: $0, forServer: $1) })

        #expect(store.capabilities(ofModel: "llava", on: home.id)?.contains(.vision) == true)
        let current = try #require(store.providers.first { $0.id == home.id })
        // Marked "reads images" in the where sheet, so the filter offers it (§4e).
        #expect(ImageModelChoice.reads(current, modelID: "llava", capabilities: store.capabilities(ofModel: "llava", on: home.id)))
        #expect(!ImageModelChoice.reads(current, modelID: "llama3", capabilities: store.capabilities(ofModel: "llama3", on: home.id)))
    }

    @Test func theMachineIsAskedAtMostOnceAnHour() async {
        let clock = Clock()
        var calls = 0
        let refresh = HomeCapabilityRefresh(list: { _ in calls += 1; return [self.row("llava", [.vision])] },
                                            now: { clock.now })
        let home = box(["llava"])
        for _ in 0..<3 { await refresh.refresh([home], kind: { _ in .ollama }, adopt: { _, _ in }) }
        #expect(calls == 1)
        clock.now += HomeCapabilityRefresh.maxAge
        await refresh.refresh([home], kind: { _ in .ollama }, adopt: { _, _ in })
        #expect(calls == 2)
    }

    @Test func onlyTheUsersOwnOllamaMachinesAreAsked() async {
        var asked: [URL] = []
        let refresh = HomeCapabilityRefresh(list: { asked.append($0); return nil })
        await refresh.refresh([box(["m"]), Provider.fireworks], kind: { _ in .lmStudio }, adopt: { _, _ in })
        #expect(asked.isEmpty, "LM Studio reports no capabilities over this path")
        await refresh.refresh([Provider.fireworks], kind: { _ in .ollama }, adopt: { _, _ in })
        #expect(asked.isEmpty, "a cloud server is never asked here")
    }

    // MARK: Before a refusal (the maintainer 2026-11-12: a fresh home setup refused a photo to gemma4:e4b)

    /// A home Ollama model whose image ability is unknown, or not read this hour, is asked once before a photo is
    /// refused; the answer decides. One /api/show to the user's own machine.
    @Test func aHomePhotoIsRecheckedBeforeItIsRefused() async throws {
        let store = ProviderStore(inMemory: true)
        let home = box(["gemma4:e4b"])
        store.addProvider(home)
        defer { store.removeProvider(home) }
        var shown: [String] = []
        let refresh = HomeCapabilityRefresh(list: { _ in nil })
        let sees = await refresh.recheckBeforeRefusing(home, kind: .ollama,
                                                       show: { model, _ in shown.append(model); return [.completion, .vision] },
                                                       adopt: { store.adoptCapabilities(from: $0, forServer: $1) })
        #expect(sees)
        #expect(shown == ["gemma4:e4b"])
        let current = try #require(store.providers.first { $0.id == home.id })
        #expect(current.modelSeesImages, "the answer is kept, so the next photo goes straight through")
    }

    /// A home server whose kind was never recorded (the probe never ran, as on a fresh setup) is asked too: an
    /// Ollama answers, anything else fails the call and the refusal stands (live run 2026-11-12 refused here).
    @Test func aHomeServerOfUnknownKindIsAskedToo() async {
        let refresh = HomeCapabilityRefresh(list: { _ in nil })
        var shown = 0
        let sees = await refresh.recheckBeforeRefusing(box(["gemma4:e4b"]), kind: nil,
                                                       show: { _, _ in shown += 1; return [.vision] }, adopt: { _, _ in })
        #expect(sees && shown == 1)
    }

    @Test func aRecheckThatCantReachTheMachineKeepsTheRefusal() async {
        let refresh = HomeCapabilityRefresh(list: { _ in nil })
        let sees = await refresh.recheckBeforeRefusing(box(["gemma4:e4b"]), kind: .ollama,
                                                       show: { _, _ in nil }, adopt: { _, _ in })
        #expect(!sees)
    }

    @Test func onlyAnUnreadHomeOllamaModelIsRechecked() async {
        let clock = Clock()
        var calls = 0
        let refresh = HomeCapabilityRefresh(list: { _ in [self.row("gemma4:e4b", [.completion])] }, now: { clock.now })
        let show: (String, URL) async -> ModelCapabilities? = { _, _ in calls += 1; return [.completion] }
        _ = await refresh.recheckBeforeRefusing(Provider.fireworks, kind: .ollama, show: show, adopt: { _, _ in })
        _ = await refresh.recheckBeforeRefusing(box(["m"]), kind: .lmStudio, show: show, adopt: { _, _ in })
        #expect(calls == 0, "a cloud server or a non-Ollama machine is never asked")
        let home = box(["gemma4:e4b"])
        await refresh.refresh([home], kind: { _ in .ollama }, adopt: { _, _ in })
        _ = await refresh.recheckBeforeRefusing(home, kind: .ollama, show: show, adopt: { _, _ in })
        #expect(calls == 0, "read this hour: its answer stands")
        clock.now += HomeCapabilityRefresh.maxAge
        _ = await refresh.recheckBeforeRefusing(home, kind: .ollama, show: show, adopt: { _, _ in })
        #expect(calls == 1, "stale: asked again")
    }
}
