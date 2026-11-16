//
//  ComposerPanelPolicy.swift
//  teemoon
//
//  What the composer panel's bottom row shows (docs/COMPOSER_PANEL.md). The view draws what this returns.
//

import Foundation

struct ComposerPanelPolicy: Equatable {
    /// `Provider.modelCapabilities?.contains(.tools)`; nil (unknown) is optimistic, as `modelSupportsTools` is.
    var modelTakesTools: Bool?
    /// The where chip carries a status: downloading, waiting for wi-fi, not downloaded.
    var chipHasStatus = false
    var accessibilitySize = false
    /// Developer mode's reasoning level after the where chip's name (docs/COMPOSER_PANEL.md §Developer mode).
    var chipShowsLevel = false

    var showsWebChip: Bool { modelTakesTools != false }
    /// The status (or developer mode's level) is never cut, so web gives up its word first.
    var webIconOnly: Bool { chipHasStatus || accessibilitySize || chipShowsLevel }
    var chipShowsName: Bool { !accessibilitySize }
    var chipShowsStatus: Bool { chipHasStatus }
    var maxLines: Int { accessibilitySize ? 4 : 6 }
}
