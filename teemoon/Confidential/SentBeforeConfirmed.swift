//
//  SentBeforeConfirmed.swift
//  teemoon
//
//  Message.sentBeforeConfirmed: a sealed send that left before its attestation record was confirmed. The reply
//  machine writes it once; only `settle` rewrites it, when that record's verdict settles (reply-machine.json).
//

import Foundation
import SwiftData

enum SentBeforeConfirmed {
    enum Outcome: String, CaseIterable, Sendable { case pass, hardFail, unsettled }

    /// Mark ids; their words live with the view that shows them.
    enum Mark: String, CaseIterable, Sendable {
        case sentWhileChecking = "mark.sentWhileChecking"
        case checkFailedAfterSend = "mark.checkFailedAfterSend"
    }

    /// `<fetchedAt, epoch ms>|<nonce>`, the record a send went out on.
    static func recordKey(fetchedAt: Date, nonce: String) -> String {
        "\(Int64((fetchedAt.timeIntervalSince1970 * 1000).rounded(.down)))|\(nonce)"
    }

    /// The key of the record a send went out on (Android: gatewayNonce, else gpuNonce).
    static func recordKey(for record: AttestationRecord) -> String {
        recordKey(fetchedAt: record.fetchedAt, nonce: record.gatewayNonce ?? record.gpuNonce ?? record.modelNonce ?? "-")
    }

    /// What a sealed send writes when the gate lets it go: pending = its verdicts were still out (the user
    /// confirmed); failed = the user sent anyway over a soft failure that kept the seal; nil = a confirmed record.
    static func atSend(sealed: Bool, pending: Bool, policy: TrustSendPolicy, record: AttestationRecord?) -> String? {
        guard sealed, let record else { return nil }
        let key = recordKey(for: record)
        if pending { return Self.pending(key) }
        return policy == .confirm ? failed(key) : nil
    }

    static func pending(_ recordKey: String) -> String { "pending|\(recordKey)" }
    static func failed(_ recordKey: String) -> String { "failed|\(recordKey)" }

    /// The value after `recordKey`'s verdict settles. Rows of other records, nil and failed rows never change.
    static func resolved(_ value: String?, recordKey: String, outcome: Outcome) -> String? {
        guard value == pending(recordKey) else { return value }
        switch outcome {
        case .pass: return nil
        case .hardFail: return failed(recordKey)
        case .unsettled: return value
        }
    }

    static func mark(_ value: String?) -> Mark? {
        guard let value else { return nil }
        if value.hasPrefix("pending|") { return .sentWhileChecking }
        if value.hasPrefix("failed|") { return .checkFailedAfterSend }
        return nil
    }

    /// The report and counters count a message as end-to-end encrypted only when this is nil.
    static func countsAsE2EE(_ value: String?) -> Bool { value == nil }

    /// Rewrites every stored row still pending on `recordKey`. Returns how many changed.
    @MainActor @discardableResult
    static func settle(recordKey: String, outcome: Outcome, in context: ModelContext) throws -> Int {
        guard outcome != .unsettled else { return 0 }
        let target: String? = pending(recordKey)
        let rows = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.sentBeforeConfirmed == target }))
        for row in rows { row.sentBeforeConfirmed = resolved(row.sentBeforeConfirmed, recordKey: recordKey, outcome: outcome) }
        if !rows.isEmpty { try context.save() }
        return rows.count
    }
}
