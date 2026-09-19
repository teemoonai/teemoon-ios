import Foundation
import Testing
@testable import teemoon

@Suite("SendPrep")
@MainActor
struct SendPrepTests {

    @Test func emptyPromptBlocks() {
        let vm = ChatViewModel()
        vm.prompt = "   "
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow)
                == .blockedEmptyPrompt)
    }

    @Test func noProviderBlocksBeforeTrust() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: false, hasKey: true, isDownloading: false, trust: .block)
                == .blockedNoProvider)
    }

    /// A keyed provider with no stored key used to send anyway: the auth header
    /// was simply omitted, and Brave answered HTTP 422 "Field required" for
    /// `header x-subscription-token` — a validation error the tester read as a
    /// broken request body. The gate sits after no-provider (a missing record
    /// is the bigger problem) and before download and trust.
    @Test func noKeyBlocksAfterNoProviderAndBeforeTrust() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: true, hasKey: false, isDownloading: true, trust: .block)
                == .blockedNoKey)
        #expect(vm.prepareSend(hasProvider: false, hasKey: false, isDownloading: false, trust: .allow)
                == .blockedNoProvider)
        #expect(vm.prepareSend(hasProvider: true, hasKey: false, isDownloading: false, trust: .allow,
                               requirePrompt: false)
                == .blockedNoKey)
    }

    @Test func downloadingBlocksBeforeTrust() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: true, trust: .allow)
                == .blockedDownloading)
    }

    @Test func confirmAndBlockAreDistinct() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .confirm)
                == .confirmE2EE)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .block)
                == .blockedE2EE)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow)
                == .ready)
    }

    @Test func retryIgnoresEmptyPrompt() {
        let vm = ChatViewModel()
        vm.prompt = ""
        #expect(vm.prepareSend(
            hasProvider: true, hasKey: true, isDownloading: false, trust: .allow, requirePrompt: false
        ) == .ready)
    }

    @Test func arrivalCopyDistinguishesProgressManifestAndMissing() {
        let progressing = ChatViewModel.Arrival(name: "gemma 4 e2b", fraction: 0.4, kind: .phone)
        #expect(progressing.alertMessage.contains("40% downloaded"))
        let manifest = ChatViewModel.Arrival(name: "gemma4:e4b", fraction: nil, kind: .homeManifest)
        #expect(manifest.alertMessage.contains("onto that machine"))
        let missing = ChatViewModel.Arrival(name: "gemma 4 e2b", fraction: nil, kind: .phone)
        #expect(missing.alertMessage.contains("isn't downloaded"))
    }
}

/// The missing-key gate runs BEFORE attestation. Incident
/// (the 2026-09-04 key-orphan incident): a near.ai record whose key had
/// been orphaned in the Keychain walked into an unauthenticated attestation
/// fetch, which 401'd, and the owner was told "End-to-end encryption could
/// not be established… re-verify from the lock icon" — a crypto message for
/// an auth problem, pointing at a control that cannot add a key.
@Suite("Missing-key send gate")
@MainActor
struct MissingKeySendGateTests {

    /// The gate re-read after `prepareTurn`: a hard block never proceeds; a
    /// soft degrade proceeds only if the user already chose "send anyway";
    /// a verdict still pending is not a pass.
    @Test func postPrepareRefusalHonoursTheSettledGate() {
        #expect(ChatViewModel.postPrepareRefusal(policy: .allow, acceptedDegrade: false, verdictsPending: false) == nil)
        #expect(ChatViewModel.postPrepareRefusal(policy: .block, acceptedDegrade: true, verdictsPending: false) != nil)
        #expect(ChatViewModel.postPrepareRefusal(policy: .confirm, acceptedDegrade: false, verdictsPending: false) != nil)
        #expect(ChatViewModel.postPrepareRefusal(policy: .confirm, acceptedDegrade: true, verdictsPending: false) == nil)
        #expect(ChatViewModel.postPrepareRefusal(policy: .allow, acceptedDegrade: false, verdictsPending: true) != nil)
        #expect(ChatViewModel.postPrepareRefusal(policy: .confirm, acceptedDegrade: true, verdictsPending: true) != nil)
    }

    @Test func keyedProviderWithNoStoredKeyIsRefused() {
        #expect(ChatViewModel.mustRefuseMissingKey(provider: .nearAI, credential: ""))
        #expect(ChatViewModel.mustRefuseMissingKey(provider: .nearAI, credential: "   "),
                "whitespace is what an empty key field saves as")
    }

    @Test func keyedProviderWithStoredKeyProceeds() {
        #expect(!ChatViewModel.mustRefuseMissingKey(provider: .nearAI, credential: "sk-live"))
    }

    @Test func keylessSelfHostedProviderProceeds() {
        let ollama = Provider(name: "ringzero", endpoint: "http://homebox.local:11434/v1",
                              model: "gemma4:e4b", requiresAPIKey: false)
        #expect(!ChatViewModel.mustRefuseMissingKey(provider: ollama, credential: ""))
    }

    @Test func onDeviceProviderProceedsEvenWithAWrongFlag() {
        var local = Provider(name: "gemma 4 e2b", endpoint: "on-device",
                             model: "google/gemma-4-e2b-it-litert-lm", requiresAPIKey: false,
                             localModelID: "google/gemma-4-e2b-it-litert-lm")
        #expect(!ChatViewModel.mustRefuseMissingKey(provider: local, credential: ""))
        // The add form once hardcoded requiresAPIKey: true; the phone's own
        // model has no key to save and must never be blocked on one.
        local.requiresAPIKey = true
        #expect(local.isLocal)
        #expect(!ChatViewModel.mustRefuseMissingKey(provider: local, credential: ""))
    }

    /// The card names the provider and the key, says where the key goes,
    /// and says nothing about encryption — that is the E2EE refusal's story.
    @Test func refusalNamesTheKeyNotTheCrypto() {
        let error = ChatViewModel.missingKeyError(for: .nearAI)
        #expect(error.userMessage.hasPrefix("near.ai "))
        #expect(error.userMessage.localizedCaseInsensitiveContains("api key"))
        #expect(error.userMessage.contains("nothing was sent"))
        #expect(error.userMessage.contains("cloud keys"))
        #expect(!error.userMessage.localizedCaseInsensitiveContains("encrypt"))
        #expect(!error.userMessage.localizedCaseInsensitiveContains("lock icon"))
        #expect(error.httpStatus == nil, "nothing went over the wire")
        #expect(error.underlyingError == nil)
        guard case .provider(let name) = error.source else {
            Issue.record("a provider refusal must be attributed to the provider")
            return
        }
        #expect(name == "near.ai")
    }
}
