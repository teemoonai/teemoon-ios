//
//  LocalWarmUpPolicy.swift
//  teemoon
//

import Foundation

/// Whether picking a provider should start loading an on-device engine, and
/// which one. Cloud and home providers never; an on-device model only when
/// its bundle is on disk — a selection is the earliest honest signal it is
/// about to be used, and the load then overlaps the user typing instead of
/// landing on the first token. See LocalWarmUpPolicyTests.
enum LocalWarmUpPolicy {
    static func target(for provider: Provider?,
                       installed: (String) -> LocalModelRef? = LocalModelStorage.ref(for:)) -> LocalModelRef? {
        guard let provider, let id = provider.localModelID else { return nil }
        return installed(id)
    }
}
