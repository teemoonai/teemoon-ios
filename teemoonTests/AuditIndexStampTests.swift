import Foundation
import Testing
@testable import teemoon

@Suite("AuditIndexStamp")
struct AuditIndexStampTests {

    @Test func missingIndexProducesNoStamp() {
        #expect(AuditIndexStamp.make(
            hasIndex: false, updated: "2026-01-01", loadedAt: Date(), now: Date()) == nil)
    }

    @Test func unknownFetchAgeIsStale() {
        let stamp = AuditIndexStamp.make(
            hasIndex: true, updated: "2026-08-01", loadedAt: nil, now: Date())
        #expect(stamp?.stale == true)
        #expect(stamp?.text.contains("fetch age unknown") == true)
        #expect(stamp?.text.contains("verdicts may lag") == true)
    }

    @Test func emptyUpdatedReadsUnknown() {
        let stamp = AuditIndexStamp.make(
            hasIndex: true, updated: "", loadedAt: nil, now: Date())
        #expect(stamp?.text.contains("updated unknown") == true)
    }

    @Test func olderThanADayIsStale() {
        let now = Date()
        let stamp = AuditIndexStamp.make(
            hasIndex: true,
            updated: "2026-08-01",
            loadedAt: now.addingTimeInterval(-(AuditIndexStamp.staleAfter + 1)),
            now: now)
        #expect(stamp?.stale == true)
        #expect(stamp?.text.contains("verdicts may lag") == true)
        #expect(stamp?.text.contains("cached") == true)
    }

    @Test func freshIndexIsNotStale() {
        let now = Date()
        let stamp = AuditIndexStamp.make(
            hasIndex: true,
            updated: "2026-08-24",
            loadedAt: now.addingTimeInterval(-60),
            now: now)
        #expect(stamp?.stale == false)
        #expect(stamp?.text.contains("2026-08-24") == true)
        #expect(stamp?.text.contains("refreshed") == true)
    }
}
