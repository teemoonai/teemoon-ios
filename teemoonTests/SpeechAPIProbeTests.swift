//
//  SpeechAPIProbeTests.swift
//  teemoonTests
//
//  DOES THE iOS 26 SPEECH API ACTUALLY DO WHAT IT SAYS?
//
//  `SpeechDetector` was tried in late 2025 and it was specced-but-not-built:
//  it did not conform to the protocol `SpeechAnalyzer` required, so it could not
//  be installed as a module — which meant no voice-activity detection, which
//  meant no automatic stop. Dictation could only ever end by the user tapping a
//  button.
//
//  The 26.5 SDK now DECLARES `SpeechDetector : SpeechModule`. That is exactly
//  what the docs claimed last time, so declaration is not evidence. This file
//  exercises it:
//
//    1. `detectorInstallsAsAModule`   — does it compile AND land in
//                                       `analyzer.modules`? (the original blocker)
//    2. `whatThisDeviceReports`       — availability, locales, asset status
//    3. `synthesizedSpeechEndToEnd`   — feed real speech audio plus trailing
//                                       silence and see whether the detector
//                                       reports the transition, and whether
//                                       anything finalizes WITHOUT us asking.
//
//  No microphone is involved: speech is synthesized with `AVSpeechSynthesizer`'s
//  buffer callback, so this runs in the simulator. Every test is bounded — a
//  probe that hangs tells us nothing.
//
//  This file is a PROBE, not a regression suite. It prints findings and only
//  fails on the questions with an unambiguous right answer.
//

import AVFoundation
import Foundation
import Speech
import Testing

// MARK: - Shared helpers

/// Everything the analyzer emitted during one run.
private actor Collector {
    var transcripts: [(text: String, isFinal: Bool)] = []
    var detections: [(speechDetected: Bool, at: Double)] = []
    var transcriberError: String?
    var detectorError: String?

    func addTranscript(_ text: String, isFinal: Bool) { transcripts.append((text, isFinal)) }
    func addDetection(_ detected: Bool, at seconds: Double) { detections.append((detected, seconds)) }
    func setTranscriberError(_ e: String) { transcriberError = e }
    func setDetectorError(_ e: String) { detectorError = e }

    var summary: String {
        var lines: [String] = []
        lines.append("transcripts (\(transcripts.count)):")
        for t in transcripts { lines.append("   [\(t.isFinal ? "final " : "volatile")] \(t.text)") }
        lines.append("detections (\(detections.count)):")
        for d in detections { lines.append("   speechDetected=\(d.speechDetected) at \(String(format: "%.2f", d.at))s") }
        if let transcriberError { lines.append("transcriber stream error: \(transcriberError)") }
        if let detectorError { lines.append("detector stream error: \(detectorError)") }
        return lines.joined(separator: "\n")
    }
}

/// Synthesizes speech to PCM buffers. No microphone, so this works in the
/// simulator and in CI.
///
/// Returns nil when the synthesizer produced nothing — which is itself a
/// finding worth printing rather than a failure to hide.
private func synthesize(_ text: String, timeout: Duration = .seconds(20)) async -> [AVAudioPCMBuffer]? {
    let synth = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // A zero-length buffer is the synthesizer's end-of-stream marker.
            if pcm.frameLength == 0 {
                continuation.finish()
            } else {
                continuation.yield(pcm)
            }
        }
    }

    var buffers: [AVAudioPCMBuffer] = []
    let deadline = ContinuousClock.now.advanced(by: timeout)
    for await buffer in stream {
        buffers.append(buffer)
        if ContinuousClock.now >= deadline { break }
    }
    // Keep the synthesizer alive until the callbacks are done.
    withExtendedLifetime(synth) {}
    return buffers.isEmpty ? nil : buffers
}

/// Converts a buffer to `format`, and can also emit pure silence in that format
/// — the silence is the whole point of the endpointing question.
private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    if buffer.format == format { return buffer }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

    var supplied = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
    if let error {
        print("   convert failed: \(error.localizedDescription)")
        return nil
    }
    return out.frameLength > 0 ? out : nil
}

private func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    // A fresh buffer's memory is already zeroed, but say so explicitly: the
    // difference between "silence" and "uninitialized garbage" is the entire
    // experiment.
    if let channels = buffer.floatChannelData {
        for c in 0..<Int(format.channelCount) {
            channels[c].update(repeating: 0, count: Int(frames))
        }
    } else if let channels = buffer.int16ChannelData {
        for c in 0..<Int(format.channelCount) {
            channels[c].update(repeating: 0, count: Int(frames))
        }
    }
    return buffer
}

// MARK: - 1. The original blocker

/// OPT-IN. One of these asserts that an Apple API is broken, which is true
/// today and is meant to start failing the day it is not — a tripwire, not a
/// regression. Left on by default it would paint the suite red forever, and a
/// permanently red suite is one nobody reads.
///
///     TEST_RUNNER_VOICE_PROBE=1 xcodebuild test -destination 'platform=iOS,id=…' \
///       -only-testing:teemoonTests/SpeechAPIProbeTests
@Suite("iOS 26 Speech API probe",
       .enabled(if: voiceProbeEnabled(), "set TEST_RUNNER_VOICE_PROBE=1 (device only)"))
struct SpeechAPIProbeTests {

    /// THE REGRESSION ACTUALLY HIT. If `SpeechDetector` does not conform to
    /// `SpeechModule`, this file does not compile — which is the 2025 behaviour.
    /// If it conforms but the analyzer refuses to hold it, `modules` comes back
    /// short.
    @Test("speech detector installs as an analyzer module")
    func detectorInstallsAsAModule() async throws {
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )

        // NEVER PUT THE DETECTOR IN AN ANALYZER ALONE.
        //
        // `SpeechAnalyzer(modules: [detector])` does not throw and does not
        // return nil — it **kills the process**:
        //
        //   Speech/SpeechDetector.swift:223: Fatal error:
        //   Cannot create SpeechDetector-only worker; use with a transcriber module
        //
        // Measured on device, 2026-07-31, iOS 26.5. The docs do say the module
        // "only functions in conjunction with a SpeechTranscriber", so this is
        // specced — but it is enforced with a `fatalError`, which means a
        // configuration mistake is an app crash rather than an error teemoon
        // could report. Worth knowing before shipping a picker that can produce
        // a transcriber-less configuration.
        print("── detector as module ──")
        print("   [detector] alone: NOT TESTED — fatalErrors by design (see comment)")

        // The pair, which is the only supported arrangement.
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("   ⚠️  SpeechTranscriber unavailable on this machine — pairing untested here.")
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [detector, transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        let installed = await analyzer.modules
        print("   [detector, transcriber] installed: \(installed.count)")
        #expect(installed.count == 2, "analyzer dropped a module")

        // setModules is the other route in, and the one a live session would use
        // to turn VAD on or off mid-dictation. Narrated step by step because one
        // of these calls takes the process down and the log is the only witness.
        print("   setModules([transcriber]) — dropping the detector…")
        try await analyzer.setModules([transcriber])
        let afterRemoval = await analyzer.modules.count
        print("   …survived. modules now: \(afterRemoval)")

        print("   setModules([detector, transcriber]) — putting it back…")
        try await analyzer.setModules(modules)
        let afterReadd = await analyzer.modules.count
        print("   …survived. modules now: \(afterReadd)")
        #expect(afterReadd == 2)

        await analyzer.cancelAndFinishNow()
    }

    // MARK: - 2. What this machine reports

    @Test("what this device reports about speech assets")
    func whatThisDeviceReports() async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)

        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let transcriberStatus = await AssetInventory.status(forModules: [transcriber])
        let bothStatus = await AssetInventory.status(forModules: [detector, transcriber])
        let detectorStatus = await AssetInventory.status(forModules: [detector])
        let reserved = await AssetInventory.reservedLocales

        print("── device report ──")
        print("   SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        print("   supportedLocales: \(supported.count) — \(supported.prefix(8).map(\.identifier))")
        print("   installedLocales: \(installed.count) — \(installed.prefix(8).map(\.identifier))")
        print("   status [transcriber]:            \(transcriberStatus)")
        print("   status [detector]:               \(detectorStatus)")
        print("   status [detector, transcriber]:  \(bothStatus)")
        print("   reservedLocales: \(reserved.map(\.identifier)) of max \(AssetInventory.maximumReservedLocales)")

        // The question that decides whether the detector needs its own download
        // at all: if [detector] alone is `.installed` while the transcriber is
        // not, VAD is free and locale-independent.
        print("   → detector needs no locale assets: \(detectorStatus == .installed)")
    }

    // MARK: - 2b. Is the detector's silence MY fault?

    /// The first device run had the transcriber working perfectly and the
    /// detector emitting **nothing** — but it fed every buffer in one burst,
    /// far faster than real time, which is a condition a live VAD never sees.
    /// That is a harness artefact, not a finding, until ruled out.
    ///
    /// So: the supported pairing (detector + transcriber), audio **paced to
    /// wall-clock**, and timestamps on everything — because the question is not
    /// only *whether* results arrive but *when* they arrive relative to the
    /// moment the speech stops. That gap is the automatic stop.
    @Test("detector + transcriber, paced in real time", .timeLimit(.minutes(5)))
    func pacedPairEndpointing() async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("── paced pair ── ⚠️ transcriber unavailable here.")
            return
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .high), reportResults: true)
        let modules: [any SpeechModule] = [detector, transcriber]

        print("── paced pair ──")
        let detectorFormats = await detector.availableCompatibleAudioFormats
        print("   detector.availableCompatibleAudioFormats: \(detectorFormats.count)")
        for f in detectorFormats.prefix(4) {
            print("      \(f.sampleRate) Hz · \(f.channelCount)ch · common=\(f.commonFormat.rawValue)")
        }

        guard await AssetInventory.status(forModules: modules) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules),
              let spoken = await synthesize("The quick brown fox jumps over the lazy dog.")
        else {
            print("   ⚠️  assets, format or audio unavailable.")
            return
        }
        print("   chosen format: \(format.sampleRate) Hz · \(format.channelCount)ch")

        let collector = Collector()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules)
        let clockStart = ContinuousClock.now
        func elapsed() -> String {
            String(format: "%.2f", Double(clockStart.duration(to: .now).components.seconds)
                   + Double(clockStart.duration(to: .now).components.attoseconds) / 1e18)
        }

        let transcriptTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await collector.addTranscript(text, isFinal: result.isFinal)
                    if result.isFinal { print("   ← FINAL at t=\(elapsed())s: \(text)") }
                }
            } catch { await collector.setTranscriberError("\(error)") }
        }
        let detectionTask = Task {
            do {
                for try await result in detector.results {
                    await collector.addDetection(result.speechDetected, at: result.range.start.seconds)
                    print("   ← detection at t=\(elapsed())s: speechDetected=\(result.speechDetected)")
                }
            } catch { await collector.setDetectorError("\(error)") }
        }

        try await analyzer.prepareToAnalyze(in: format)

        // PACED: each buffer handed over roughly when a microphone would have
        // produced it.
        for buffer in spoken {
            guard let converted = convert(buffer, to: format) else { continue }
            let duration = Double(converted.frameLength) / format.sampleRate
            continuation.yield(AnalyzerInput(buffer: converted))
            try? await Task.sleep(for: .seconds(duration))
        }
        let silenceStarted = elapsed()
        print("   speech ended, silence begins at t=\(silenceStarted)s")

        if let quiet = silence(seconds: 0.25, format: format) {
            for _ in 0..<16 {   // 4 seconds of paced silence
                continuation.yield(AnalyzerInput(buffer: quiet))
                try? await Task.sleep(for: .seconds(0.25))
            }
        }

        let detectionsBefore = await collector.detections
        let finalsBefore = await collector.transcripts.filter(\.isFinal).count
        print("── during silence, WITHOUT calling finalize ──")
        print("   detections: \(detectionsBefore.count) · finals: \(finalsBefore)")

        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        try? await Task.sleep(for: .seconds(2))
        transcriptTask.cancel()
        detectionTask.cancel()

        print("── paced-pair VERDICT ──")
        print("   detector produced results:            \(!detectionsBefore.isEmpty)")
        print("   transcript finalized during silence:  \(finalsBefore > 0)")
        if let err = await collector.detectorError { print("   detector stream error: \(err)") }
        print(await collector.summary)
    }

    // MARK: - 3. The endpointing question

    /// Feeds real synthesized speech followed by two seconds of digital silence
    /// and **never calls `finalize`**. What we are looking for:
    ///
    ///   • does `SpeechDetector` emit `speechDetected: true` then `false`?
    ///     → that transition is the automatic stop, and the whole reason to care.
    ///   • does the transcriber deliver text at all in this configuration?
    ///   • does anything finalize on its own, or does everything stay volatile
    ///     until the app asks?
    @Test("synthesized speech, then silence — does anything end by itself?", .timeLimit(.minutes(5)))
    func synthesizedSpeechEndToEnd() async throws {
        // Ask the framework which locale it will accept rather than asserting
        // one: "en-US" is rejected outright where the assets are absent, and the
        // supported identifier can be a variant of what you asked for.
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            print("── end-to-end ──")
            print("   ⚠️  SpeechTranscriber unavailable here — endpointing UNANSWERED. Run on a device.")
            return
        }
        print("── end-to-end ── locale: \(locale.identifier)")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [detector, transcriber]

        // Assets first — without them the analyzer has nothing to run.
        let statusBefore = await AssetInventory.status(forModules: modules)
        print("   asset status before: \(statusBefore)")
        if statusBefore != .installed {
            do {
                try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    print("   downloading assets…")
                    try await request.downloadAndInstall()
                } else {
                    print("   no installation request offered (assets already present, or unsupported)")
                }
            } catch {
                print("   asset install FAILED: \(error)")
            }
        }
        let statusAfter = await AssetInventory.status(forModules: modules)
        print("   asset status after:  \(statusAfter)")

        guard statusAfter == .installed else {
            print("   ⚠️  assets unavailable here — the endpointing question is UNANSWERED on this machine.")
            print("      Re-run on a real device before trusting any conclusion.")
            return
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            print("   ⚠️  no compatible audio format offered — cannot feed the analyzer.")
            return
        }
        print("   analyzer format: \(format.sampleRate) Hz, \(format.channelCount)ch, \(format.commonFormat.rawValue)")

        guard let spoken = await synthesize("The quick brown fox jumps over the lazy dog.") else {
            print("   ⚠️  AVSpeechSynthesizer produced no audio here — cannot feed the analyzer.")
            return
        }
        print("   synthesized \(spoken.count) buffers at \(spoken[0].format.sampleRate) Hz")

        let collector = Collector()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules)

        let transcriptTask = Task {
            do {
                for try await result in transcriber.results {
                    await collector.addTranscript(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                await collector.setTranscriberError("\(error)")
            }
        }
        let detectionTask = Task {
            do {
                for try await result in detector.results {
                    await collector.addDetection(result.speechDetected, at: result.range.start.seconds)
                }
            } catch {
                await collector.setDetectorError("\(error)")
            }
        }

        try await analyzer.prepareToAnalyze(in: format)

        var fed = 0
        for buffer in spoken {
            if let converted = convert(buffer, to: format) {
                continuation.yield(AnalyzerInput(buffer: converted))
                fed += 1
            }
        }
        // THE SILENCE. Two seconds of it, in chunks, so the detector sees a
        // sequence of quiet buffers rather than one long one.
        if let quiet = silence(seconds: 0.25, format: format) {
            for _ in 0..<8 {
                continuation.yield(AnalyzerInput(buffer: quiet))
                fed += 1
            }
        }
        print("   fed \(fed) buffers (speech + 2s silence), NOT calling finalize")

        // Give it room to decide on its own. If endpointing works, results land
        // in here without us asking.
        try? await Task.sleep(for: .seconds(6))
        let beforeFinalize = await collector.summary
        print("── BEFORE any finalize call ──")
        print(beforeFinalize)

        let autoFinalized = await collector.transcripts.contains { $0.isFinal }
        let detections = await collector.detections
        let sawSpeech = detections.contains { $0.speechDetected }
        let sawSilence = detections.contains { !$0.speechDetected }

        // Now close it properly and see what was being withheld.
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        try? await Task.sleep(for: .seconds(2))
        transcriptTask.cancel()
        detectionTask.cancel()

        print("── AFTER finalizeAndFinishThroughEndOfInput ──")
        print(await collector.summary)

        print("── VERDICT ──")
        print("   detector emitted speechDetected=true:   \(sawSpeech)")
        print("   detector emitted speechDetected=false:  \(sawSilence)")
        print("   → automatic stop is implementable:      \(sawSpeech && sawSilence)")
        print("   transcript finalized WITHOUT asking:    \(autoFinalized)")

        // The one hard assertion: if the detector reports nothing at all, it is
        // still not built, whatever the SDK declares.
        #expect(!detections.isEmpty, "SpeechDetector produced no results — still specced-but-not-built")
    }
}
