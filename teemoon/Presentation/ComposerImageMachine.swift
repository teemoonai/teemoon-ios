//
//  ComposerImageMachine.swift
//  teemoon
//
//  The composer's images as one state machine (docs/IMAGES.md §4d, conformance/composerimages.json, which Android runs
//  too). Views send events and run the effects in the order given; they keep no image flags of their own.
//

import Foundation

enum ComposerImageMachine {
    enum State: String, CaseIterable { case empty, attached }

    enum Event: String, CaseIterable {
        case tapPlusSees = "tapPlus/sees", tapPlusBlind = "tapPlus/blind", attachSheetChooseModel
        case picked, paste, removeOne, removeLast, modelSwitched, tapWhereChip
        case sendSees = "send/sees", sendBlind = "send/blind", alertChooseModel, sendWithoutImages, questionReturned
    }

    enum Effect: String {
        case openAttachSheet, openAttachSheetCantSee = "openAttachSheet(cantSee)", closeAttachSheet
        case openWhereReadsImages = "openWhere(readsImages)", openWhere
        case attach, remove, removeAll, sendImages, sendText, showRefusedAlert
    }

    static func next(_ state: State, _ event: Event) -> (State, [Effect]) {
        let has = state == .attached
        switch event {
        case .tapPlusSees: return (state, [.openAttachSheet])
        case .tapPlusBlind: return (state, [.openAttachSheetCantSee])
        case .attachSheetChooseModel: return (state, [.closeAttachSheet, .openWhereReadsImages])
        case .picked, .paste, .questionReturned: return (.attached, [.attach])
        case .removeOne: return (state, has ? [.remove] : [])
        case .removeLast: return has ? (.empty, [.remove]) : (state, [])
        // A model switch never drops images (the maintainer's Android bug, 2026-11-11).
        case .modelSwitched: return (state, [])
        case .tapWhereChip: return (state, [has ? .openWhereReadsImages : .openWhere])
        // Images go only to a model that reads them; formal/ComposerImages.tla holds this too (NoImageToBlindModel).
        case .sendSees: return has ? (.empty, [.sendImages]) : (state, [])
        case .sendBlind: return (state, has ? [.showRefusedAlert] : [])
        case .alertChooseModel: return (state, has ? [.openWhereReadsImages] : [])
        case .sendWithoutImages: return has ? (.empty, [.removeAll, .sendText]) : (state, [])
        }
    }
}
