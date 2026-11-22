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
        #expect(v.heroTitle == "encrypted to glm-5.2's enclave key")
        #expect(v.sendPolicy == .allow)
        #expect(v.chipCaption == "end-to-end encrypted")
    }

    /// the maintainer 2026-11-20: the quant follows the model's enclave key ("GLM-5.1 · AWQ's enclave key" read as the quant's key).
    @Test func theQuantFollowsTheModelsEnclaveKey() {
        let quanted = TrustVerdict.make(input { $0.modelName = "GLM-5.1"; $0.quant = "AWQ" })
        #expect(quanted.heroTitle == "encrypted to GLM-5.1's enclave key · AWQ")
        #expect(TrustVerdict.make(input { $0.modelName = "GLM-5.1" }).heroTitle == "encrypted to GLM-5.1's enclave key")
        // Subtitle and sealed row name the model only, with or without a quant.
        for quant in [nil, "AWQ"] as [String?] {
            let v = TrustVerdict.make(input { $0.modelName = "GLM-5.1"; $0.quant = quant })
            #expect(v.heroSubtitle == "sealed to GLM-5.1's enclave key. near.ai's key service decides which secure enclaves hold it.")
            #expect(v.everydayClaims.first { $0.id == "sealed" }?.title == "sealed to GLM-5.1's enclave key")
        }
        // No enclave-key tail: the quant stays beside the model.
        let unreviewed = TrustVerdict.make(input { $0.modelName = "GLM-5.1"; $0.quant = "AWQ"; $0.auditState = nil })
        #expect(unreviewed.heroTitle == "encrypted to GLM-5.1 · AWQ")
        let unpublished = TrustVerdict.make(input { $0.modelName = "GLM-5.1"; $0.quant = "AWQ"; $0.unpublishedButSealed = true })
        #expect(unpublished.heroTitle == "encrypted to GLM-5.1 · AWQ — one image unpublished")
    }

    /// trust-leaks-wording (the maintainer 2026-11-06), row 3: the reviewer's own sentence, never a fixed one.
    @Test func leaksReviewQualifiesTheHero() {
        let found = "every prompt is written to the container log and shipped to telemetry."
        let v = TrustVerdict.make(input { $0.auditState = .leaks; $0.leaksExposure = found })
        #expect(v.heroTitle == "encrypted to glm-5.2")
        #expect(v.heroSubtitle == "sealed to the model's hardware on the way in. a review of this exact build found: \(found)")
        #expect(v.everydayClaims.contains { $0.id == "audit" && $0.status == .alert && $0.title == found })
        #expect(!v.everydayClaims.contains { $0.title.contains("copies what you type") || $0.detail.contains("monitoring systems") },
                "the fixed claim is gone from title and detail")
        #expect(v.everydayClaims.first { $0.id == "audit" }?.detail
                == "The seal still protects your message on the way in; this is about what happens after it's unlocked.")
        let bare = TrustVerdict.make(input { $0.auditState = .leaks })
        #expect(bare.heroSubtitle == AuditedSealText.notReviewed, "no exposure recorded: line A")
        #expect(bare.sendPolicy == .allow, "audits never gate")
    }

    /// Row 1 and 2: the enclave-key tail only when reviewed; otherwise the tail drops and line A shows.
    @Test func theReadingClaimNeedsAReviewedBuild() {
        for state: EverydayAuditState? in [nil, .incomplete, .reviewedWithCaveat] {
            let v = TrustVerdict.make(input { $0.auditState = state })
            #expect(v.heroTitle == "encrypted to glm-5.2", "\(String(describing: state))")
            #expect(v.heroSubtitle == AuditedSealText.notReviewed)
            #expect(v.chipCaption == "end-to-end encrypted", "row 5: the chip is unchanged")
        }
        let reviewed = TrustVerdict.make(input { _ in })
        #expect(reviewed.heroSubtitle == "sealed to glm-5.2's enclave key. near.ai's key service decides which secure enclaves hold it.")
        let unchecked = TrustVerdict.make(input { $0.provenanceState = .unchecked })
        #expect(unchecked.heroTitle == "encrypted to glm-5.2" && unchecked.heroSubtitle == ProvenanceUncheckedText.header)
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

    /// GLM-5.3 flash, 2026-09-12: the sheet opened on "but its logs copy what
    /// you type" (a reviewed leak) and flipped to "one image unpublished" the
    /// moment provenance landed — the weaker line hid the stronger one.
    @Test func aReviewedLeakOutranksAnUnpublishedImage() {
        let v = TrustVerdict.make(input { $0.auditState = .leaks; $0.unpublishedButSealed = true; $0.leaksExposure = "x." })
        #expect(v.heroTitle == "encrypted to glm-5.2")
        #expect(!v.heroTitle.contains("unpublished"))
        #expect(v.heroSubtitle.hasSuffix("found: x."))
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

/// trust-blocked-chain-and-gateway-row (a) with the pm ruling (2026-11-06, Android d971bdb5): steps after a
/// failure, a block or a stale record are empty grey rings (not checked); a step that genuinely passed before a
/// later failure keeps its ✓; the rail into a failing step is grey.
@Suite("TrustVerdict — halted chain")
struct TrustVerdictHaltedChainTests {
    private func input(_ mutate: (inout TrustVerdict.Input) -> Void) -> TrustVerdict.Input {
        var i = TrustVerdict.Input(attestationState: .ok, modelName: "glm-5.3", providerDisplayName: "near.ai",
                                   e2eeKeyBound: true, provenanceState: .done, responseSigState: .done,
                                   hasSigningAddress: true, auditState: .reviewed,
                                   deviceBoundary: "your phone", deviceSubject: "your phone")
        mutate(&i)
        return i
    }

    @Test func stepsAfterAFailureAreNotCheckedAndEarlierPassesStay() {
        for halted in [true, false] {
            #expect(TrustVerdict.settleChain([.origin, .ok, .fail, .ok, .pending, .info], halted: halted)
                    == [.origin, .ok, .fail, .notChecked, .notChecked, .notChecked])
        }
    }

    @Test func aHaltWithNoFailureOnTheChainLeavesNothingGreen() {
        #expect(TrustVerdict.settleChain([.origin, .ok, .ok, .info, .pending], halted: true)
                == [.origin, .notChecked, .notChecked, .info, .notChecked])
        #expect(TrustVerdict.settleChain([.origin, .ok, .ok, .info], halted: false) == [.origin, .ok, .ok, .info])
    }

    @Test func theRailIntoAFailingOrUncheckedStepIsGrey() {
        #expect(TrustVerdict.greyRails([.origin, .ok, .fail, .notChecked], halted: false) == [false, true, false, false],
                "into the red step: grey; below the red step the break draws itself")
        #expect(TrustVerdict.greyRails([.origin, .ok, .notChecked], halted: false) == [false, true, false])
        #expect(TrustVerdict.greyRails([.origin, .ok, .ok], halted: false) == [false, false, false])
    }

    /// The first after-render (block, everyday): the rail between two grey info steps still drew green.
    @Test func underAHaltNoRailIsGreen() {
        #expect(TrustVerdict.greyRails([.origin, .notChecked, .info, .info, .notChecked], halted: true)
                == [true, true, true, true, false])
        #expect(TrustVerdict.greyRails([.origin, .ok, .info, .info], halted: false) == [false, false, false, false])
    }

    @Test func aBlockOffTheChainShowsNoGreenStep() {
        // A hardware failure off the chain blocks the send while the key binding itself still reads bound.
        let v = TrustVerdict.make(input { $0.attestationState = .degraded; $0.requiresConfirmation = true
                                          $0.degradeIsHardFailure = true })
        #expect(v.sendPolicy == .block, "precondition")
        #expect(!v.everydayClaims.contains { $0.status == .ok })
        #expect(v.everydayClaims.first { $0.id == "sealed" }?.status == .notChecked)
        #expect(v.everydayClaims.first { $0.id == "signed" }?.status == .notChecked)
    }

    @Test func aPassBeforeTheFailingStepKeepsItsCheck() throws {
        let v = TrustVerdict.make(input { $0.attestationState = .degraded; $0.requiresConfirmation = true
                                          $0.degradeIsHardFailure = true; $0.provenanceState = .stuck
                                          $0.listedEnclaves = .checked })
        let failAt = try #require(v.everydayClaims.firstIndex { $0.status == .fail })
        #expect(v.everydayClaims[failAt].id == "identity")
        #expect(v.everydayClaims.first { $0.id == "sealed" }?.status == .ok)
        #expect(v.everydayClaims[(failAt + 1)...].allSatisfy { $0.status == .notChecked })
    }

    @Test func aStaleUnrefreshableRecordHaltsTheChainToo() {
        let v = TrustVerdict.make(input { $0.attestationState = .degraded; $0.requiresConfirmation = true
                                          $0.recordStale = true })
        #expect(v.chainHalted)
        #expect(!v.everydayClaims.contains { $0.status == .ok })
    }

    @Test func aHealthyChainKeepsItsGreen() {
        let v = TrustVerdict.make(input { _ in })
        #expect(!v.chainHalted)
        #expect(v.everydayClaims.contains { $0.status == .ok })
        #expect(!v.everydayClaims.contains { $0.status == .notChecked })
    }
}
