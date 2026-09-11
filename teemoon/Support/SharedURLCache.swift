//
//  SharedURLCache.swift
//  teemoon
//
//  Every authenticated fetch outside the chat request — attestation reports,
//  the per-reply signature, key checks, model catalogs, endpoint probes, web
//  search — goes through `URLSession.shared` or a `.default` session. Both
//  use `URLCache.shared`, and with its default disk store CFNetwork archives
//  each cacheable response together with the request that produced it,
//  `Authorization` header included, into Library/Caches/<bundle>/Cache.db.
//  The teemoonai/audits runtime pass on 1.0.2 found the near.ai key there nine
//  times after one session (client/teemoon-ios/v1.0.2-21d534e.md, MEDIUM).
//
//  Nothing the app fetches benefits from a persistent cache: attestation
//  reports carry fresh nonces, catalogs and the audit index keep their own
//  copies in UserDefaults, and the chat request already runs on an ephemeral
//  session. So the shared cache is replaced with a zero-capacity one before
//  any session exists, and the on-disk store it would have used is emptied.
//

import Foundation

enum SharedURLCache {
    /// Must run before the first access to `URLSession.shared` or the first
    /// `URLSessionConfiguration.default` — both capture `URLCache.shared` when
    /// they are created. `TeemoonApp.init` calls this first.
    static func disable() {
        // Empty the store the previous builds wrote to, then stop using it.
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    /// Belt for the key-change and key-removal paths: nothing should be cached
    /// after `disable()`, and this keeps that true even if a session was
    /// created earlier than intended.
    static func purge() {
        URLCache.shared.removeAllCachedResponses()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
    }
}
