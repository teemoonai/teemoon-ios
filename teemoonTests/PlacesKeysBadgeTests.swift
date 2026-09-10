import Testing
@testable import teemoon

/// The "cloud keys" badge reports KEYS. A tester's hub read "1" for a Brave
/// Answers setup that had no key, and her next message went out with no
/// auth header (see `SendPrepTests.noKeyBlocksAfterNoProviderAndBeforeTrust`).
@Suite("Places & keys badge")
struct PlacesKeysBadgeTests {

    @Test func countsKeysNotRecords() {
        #expect(PlacesKeysBadge.cloud(keyed: 0, unkeyed: 0) == "none")
        #expect(PlacesKeysBadge.cloud(keyed: 0, unkeyed: 1) == "1 needs key")
        #expect(PlacesKeysBadge.cloud(keyed: 0, unkeyed: 2) == "2 need keys")
        #expect(PlacesKeysBadge.cloud(keyed: 2, unkeyed: 0) == "2")
        #expect(PlacesKeysBadge.cloud(keyed: 1, unkeyed: 1) == "1 · 1 needs key")
        #expect(PlacesKeysBadge.cloud(keyed: 2, unkeyed: 3) == "2 · 3 need keys")
    }
}
