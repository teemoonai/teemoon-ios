//
//  PlaceLabel.swift
//  teemoon
//
//  Auto-generated provider names are the PLACE, never the model. A typed name
//  is never overwritten. Pins healAutoLabels' other half — see PlaceLabelTests.
//

import Foundation

enum PlaceLabel {
    /// Next auto label, or nil if the current name must be left alone.
    static func proposed(
        currentName: String,
        lastAuto: String,
        presetName: String,
        host: String?
    ) -> String? {
        let trimmed = currentName.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || trimmed == lastAuto else { return nil }
        if !presetName.isEmpty { return presetName.lowercased() }
        if let host { return HostLabel.friendly(host).lowercased() }
        return nil
    }
}
