//
//  TrustVerdictTests.swift
//  teemoonTests
//
//  The sentences a reviewer will quote. Authored by TrustVerdict, not a View.
//

import Foundation
import Testing
@testable import teemoon

@Suite("TrustVerdict")
struct TrustVerdictTests {

    private func input(_ mutate: (inout TrustVerdict.Input) -> Void) -> TrustVerdict.Input {
        var i = TrustVerdict.Input(
            attestationState: .ok,
            modelName: "glm-5.2",
            providerDisplayName: "near.ai",
            e2eeKeyBound: true,
            provenanceState: .done,
            hasSigningAddress: true,
            auditState: .reviewed,
            deviceBoundary: "your phone",
            deviceSubject: "your phone"
        )
        mutate(&i)
        return i
    }

    @Test func verifiedHeroIsTheSealClaim() {
        let v = TrustVerdict.make(input { _ in })
        #expect(v.heroTitle == "encrypted to glm-5.2 — only it can read this")
        #expect(v.sendPolicy == .allow)
        #expect(v.chipCaption == "end-to-end encrypted")
    }

    @Test func leaksReviewQualifiesTheHero() {
        let v = TrustVerdict.make(input { $0.auditState = .leaks })
        #expect(v.heroTitle == "encrypted to glm-5.2 — but its logs copy what you type")
        #expect(v.everydayClaims.contains { $0.id == "audit" && $0.status == .alert })
    }

    @Test func hardFailureBlocksSending() {
        let v = TrustVerdict.make(input {
            $0.attestationState = .degraded
            $0.requiresConfirmation = true
            $0.degradeIsHardFailure = true
        })
        #expect(v.heroTitle == "sending blocked")
        #expect(v.sendPolicy == .block)
        #expect(v.chipCaption == "verification failed \u{2014} sending blocked")
    }

    @Test func softDegradeAsksBeforeSending() {
        let v = TrustVerdict.make(input {
            $0.attestationState = .degraded
            $0.requiresConfirmation = true
            $0.degradeIsHardFailure = false
        })
        #expect(v.heroTitle == "sending paused")
        #expect(v.sendPolicy == .confirm)
        #expect(v.chipCaption == "not end-to-end encrypted")
    }

    @Test func mismatchCaptionNamesTheFailedReply() {
        let v = TrustVerdict.make(input {
            $0.attestationState = .ok
            $0.mismatchedResponseCount = 1
        })
        #expect(v.chipMode == .mismatch)
        #expect(v.chipCaption == "a reply didn\u{2019}t check out")
        #expect(v.sendPolicy == .allow)
        #expect(v.heroTitle == "one reply didn't check out")
    }

    @Test func unpublishedButSealedDoesNotSayUnencrypted() {
        let v = TrustVerdict.make(input {
            $0.attestationState = .degraded
            $0.requiresConfirmation = false
            $0.unpublishedButSealed = true
        })
        #expect(v.sendPolicy == .allow)
        #expect(v.chipMode == .softDegrade)
        #expect(v.chipCaption == "encrypted \u{2014} image unpublished")
        #expect(v.heroTitle == "encrypted to glm-5.2 — one image unpublished")
        #expect(!v.chipCaption.contains("not end-to-end encrypted"))
    }

    @Test func onDeviceChipIsNotSilent() {
        let v = TrustVerdict.make(input {
            $0.attestationState = .none
            $0.isLocal = true
        })
        #expect(v.chipMode == .onDevice)
        #expect(v.chipCaption == "on this device")
    }
}
