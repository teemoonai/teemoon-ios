//
//  CellularDownloadGate.swift
//  teemoon
//
//  Whether tapping "download" on a model bundle starts it or asks first.
//
//  The iOS convention for multi-gigabyte downloads: on Wi-Fi they start, and
//  pause if the phone leaves Wi-Fi; on mobile data the user is asked, and may
//  choose to wait for Wi-Fi instead. Nothing here presents UI — the Where sheet
//  and the chat's restart button switch on the result.
//

import Foundation

enum CellularDownloadGate {

    /// Why the tap is being questioned; picks the alert copy.
    enum Reason: Equatable, Sendable {
        /// Cellular or a personal hotspot.
        case mobileData
        /// Low Data Mode is on — the user asked for less traffic, on any interface.
        case lowDataMode
    }

    enum Decision: Equatable, Sendable {
        /// Start now, under this allowance.
        case download(DownloadNetwork)
        /// Ask first. The answer becomes a `DownloadNetwork`, or nothing.
        case ask(Reason)
    }

    /// A download the user just asked for, on the current path.
    ///
    /// Started on Wi-Fi it is Wi-Fi-only: walking out of the house pauses it
    /// rather than moving gigabytes onto the plan without a word.
    ///
    /// `pathIsExpensive` is `NetworkPathObserver.isMobileData` — the cellular
    /// radio OR iOS's expensive flag — never the flag alone: a phone on an
    /// unlimited plan reports cellular as `expensive=false`.
    static func decision(pathIsExpensive: Bool, pathIsConstrained: Bool) -> Decision {
        if pathIsExpensive { return .ask(.mobileData) }
        if pathIsConstrained { return .ask(.lowDataMode) }
        return .download(.wifiOnly)
    }

    /// A running download's row label. `nil` means "show progress as usual".
    ///
    /// Keyed on the downloader's own `parked` state and nothing else: reading
    /// the live path here made the label flicker through every few-second
    /// route blip that the downloader deliberately waits out.
    static func waitingLabel(network: DownloadNetwork, parked: Bool) -> String? {
        guard network == .wifiOnly, parked else { return nil }
        return "waiting for wi-fi"
    }

    /// Alert copy for `.ask`.
    static func title(for reason: Reason) -> String {
        switch reason {
        case .mobileData: return "download over mobile data?"
        case .lowDataMode: return "low data mode is on"
        }
    }

    static func message(for reason: Reason, model: LocalModel) -> String {
        switch reason {
        case .mobileData:
            return "\(model.displayName) is a \(model.sizeLabel) download. It can wait until you're on wi-fi."
        case .lowDataMode:
            return "\(model.displayName) is a \(model.sizeLabel) download. It can wait until you're on an unrestricted connection."
        }
    }
}
