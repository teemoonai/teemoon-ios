//
//  KeyCustodyCopy.swift
//  teemoon
//
//  What the trust screens say about the model key. near.ai's key service derives it from the app id and decides which
//  sealed chips get it (dstack kms derive_k256_key); one listed holder serves other models too. Never say the key
//  "never leaves" a chip or that only one chip holds it (KeyCustodyCopyTests).
//

enum KeyCustodyCopy {
    /// What teemoon knows about the enclaves near.ai lists for the model (audit 1.1.1 A7): "checked" only when the list
    /// was read and every listed check passed: each entry's own checks, its DCAP verdict and the GPU verdict (A3, which
    /// covers every listed enclave's evidence) and each trust scope (A4). Add any new per-enclave check here too.
    enum Listed: Equatable, Sendable { case checked, listFailed, checking, unfinished, failed }

    static func listed(record: AttestationRecord?, dcap: RecordDCAPVerification?, gpu: NRASVerification?,
                       scopes: [TrustScope]?, deadlinePassed: Bool = false) -> Listed {
        // Past the verdict deadline the send ask says the checks didn't finish: a missing input never reads "checking".
        let waiting: Listed = deadlinePassed ? .unfinished : .checking
        guard let record else { return waiting }
        if record.modelCandidatesListFailed { return .listFailed }
        if record.candidatesBroken || dcap?.listed.contains(where: \.isHardFailure) == true || gpu?.isHardFailure == true
            || scopes?.contains(where: \.hardBreak) == true {
            return .failed
        }
        guard let enclaves = record.modelCandidates?.enclaves, let dcap, dcap.listed.count == enclaves.count, let gpu,
              let scopes, scopes.count == enclaves.count else {
            return waiting
        }
        let scopeUnfinished = scopes.contains { scope in
            scope.binding == .unchecked || scope.listedEvidenceAbsent
                || scope.running.contains { [.inconclusive, .notFetched, .unpublished].contains($0.outcome) }
        }
        return dcap.listed.contains(where: \.isUnchecked) || !gpu.isVerified || scopeUnfinished ? .unfinished : .checked
    }

    // Approved 2026-11-19 (card key-custody-listed-states v2): everyday = expert.
    static func listedSentence(_ state: Listed) -> String {
        switch state {
        case .checked: "teemoon checked every enclave near.ai listed."
        case .listFailed: "teemoon couldn't load near.ai's list of enclaves, so it couldn't check them."
        case .checking: "teemoon is checking the enclaves near.ai listed…"
        case .unfinished: "teemoon couldn't finish checking the enclaves near.ai listed."
        case .failed: "one of the enclaves near.ai listed failed teemoon's check."
        }
    }

    static func listedTail(_ state: Listed) -> String {
        switch state {
        case .checked: "teemoon checked each one near.ai listed."
        case .listFailed: "teemoon couldn't load near.ai's list, so it couldn't check them."
        case .checking: "teemoon is checking each one near.ai listed…"
        case .unfinished: "teemoon couldn't finish checking the ones near.ai listed."
        case .failed: "one near.ai listed failed teemoon's check."
        }
    }

    static func sealedDetail(device: String, model: String, listed: Listed) -> String {
        "before anything leaves \(device) it's locked to \(model)'s enclave key. near.ai's key service decides which secure enclaves get that key; the network and near.ai's gateway don't have it. \(listedSentence(listed))"
    }
    static func sealingPending(model: String) -> String { "locking it to \(model)'s enclave key…" }
    static func replySigned(model: String) -> String {
        "each answer carries a signature from \(model)'s enclave key, so you know it came from near.ai's enclaves for the model."
    }
    static func replySignatureFailed(model: String) -> String {
        "one answer didn't carry a valid signature from \(model)'s enclave key."
    }
    static func keyInQuoteExpert(model: String, listed: Listed) -> String {
        "that public key sits in `report_data` of \(model)'s hardware quote. near.ai's key service derives it for this app and decides which enclaves get it; teemoon can't check that decision. \(listedSentence(listed)) the gateway doesn't hold the key."
    }
    static func keyHeldEveryday(listed: Listed) -> String {
        "the key to open your chat is held in near.ai's secure enclaves — near.ai's key service decides which ones — not by the network or near.ai's gateway. \(listedTail(listed))"
    }
    static let replySignedExpert = "each reply is signed by the enclave's key — recover any message to check it yourself."

    // Approved 2026-11-19 (card key-custody-copy-2).
    static let keyHeldEverydayTitle = "near.ai's secure enclaves hold the key"
    static let keyNotHeldRow = "the network and gateway don't hold the key"
}
