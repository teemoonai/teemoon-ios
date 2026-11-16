//
//  ComposerImages.swift
//  teemoon
//

import Foundation

/// The composer's send rule, the same as Android's. `picked` are ready images, `pending` ones still loading.
enum ComposerImages {
    /// Never while a photo is loading: the text would go alone and the photo land in the emptied composer.
    static func canSend(prompt: String, picked: Int, pending: Int, limit: Int) -> Bool {
        guard pending == 0, picked <= limit else { return false }
        return picked > 0 || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many loading tiles a load shows: never more than the free slots, as the picker already caps.
    static func loadingTiles(requested: Int, limit: Int, ready: Int, loading: Int) -> Int {
        min(max(requested, 0), max(limit - ready - loading, 0))
    }
}
