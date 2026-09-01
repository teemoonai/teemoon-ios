//
//  ProvidersSettingsView.swift
//  teemoon
//
//  Compatibility shim — the old “providers” list was a daily picker.
//  Management now lives under PlacesKeysHubView (places & keys).
//  Kept so older navigation/tests that name this type still compile.
//

import SwiftUI

/// Forwards to the places & keys hub. Prefer `PlacesKeysHubView` in new code.
typealias ProvidersSettingsView = PlacesKeysHubView
