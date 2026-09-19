//
//  SharedURLCache.swift
//  teemoon
//
//  `URLSession.shared` and every `.default` session read `URLCache.shared`
//  live, and with the default disk-backed cache CFNetwork archives cacheable
//  responses together with the request that produced them — Authorization
//  header included. Nothing the app fetches wants a persistent cache, so the
//  shared cache is zero-capacity for the life of the process. Keep `disable()`
//  the first call in `TeemoonApp.init`; do not give any session its own
//  disk-backed `urlCache`.
//

import Foundation

enum SharedURLCache {
    /// Empties what builds up to 1.0.2 wrote (without opening it — instantiating
    /// the default cache creates the store it is about to discard), then swaps
    /// in a cache that stores nothing.
    static func disable() {
        removeDefaultStore()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    /// Library/Caches/<bundle id>/ — the default `URLCache` location. Only the
    /// cache's own files go; the directory also holds unrelated system caches.
    static var defaultStoreFiles: [URL] {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier else { return [] }
        let dir = caches.appending(path: bundle)
        return ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"].map { dir.appending(path: $0) }
    }

    private static func removeDefaultStore() {
        for url in defaultStoreFiles where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
