//
//  OnDeviceImageProbeTests.swift
//  teemoonTests
//
//  Can Gemma 4 on the phone read 1, 4 and 10 images in one message, through the APP's on-device turn
//  (ImageIntake → WireImage → GenerationEngine.content → LiteRTTransport.runTurn), and what does it cost?
//  Decides LocalModelCatalog.imagesOnDevice, ChatViewModel.onDeviceImagesPerSend and E4B's image story.
//
//  ChatGeneration.imageRefusal (one image per on-device message) sits above the transport and is not on
//  this path: the probe measures the transport, the gate decides separately.
//
//  REAL DEVICE ONLY, opt-in; downloads E2B (~2.5 GB) and E4B (~3.5 GB) when absent:
//
//      TEST_RUNNER_TEEMOON_IMAGE_PROBE=1 xcodebuild test … -only-testing:teemoonTests/OnDeviceImageProbeTests
//
//  The value picks cases: `1`/`all` for every one, or a list such as `e2b-10,e4b-4`.
//  One `IMAGEPROBE {json}` line per case; `IMAGEPROBE-START {json}` before it, so a case jetsam killed
//  shows as a START with no result. Both also land in Documents/image-probe-results.jsonl.
//

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
#if canImport(UIKit)
import UIKit
#endif
@testable import teemoon

struct ImageProbeCase: Sendable, CustomStringConvertible {
    let key: String
    let modelID: String
    let images: Int
    /// A text turn first, so the image turn swaps a resident text engine for a vision one (the real path).
    var textFirst = false

    var description: String { key }

    static let e2b = "litert-community/gemma-4-E2B-it-litert-lm"
    static let e4b = "litert-community/gemma-4-E4B-it-litert-lm"

    /// Run order: E2B first, so an E4B download or load failure cannot cost the E2B numbers.
    static let all: [ImageProbeCase] = [
        .init(key: "e2b-1", modelID: e2b, images: 1),
        .init(key: "e2b-4", modelID: e2b, images: 4),
        .init(key: "e2b-10", modelID: e2b, images: 10),
        .init(key: "e4b-1", modelID: e4b, images: 1),
        .init(key: "e4b-4", modelID: e4b, images: 4),
        .init(key: "e2b-text-1", modelID: e2b, images: 1, textFirst: true),
        .init(key: "e4b-text-1", modelID: e4b, images: 1, textFirst: true),
    ]
}

@Suite("On-device image probe (device, opt-in: TEEMOON_IMAGE_PROBE=1)", .serialized)
struct OnDeviceImageProbeTests {

    static var armValue: String? {
        let env = ProcessInfo.processInfo.environment
        return env["TEEMOON_IMAGE_PROBE"] ?? env["TEST_RUNNER_TEEMOON_IMAGE_PROBE"]
    }

    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return armValue != nil
        #endif
    }

    static func selected(_ c: ImageProbeCase) -> Bool {
        let raw = (armValue ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw == "1" || raw == "all" || raw == "true" { return true }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(c.key)
    }

    @Test(.enabled(if: Self.enabled, "set TEEMOON_IMAGE_PROBE=1 (device only)"), .timeLimit(.minutes(60)),
          arguments: ImageProbeCase.all)
    func imageTurn(_ probe: ImageProbeCase) async throws {
        guard Self.selected(probe) else { return }
        let out = ImageProbeOutput.shared
        var line: [String: Any] = ["model": probe.modelID, "case": probe.key, "images": probe.images,
                                   "device": ImageProbeOutput.machine(),
                                   "physicalMemoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)]
        let catalog = try #require(LocalModelCatalog.model(id: probe.modelID))
        line["marketedRAMGB"] = LocalMemory.marketedRAMGB()
        line["minRAMGB"] = catalog.minRAMGB
        line["belowFloor"] = LocalMemory.belowFloor(catalog)

        // A model that can't be had is a reported result, not a crash of the run.
        let path: URL
        do {
            path = try await ImageProbeModel.ensure(catalog)
        } catch {
            line["ok"] = false
            line["error"] = "download: \(error)"
            await out.emit("IMAGEPROBE ", line)
            Issue.record("\(probe.key): model unavailable — \(error)")
            return
        }

        // Each case starts clean: nothing resident (the app pre-warms a text engine at launch).
        await LiteRTTransport.evictEngines()
        try await Task.sleep(for: .seconds(5))

        // Images as a sent message carries them: synthesized camera-size JPEGs through ImageIntake.
        var wire: [WireImage] = []
        for i in 0..<probe.images {
            let jpeg = try #require(ImageProbeFixture.photoJPEG(index: i), "could not synthesize image \(i)")
            switch ImageIntake.fromBytes(jpeg, declared: .jpeg) {
            case .success(let image):
                wire.append(WireImage(mimeType: image.mimeType, data: image.data, width: image.width, height: image.height))
            case .failure(let failure):
                Issue.record("intake refused synthesized image \(i): \(failure)")
                return
            }
        }
        let text = probe.images == 1
            ? "Describe this image in one short line."
            : "Describe each of these \(probe.images) images in one short line each, numbered 1 to \(probe.images)."
        let content = GenerationEngine.content(text, wire)
        let systemPrompt = await MainActor.run {
            ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
        }
        // Small, but enough for a line per image; the transport's cap counts chars/4.
        let maxAnswerTokens = max(64, 32 * probe.images)

        // What the load gate inside the engine cache will decide, read the same way.
        let availableAtStart = LocalMemory.availableMB()
        let needMB = LocalMemory.loadNeedMB(sizeMB: catalog.sizeMB, peakFootprintMB: catalog.peakFootprintMB)
        line["guardNeedMB"] = needMB
        line["availableAtStartMB"] = availableAtStart
        line["guardAllows"] = availableAtStart <= 0 || availableAtStart >= needMB
        line["startFootprintMB"] = ImageProbeMemory.footprintMB()
        line["visionCachePresent"] = LocalModelStorage.engineCachePresent(forBundle: path, vision: true)
        line["maxAnswerTokens"] = maxAnswerTokens
        line["imageBytes"] = wire.map(\.data.count)

        await out.emit("IMAGEPROBE-START ", ["model": probe.modelID, "case": probe.key, "images": probe.images])

        // The same construction as `LocalLanguageModel.transport(for:)`, with the answer capped.
        let transport = LiteRTTransport(
            modelPath: path, estimatedSizeMB: catalog.sizeMB,
            tools: [BraveWebSearchTool(apiKey: "", onDevice: true)],
            maxAnswerTokens: maxAnswerTokens)

        if probe.textFirst {
            let warm = try await transport.runTurn(
                messages: [["role": "system", "content": systemPrompt],
                           ["role": "user", "content": "Say hello in five words."]],
                includeTools: true
            ) { _ in }
            line["textTurnChars"] = warm.content.count
            line["footprintAfterTextMB"] = ImageProbeMemory.footprintMB()
            line["availableAfterTextMB"] = LocalMemory.availableMB()
        }

        let sampler = ImageProbeMemory.Sampler()
        sampler.start()
        let heartbeat = out.heartbeat("\(probe.key)")
        let sentAt = Date()
        let start = ContinuousClock.now
        let firstToken = LockedBox<Duration?>(nil)
        var ok = false
        do {
            let turn = try await transport.runTurn(
                messages: [["role": "system", "content": systemPrompt],
                           ["role": "user", "content": content]],
                includeTools: true
            ) { _ in
                if firstToken.value == nil { firstToken.value = start.duration(to: .now) }
            }
            ok = !turn.content.isEmpty
            line["answer"] = String(turn.content.prefix(600))
            line["answerChars"] = turn.content.count
            line["toolCalls"] = turn.toolCalls.count
            line["finish"] = turn.finish.map { String(describing: $0) } ?? "nil"
            if !ok { line["error"] = "empty answer" }
        } catch {
            line["error"] = "\(error)"
        }
        let total = start.duration(to: .now)
        heartbeat.cancel()
        let (peakMB, minAvailMB) = sampler.stop()

        let load = await MainActor.run { () -> (Double?, Bool?, Bool?) in
            guard let c = EngineLoadObserver.shared.current, c.started >= sentAt else { return (nil, nil, nil) }
            return (c.ended.map { $0.timeIntervalSince(c.started) }, c.imageCapable, c.cachePresent)
        }
        line["ok"] = ok
        line["engineBuildSeconds"] = orNull(load.0)
        line["engineImageCapable"] = orNull(load.1)
        line["engineCachePresent"] = orNull(load.2)
        line["ttftSeconds"] = orNull(firstToken.value.map(\.probeSeconds))
        line["totalSeconds"] = total.probeSeconds
        line["peakPhysFootprintMB"] = peakMB
        line["minAvailableMB"] = minAvailMB
        line["endFootprintMB"] = ImageProbeMemory.footprintMB()
        await out.emit("IMAGEPROBE ", line)

        await LiteRTTransport.evictEngines()
        #expect(ok, "\(probe.key): \(line["error"] ?? "no answer")")
    }
}

// MARK: - Images

enum ImageProbeFixture {
    /// A 2048×1536 JPEG that reads like a photo to an encoder: a coloured gradient, clutter, grain. Each index
    /// gets its own palette and layout, so no two images in one message are alike.
    static func photoJPEG(index: Int, width: Int = 2048, height: Int = 1536) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = SplitMix(seed: UInt64(index + 1) &* 0x9E37_79B9)
        let hue = Double(index) / 10
        func color(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            let (r, g, bl) = hsb(h.truncatingRemainder(dividingBy: 1), s, b)
            return CGColor(srgbRed: r, green: g, blue: bl, alpha: a)
        }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [color(hue, 0.7, 0.95), color(hue + 0.35, 0.8, 0.35)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: Double(width) * rng.unit(), y: Double(height)), options: [])
        for _ in 0..<300 {
            ctx.setFillColor(color(hue + rng.unit() * 0.5, 0.3 + rng.unit() * 0.7, 0.2 + rng.unit() * 0.8, 0.4 + rng.unit() * 0.6))
            let w = 20 + rng.unit() * 400, h = 20 + rng.unit() * 300
            let rect = CGRect(x: rng.unit() * Double(width), y: rng.unit() * Double(height), width: w, height: h)
            if rng.unit() < 0.5 { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        }
        // Grain: a small noise tile stretched over the frame, so the JPEG carries real high-frequency content.
        let nw = 512, nh = 384
        var noise = [UInt8](repeating: 255, count: nw * nh * 4)
        for p in 0..<(nw * nh) {
            let v = UInt8(truncatingIfNeeded: rng.next() >> 56)
            noise[p * 4] = v; noise[p * 4 + 1] = v; noise[p * 4 + 2] = v
        }
        if let provider = CGDataProvider(data: Data(noise) as CFData),
           let tile = CGImage(width: nw, height: nh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: nw * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            ctx.setAlpha(0.18)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setAlpha(1)
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}

// MARK: - Memory

enum ImageProbeMemory {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    static func availableMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return 0
        #endif
    }

    /// Polls every 50 ms on its own queue, off the cooperative pool a native engine build may hold.
    final class Sampler: @unchecked Sendable {
        private let queue: DispatchQueue
        private let timer: DispatchSourceTimer
        private let peak = LockedBox<Int>(0)
        private let minAvailable = LockedBox<Int>(Int.max)

        init() {
            let queue = DispatchQueue(label: "ai.teemoon.imageprobe.sampler", qos: .userInitiated)
            self.queue = queue
            timer = DispatchSource.makeTimerSource(queue: queue)
        }

        private func sample() {
            let f = ImageProbeMemory.footprintMB()
            if f > peak.value { peak.value = f }
            let a = ImageProbeMemory.availableMB()
            if a > 0, a < minAvailable.value { minAvailable.value = a }
        }

        func start() {
            sample()
            timer.schedule(deadline: .now(), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }

        /// (peak phys_footprint MB, minimum os_proc_available_memory MB; -1 when unreadable).
        func stop() -> (Int, Int) {
            timer.cancel()
            queue.sync { sample() }
            return (peak.value, minAvailable.value == Int.max ? -1 : minAvailable.value)
        }
    }
}

// MARK: - The model file

enum ImageProbeModel {
    /// Remembered per process, so the second E4B case does not retry a download that already failed.
    private static let failures = LockedBox<[String: String]>([:])

    /// The bundle at the app's own path, downloaded from the catalog's pinned revision when absent:
    /// Range-resumable, at most 8 attempts, SHA-256 verified before the move.
    static func ensure(_ model: LocalModel) async throws -> URL {
        let destination = LocalModelStorage.file(for: model)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let earlier = failures.value[model.id] { throw ImageProbeError.earlier(earlier) }
        do {
            return try await download(model, to: destination)
        } catch {
            failures.value[model.id] = "\(error)"
            throw error
        }
    }

    private static func download(_ model: LocalModel, to destination: URL) async throws -> URL {
        let out = ImageProbeOutput.shared
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let part = directory.appending(component: "imageprobe-download.part")
        let url = URL(string: "https://huggingface.co")!
            .appending(path: "\(model.id)/resolve/\(model.revision)/\(model.fileName)")
        let started = ContinuousClock.now
        var attempt = 0
        while true {
            attempt += 1
            let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            do {
                try await ImageProbeDownload.fetch(url, into: part, from: have)
                break
            } catch {
                let now = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
                await out.note("\(model.id): download attempt \(attempt) stopped at \(now) bytes: \(error)")
                if attempt >= 8 { throw error }
                try await Task.sleep(for: .seconds(min(30, attempt * 5)))
            }
        }
        let sha = try LocalModelDownloader.sha256OfFile(at: part)
        await out.note("\(model.id): downloaded in \(started.duration(to: .now)) over \(attempt) attempt(s); sha256 \(sha)")
        guard sha == model.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw ImageProbeError.checksum(expected: model.sha256, actual: sha)
        }
        try FileManager.default.moveItem(at: part, to: destination)
        return destination
    }
}

enum ImageProbeError: Error, CustomStringConvertible {
    case checksum(expected: String, actual: String)
    case http(Int)
    case truncated
    case earlier(String)
    var description: String {
        switch self {
        case .checksum(let e, let a): return "checksum mismatch: expected \(e), got \(a)"
        case .http(let code):         return "HTTP \(code)"
        case .truncated:              return "connection closed before the body ended"
        case .earlier(let why):       return "download already failed in this run: \(why)"
        }
    }
}

/// One HTTP transfer appended to a file, streamed in chunks (a multi-gigabyte body never sits in memory).
final class ImageProbeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var received: Int64
    private var expected: Int64 = -1
    private var lastReport: Int64
    private var failed = false
    private let continuation: CheckedContinuation<Void, any Error>
    private var session: URLSession?

    private init(handle: FileHandle, offset: Int64, continuation: CheckedContinuation<Void, any Error>) {
        self.handle = handle
        self.received = offset
        self.lastReport = offset
        self.continuation = continuation
    }

    static func fetch(_ url: URL, into file: URL, from offset: Int64) async throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let delegate = ImageProbeDownload(handle: handle, offset: offset, continuation: continuation)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        if http.statusCode == 206 {
            handle.seekToEndOfFile()
            expected = received + http.expectedContentLength
        } else if http.statusCode == 200 {
            // The server ignored the Range: start the file over.
            try? handle.truncate(atOffset: 0)
            received = 0
            lastReport = 0
            expected = http.expectedContentLength
        } else {
            failed = true
            continuation.resume(throwing: ImageProbeError.http(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle.write(data)
        received += Int64(data.count)
        if received - lastReport >= 256 << 20 {
            lastReport = received
            let total = expected > 0 ? " of \(expected)" : ""
            let at = received
            Task { await ImageProbeOutput.shared.note("download at \(at)\(total) bytes") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        guard !failed else { return }
        failed = true
        if let error { continuation.resume(throwing: error); return }
        if expected > 0, received < expected { continuation.resume(throwing: ImageProbeError.truncated); return }
        continuation.resume()
    }
}

// MARK: - Output

/// Lines to stdout, the system log and Documents/image-probe-results.jsonl, each with its conditions.
actor ImageProbeOutput {
    static let shared = ImageProbeOutput()
    private let file = URL.documentsDirectory.appending(component: "image-probe-results.jsonl")
    private let started = Date()

    func emit(_ prefix: String, _ fields: [String: Any]) async {
        var object = fields
        object["thermal"] = Self.thermal
        object["t_s"] = Date().timeIntervalSince(started).rounded()
        object["lowPower"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if canImport(UIKit)
        let (osVersion, battery, charging) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            return (UIDevice.current.systemVersion, UIDevice.current.batteryLevel, state == .charging || state == .full)
        }
        object["os"] = osVersion
        object["batteryLevel"] = battery
        object["charging"] = charging
        #endif
        let text = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"unserialisable line\"}"
        let line = prefix + text
        print(line)
        NSLog("%@", line)
        // Appended and synced at once: a jetsam kill right after a START must still leave the START on disk.
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.synchronize()
            try? handle.close()
        }
    }

    func note(_ text: String) async {
        await emit("IMAGEPROBE-NOTE ", ["text": text])
    }

    /// A line every 30 s while something long and silent runs (a first vision-cache compile is minutes).
    nonisolated func heartbeat(_ what: String) -> Task<Void, Never> {
        Task {
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                n += 30
                await note("still running: \(what), \(n)s, footprint \(ImageProbeMemory.footprintMB()) MB")
            }
        }
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// `iPhone17,1`-style hardware identifier; `UIDevice.model` only says "iPhone".
    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// JSON null for a missing reading.
private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

private extension Duration {
    var probeSeconds: Double {
        let (s, attos) = components
        return Double(s) + Double(attos) / 1e18
    }
}
