import Foundation
import Testing
@testable import teemoon

@Suite("SendPrep")
@MainActor
struct SendPrepTests {

    @Test func emptyPromptBlocks() {
        let vm = ChatViewModel()
        vm.prompt = "   "
        #expect(vm.prepareSend(hasProvider: true, isDownloading: false, trust: .allow)
                == .blockedEmptyPrompt)
    }

    @Test func noProviderBlocksBeforeTrust() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: false, isDownloading: false, trust: .block)
                == .blockedNoProvider)
    }

    @Test func downloadingBlocksBeforeTrust() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: true, isDownloading: true, trust: .allow)
                == .blockedDownloading)
    }

    @Test func confirmAndBlockAreDistinct() {
        let vm = ChatViewModel()
        vm.prompt = "hi"
        #expect(vm.prepareSend(hasProvider: true, isDownloading: false, trust: .confirm)
                == .confirmE2EE)
        #expect(vm.prepareSend(hasProvider: true, isDownloading: false, trust: .block)
                == .blockedE2EE)
        #expect(vm.prepareSend(hasProvider: true, isDownloading: false, trust: .allow)
                == .ready)
    }

    @Test func retryIgnoresEmptyPrompt() {
        let vm = ChatViewModel()
        vm.prompt = ""
        #expect(vm.prepareSend(
            hasProvider: true, isDownloading: false, trust: .allow, requirePrompt: false
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
