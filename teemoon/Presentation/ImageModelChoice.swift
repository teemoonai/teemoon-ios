//
//  ImageModelChoice.swift
//  teemoon
//
//  Which models read images, and the marker that says so (review entry images-model-marker, approved 2026-11-01).
//  What happens on a model that can't see images is ComposerImageMachine's (docs/IMAGES.md §4d).
//

import Foundation

enum ImageModelChoice {

    static let marker = "reads images"
    /// The browser row's glyph for that marker (the maintainer 2026-11-07); muted, so it doesn't read as a control.
    static let markerGlyph = "eye"
    static let captionTag = "images"

    /// A phone model reads images only when they work on this phone; a server model when its own list says so.
    static func reads(_ provider: Provider, modelID: String, capabilities: ModelCapabilities?) -> Bool {
        if provider.isLocal { return LocalModelCatalog.imagesOnDevice && PhoneImageMemory.reads(modelID: modelID) }
        return capabilities?.contains(.vision) == true
    }
}
