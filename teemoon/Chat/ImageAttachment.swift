//
//  ImageAttachment.swift
//  teemoon
//
//  An image belonging to a message (docs/IMAGES.md §1). Standalone: it names its message by
//  id, so Message's table is untouched by it (TeemoonSchemaV2 added this model and nothing else).
//  `data` is always teemoon's own re-encoded image, never bytes it received.
//  Deleting a message deletes its attachments through MessageDeletion, never by a delete rule.
//

import Foundation
import SwiftData

@Model
final class ImageAttachment {
    @Attribute(.unique) var id: UUID
    var messageID: UUID
    /// Order within the message.
    var index: Int
    /// "image/jpeg" or "image/png": the re-encoded form.
    var mimeType: String
    var width: Int
    var height: Int
    @Attribute(.externalStorage) var data: Data
    /// ≤ 256 px JPEG for the bubble.
    var thumbnail: Data

    /// A message's images, in order. Empty when the message has none or is not in a store.
    static func images(of message: Message) -> [ImageAttachment] {
        guard let context = message.modelContext else { return [] }
        let id = message.id
        let found = (try? context.fetch(FetchDescriptor<ImageAttachment>(predicate: #Predicate { $0.messageID == id }))) ?? []
        return found.sorted { $0.index < $1.index }
    }

    init(id: UUID, messageID: UUID, index: Int, mimeType: String, width: Int, height: Int, data: Data, thumbnail: Data) {
        self.id = id
        self.messageID = messageID
        self.index = index
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.data = data
        self.thumbnail = thumbnail
    }
}
