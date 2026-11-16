//
//  ComposerImageLimitTests.swift
//  teemoonTests
//
//  The composer over its image limit (reply-machine.json composerReturn): every image is kept, send is refused and
//  the existing "up to N images per message" note shows until enough are removed. Two ways in: a returned question,
//  and a provider switch that lowers the limit.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Composer over its image limit")
struct ComposerImageLimitTests {

    static func images(_ n: Int) -> [ImageIntake.Image] { (1...n).map { ComposerImageTests.kept($0) } }

    @Test func aProviderSwitchThatLowersTheLimitKeepsEveryImageAndRefusesSend() {
        let vm = ChatViewModel()
        vm.prompt = "compare these"
        vm.pendingImages = Self.images(6)
        vm.imageLimit = ChatViewModel.imagesPerSend(localModelID: nil)
        #expect(!vm.imagesOverLimit)
        #expect(vm.overLimitNote == nil)

        vm.imageLimit = ChatViewModel.imagesPerSend(localModelID: "litert-community/gemma-4-E4B-it-litert-lm")   // cloud 10 → E4B 4
        #expect(vm.pendingImages.count == 6, "no image is dropped")
        #expect(vm.imagesOverLimit)
        #expect(vm.overLimitNote == "up to 4 images per message")
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow) == .blockedTooManyImages)

        vm.removePendingImage(at: 0)
        vm.removePendingImage(at: 0)
        #expect(!vm.imagesOverLimit, "removing enough lifts it")
        #expect(vm.overLimitNote == nil)
        #expect(vm.prepareSend(hasProvider: true, hasKey: true, isDownloading: false, trust: .allow) == .ready)
    }

    @Test func atTheLimitIsNotOver() {
        let vm = ChatViewModel()
        vm.pendingImages = Self.images(4)
        vm.imageLimit = 4
        #expect(!vm.imagesOverLimit)
    }
}
