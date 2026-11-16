//
//  AttachmentDeletionTests.swift
//  teemoonTests
//
//  No attachment outlives its message (docs/IMAGES.md §1): an ImageAttachment names its message
//  by id with no delete rule, so every deleting path goes through MessageDeletion.
//

import Foundation
import SwiftData
import Testing
@testable import teemoon

@MainActor
@Suite("Attachments — deletion")
struct AttachmentDeletionTests {

    private func store() throws -> ModelContext {
        let container = try ModelContainer(for: ChatThread.self, Message.self, ImageAttachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func chat(_ context: ModelContext, images: Int) throws -> (ChatThread, [Message]) {
        let thread = ChatThread()
        context.insert(thread)
        let question = Message(role: .user, content: "what is this?", thread: thread)
        let answer = Message(role: .assistant, content: "a cat", thread: thread)
        [question, answer].forEach(context.insert)
        for i in 0..<images {
            context.insert(ImageAttachment(id: UUID(), messageID: question.id, index: i, mimeType: "image/jpeg",
                                      width: 4, height: 3, data: Data(repeating: 1, count: 64), thumbnail: Data([2])))
        }
        try context.save()
        return (thread, [question, answer])
    }

    @Test func deletingAChatDeletesItsImages() throws {
        let context = try store()
        let (thread, _) = try chat(context, images: 2)
        let (other, _) = try chat(context, images: 1)
        ThreadDeletion.delete(thread, in: context)
        #expect(try context.fetchCount(FetchDescriptor<ImageAttachment>()) == 1, "only the other chat's image remains")
        ThreadDeletion.delete(other, in: context)
        #expect(try context.fetchCount(FetchDescriptor<ImageAttachment>()) == 0)
    }

    @Test func deletingMessagesDeletesTheirImages() throws {
        let context = try store()
        let (_, messages) = try chat(context, images: 3)
        MessageDeletion.delete([messages[0]], in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ImageAttachment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 1)
    }

    @Test func deleteAllChatsDeletesEveryImage() throws {
        let context = try store()
        _ = try chat(context, images: 2)
        _ = try chat(context, images: 2)
        try ThreadDeletion.deleteAll(in: context)
        #expect(try context.fetchCount(FetchDescriptor<ImageAttachment>()) == 0)
    }
}
