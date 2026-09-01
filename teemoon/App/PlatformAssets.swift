//
//  PlatformAssets.swift
//  teemoon
//
//  Asset-catalogue lookups that differ only by which class the platform names.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether an image with this name exists in the asset catalogue.
///
/// Provider tiles ask this to decide between drawing a vendor logo on a white
/// chip and falling back to an SF Symbol, so a missing asset has to be a
/// question the UI can ask — not a crash and not an empty box.
///
/// There is no SwiftUI-level way to ask it: `Image(_:)` renders a placeholder
/// for a name that does not resolve rather than reporting failure, so this has
/// to go through the platform image class. That class is `UIImage` on
/// iOS/iPadOS/visionOS and `NSImage` on macOS, which is the entire difference —
/// hence one shared function instead of the check being spelled out per site.
///
/// This lived as a `private` copy in ProviderIdentityTile.swift while
/// the add-provider form hand-rolled a UIKit-only `UIImage(named:)`. The private
/// copy was already correct on macOS; the open-coded one was the thing that
/// broke the build, so both now call this.
func namedAssetExists(_ name: String) -> Bool {
    #if canImport(UIKit)
    return UIImage(named: name) != nil
    #elseif canImport(AppKit)
    return NSImage(named: name) != nil
    #else
    return false
    #endif
}
