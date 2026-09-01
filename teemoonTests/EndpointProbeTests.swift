import Foundation
import Testing
@testable import teemoon

@Suite("EndpointProbe")
struct EndpointProbeTests {

    private let base = URL(string: "https://example.com/v1")!

    private func request(
        apiKey: String = "",
        userInitiated: Bool = false,
        stickyKind: LocalServerKind = .unknown,
        isSelfHosted: Bool = false,
        currentModel: String = "",
        preferred: String? = nil,
        existing: [KnownModel] = [],
        rule: ModelDefaultRule? = nil,
        validation: ProviderKeyValidator.Endpoint? = nil
    ) -> EndpointProbe.Request {
        EndpointProbe.Request(
            baseURL: base,
            host: "example.com",
            apiKey: apiKey,
            authHeaderName: nil,
            isSelfHosted: isSelfHosted,
            stickyKind: stickyKind,
            currentModel: currentModel,
            preferredModel: preferred,
            userInitiated: userInitiated,
            existingModels: existing,
            defaultModelRule: rule,
            keyValidationEndpoint: validation
        )
    }

    private func catalog(
        detect: LocalServerKind = .unknown,
        listed: EndpointModelCatalog.ProbeResult = .failed(.offline),
        loaded: Set<String> = [],
        validate: ProviderKeyValidator.ValidationResult = .otherFailure
    ) -> EndpointProbe.Catalog {
        EndpointProbe.Catalog(
            detectKind: { _ in detect },
            listOllama: { _ in listed },
            listLMStudio: { _ in listed },
            liveCatalog: { _, _, _, _ in listed },
            loadedOllama: { _ in loaded },
            loadedLMStudio: { _ in loaded },
            validateKey: { _, _ in validate }
        )
    }

    @Test func unauthorizedWithoutKeyOnAutomaticProbeIsIdle() async {
        let result = await EndpointProbe.run(
            request(),
            catalog: catalog(listed: .failed(.unauthorized))
        )
        #expect(result.outcome == .idle)
        #expect(result.authNeeded)
    }

    @Test func unauthorizedWithoutKeyOnUserTapIsFailed() async {
        let result = await EndpointProbe.run(
            request(userInitiated: true),
            catalog: catalog(listed: .failed(.unauthorized))
        )
        #expect(result.outcome == .failed(.unauthorized))
        #expect(result.authNeeded)
    }

    @Test func unauthorizedWithKeyIsFailed() async {
        let result = await EndpointProbe.run(
            request(apiKey: "sk-test"),
            catalog: catalog(listed: .failed(.unauthorized))
        )
        #expect(result.outcome == .failed(.unauthorized))
    }

    @Test func timeoutKeepsCachedList() async {
        let cached = [KnownModel(id: "m1", displayName: "m1", vendor: "", price: "")]
        let result = await EndpointProbe.run(
            request(existing: cached),
            catalog: catalog(listed: .failed(.offline))
        )
        #expect(result.outcome == .connected)
        #expect(result.models == cached)
    }

    @Test func fixedPresetWithoutValidationConnectsWhenKeyPresent() async {
        let result = await EndpointProbe.run(
            request(apiKey: "token", rule: .fixed("brave")),
            catalog: catalog()
        )
        #expect(result.outcome == .connected)
        #expect(result.selectedModel == "brave")
        #expect(result.models.isEmpty)
    }

    @Test func fixedPresetWithoutKeyStaysIdle() async {
        let result = await EndpointProbe.run(
            request(rule: .fixed("brave"), validation: .braveSearch),
            catalog: catalog()
        )
        #expect(result.outcome == .idle)
        #expect(result.selectedModel == "brave")
    }

    @Test func stickyKindSkipsDetection() async {
        let listed = EndpointModelCatalog.ProbeResult.connected([
            KnownModel(id: "llama", displayName: "llama", vendor: "", price: "")
        ])
        let result = await EndpointProbe.run(
            request(stickyKind: .ollama, isSelfHosted: true),
            catalog: catalog(detect: .lmStudio, listed: listed)
        )
        #expect(result.kind == .ollama)
        #expect(result.outcome == .connected)
        #expect(result.selectedModel == "llama")
    }

    @Test func preferredModelWinsOnPrefix() async {
        let models = [
            KnownModel(id: "gemma4:e2b", displayName: "e2b", vendor: "", price: ""),
            KnownModel(id: "gemma4:e4b", displayName: "e4b", vendor: "", price: ""),
        ]
        let result = await EndpointProbe.run(
            request(preferred: "gemma4:e2b"),
            catalog: catalog(listed: .connected(models))
        )
        #expect(result.selectedModel == "gemma4:e2b")
        #expect(result.shouldAutofillLabel)
        #expect(result.dismissEndpointFocus)
    }

    @Test func failureMessageNamesUnauthorized() {
        #expect(EndpointProbe.failureMessage(.unauthorized) == "key rejected — check your api key")
    }
}
