//
//  Appearance.swift
//  teemoon
//
//  User-configurable appearance options and platform color helpers.
//

import SwiftUI

enum PlatformColors {
    /// The background content sits on: the chat transcript, sheets, the fades
    /// that dissolve scrolled content into the surface behind it.
    ///
    /// `Color(.systemBackground)` cannot be written at the use site because the
    /// leading dot resolves against `UIColor` on iOS/visionOS and `NSColor` on
    /// macOS — and `NSColor` has no `systemBackground`. That is a compile error,
    /// not a fallback, so every unguarded use broke the macOS build.
    ///
    /// macOS maps to `textBackgroundColor`, not `windowBackgroundColor`: this is
    /// the surface *content* is drawn on (white in light, near-black in dark),
    /// whereas `windowBackgroundColor` is the grey of window chrome. The chat
    /// transcript is a content surface, so `textBackgroundColor` is the honest
    /// analogue — and it keeps the gradient fades in `ChatView` matching the
    /// transcript they fade into, which is what those call sites depend on.
    ///
    /// visionOS deliberately shares the iOS value rather than getting a branch:
    /// it is UIKit there too, so this is exactly the colour that platform
    /// already resolved before macOS forced the indirection. No behaviour change.
    static let background: Color = {
        #if os(macOS)
        return Color(NSColor.textBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }()

    static let secondaryBackground: Color = {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(visionOS)
        return Color(UIColor.separator)
        #elseif os(macOS)
        return Color(NSColor.secondarySystemFill)
        #endif
    }()

    /// The RAISED sibling of `secondaryBackground` — the "on" state of a toggle
    /// chip, a control that has come forward.
    ///
    /// macOS maps to `systemFill`, NOT `tertiarySystemFill`, and the inversion
    /// is the whole point. iOS runs two ladders that go opposite ways:
    ///
    ///   backgrounds, dark mode:  system #000 < secondary #1C1C1E < tertiary #2C2C2E
    ///                            → tertiary is the LIGHTEST
    ///   fills, dark mode:        system .36α > secondary .32α > tertiary .24α
    ///                            → system is the LIGHTEST
    ///
    /// `secondaryBackground` already maps onto `secondarySystemFill`. Mapping
    /// `tertiarySystemBackground` onto `tertiarySystemFill` would look like the
    /// tidy parallel and would be wrong: tertiary-fill is DIMMER than
    /// secondary-fill, so the raised state would render darker than the resting
    /// one and the toggle in `WebSearchChip` would read inside-out. `systemFill`
    /// is the fill that sits brighter than `secondarySystemFill`, which is the
    /// relationship the call site actually depends on.
    static let tertiaryBackground: Color = {
        #if os(macOS)
        return Color(NSColor.systemFill)
        #else
        return Color(UIColor.tertiarySystemBackground)
        #endif
    }()

    /// Hairline dividers and stroked borders.
    ///
    /// A plain spelling difference, not a design decision: UIKit calls it
    /// `separator`, AppKit calls it `separatorColor`, and the leading-dot form
    /// at a use site resolves against whichever class the platform picked — so
    /// `Color(.separator)` is a macOS compile error rather than a fallback.
    static let separator: Color = {
        #if os(macOS)
        return Color(NSColor.separatorColor)
        #else
        return Color(UIColor.separator)
        #endif
    }()

    /// Sheet chrome (the where sheet's reasoning bar): halfway between a grouped sheet's ground and its card fill,
    /// one step off each, solid so rows scrolling under it don't tint it. Android's sheetBand, the same values.
    static let sheetBand: Color = dynamic(light: (249 / 255, 249 / 255, 251 / 255),
                                          dark: (36 / 255, 36 / 255, 38 / 255))

    /// A colour that resolves against the live appearance, light or dark.
    ///
    /// Both platforms support this and neither shares an API for it: UIKit hands
    /// the trait collection to a closure, AppKit hands it an `NSAppearance` and
    /// wants the pair of names it is allowed to match against. Channels are sRGB
    /// on both sides, so the same literals mean the same colour.
    static func dynamic(light: (Double, Double, Double),
                        dark: (Double, Double, Double)) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

// MARK: - Verification tokens

// THESE ARE DESIGN TOKENS AND DO NOT BELONG BEHIND A PLATFORM GUARD.
//
// They used to live inside `#if os(iOS)` in E2EETitleBlock.swift, because the
// attestation sheet that consumes them is iOS-only and the UIKit dynamic-colour
// initialiser they were written with is too. That conflated two different
// things. The trust-ladder UI genuinely is iOS-only for now — TrustLadderView,
// VerificationRunView, TrustLadder and CodeBlock account for 34 of the 36 uses
// and all of them sit inside the guard. But the add-provider form is NOT gated
// and uses them too, so on macOS the token vanished while its consumer compiled,
// and every reference failed with "cannot find 'teeVerified' in scope".
//
// The colour of "a proof ran and held" is not an iOS fact. It moves here, next
// to the other tokens, and resolves on every platform; the iOS-only SHEETS stay
// iOS-only. Same values as before, light and dark both.

/// The verification green (≈ #30d158): a proof ran and held. Everything that is
/// not verified stays gray — this colour is never decorative.
let teeVerified = PlatformColors.dynamic(
    light: (0.22, 0.56, 0.38),
    dark:  (0.36, 0.78, 0.55)
)

/// The same signal as a background wash rather than a foreground: capsule fills
/// and section tints behind `teeVerified` text.
let teeVerifiedSoft = PlatformColors.dynamic(
    light: (0.92, 0.97, 0.94),
    dark:  (0.10, 0.20, 0.14)
)

enum AppTintColor: String, CaseIterable {
    case monochrome, blue, brown, gray, green, indigo, mint, orange, pink, purple, red, teal, yellow

    func getColor() -> Color {
        switch self {
        case .monochrome:
            .primary
        case .blue:
            .blue
        case .red:
            .red
        case .green:
            .green
        case .yellow:
            .yellow
        case .brown:
            .brown
        case .gray:
            .gray
        case .indigo:
            .indigo
        case .mint:
            .mint
        case .orange:
            // teemoon's own orange, NOT SwiftUI's.
            //
            // `Color.orange` is #FF9F0A; `ML.accent` is #FF7A1A. Close enough
            // that showing both reads as a mistake rather than a system — and
            // both WOULD show, since ML.accent is used by the trust ladder and
            // by the Where chip's unconfigured state. One orange in the
            // product, defined once.
            ML.accent
        case .pink:
            .pink
        case .purple:
            .purple
        case .teal:
            .teal
        }
    }

    #if os(iOS)
    /// UIKit-drawn controls (menu pickers, edit menus, alerts) take the window's tint, not
    /// SwiftUI's `.tint`; left alone that is the orange AccentColor asset whatever was picked.
    @MainActor func applyToWindows() {
        let color = self == .monochrome ? UIColor.label : UIColor(getColor())
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            window.tintColor = color
        }
    }
    #endif
}

enum AppFontDesign: String, CaseIterable {
    case standard, monospaced, rounded, serif

    func getFontDesign() -> Font.Design {
        switch self {
        case .standard:
            .default
        case .monospaced:
            .monospaced
        case .rounded:
            .rounded
        case .serif:
            .serif
        }
    }
}

enum AppFontWidth: String, CaseIterable {
    case compressed, condensed, expanded, standard

    func getFontWidth() -> Font.Width {
        switch self {
        case .compressed:
            .compressed
        case .condensed:
            .condensed
        case .expanded:
            .expanded
        case .standard:
            .standard
        }
    }
}

/// Settings → appearance → size: steps relative to the phone's text size, so Dynamic Type still works under every
/// choice. `system` is the phone's own; it stores "large", the name builds before 1.1.0 wrote for the same step.
enum AppFontSize: String, CaseIterable {
    case xsmall, small, medium, system = "large", xlarge

    private var offset: Int {
        switch self {
        case .xsmall: -3
        case .small: -2
        case .medium: -1
        case .system: 0
        case .xlarge: 1
        }
    }

    /// The step to draw at when the phone is at `phone`, clamped to the range SwiftUI has.
    func dynamicTypeSize(phone: DynamicTypeSize) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        let i = (all.firstIndex(of: phone) ?? all.firstIndex(of: .large)!) + offset
        return all[min(max(i, 0), all.count - 1)]
    }
}

/// Applies the size setting on top of the phone's. Reads the phone's size from the app, not the environment: a
/// sheet inherits the size its presenter already set, and reading that would apply the offset twice.
struct AppTextSize: ViewModifier {
    let size: AppFontSize
    @State private var phone = Self.phoneSize()

    func body(content: Content) -> some View {
        content
            .environment(\.dynamicTypeSize, size.dynamicTypeSize(phone: phone))
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)) { _ in
                phone = Self.phoneSize()
            }
            #endif
    }

    @MainActor static func phoneSize() -> DynamicTypeSize {
        #if os(iOS)
        DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large
        #else
        .large
        #endif
    }
}

extension View {
    func appTextSize(_ size: AppFontSize) -> some View { modifier(AppTextSize(size: size)) }

    /// The design's point size at the default text setting, growing with the phone's setting (and the size step
    /// above) like `style` does. Words people read use this or a text style, never a bare `.system(size:)`.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    relativeTo style: Font.TextStyle? = nil) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design,
                                  style: style ?? ScaledText.nearestStyle(to: size)))
    }

    /// `lineLimit(lines)` at the ordinary sizes; at the accessibility sizes the text wraps instead of truncating.
    func lineLimitGrowing(_ lines: Int) -> some View { modifier(GrowingLineLimit(lines: lines)) }

    /// A minimum height that holds one line of `style` text, growing with it.
    func scaledMinHeight(_ height: CGFloat, relativeTo style: Font.TextStyle, alignment: Alignment = .center) -> some View {
        modifier(ScaledMinHeight(height: height, style: style, alignment: alignment))
    }
}

/// Plain rules behind `scaledFont` and `lineLimitGrowing`.
enum ScaledText {
    /// iOS default (`.large`) point sizes, smallest first.
    static let defaultSizes: [(Font.TextStyle, CGFloat)] = [
        (.caption2, 11), (.caption, 12), (.footnote, 13), (.subheadline, 15), (.callout, 16), (.body, 17),
        (.title3, 20), (.title2, 22), (.title, 28), (.largeTitle, 34),
    ]

    /// The text style whose default size is closest to `size`, so it scales the way a style of that size would.
    static func nearestStyle(to size: CGFloat) -> Font.TextStyle {
        defaultSizes.min { abs($0.1 - size) < abs($1.1 - size) }!.0
    }

    /// Three times the lines at the accessibility sizes: a name that fit one line no longer does.
    static func lineLimit(_ lines: Int, at size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? lines * 3 : lines
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

private struct ScaledMinHeight: ViewModifier {
    @ScaledMetric private var height: CGFloat
    private let alignment: Alignment

    init(height: CGFloat, style: Font.TextStyle, alignment: Alignment) {
        _height = ScaledMetric(wrappedValue: height, relativeTo: style)
        self.alignment = alignment
    }

    func body(content: Content) -> some View { content.frame(minHeight: height, alignment: alignment) }
}

private struct GrowingLineLimit: ViewModifier {
    let lines: Int
    @Environment(\.dynamicTypeSize) private var size

    func body(content: Content) -> some View {
        content.lineLimit(ScaledText.lineLimit(lines, at: size))
    }
}

/// The device's layout class, replacing per-object idiom lookups.
enum DeviceLayout {
    case mac, phone, pad, vision, unknown

    @MainActor
    static var current: DeviceLayout {
        #if os(visionOS)
        return .vision
        #elseif os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
        return .unknown
        #endif
    }
}
