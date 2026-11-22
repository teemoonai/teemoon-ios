//
//  SendChoices.swift
//  teemoon
//
//  The three-way questions, in order, the way out last. Shown as action sheets on iOS and bottom sheets on Android
//  (UI audit, pm 2026-10-25); SendChoicesTests pins the order and the words.
//

import Foundation

enum E2EESendChoice: Equatable {
    case retryVerification
    case sendAnyway(stillEncrypted: Bool)
    /// A plain button, never role .cancel: iOS 26 hides the cancel button when the sheet is a popover.
    case dontSend
    /// The hardware isn't confirmed but the seal holds (near-send-gate-rule, the maintainer 2026-11-06).
    case sendSealedUnconfirmed
    case wait

    var label: String {
        switch self {
        case .retryVerification: "retry verification"
        case .sendAnyway(let sealed): sealed ? "send anyway (still encrypted)" : "send without encryption"
        case .dontSend: "don't send"
        case .sendSealedUnconfirmed: "send anyway"
        case .wait: "wait"
        }
    }

    /// Red: the message leaves without the seal.
    var isDestructive: Bool { self == .sendAnyway(stillEncrypted: false) }

    /// A hard integrity break offers no way to send.
    static func choices(hardFailure: Bool, provenanceOnly: Bool) -> [E2EESendChoice] {
        hardFailure ? [.retryVerification, .dontSend]
            : [.retryVerification, .sendAnyway(stillEncrypted: provenanceOnly), .dontSend]
    }

    static let stillChecking: [E2EESendChoice] = [.sendSealedUnconfirmed, .wait]
    static let stillCheckingTitle = "still checking near.ai's hardware"
    static let stillCheckingMessage = "some checks haven't finished. your message would still be sealed to the model's key, but the hardware behind that key isn't confirmed yet."

    /// Image provenance alone still running at the settle timeout (S30, the maintainer 2026-11-07).
    static let provenancePendingTitle = "couldn't confirm near.ai's software yet"
    static let provenancePendingMessage = "your message would still be sealed to the model's verified hardware key, but teemoon hasn't yet confirmed that the software running on it is the published code."
    /// The provenance lookup ended without an answer (T2b): nothing to wait for, so no "wait".
    static let provenanceUncheckedTitle = "couldn't confirm near.ai's software"
    static let provenanceUncheckedMessage = "your message would still be sealed to the model's verified hardware key, but teemoon couldn't reach GitHub or Docker Hub to confirm that the software running on it is the published code."
    /// DRAFT (verify-deadline, 2026-11-14): near.ai's tier list never came. Nothing reloads it, so no "wait".
    static let tierUncheckedTitle = "couldn't confirm near.ai's hardware"
    /// the maintainer approved this body as written (card near-verify-deadline, 2026-11-14); don't lengthen it without him.
    static let tierUncheckedMessage = VerdictDeadline.tierReason
    static let tierUnchecked: [E2EESendChoice] = [.sendSealedUnconfirmed, .dontSend]
    /// Card trust-copy-sweep-111 v4 (A8), verbatim. Re-verify refetches the list; nothing is in flight, so no "wait".
    static let listFailedTitle = "couldn't load near.ai's list of enclaves"
    static let listFailedMessage = "your message would still be sealed to the model's key, but teemoon couldn't check the other enclaves near.ai lists for this model, which hold the same key. retry verification to ask near.ai for the list again."
    static let listFailed: [E2EESendChoice] = [.retryVerification, .sendSealedUnconfirmed, .dontSend]

    static let unavailableMessage = "teemoon couldn't seal this message to the model's enclave key. nothing has been sent."
    static let provenanceOnlyMessage = "your message would still be sealed to the model's verified hardware key — but one running image on this server couldn't be verified as published code. re-verifying may reach a different server of this model."

    /// `cause` is the session's degrade reason; only a hard break names it.
    static func message(hardFailure: Bool, provenanceOnly: Bool, cause: String?) -> String {
        if provenanceOnly { return provenanceOnlyMessage }
        guard hardFailure else { return unavailableMessage }
        let cause = cause ?? "end-to-end encryption couldn't be set up for this provider."
        return "\(cause) sending is blocked until this re-verifies. this could mean the enclave was tampered with or the connection was intercepted."
    }
}

/// The question the send gate shows, chosen in one place so the view only lays it out.
struct E2EEAsk: Equatable {
    /// Which question is on screen. Only `.tierDowngrade`'s answer is the downgrade consent (`SealedModels.accept`).
    enum Kind: Equatable { case verification, tierDowngrade }

    let title: String
    let message: String
    let choices: [E2EESendChoice]
    var kind: Kind = .verification

    /// `pendingAsk`: the kind still pending when the settle timeout asked, nil when no pending ask is up.
    /// `deadlinePassed`: the checks gave up (`ConfidentialSession.deadlinePassed`), so nothing is "still checking".
    /// `enclaveListFailed`: `ConfidentialSession.enclaveListFailedAsks`.
    static func make(hardFailure: Bool, pendingAsk: ConfidentialSession.PendingKind?, provenanceUnchecked: Bool,
                     softButSealed: Bool, provenanceBlocked: Bool, cause: String?,
                     deadlinePassed: Bool = false, enclaveListFailed: Bool = false) -> E2EEAsk {
        if !hardFailure, pendingAsk == .provenance {
            return E2EEAsk(title: E2EESendChoice.provenancePendingTitle, message: E2EESendChoice.provenancePendingMessage,
                           choices: E2EESendChoice.stillChecking)
        }
        if !hardFailure, pendingAsk == nil, deadlinePassed, softButSealed {
            return E2EEAsk(title: E2EESendChoice.tierUncheckedTitle, message: E2EESendChoice.tierUncheckedMessage,
                           choices: E2EESendChoice.tierUnchecked)
        }
        if !hardFailure, pendingAsk == nil, provenanceUnchecked {
            return E2EEAsk(title: E2EESendChoice.provenanceUncheckedTitle, message: E2EESendChoice.provenanceUncheckedMessage,
                           choices: E2EESendChoice.choices(hardFailure: false, provenanceOnly: true))
        }
        if !hardFailure, pendingAsk == nil, enclaveListFailed {
            return E2EEAsk(title: E2EESendChoice.listFailedTitle, message: E2EESendChoice.listFailedMessage,
                           choices: E2EESendChoice.listFailed)
        }
        if !hardFailure, pendingAsk != nil || softButSealed {
            return E2EEAsk(title: E2EESendChoice.stillCheckingTitle, message: E2EESendChoice.stillCheckingMessage,
                           choices: E2EESendChoice.stillChecking)
        }
        let title = hardFailure ? "verification failed — sending blocked"
            : provenanceBlocked ? "couldn't verify the running code" : "end-to-end encryption unavailable"
        return E2EEAsk(title: title,
                       message: E2EESendChoice.message(hardFailure: hardFailure, provenanceOnly: provenanceBlocked, cause: cause),
                       choices: E2EESendChoice.choices(hardFailure: hardFailure, provenanceOnly: provenanceBlocked))
    }
}

enum CellularDownloadChoice: Equatable, CaseIterable {
    case downloadNow, waitForWiFi, notNow

    var label: String {
        switch self {
        case .downloadNow: "download now"
        case .waitForWiFi: "wait for wi-fi"
        case .notNow: "not now"
        }
    }
}
