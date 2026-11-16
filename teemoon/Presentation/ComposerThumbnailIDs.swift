//
//  ComposerThumbnailIDs.swift
//  teemoon
//
//  Who each composer thumbnail is, so SwiftUI can animate the one that left (docs/IMAGES.md §4d). Not its position:
//  removing one shifted every position after it, and the removal snapped.
//

import Foundation

enum ComposerThumbnailIDs {
    static func ids(_ images: [ImageIntake.Image]) -> [String] {
        var seen: [Int: Int] = [:]
        return images.map { image in
            let key = image.data.hashValue
            let nth = seen[key, default: 0]
            seen[key] = nth + 1
            return "\(key)#\(nth)"
        }
    }
}
