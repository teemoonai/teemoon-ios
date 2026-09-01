//
//  WhereLocality.swift
//  teemoon
//
//  Where inference runs, as a continuum — not a vendor list. Pure classification
//  over Provider; lives with Provider so the store can filter recents without
//  importing Presentation.
//
//  Related: Provider, WhereProviderPresentation, WhereSheetView.
//

import Foundation

/// Where a configured provider actually runs. The continuum, not a vendor list.
enum WhereLocality: String, CaseIterable, Identifiable, Hashable {
    /// Weights on the phone, run by LiteRT. Nothing leaves the device.
    case phone
    /// A computer the user owns (LAN / Tailscale / Ollama).
    case home
    /// Cloud API (near.ai, BYOK, …).
    case cloud

    var id: String { rawValue }

    /// List order, taken from the declaration order — which is also the order
    /// the segmented control renders, because it builds from `allCases`.
    ///
    /// Deriving it rather than writing a second switch is the point: the picker
    /// reads phone · home · cloud, so the rows below it read phone · home ·
    /// cloud, and neither can drift from the other.
    var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    var shortLabel: String {
        switch self {
        case .phone: return "phone"
        case .home:  return "home"
        case .cloud: return "cloud"
        }
    }

    var systemImage: String {
        switch self {
        case .phone: return "iphone"
        case .home:  return "desktopcomputer"
        case .cloud: return "cloud"
        }
    }

    /// Classifies a saved provider: on-device → phone, a host on your own
    /// network → home, everything else → cloud.
    ///
    /// `isLocal` MUST be checked before `isSelfHosted`, and cannot be replaced
    /// by it. `Provider.local` carries `endpoint: "on-device"`, which is not a
    /// URL, so it has no host and `isSelfHosted` is false — an on-device model
    /// tested as CLOUD, the most private place teemoon can run rated as the
    /// least. `E2EETitleBlock` hit the identical bug one tier down; the two
    /// surfaces have to agree.
    static func of(_ provider: Provider) -> WhereLocality {
        if provider.isLocal { return .phone }
        return provider.isSelfHosted ? .home : .cloud
    }

    /// The setups "places & keys" actually MANAGES: home machines and cloud
    /// keys, never the phone.
    ///
    /// `PlacesKeysHubView` deliberately has no "on this phone" row — a
    /// downloaded model has no key and no host to delete, so it does not belong
    /// on a screen about places you connect to and the credentials that open
    /// them. But Settings' badge counted `providers.count`, phone included, so
    /// it read "4 setups" over a screen that could only ever show three.
    ///
    /// Lives here, and is used by both, so the badge and the screen cannot
    /// disagree about what a setup is.
    static func managed(in providers: [Provider]) -> [Provider] {
        providers.filter { of($0) != .phone }
    }
}

extension Provider {
    /// One fixed id, no catalog (Brave Answers). Not a browse row.
    var isFixedAnswerService: Bool {
        answersSingleTurnOnly && hasBuiltInGrounding
    }

    /// Large multi-vendor routers that need search-first browse.
    var prefersSearchFirstBrowse: Bool {
        let host = openAIBaseURL?.host?.lowercased() ?? endpoint.lowercased()
        return host.contains("openrouter")
    }
}
