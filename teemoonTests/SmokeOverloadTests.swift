//
//  SmokeOverloadTests.swift
//  teemoonTests
//
//  When a live smoke call counts as "provider overloaded" (pm 2026-11-13): http 429 or 503 whose body says overloaded
//  or retry. Those are retried, then recorded as a named skip; anything else still fails.
//

import Testing
@testable import teemoon

@Suite("Smoke overload")
struct SmokeOverloadTests {

    @Test func a429OrA503SayingOverloadedOrRetryIsAnOverload() {
        #expect(SmokeOverload.status(
            in: "near.ai (http 429): The service is temporarily overloaded. Please retry with exponential backoff.") == 429)
        #expect(SmokeOverload.status(in: "Fireworks (http 503): service overloaded, please try again later") == 503)
        #expect(SmokeOverload.status(in: "Grok (http 503): Retry later") == 503)
    }

    @Test func anythingElseIsNot() {
        #expect(SmokeOverload.status(in: "near.ai (http 429): rate limit exceeded for this key") == nil,
                "a 429 that names no overload is a real limit: it fails")
        #expect(SmokeOverload.status(in: "Fireworks (http 500): internal error, overloaded") == nil, "only 429 and 503")
        #expect(SmokeOverload.status(in: "near.ai (http 401): unauthorized") == nil)
        #expect(SmokeOverload.status(in: "decode failed: overloaded") == nil, "no status")
    }

    @Test func theBackoffIsTwoFourEight() {
        #expect(SmokeOverload.backoffSeconds == [2, 4, 8])
    }

    /// A provider outage (pm 2026-11-13): 502, 503 or 504 saying unavailable, overloaded or try again.
    @Test func a502To504SayingUnavailableIsAnOutageToo() {
        #expect(SmokeOverload.status(
            in: "near.ai (http 502): The model is currently unavailable. Please try again later.") == 502)
        #expect(SmokeOverload.status(in: "Fireworks (http 504): gateway timeout, try again") == 504)
        #expect(SmokeOverload.status(in: "near.ai (http 502): bad gateway") == nil, "a 502 that names no outage fails")
        #expect(SmokeOverload.status(in: "near.ai (http 500): currently unavailable") == nil, "500 still fails")
    }

    /// The live near.ai E2E test is a trust check: an outage may skip it only before any reply was verified; after a
    /// verified turn, or on any verification failure, it fails (pm 2026-11-13).
    @Test func anOutageSkipsATrustCheckOnlyBeforeAnythingWasVerified() {
        let outage = "near.ai (http 502): The model is currently unavailable. Please try again later."
        #expect(SmokeOverload.outageBeforeVerification(verifiedTurns: 0, message: outage) == 502)
        #expect(SmokeOverload.outageBeforeVerification(verifiedTurns: 1, message: outage) == nil,
                "a 502 after a verified turn fails")
        #expect(SmokeOverload.outageBeforeVerification(verifiedTurns: 0, message: "reply signature does not check out") == nil,
                "a verification failure is never an outage")
    }
}
