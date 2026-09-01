//
//  PerformanceBenchmarks.swift
//  teemoonTests
//
//  XCTest `measure {}` regression benchmarks for the hot paths identified in
//  the 2026-07 performance pass. All benchmarks are
//  deterministic and offline — fixture data only, never the network — so they
//  can run in CI and pin regressions.
//
//  XCTest (not Swift Testing) because `measure {}` is an XCTest facility;
//  both frameworks coexist in this target.
//

import XCTest
import SwiftUI
import SwiftData
import CryptoKit
@testable import teemoon

@MainActor
final class PerformanceBenchmarks: XCTestCase {

    // MARK: - Fixtures

    /// A fully-verified session populated from static preview fixtures,
    /// built WITHOUT triggering the live attestation pipeline: the session is
    /// created before the provider becomes active, so `refreshAttestation()`
    /// in init no-ops (no active provider → no network task).
    static func offlineVerifiedSession() -> (ConfidentialSession, ProviderStore) {
        let store = ProviderStore(inMemory: true)
        let provider = Provider.nearAI
        store.addProvider(provider)
        let session = ConfidentialSession(providers: store)
        // Activate after init; the onActiveProviderChanged hook is unset in
        // tests, so no refresh (and no network) fires.
        store.currentProviderID = provider.id.uuidString
        session.attestation = .preview
        var dcap = RecordDCAPVerification()
        dcap.gateway = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        dcap.model = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
        session.dcapVerification = dcap
        session.gpuAttestation = .verified
        session.tlsAttestation = .verified
        let cloudAPI = ProvenanceService.ImageRef(
            image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64),
            sourceRepo: "https://github.com/nearai/private-ml-sdk",
            sourceRef: "refs/tags/v0.5.1",
            sourceCommit: "84367f0253fa94aa6816d64210e5812215ee2622",
            hosts: ["gateway"])
        let mesh = ProvenanceService.ImageRef(
            image: "nearaidev/dstack-vpc", digest: String(repeating: "c", count: 64),
            sourceRepo: "https://github.com/nearai/dstack-vpc",
            sourceRef: "refs/heads/main",
            sourceCommit: "1234abc9253fa94aa6816d64210e5812215ee262",
            hosts: ["gateway", "model"])
        let sidecar = ProvenanceService.ImageRef(
            image: "datadog/agent", digest: String(repeating: "b", count: 64))
        session.imageProvenance = .allVerified(verified: [cloudAPI, mesh], thirdParty: [sidecar])
        session.modelLayerVerification = .verified
        session.modelArtifact = ModelArtifact(
            modelPath: "QuantTrio/GLM-5.1-AWQ",
            revision: "8f60817aa28023f2607850d1a1e51d21aa34817a",
            servedName: "zai-org/GLM-5.1-FP8",
            quant: "AWQ")
        session.verifiedResponseCount = 3
        // THE INNER COMPOSE, AT THE SIZE THE SERVICE ACTUALLY SERVES IT.
        //
        // Without this the fixture's `exposure` is nil, the recipe
        // classification loop in `enclaveGroup` never runs, and these
        // benchmarks measure a version of the screen that does not exist in
        // production. That omission is why they reported 33 ms for a sheet
        // that took FIVE SECONDS to open on device (2026-08-22, main-thread
        // stacks in hangstacks.log): the cost is per-image regex over this
        // document, and there was no document.
        session.modelLayerManifest = Self.realisticInnerCompose()
        return (session, store)
    }

    /// ~16 KB over ten digest-pinned services, with the label noise near.ai's
    /// real compose carries \u{2014} sized against a live
    /// `glm-5-2.completions.near.ai` report: 16,168 characters.
    static func realisticInnerCompose() -> String {
        var yaml = "services:\n"
        for i in 0..<10 {
            let digest = String(format: "%064x", i &* 0x9E3779B9 &+ 0xABCDEF)
            yaml += "  service-\(i):\n"
            yaml += "    image: nearaidev/component-\(i)@sha256:\(digest)\n"
            yaml += "    container_name: component-\(i)\n"
            yaml += "    command: [\"--config=/etc/component-\(i)/config.yaml\"]\n"
            yaml += "    labels:\n"
            // The labels are the point: the real document is saturated with
            // them, which is why classification may never be a name substring.
            for j in 0..<14 {
                yaml += "      nearai.otel.attribute.\(j): \"service-\(i)-value-\(j)-padding-pad\"\n"
                yaml += "      com.datadoghq.tags.\(j): \"env:prod,service:component-\(i),v:\(j)\"\n"
            }
        }
        return yaml
    }

    private func verifiedSummary() -> AttestationSummary {
        AttestationSummary(
            attestation: .preview, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: true, lastE2EEFailReason: nil,
            verifiedResponseCount: 3, mismatchedResponseCount: 0,
            attestationFetchFailed: false)
    }

// UIKIT-HOSTED RENDER BENCHMARKS ARE iOS-ONLY, AND ONLY THESE ARE.
//
// They measure a SwiftUI tree laid out inside a real UIWindow, and the view they
// host (TrustLadderView) is itself inside `#if os(iOS)`. There is no macOS
// equivalent to port: NSWindow would measure AppKit's layout of a view that does
// not exist there, which is a different number wearing the same name.
//
// The other twelve benchmarks in this file — SSE parsing, E2EE seal/decrypt,
// thinking-parse, chats-list derivation, script generation — are pure logic and
// deliberately stay OUTSIDE this guard. They are the ones worth watching on both
// platforms, and gating the whole file to iOS (the easy move) would have thrown
// them away for the sake of four that genuinely cannot run.
#if os(iOS)

    /// One SwiftUI update pass: lets the runloop deliver the scheduled
    /// @Observable-driven body re-evaluation, then flushes layout.
    private func pumpRunLoop(_ window: UIWindow) {
        RunLoop.main.run(until: Date())
        window.layoutIfNeeded()
    }

    static func hostTrustLadder(rung: TrustRung,
                                 session: ConfidentialSession,
                                 store: ProviderStore) -> UIWindow {
        let host = UIHostingController(
            rootView: NavigationStack { TrustLadderView(initialRung: rung) }
                .environment(session)
                .environment(store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date())
        window.layoutIfNeeded()
        return window
    }

    // MARK: - 1. TrustLadderView re-render on session mutation
    // The sheet rebuilds chainNodes + summary (+ at expert: the enclave
    // groups, self-verify script, and its AttributedString highlight) on
    // every @Observable mutation. These pin the cost of one mutation-driven
    // update pass while the sheet is open.

    func testTrustLadderRerender_everyday() {
        let (session, store) = Self.offlineVerifiedSession()
        let window = Self.hostTrustLadder(rung: .everyday, session: session, store: store)
        measure {
            for _ in 0..<10 {
                session.verifiedResponseCount += 1
                pumpRunLoop(window)
            }
        }
        window.isHidden = true
    }

    func testTrustLadderRerender_expert() {
        let (session, store) = Self.offlineVerifiedSession()
        let window = Self.hostTrustLadder(rung: .expert, session: session, store: store)
        measure {
            for _ in 0..<10 {
                session.verifiedResponseCount += 1
                pumpRunLoop(window)
            }
        }
        window.isHidden = true
    }

    /// Cold cost of presenting the expert sheet (first full render, including
    /// the self-verify code block's syntax highlight).
    ///
    /// The sections are an eager `VStack` again (the LazyVStack fix was REVERSED), so
    /// this is the whole several-screens-tall document, not just the first
    /// viewport. That is the point: the laziness bought ~130 ms here and cost a
    /// 1,075 s freeze. The 655 ms once cited for the eager path predates the
    /// render caches — it measures ~417 ms first / ~95 ms warm now.
    func testTrustLadderFirstRender_expert() {
        let (session, store) = Self.offlineVerifiedSession()
        measure {
            let window = Self.hostTrustLadder(rung: .expert, session: session, store: store)
            window.isHidden = true
        }
    }

    /// Cold cost of presenting the sheet the way a tap on the lock icon
    /// actually presents it: at the everyday rung. This is the number behind
    /// "the attestation screen takes too long to open".
    func testTrustLadderFirstRender_everyday() {
        let (session, store) = Self.offlineVerifiedSession()
        measure {
            let window = Self.hostTrustLadder(rung: .everyday, session: session, store: store)
            window.isHidden = true
        }
    }

#endif

    // MARK: - 2. Self-verify script generation + compose analysis
    // Called once per body evaluation of the expert re-verify section
    // (script) and per expertChain build (PlaintextExposure).

    // MARK: - Streaming preparation, tick by tick
    //
    // The transcript prepares every block it renders through
    // `TranscriptMarkdown.prepared` (the empty-table-cell fix) and parses it
    // through `CachedMarkdownParser`. Both are CONTENT-ADDRESSED, which is
    // exactly right for a persisted message — its text never changes, so the
    // text is a complete key — and exactly wrong for the block still being
    // written: it is a different string on every pacer tick, so every tick
    // hashes the whole growing block and stores another copy of it. The work
    // per tick is O(block), which over a stream is O(n²).
    //
    // A table-bearing document, because that is the reported shape:
    // "stuttering when it reflows text or tables".

    private static func growingTable(ticks: Int) -> [String] {
        var rows = "| Item | Price | Notes |\n| --- | --- | --- |\n"
        var out: [String] = []
        for tick in 0..<ticks {
            rows += "| Item \(tick) | ~$\(tick * 3) | \(String(repeating: "detail ", count: 6)) |\n"
            // STRICTLY APPENDING. An earlier version varied the trailing
            // paragraph with `count: tick % 8`, which EMPTIED it every eighth
            // tick — so the document genuinely shrank and the stability test
            // dutifully reported four shrinks that were the fixture's doing.
            // A stream only ever appends; the fixture has to as well, or it
            // manufactures the defect it is looking for.
            out.append("## The comparison\n\n" + rows
                       + "\nA paragraph that grows with it, "
                       + String(repeating: "wrapping across several lines. ", count: tick / 4))
        }
        return out
    }

    /// What the tail costs per tick TODAY.
    func testStreamingTailPreparation_120Ticks() {
        let ticks = Self.growingTable(ticks: 120)
        measure {
            for tick in ticks {
                _ = TranscriptMarkdown.prepared(tick)
            }
        }
    }

    /// The same document arriving as SETTLED blocks — the case the caches are
    /// for. Should be ~free after the first pass.
    func testSettledBlockPreparation_120Blocks() {
        let blocks = Self.growingTable(ticks: 120)
        _ = blocks.map(TranscriptMarkdown.prepared)   // warm
        measure {
            for block in blocks {
                _ = TranscriptMarkdown.prepared(block)
            }
        }
    }

#if os(iOS)
    /// WHAT A GROWING TABLE COSTS TO MEASURE, PER TICK.
    ///
    /// `layoutStreamingView` asks the streaming host for `sizeThatFits` on
    /// every layout pass, and a table is the most expensive thing that can be
    /// inside it. Reported: "stuttering when generating — when it reflows text
    /// or tables". Textual's `Overflow` wraps tables and code blocks in a
    /// horizontal `ScrollView`, and teemoon patches that scroll view to take
    /// its content's IDEAL height (so a row measures right the first time
    /// instead of resizing a frame later) — which means the ideal size of a
    /// wide table is computed on every measure. This pins that cost.
    func testStreamingTableMeasure_perTick() {
        // FRESH HOSTS INSIDE THE MEASURE, deliberately. SwiftUI caches a
        // hosting controller's measurement, so reusing them measures the cache
        // and not the work: the first iteration of the reused version came in
        // at 1.117s and the next nine at 0.03ms. Streaming never gets that
        // cache — every tick is new content.
        let ticks = Self.growingTable(ticks: 40)
        let fitting = CGSize(width: 393, height: UIView.layoutFittingExpandedSize.height)
        measure {
            for markdown in ticks {
                let host = UIHostingController(rootView: AnyView(
                    StreamingMarkdownView(content: markdown).frame(width: 393)))
                _ = host.sizeThatFits(in: fitting)
            }
        }
    }
#endif

#if os(iOS)
    /// The SAME growing table through a host that is mounted ONCE, which is
    /// what the app does: `setStreaming` mounts the streaming view a single
    /// time per turn and never reassigns its `rootView`, so SwiftUI keeps the
    /// tree and only the tail block changes. The fresh-host benchmark above is
    /// the worst case (everything re-laid-out); this is the real one, and the
    /// gap between them is what `MarkdownStreamSplitter` is worth.
    func testStreamingTableMeasure_mountedOnce() {
        let ticks = Self.growingTable(ticks: 40)
        let fitting = CGSize(width: 393, height: UIView.layoutFittingExpandedSize.height)
        measure {
            let content = StreamingBenchContent()
            let host = UIHostingController(rootView: StreamingBenchHarness(content: content))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.makeKeyAndVisible()
            for markdown in ticks {
                content.markdown = markdown
                RunLoop.main.run(until: Date())
                _ = host.sizeThatFits(in: fitting)
            }
            window.isHidden = true
        }
    }
#endif

#if os(iOS)
    /// REFLOW, MEASURED AS INSTABILITY RATHER THAN COST.
    ///
    /// "It's stuttering when generating — I think when it reflows text or
    /// tables." A growing document can only get TALLER: every tick appends.
    /// Any tick where the measured height goes DOWN is the layout changing its
    /// mind about content it already had, and the follow, which is pinned to
    /// the end, moves the viewport by exactly that much. That is what a reflow
    /// stutter is made of.
    ///
    /// Prints the sequence so a regression can be read rather than inferred.
    func testStreamingTableHeightOnlyGrows() {
        let ticks = Self.growingTable(ticks: 40)
        let content = StreamingBenchContent()
        let host = UIHostingController(rootView: StreamingBenchHarness(content: content))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let fitting = CGSize(width: 393, height: UIView.layoutFittingExpandedSize.height)

        var heights: [CGFloat] = []
        for markdown in ticks {
            content.markdown = markdown
            RunLoop.main.run(until: Date())
            window.layoutIfNeeded()
            heights.append(host.sizeThatFits(in: fitting).height)
        }

        let shrinks = zip(heights, heights.dropFirst())
            .enumerated()
            .filter { $1.1 < $1.0 - 0.5 }
            .map { (tick: $0.offset + 1, from: $0.element.0, to: $0.element.1) }
        print("[reflow] heights: \(heights.map { Int($0) })")
        print("[reflow] shrinks: \(shrinks.map { "tick \($0.tick): \(Int($0.from))->\(Int($0.to))" })")
        XCTAssertTrue(shrinks.isEmpty,
            "the streaming view got SHORTER on \(shrinks.count) of 40 ticks while the document "
            + "only grew — the follow moves the viewport by each of those: "
            + "\(shrinks.prefix(4).map { "\(Int($0.from))->\(Int($0.to))" })")
        window.isHidden = true
    }
#endif

    func testSelfVerifyScriptGeneration() {
        let summary = verifiedSummary()
        XCTAssertNotNil(summary.selfVerifyScript)
        measure {
            for _ in 0..<100 { _ = summary.selfVerifyScript }
        }
    }

    func testPlaintextExposureAnalyze() {
        // Production shape (post wrong-document fix): the outer manifest is the
        // harness only; the touchers live in the hash-verified INNER compose.
        let outer = AttestationRecord.preview.gpuNodeComposeManifest!
        let inner = """
        services:
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "d", count: 64))
            environment:
              - OHTTP_ENABLED=true
              - TLS_CERT_PATH=/certs/completions.near.ai
          model-sg-glm51-awq-tp4-r1:
            image: glm51-sgl-awq-tp4-patched:local
            command: >
              sglang serve --model-path QuantTrio/GLM-5.1-AWQ
              --revision 8f60817aa28023f2607850d1a1e51d21aa34817a
              --served-model-name zai-org/GLM-5.1-FP8 --tp 4
              --log-requests-level 0 --enable-cache-report --enable-metrics
          nginx:
            image: nginx:1.25
        """
        XCTAssertFalse(PlaintextExposure.analyze(innerComposeYAML: inner, outerComposeYAML: outer).touchers.isEmpty)
        measure {
            for _ in 0..<1000 { _ = PlaintextExposure.analyze(innerComposeYAML: inner, outerComposeYAML: outer) }
        }
    }

    // MARK: - 3. Chats list preview derivation at scale
    // ChatsListView derives each row's title/preview from
    // thread.sortedMessages; search walks every message's content.

    private func seededThreads(threadCount: Int, messagesPerThread: Int) throws -> (ModelContainer, [ChatThread]) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ChatThread.self, Message.self, configurations: config)
        let ctx = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for t in 0..<threadCount {
            let thread = ChatThread()
            thread.timestamp = base.addingTimeInterval(Double(t) * 60)
            ctx.insert(thread)
            for m in 0..<messagesPerThread {
                let role: Role = m.isMultiple(of: 2) ? .user : .assistant
                let message = Message(
                    role: role,
                    content: "thread \(t) message \(m): " + String(repeating: "lorem ipsum dolor sit amet ", count: 4),
                    thread: thread)
                message.timestamp = base.addingTimeInterval(Double(t) * 60 + Double(m))
                ctx.insert(message)
            }
        }
        try ctx.save()
        let threads = try ctx.fetch(FetchDescriptor<ChatThread>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
        XCTAssertEqual(threads.count, threadCount)
        return (container, threads)
    }

    /// Cold per-row derivation for a 150-thread list (what a fresh list render
    /// pays before Thread's transient sort cache warms).
    func testChatsListRowDerivation_150Threads_cold() throws {
        let (container, threads) = try seededThreads(threadCount: 150, messagesPerThread: 20)
        measure {
            for thread in threads {
                thread.invalidateSortedMessages()
                _ = thread.sortedMessages.first?.content
                _ = thread.sortedMessages.last(where: { $0.role == .assistant })?.content
            }
        }
        _ = container // keep alive through the measurement
    }

    /// Warm re-derivation (the steady-state List re-render path — cache hits).
    func testChatsListRowDerivation_150Threads_warm() throws {
        let (container, threads) = try seededThreads(threadCount: 150, messagesPerThread: 20)
        for thread in threads { _ = thread.sortedMessages }  // warm the cache
        measure {
            for _ in 0..<10 {
                for thread in threads {
                    _ = thread.sortedMessages.first?.content
                    _ = thread.sortedMessages.last(where: { $0.role == .assistant })?.content
                }
            }
        }
        _ = container
    }

    /// The search filter walks every message's content per keystroke
    /// (ChatsListView.filteredThreads).
    func testChatsListSearchFilter_150Threads() throws {
        let (container, threads) = try seededThreads(threadCount: 150, messagesPerThread: 20)
        measure {
            let hits = threads.filter { thread in
                thread.messages.contains { $0.content.localizedCaseInsensitiveContains("message 19") }
            }
            XCTAssertEqual(hits.count, 150)
        }
        _ = container
    }

    // MARK: - 4. Streaming render helpers
    // StreamingMessageView re-runs these over the FULL accumulated output on
    // every pacer tick (~24 fps), so their cost grows with reply length.

    private static let longReply: String = {
        let paragraph = "The quick brown fox jumps over the lazy dog. Attestation binds the key to the enclave. "
        return "<think>" + String(repeating: paragraph, count: 60) + "</think>"
            + String(repeating: paragraph, count: 300)   // ~32 KB answer
    }()

    func testThinkingParse_fullDocument() {
        let doc = Self.longReply
        measure {
            for _ in 0..<100 { _ = ThinkingContentParser.parse(doc) }
        }
    }

    /// Simulates a stream: parse cost integrated over a growing document
    /// (120 ticks ≈ 5 s of streaming at 24 fps), the shape the pacer produces.
    func testThinkingParse_simulatedStream() {
        let doc = Self.longReply
        let ticks = 120
        measure {
            for i in 1...ticks {
                let end = doc.index(doc.startIndex,
                                    offsetBy: doc.count * i / ticks,
                                    limitedBy: doc.endIndex) ?? doc.endIndex
                _ = ThinkingContentParser.parse(String(doc[..<end]))
            }
        }
    }

    func testFixEmptyTableCells_fullDocument() {
        let doc = Self.longReply + "\n| a | b |\n|---|---|\n| 1 | |\n"
        measure {
            for _ in 0..<100 { _ = MessageView.fixEmptyTableCells(doc) }
        }
    }

    // MARK: - 5. SSE stream parsing (the wire → tokens path)
    // One SSEStreamParser instance consumes the whole stream chunk-by-chunk,
    // exactly as GenerationEngine feeds it. `hasTools: true` exercises the
    // streaming markup-elision scan, which must stay O(chunk) — it may look at
    // the new chunk plus a bounded boundary tail, never the accumulated reply.

    /// A synthetic 800-event SSE stream (~40 chars of content per delta).
    private static func syntheticSSEStream(events: Int) -> [Data] {
        (0..<events).map { i in
            let content = "token \(i) lorem ipsum dolor sit amet consect "
            let json = #"{"id":"chatcmpl-bench","choices":[{"delta":{"content":"\#(content)"},"index":0}]}"#
            return Data("data: \(json)\n\n".utf8)
        } + [Data("data: [DONE]\n\n".utf8)]
    }

    func testSSEParser_800Events_noTools() {
        let chunks = Self.syntheticSSEStream(events: 800)
        measure {
            let parser = SSEStreamParser(hasTools: false)
            for chunk in chunks { _ = parser.consume(chunk) }
            XCTAssertFalse(parser.accumulatedContent.isEmpty)
        }
    }

    func testSSEParser_800Events_withTools() {
        let chunks = Self.syntheticSSEStream(events: 800)
        measure {
            let parser = SSEStreamParser(hasTools: true)
            for chunk in chunks { _ = parser.consume(chunk) }
            XCTAssertFalse(parser.accumulatedContent.isEmpty)
        }
    }

    // MARK: - 6. E2EE crypto path
    // Per streaming delta the codec does hex-decode → X25519 agreement →
    // HKDF → XChaCha20-Poly1305 open. Sealing is done outside the measure
    // block (models the server); decryption is the client-side hot path.

    func testE2EEDecrypt_200StreamFields() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)
        let fields: [String] = try (0..<200).map { i in
            try E2EEEnvelope.seal(
                plaintext: Data("streamed delta number \(i) with some text ".utf8),
                recipientPubKey: session.agreementKey.publicKey
            ).hexString
        }
        measure {
            for f in fields {
                XCTAssertNotNil(try? session.decrypt(f))
            }
        }
    }

    func testE2EEEncryptRequestBody_20Messages() throws {
        let modelEdKey = Curve25519.Signing.PrivateKey()
        let session = try E2EEPeer(modelEd25519PubKey: modelEdKey.publicKey.rawRepresentation)
        let messages: [[String: Any]] = (0..<20).map { i in
            ["role": i.isMultiple(of: 2) ? "user" : "assistant",
             "content": "message \(i): " + String(repeating: "lorem ipsum dolor sit amet ", count: 20)]
        }
        let body = try JSONSerialization.data(withJSONObject: ["model": "m", "messages": messages])
        measure {
            for _ in 0..<10 {
                XCTAssertNotNil(try? session.encryptRequestBody(body))
            }
        }
    }

#if os(iOS)
    // MARK: - 7. Conversation cold render
    // ConversationView lays out ALL messages in a plain (non-lazy) VStack —
    // opening a thread pays full markdown layout for every message.

    func testConversationColdRender_60Messages() {
        let messages: [Message] = (0..<60).map { i in
            Message(role: i.isMultiple(of: 2) ? .user : .assistant,
                    content: "message \(i): " + String(repeating: "some **markdown** with `code` and text. ", count: 8))
        }
        let llm = ChatGeneration()
        let settings = AppSettings()
        measure {
            let host = UIHostingController(
                rootView: ConversationView(messages: messages, threadID: UUID(), generatingThreadID: nil)
                    .environment(llm)
                    .environment(settings))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date())
            window.layoutIfNeeded()
            window.isHidden = true
        }
    }
#endif
}

#if os(iOS)
/// Helpers for `testStreamingTableMeasure_mountedOnce`. At file scope because
/// a local type cannot carry the `@Observable` macro.
@MainActor @Observable final class StreamingBenchContent {
    var markdown = ""
}

struct StreamingBenchHarness: View {
    let content: StreamingBenchContent
    var body: some View {
        StreamingMarkdownView(content: content.markdown).frame(width: 393)
    }
}
#endif
