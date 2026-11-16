//
//  ReplyTurns.swift
//  teemoon
//
//  Applies ReplyMachine effects to the store: one machine per chat, generation ids for reply rows. Only this type
//  writes Message.statusRaw. Effects that belong to the composer or the screen are handed back to the caller.
//

import Foundation
import Observation
import SwiftData
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "reply")

@MainActor @Observable
final class ReplyTurns {
    @ObservationIgnored private var machines: [UUID: ReplyMachine] = [:]
    @ObservationIgnored private var lastIssued = 0
    @ObservationIgnored private var messageIDs: [ReplyGeneration: UUID] = [:]
    @ObservationIgnored private var generations: [UUID: ReplyGeneration] = [:]
    /// Reply rows of live generations: the streaming view draws these, the transcript must not.
    private(set) var liveRowIDs: Set<UUID> = []

    func newGeneration() -> ReplyGeneration {
        lastIssued += 1
        return ReplyGeneration(lastIssued)
    }

    /// A stable generation id for a stored row, so a retry or think harder can name what it replaces.
    func generation(of message: Message) -> ReplyGeneration {
        if let g = generations[message.id] { return g }
        let g = newGeneration()
        generations[message.id] = g
        messageIDs[g] = message.id
        return g
    }

    /// The rows the transcript draws: never a live generation's (its stored row reads "didn't finish" until it ends).
    func transcriptRows(_ messages: [Message]) -> [Message] {
        messages.filter { !liveRowIDs.contains($0.id) }
    }

    func state(in threadID: UUID) -> ReplyState { machines[threadID]?.state ?? .idle }
    func live(in threadID: UUID) -> ReplyGeneration? { machines[threadID]?.live }
    /// The newest generation started in this chat; a re-verify retry captures it.
    func latest(in threadID: UUID) -> ReplyGeneration { machines[threadID]?.highest ?? ReplyGeneration(0) }
    func resumeArmed(in threadID: UUID) -> Bool { machines[threadID]?.resumeArmed ?? false }

    func message(for g: ReplyGeneration, in thread: Thread) -> Message? {
        guard let id = messageIDs[g] else { return nil }
        return thread.messages.first { $0.id == id }
    }

    /// The kit's `restorable`: a replaced row has content and is not interrupted, failed or decryptFailed.
    static func restorable(_ replaced: [Message]) -> Bool {
        replaced.contains { m in
            m.role == .assistant && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !["interrupted", "failed", "decryptFailed"].contains(m.statusRaw ?? "")
        }
    }

    /// Runs one event and applies its store effects. Returns every effect, for the caller's own.
    @discardableResult
    func handle(_ event: ReplyEvent, in thread: Thread, context: ModelContext) -> [ReplyEffect] {
        var machine = machines[thread.id] ?? ReplyMachine(highest: ReplyGeneration(0))
        let effects = machine.handle(event)
        machines[thread.id] = machine
        var changed = false
        for effect in effects {
            switch effect {
            case .persistRow(let g, let row):
                let message = self.message(for: g, in: thread) ?? {
                    let m = Message(role: .assistant, content: "", thread: thread)
                    context.insert(m)
                    messageIDs[g] = m.id
                    generations[m.id] = g
                    return m
                }()
                message.content = row.content
                message.statusRaw = row.status.rawValue
                message.sentBeforeConfirmed = row.sentBeforeConfirmed
                changed = true
            case .deleteRows(let gs):
                let doomed = gs.compactMap { self.message(for: $0, in: thread) }
                guard !doomed.isEmpty else { continue }
                ChatSearchService.shared.didDelete(messageIDs: doomed.map(\.id))
                MessageDeletion.delete(doomed, in: context)
                changed = true
            case .persistSentBeforeConfirmed(let g, let value):
                let row = self.message(for: g, in: thread)
                row?.sentBeforeConfirmed = value
                let sorted = thread.sortedMessages
                let before = row.flatMap { r in sorted.firstIndex { $0.id == r.id } } ?? sorted.endIndex
                sorted[..<before].last { $0.role == .user }?.sentBeforeConfirmed = value
                changed = true
            default:
                break
            }
        }
        // The live generation's row is drawn by the streaming view; every other row by the transcript.
        let rows: Set<UUID> = machine.live.flatMap { messageIDs[$0] }.map { [$0] } ?? []
        if rows != liveRowIDs { liveRowIDs = rows }   // same-value writes still notify every observer
        if changed {
            thread.invalidateSortedMessages()
            do { try context.save() } catch { logger.error("Failed to save reply rows: \(error)") }
        }
        return effects
    }
}
