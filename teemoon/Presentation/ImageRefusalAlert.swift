//
//  ImageRefusalAlert.swift
//  teemoon
//
//  The words of the alert when a send with images meets a model that can't see them (docs/IMAGES.md §4d). DRAFT
//  strings; Android says the same. The attach sheet keeps "choose an image-capable model".
//

import Foundation

struct ImageRefusalAlert: Equatable {
    static let chooseModel = "choose model"
    static let sendTextOnly = "send text only"
    static let cancel = "cancel"

    let title: String
    let message: String
    /// In order; "send text only" only with text to send.
    let buttons: [String]

    static let ok = "ok"
    static func useSmaller(_ model: String) -> String { "use \(model)" }

    /// A phone model this phone can never give the memory images need (§4b): the permanent line, a smaller phone model
    /// when one is on the phone and fits, and ok.
    init(phoneModel: String, smaller: String?) {
        title = PhoneImageMemory.permanentLine(model: phoneModel)
        message = ""
        buttons = (smaller.map { [Self.useSmaller($0)] } ?? []) + [Self.ok]
    }

    init(modelName: String, hasText: Bool) {
        title = "\(modelName.lowercased()) can't see images"
        message = hasText
            ? "your message wasn't sent. pick a model that can, or send just the text."
            : "your message wasn't sent. pick a model that can."
        buttons = hasText ? [Self.chooseModel, Self.sendTextOnly, Self.cancel] : [Self.chooseModel, Self.cancel]
    }
}
