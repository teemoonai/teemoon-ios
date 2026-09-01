import Foundation
import Testing
@testable import teemoon

@Suite("WhereGetPolicy")
struct WhereGetPolicyTests {

    private func grok(id: UUID = UUID(), endpoint: String = "https://api.x.ai/v1/chat/completions") -> Provider {
        var p = Provider.grok
        p.id = id
        p.endpoint = endpoint
        return p
    }

    private func ollama(id: UUID = UUID()) -> Provider {
        Provider(
            id: id,
            name: "box",
            endpoint: "http://100.64.0.1:11434/v1",
            model: "llama",
            requiresAPIKey: false
        )
    }

    private func policy(
        filter: WhereLocality? = nil,
        providers: [Provider],
        network: Bool = true,
        kinds: [UUID: LocalServerKind] = [:],
        byID: [UUID: String] = [:],
        byEndpoint: [String: String] = [:]
    ) -> WhereGetPolicy {
        WhereGetPolicy(
            filter: filter,
            providers: providers,
            networkSatisfied: network,
            home: kinds.mapValues { WhereGetPolicy.HomeInfo(kind: $0) },
            credentialFor: { byID[$0.id] ?? "" },
            credentialForEndpoint: { byEndpoint[$0] ?? "" }
        )
    }

    @Test func hasKeyFindsCredentialUnderADifferentInstanceID() {
        let preset = Provider.grok
        let saved = grok()
        let p = policy(
            providers: [saved],
            byID: [preset.id: "sk-from-onboarding"]
        )
        #expect(!p.hasKey(saved))
        let viaEndpoint = policy(
            providers: [saved],
            byEndpoint: [saved.endpoint: "sk-from-settings"]
        )
        #expect(viaEndpoint.hasKey(saved))
    }

    @Test func keylessSelfHostedHasKeyWithoutAStoreEntry() {
        let box = ollama()
        let p = policy(providers: [box])
        #expect(p.hasKey(box))
    }

    @Test func pullAndDeleteAreOllamaOnly() {
        let ollamaID = UUID()
        let lmID = UUID()
        let ollama = ollama(id: ollamaID)
        let lm = Provider(
            id: lmID,
            name: "studio",
            endpoint: "http://100.64.0.2:1234/v1",
            model: "x",
            requiresAPIKey: false
        )
        let p = policy(
            filter: .home,
            providers: [ollama, lm],
            kinds: [ollamaID: .ollama, lmID: .lmStudio]
        )
        #expect(p.pullableProviders.map(\.id) == [ollamaID])
        #expect(p.canDeleteFromServer(ollama))
        #expect(!p.canDeleteFromServer(lm))
    }

    @Test func recommendedDownloadDoesNotFallThroughToE4B() {
        let e2b = LocalModelCatalog.all[0]
        let e4b = LocalModelCatalog.all[1]
        let installed = Provider.local(e2b)
        let p = policy(filter: nil, providers: [installed])
        #expect(p.recommendedDownload == nil)
        #expect(p.downloadableModels.map(\.id) == [e4b.id])
    }

    @Test func getSectionEmptyOnPhoneWhenEverythingIsDownloaded() {
        let installed = LocalModelCatalog.all.map { Provider.local($0) }
        let p = policy(filter: .phone, providers: installed)
        #expect(p.getSectionIsEmpty)
        #expect(p.downloadableModels.isEmpty)
    }

    @Test func browseRequiresAKey() {
        let g = grok()
        let p = policy(providers: [g])
        #expect(!p.canBrowse(g))
        let keyed = policy(providers: [g], byEndpoint: [g.endpoint: "sk"])
        #expect(keyed.canBrowse(g))
    }

    @Test func braveIsAFixedAnswerServiceAndNotBrowsable() {
        #expect(Provider.braveAnswers.isFixedAnswerService)
        #expect(!Provider.grok.isFixedAnswerService)
        let brave = Provider.braveAnswers
        let keyed = policy(providers: [brave], byEndpoint: [brave.endpoint: "token"])
        #expect(!keyed.canBrowse(brave))
    }

    @Test func addProviderGlyphFollowsFilter() {
        let empty = [Provider]()
        #expect(policy(filter: .home, providers: empty).addProviderGlyph
                == WhereLocality.home.systemImage)
        #expect(policy(filter: .cloud, providers: empty).addProviderGlyph == "key")
        #expect(policy(filter: nil, providers: empty).addProviderGlyph == "plus")
    }

    @Test func openRouterPrefersSearchFirstBrowse() {
        let router = Provider(
            name: "openrouter",
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            model: "x"
        )
        #expect(router.prefersSearchFirstBrowse)
        #expect(!Provider.grok.prefersSearchFirstBrowse)
    }

    @Test func browseNamePrefersServerKindOverNickname() {
        let id = UUID()
        let box = ollama(id: id)
        var named = box
        named.name = "second mac"
        let p = policy(providers: [named], kinds: [id: .ollama])
        #expect(p.browseName(for: named) == "ollama")
        #expect(p.browseCaption(for: named) == "equip another model on this setup")
        let counted = WhereGetPolicy(
            filter: .home,
            providers: [named],
            networkSatisfied: true,
            home: [id: .init(kind: .ollama, modelCount: 3)],
            credentialFor: { _ in "" },
            credentialForEndpoint: { _ in "" }
        )
        #expect(counted.browseCaption(for: named) == "3 models on this server")
    }

    @Test func addProviderCaptionDependsOnFilter() {
        let empty = [Provider]()
        #expect(policy(filter: .cloud, providers: empty).addProviderCaption
                == "configures an api key for any provider")
        #expect(policy(filter: nil, providers: empty).addProviderCaption == nil)
    }

    @Test func customEndpointIsNotAPreset() {
        let custom = Provider(
            name: "mine",
            endpoint: "https://example.com/v1/chat/completions",
            model: "x"
        )
        let p = policy(providers: [custom])
        #expect(p.isCustom(custom))
        #expect(!p.isCustom(Provider.grok))
    }

    @Test func phoneFooterIsSilentWithoutAMemoryFigure() {
        let p = policy(filter: .phone, providers: [])
        #expect(p.getFooter(openToGet: false, memoryFigure: nil) == "")
        #expect(p.getFooter(openToGet: false, memoryFigure: "4.1 gb")
                .contains("memory, not storage"))
        #expect(p.getFooter(openToGet: true, memoryFigure: nil).contains("start here"))
    }

    @Test func destructionDependsOnPlace() {
        let phone = Provider.local(LocalModelCatalog.all[0])
        let ollamaID = UUID()
        let box = ollama(id: ollamaID)
        var boxTwo = box
        boxTwo.equippedModels = ["a", "b"]
        let lm = Provider(
            id: UUID(),
            name: "studio",
            endpoint: "http://100.64.0.2:1234/v1",
            model: "x",
            requiresAPIKey: false,
            equippedModels: ["a", "b"]
        )
        let p = policy(
            providers: [phone, boxTwo, lm, Provider.grok],
            kinds: [ollamaID: .ollama, lm.id: .lmStudio]
        )
        #expect(p.destruction(for: phone) == .deleteLocalWeights)
        #expect(p.destruction(for: boxTwo) == .deleteFromServer)
        #expect(p.destruction(for: lm) == .none)
        #expect(p.destruction(for: Provider.grok) == .unequipCloud)
    }

    @Test func exceedsAvailableMemoryIgnoresUnknownBudget() {
        #expect(!LocalMemory.exceedsAvailable(sizeMB: 3000, availableMB: 0))
        #expect(LocalMemory.exceedsAvailable(sizeMB: 3000, availableMB: 2000))
        #expect(!LocalMemory.exceedsAvailable(sizeMB: 1000, availableMB: 2000))
    }

    @Test func recommendedPhoneModelDoesNotHeroADownloadThatWouldFail() {
        let model = LocalModelCatalog.all[0]
        #expect(WhereGetPolicy.recommendedPhoneModel(availableMB: 0) == model)
        #expect(WhereGetPolicy.recommendedPhoneModel(availableMB: model.sizeMB) == nil)
        #expect(WhereGetPolicy.recommendedPhoneModel(
            availableMB: model.sizeMB + LocalMemory.headroomMB) == model)
    }

    @Test func firstRunIsEmptyAllWithAFitAndNothingMoreUrgent() {
        let leader = LocalModelCatalog.all[0]
        let empty = policy(filter: nil, providers: [])
        #expect(empty.showsFirstRun(loadFailed: false, recommended: leader))
        #expect(!empty.showsFirstRun(loadFailed: true, recommended: leader))
        #expect(!empty.showsFirstRun(loadFailed: false, recommended: nil))
        #expect(!policy(filter: .phone, providers: []).showsFirstRun(
            loadFailed: false, recommended: leader))
        #expect(!policy(filter: nil, providers: [], network: false).showsFirstRun(
            loadFailed: false, recommended: leader))
        #expect(!policy(providers: [Provider.grok]).showsFirstRun(
            loadFailed: false, recommended: leader))
    }

    @Test func emptyCopyNamesTheTierNotAllThreePlaces() {
        let all = policy(filter: nil, providers: [])
        #expect(all.emptyTitle == "no setups yet")
        #expect(all.emptyDescription(openToGet: true).contains("get below"))
        #expect(!all.emptyDescription(openToGet: false).contains("get below"))
        #expect(policy(filter: .phone, providers: []).emptyTitle == "nothing downloaded")
        #expect(policy(filter: .home, providers: []).emptyTitle == "no computers connected")
        #expect(policy(filter: .cloud, providers: []).emptyTitle == "no cloud keys")
        #expect(policy(filter: .phone, providers: []).emptyGlyph
                == WhereLocality.phone.systemImage)
    }

    @Test func readyCaptionMarksUnreachableHome() {
        let id = UUID()
        let box = ollama(id: id)
        let unreachable = WhereGetPolicy(
            filter: nil,
            providers: [box],
            networkSatisfied: true,
            home: [id: .init(kind: .unknown, modelCount: nil)],
            credentialFor: { _ in "" },
            credentialForEndpoint: { _ in "" }
        )
        #expect(unreachable.readyCaption(for: box)?.contains("couldn't reach") == true)
    }

    @Test func readyCaptionHidesTheServerNameOnASingleHomeFilter() {
        let id = UUID()
        let box = ollama(id: id)
        let one = policy(filter: .home, providers: [box], kinds: [id: .ollama])
        #expect(one.readyCaption(for: box) == nil)
        let other = ollama(id: UUID())
        let two = policy(
            filter: .home,
            providers: [box, other],
            kinds: [id: .ollama, other.id: .ollama]
        )
        #expect(two.readyCaption(for: box) == "ollama")
    }

    @Test func readyCaptionFlagsCloudWithoutE2EE() {
        NearAIModelCatalog.resetTierCache()
        let grok = Provider.grok
        #expect(policy(providers: [grok]).readyCaption(for: grok)?
            .contains("not end-to-end encrypted") == true)
        let confidential = Provider.nearAI
        #expect(confidential.capabilities.contains(.endToEndEncryption))
        #expect(policy(providers: [confidential]).readyCaption(for: confidential)?
            .contains("end-to-end encrypted") == true)
        #expect(policy(providers: [confidential]).readyCaption(for: confidential)?
            .contains("not end-to-end encrypted") != true)
    }

    @Test func isWarmIsNilWhenUnmeasuredAndFalseWhenCold() {
        let id = UUID()
        let box = ollama(id: id)
        let unmeasured = policy(providers: [box])
        #expect(unmeasured.isWarm(provider: box, modelID: "llama") == nil)
        let unknown = WhereGetPolicy(
            filter: nil,
            providers: [box],
            networkSatisfied: true,
            home: [id: .init(kind: .unknown, warm: ["llama"])],
            credentialFor: { _ in "" },
            credentialForEndpoint: { _ in "" }
        )
        #expect(unknown.isWarm(provider: box, modelID: "llama") == nil)
        let identified = WhereGetPolicy(
            filter: nil,
            providers: [box],
            networkSatisfied: true,
            home: [id: .init(kind: .ollama, warm: ["llama"])],
            credentialFor: { _ in "" },
            credentialForEndpoint: { _ in "" }
        )
        #expect(identified.isWarm(provider: box, modelID: "llama") == true)
        #expect(identified.isWarm(provider: box, modelID: "other") == false)
        #expect(identified.isWarm(provider: Provider.grok, modelID: "x") == nil)
    }

    @Test func warnsUnencryptedNearIsProxiedOnly() {
        NearAIModelCatalog.resetTierCache()
        #expect(!policy(providers: [Provider.nearAI]).warnsUnencryptedNear(Provider.nearAI))
        let proxied = Provider(
            name: "near.ai",
            endpoint: "https://cloud-api.near.ai/v1/chat/completions",
            model: "anthropic/claude-opus-4-6"
        )
        #expect(policy(providers: [proxied]).warnsUnencryptedNear(proxied))
        #expect(!policy(providers: [Provider.grok]).warnsUnencryptedNear(Provider.grok))
    }
}
