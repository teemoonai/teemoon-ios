//
//  MainThreadHangReporterTests.swift
//  teemoonTests
//
//  The 2026-08-15 UI-test crash: SIGPROF allocated a Swift Array inside the
//  handler (`gHangFrames` lazy init → objc_readClassPair → recursive
//  unfair-lock abort). The handler must run against a preallocated C buffer.
//

#if DEBUG
import Testing
@testable import teemoon

@Suite("MainThreadHangReporter")
struct MainThreadHangReporterTests {

    @Test func signalHandlerDoesNotAllocateASwiftArray() {
        let frames = MainThreadHangReporter.captureOnceForTesting()
        #expect(frames > 0, "preallocated backtrace buffer should already hold this call")
        // A second capture must also work — the first call used to be the
        // crash (lazy Array init), the second would have been fine.
        let again = MainThreadHangReporter.captureOnceForTesting()
        #expect(again > 0)
    }
}
#endif
