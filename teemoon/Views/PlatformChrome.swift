//
//  PlatformChrome.swift
//  teemoon
//
//  SwiftUI chrome — list styling, toolbar placement — that iOS names and macOS
//  either names differently or does not have. Each entry states what the macOS
//  behaviour actually is, so a reader never has to guess whether a difference
//  was intended.
//

import SwiftUI
import UniformTypeIdentifiers

/// THE VERB FOR "ACTIVATE THIS CONTROL", WHICH IS NOT "TAP" ON A MAC.
///
/// Instruction copy was written for the phone and shipped verbatim to macOS:
/// "tap the model chip above the message field", "tap a provider to fill the
/// fields", "download failed — tap to retry". Nobody taps a Mac. It is a small
/// wrong word in a visible place, and telling a user to perform a gesture their
/// device does not have is the same class of tell as an empty File menu.
///
/// Deliberately not localized-by-platform-idiom beyond this: the point is one
/// verb, resolved once, so new copy cannot reintroduce the phone's word.
enum PointerVerbDoc {}

/// THE DEVICE, WHICH THE SHIPPED COPY CALLS "your phone" ON A MAC.
///
/// The trust ladder is the product's central claim, and six of its strings named
/// the wrong machine — "readable only here, on your phone", "before anything
/// leaves your phone". On a Mac that is not a tone problem, it is false.
///
/// TWO OPERATIONS, NOT ONE SUBSTITUTION. This is the part worth reading before
/// adding copy:
///
///   - `boundary` is a TOKEN. "before anything leaves **this Mac**" — Apple's
///     register is "this Mac", not "your Mac".
///   - the deictic case is a DELETION. "readable only here" is already complete
///     on every platform; "only here, on this Mac" says *here* twice.
///
/// So a blind find-and-replace of the noun would produce correct-sounding,
/// slightly wrong English. The call sites differ deliberately.
enum DeviceNoun {
    /// The machine, named — for boundary claims about what leaves it.
    static var boundary: String {
        #if os(macOS)
        "this Mac"
        #else
        "your phone"
        #endif
    }

    /// The machine, possessive — "your phone couldn't confirm…".
    static var subject: String {
        #if os(macOS)
        "this Mac"
        #else
        "your phone"
        #endif
    }
}

/// UIKit COLOUR NAMES THAT macOS DOES NOT HAVE.
///
/// `Color(.systemGroupedBackground)` and `Color(.separator)` are UIKit colours.
/// On macOS `.separator` resolves to `SeparatorShapeStyle` — not a `Color` — and
/// `.systemGroupedBackground` does not resolve at all. Between them they were
/// the last compile errors keeping the trust ladder off the Mac, which is a
/// thin reason for a platform to ship without its central proof surface.
enum PlatformTone {
    static var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(.separator)
        #endif
    }

    static var secondaryGroupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    static var groupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }
}

/// COPY, ON EITHER PLATFORM.
///
/// `UIPasteboard` is why two of the trust-ladder files were gated to iOS. The
/// ladder is a proof surface — every digest, key and script has to be copyable,
/// or it is a picture of evidence rather than evidence — so this exists to stop
/// that requirement from being a reason the whole screen is iOS-only.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// How long a copied credential stays on the pasteboard.
    static let sensitiveLifetime: TimeInterval = 120

    /// COPY A CREDENTIAL. Not the same operation as `copy`, and it must not
    /// share its implementation.
    ///
    /// `UIPasteboard.general.string = key` is a Handoff broadcast. The general
    /// pasteboard is the Universal Clipboard: the value leaves the device over
    /// the network to every Mac and iPad signed into the same Apple Account
    /// and sits there, in the clear, until something else is copied — which on
    /// a rarely-used iPad can be days. An API key that the user typed into a
    /// SecureField, and that the app otherwise keeps in the Keychain, should
    /// not be the one thing that walks off the device.
    ///
    /// Two bounds, both cheap:
    /// - `.localOnly` keeps it on THIS device — no Universal Clipboard, no
    ///   Handoff. Pasting into another app here, which is the entire point of
    ///   a copy button, still works.
    /// - `.expirationDate` clears it after two minutes, so a key does not
    ///   outlive the paste it was copied for.
    ///
    /// The single choke point for both key-copy call sites (provider editor,
    /// search settings). New credential copies go through here.
    static func copySensitive(_ string: String) {
        #if os(macOS)
        // No public opt-out of Universal Clipboard on macOS. `ConcealedType` is
        // the cross-app convention (password managers set it) that tells
        // clipboard-history utilities not to record the value.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .init("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: string]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(sensitiveLifetime)
            ]
        )
        #endif
    }
}

enum PointerVerb {
    /// "tap" / "click"
    static var act: String {
        #if os(macOS)
        "click"
        #else
        "tap"
        #endif
    }

    /// "double tap" / "double-click"
    static var actTwice: String {
        #if os(macOS)
        "double-click"
        #else
        "double tap"
        #endif
    }
}

/// CONTROL SIZE, WHICH IS SET BY THE POINTING DEVICE AND NOT BY TASTE.
///
/// Every number on the iOS side of this was chosen for a fingertip. A finger has
/// a contact patch about 44pt across and cannot see what it is covering, so iOS
/// controls are large and generously spaced. A pointer is one pixel, is visible
/// at all times, and is driven by an arm resting on a desk — so Mac controls are
/// smaller, denser, and set in smaller type. Shipping the phone's metrics to a
/// Mac does not read as "spacious", it reads as an app built for something else.
///
/// This is the specific thing that made teemoon's Mac window read as a port even
/// after the menus, keyboard and window chrome were right: a 44pt model chip and
/// 15.5pt sidebar rows next to a 13pt system font.
///
/// Reference points, measured against Apple's own apps rather than invented:
/// Mail and Notes set sidebar row titles at 13pt with an 11pt preview line;
/// standard Mac push buttons and pills are 28pt tall (`.regular` control size).
enum ControlMetrics {
    /// Height of a pill-shaped control — the Where chip, the web-search chip.
    static var pillHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    /// Horizontal padding inside those pills.
    static var pillHorizontalPadding: CGFloat {
        #if os(macOS)
        10
        #else
        14
        #endif
    }

    /// Sidebar row: the conversation's first line.
    static var sidebarTitleSize: CGFloat {
        #if os(macOS)
        13
        #else
        15.5
        #endif
    }

    /// Sidebar row: the reply preview under it.
    static var sidebarPreviewSize: CGFloat {
        #if os(macOS)
        11.5
        #else
        13.5
        #endif
    }

    /// Sidebar row: the date on the trailing edge.
    static var sidebarDateSize: CGFloat {
        #if os(macOS)
        11
        #else
        12
        #endif
    }

    // MARK: - Where sheet rows
    //
    // The sheet kept phone metrics after the rest of the app moved, and it was
    // not only a look. The sheet is 560pt; at phone row heights its content runs
    // to 606pt, so `add a cloud key` sat entirely below the fold — measured at
    // zero points visible, reachable only by scrolling a sheet that gives no
    // sign there is anything under it.
    //
    // Shrinking the rows is therefore both the design fix and the overflow fix.

    /// Where-sheet row: the model or action name.
    static var sheetRowTitleSize: CGFloat {
        #if os(macOS)
        13
        #else
        16
        #endif
    }

    /// The fixed line box that keeps a row from resizing mid-download.
    static var sheetRowTitleLineHeight: CGFloat {
        #if os(macOS)
        17
        #else
        21
        #endif
    }

    /// Where-sheet row: the metadata line under the title.
    static var sheetRowCaptionSize: CGFloat {
        #if os(macOS)
        11.5
        #else
        13
        #endif
    }

    /// Minimum height of that single-line caption box.
    static var sheetRowCaptionLineHeight: CGFloat {
        #if os(macOS)
        14
        #else
        17
        #endif
    }

    /// `ready now` / `get`. A Mac section header is small, semibold and
    /// letterspaced — not a 15pt bold line the size of the rows beneath it.
    static var sheetSectionHeaderSize: CGFloat {
        #if os(macOS)
        11
        #else
        15
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The leading slot of the navigation bar (iOS) / window toolbar (macOS).
    ///
    /// `.topBarLeading` is unavailable on macOS — a compile error, since there
    /// is no top bar to be leading in. `.navigation` is the AppKit equivalent:
    /// the leading region of the window toolbar, where a close or back control
    /// belongs.
    ///
    /// This exists as a placement rather than a `#if` at the call site so the
    /// iOS value stays literally `.topBarLeading` — unchanged, not approximated
    /// by something that merely lands in the same place today. The trailing
    /// counterpart can follow the same shape if a `.topBarTrailing` site ever
    /// needs to build on macOS; every one of them is inside `#if os(iOS)` today.
    static var barLeading: ToolbarItemPlacement {
        #if os(macOS)
        return .navigation
        #else
        return .topBarLeading
        #endif
    }
}

extension View {
    /// The grouped-list look teemoon's settings, sheets and model browsers use.
    ///
    /// `.insetGrouped` is unavailable on macOS — a hard compile error, not a
    /// style that silently falls back. `.inset` is the closest AppKit-backed
    /// equivalent: inset rows with the same section grouping, minus the rounded
    /// card iOS draws around each group.
    ///
    /// Deliberately NOT `.sidebar`, even though `ChatsListView` maps to that.
    /// The chat list is genuinely a sidebar on a Mac — a persistent navigation
    /// column — so it gets sidebar affordances on purpose, and it keeps its own
    /// explicit `#if`. These lists are CONTENT, and styling them as sidebars
    /// would give settings rows selection highlighting they should not have.
    func groupedListStyle() -> some View {
        #if os(macOS)
        return listStyle(.inset)
        #else
        return listStyle(.insetGrouped)
        #endif
    }

    /// Tighten the gap below a section, where the platform can express it.
    ///
    /// `listSectionSpacing` is iOS-only. macOS grouped lists do not run the
    /// oversized inter-section gap this exists to correct, so the honest macOS
    /// behaviour is to leave the default alone rather than approximate it with
    /// manual padding that would then be wrong in the other direction.
    func compactSectionSpacing() -> some View {
        #if os(macOS)
        return self
        #else
        return listSectionSpacing(.compact)
        #endif
    }
}
