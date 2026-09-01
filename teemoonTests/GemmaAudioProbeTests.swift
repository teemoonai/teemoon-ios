//
//  GemmaAudioProbeTests.swift
//  teemoonTests
//
//  CAN THE ON-DEVICE MODEL HEAR?
//
//  The LiteRT-LM package teemoon already vendors exposes `Content.audioData` /
//  `Content.audioFile`, and `EngineConfig` already takes an `audioBackend` and
//  an `audioLoraRank`. Both are unused today — `LiteRTTransport` builds its
//  config with `backend: .gpu` and nothing else, so the audio executor is off.
//
//  If the shipped `.litertlm` bundle contains the audio encoder, then "speak to
//  Gemma" needs a config change and a message content case, and teemoon gets a
//  voice path with NO transcription service, NO second model, and (in the cloud
//  case) one that can ride the existing E2EE seal.
//
//  If it does not, this is a different download and a much bigger feature.
//
//  That is the only question here, and it is answered by running it.
//
//  REAL DEVICE ONLY (the simulator cannot load LiteRT), and the model must
//  already be downloaded through the app — this never pulls 2.5 GB itself.
//
//      xcodebuild test -destination 'platform=iOS,id=…' \
//        -only-testing:teemoonTests/GemmaAudioProbeTests
//

import AVFoundation
import Foundation
import LiteRTLM
import Testing

@testable import teemoon

// MARK: - Audio fixture

/// Synthesizes speech and writes it as 16 kHz mono PCM WAV — the format every
/// speech-conditioned model expects, and the one an app would produce from a
/// microphone tap.
private func makeSpokenWAV(_ text: String, named name: String) async -> URL? {
    let synth = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { continuation.finish() } else { continuation.yield(pcm) }
        }
    }

    var buffers: [AVAudioPCMBuffer] = []
    for await buffer in stream { buffers.append(buffer) }
    withExtendedLifetime(synth) {}
    guard let first = buffers.first else { return nil }

    guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                     channels: 1, interleaved: true) else { return nil }
    let url = FileManager.default.temporaryDirectory.appending(component: name)
    try? FileManager.default.removeItem(at: url)

    do {
        let file = try AVAudioFile(forWriting: url,
                                   settings: target.settings,
                                   commonFormat: .pcmFormatInt16,
                                   interleaved: true)
        guard let converter = AVAudioConverter(from: first.format, to: target) else { return nil }
        for buffer in buffers {
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { try file.write(from: out) }
            converter.reset()
        }
    } catch {
        print("   WAV write failed: \(error)")
        return nil
    }
    return url
}

// MARK: - The probe

/// Memory headroom, where the platform has such a concept.
///
/// `os_proc_available_memory()` is iOS-only, and deliberately so: it reports how
/// much THIS process may still allocate before jetsam kills it. macOS has no
/// per-process budget — it pages rather than killing — so there is no equivalent
/// number to print.
///
/// Substituting host free memory would compile and would be misleading: the two
/// platforms' logs would line up as if they measured the same thing, and the
/// whole point of this probe is judging whether a model fits inside a budget
/// that only one of them has. So macOS says so instead of guessing.
private func availableMemoryDescription() -> String {
    #if os(iOS)
    return "\(os_proc_available_memory() / 1_048_576) MB"
    #else
    return "n/a (macOS has no per-process jetsam budget)"
    #endif
}

@Suite("Gemma on-device audio probe",
       .enabled(if: voiceProbeEnabled(), "set TEST_RUNNER_VOICE_PROBE=1 (device only)"))
struct GemmaAudioProbeTests {

    /// What is actually on this phone, and how big is it? The bundle size is
    /// the cheapest signal about whether an audio encoder is in there.
    @Test("what local models are installed")
    func whatIsInstalled() async throws {
        print("── installed local models ──")
        for model in LocalModelCatalog.all {
            let installed = LocalModelStorage.isInstalled(model)
            var actualMB = 0
            if installed {
                let path = LocalModelStorage.file(for: model).path
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                actualMB = Int((attrs?[.size] as? Int64 ?? 0) / 1_048_576)
            }
            print("   \(model.id)")
            print("      installed: \(installed) · catalog says \(model.sizeMB) MB · on disk \(actualMB) MB")
        }
    }

    /// THE QUESTION. Load the installed model with the audio executor turned on
    /// and hand it a spoken WAV.
    ///
    /// Three outcomes, all informative:
    ///   • it answers about the audio        → the path is real, wire it up
    ///   • engine init fails with audio on   → the bundle has no audio encoder
    ///   • it answers as if audio were absent → the content case is ignored
    @Test("does the on-device model hear a spoken WAV?", .timeLimit(.minutes(10)))
    func gemmaHearsAudio() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── gemma audio ── ⚠️ no local model installed on this device; download one in the app first.")
            return
        }
        let path = LocalModelStorage.file(for: model).path
        print("── gemma audio ──")
        print("   model: \(model.id)")

        guard let wav = await makeSpokenWAV("What is the capital of France?", named: "probe-speech.wav") else {
            print("   ⚠️ could not synthesize the WAV fixture.")
            return
        }
        let wavBytes = (try? Data(contentsOf: wav).count) ?? 0
        print("   fixture: \(wav.lastPathComponent), \(wavBytes) bytes (16 kHz mono PCM)")

        LiteRTTransport.enableExperimentalFeatures()

        // AUDIO EXECUTOR ON. This is the one line teemoon does not ship today.
        // CPU for the audio encoder: the GPU path is the one the text runtime
        // was tuned for, and a failure there would be ambiguous between "no
        // audio weights" and "no GPU kernel for them".
        let config = try LiteRTLM.EngineConfig(
            modelPath: path,
            backend: .gpu,
            audioBackend: .cpu(),
            maxNumTokens: 2048,
            cacheDir: FileManager.default.temporaryDirectory.path
        )

        let engine = LiteRTLM.Engine(engineConfig: config)
        do {
            let start = ContinuousClock.now
            try await engine.initialize()
            print("   engine initialized WITH audioBackend in \(start.duration(to: .now))")
        } catch {
            print("── VERDICT ──")
            print("   engine init FAILED with the audio executor on: \(error)")
            print("   → the shipped bundle almost certainly has no audio encoder.")
            return
        }

        let conversation: LiteRTLM.Conversation
        do {
            conversation = try await engine.createConversation()
        } catch {
            print("   createConversation failed: \(error)")
            return
        }

        // Audio first, then the instruction — the ordering multimodal chat
        // templates expect.
        let message = LiteRTLM.Message(
            of: .audioFile(wav.path),
            .text("Answer the question you just heard. If you cannot hear any audio, say exactly: NO AUDIO."),
            role: .user
        )

        do {
            let start = ContinuousClock.now
            let reply = try await conversation.sendMessage(message)
            let took = start.duration(to: .now)
            let text = reply.toString
            print("── VERDICT ──")
            print("   replied in \(took)")
            print("   reply: \(text)")
            let heard = !text.uppercased().contains("NO AUDIO") && !text.isEmpty
            print("   → the model appears to have heard the audio: \(heard)")
            if heard {
                print("   → mentions Paris/France: \(text.lowercased().contains("paris") || text.lowercased().contains("france"))")
            }
        } catch {
            print("── VERDICT ──")
            print("   sendMessage FAILED with audio content: \(error)")
            print("   → audio content is not accepted by this bundle/runtime.")
        }
    }

    /// IS IT ACTUALLY LISTENING, OR JUST GUESSING?
    ///
    /// "What is the capital of France?" → "Paris" is not evidence: it is the
    /// most guessable answer in the language, and the prompt tells the model a
    /// question was asked. A model that hears nothing and bluffs produces the
    /// same output.
    ///
    /// So this asks for something no prior can supply — three arbitrary words —
    /// and runs the SAME prompt twice: once with the audio attached, once
    /// without. If the audio arm repeats the words and the no-audio arm does
    /// not, the model is genuinely hearing. Anything else and it is bluffing.
    @Test("discriminating: arbitrary words, with and without the audio", .timeLimit(.minutes(10)))
    func hearsSomethingUnguessable() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── discriminating ── ⚠️ no local model installed.")
            return
        }
        let secret = "purple elephant seventeen"
        guard let wav = await makeSpokenWAV("Repeat after me: \(secret).", named: "probe-secret.wav") else {
            print("   ⚠️ could not synthesize the WAV fixture.")
            return
        }

        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu,
            audioBackend: .cpu(),
            maxNumTokens: 2048,
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()

        let instruction = "Do exactly what the audio asks. If there is no audio, say exactly: NO AUDIO."

        // Arm A — audio attached.
        let withAudio = try await engine.createConversation()
        let replyA = try await withAudio.sendMessage(
            LiteRTLM.Message(of: .audioFile(wav.path), .text(instruction), role: .user)
        ).toString

        // Arm B — identical prompt, NO audio. The bluff detector.
        let withoutAudio = try await engine.createConversation()
        let replyB = try await withoutAudio.sendMessage(
            LiteRTLM.Message(of: .text(instruction), role: .user)
        ).toString

        let words = secret.split(separator: " ").map(String.init)
        let hitsA = words.filter { replyA.lowercased().contains($0) }
        let hitsB = words.filter { replyB.lowercased().contains($0) }

        print("── discriminating ──")
        print("   spoken (never in the text prompt): \"\(secret)\"")
        print("   WITH audio    → \(replyA)")
        print("   WITHOUT audio → \(replyB)")
        print("   secret words present — with: \(hitsA.count)/3 \(hitsA) · without: \(hitsB.count)/3 \(hitsB)")
        print("── VERDICT ──")
        print("   → genuinely hearing (not bluffing): \(hitsA.count >= 2 && hitsB.count == 0)")

        #expect(hitsA.count >= 2, "audio arm did not repeat the spoken words — the model is not hearing")
        #expect(hitsB.count == 0, "no-audio arm produced the words — the harness is leaking the secret")
    }

    /// WHY is it not hearing? Three candidate causes, and they have very
    /// different price tags:
    ///
    ///   a) the bundle has no audio encoder      → need a different artifact
    ///   b) audio needs the audio LoRA, absent   → need a second file
    ///   c) `.audioFile` path handling is broken → fix in our code, use bytes
    ///
    /// (a) is answered by scanning the `.litertlm` for audio-encoder markers,
    /// (b) by asking for a LoRA rank and seeing whether the runtime objects,
    /// (c) by sending the same audio as raw bytes instead of a path.
    @Test("why is it deaf — bundle contents, LoRA, and audioData", .timeLimit(.minutes(15)))
    func whyIsItDeaf() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── why deaf ── ⚠️ no local model installed.")
            return
        }
        let modelPath = LocalModelStorage.file(for: model).path
        print("── why deaf ──")

        // (a) Does the bundle contain an audio tower?
        //
        // THE FIRST VERSION OF THIS SCAN WAS BROKEN AND SAID NO.
        // It decoded each chunk with `String(data:encoding:.ascii)`, which
        // returns **nil** if any byte exceeds 127 — guaranteed in every chunk of
        // quantized weights. So the `if let` failed on all 309 chunks, nothing
        // was ever examined, and "no markers found" was a false negative that
        // read exactly like evidence. Search the BYTES.
        //
        // The section names come from litert-torch#1039, which inspected the
        // official bundle and found 12 sections including `tf_lite_audio_encoder_hw`.
        let markers = ["tf_lite_audio_encoder_hw", "tf_lite_audio_adapter",
                       "tf_lite_end_of_audio", "tf_lite_vision_encoder",
                       "tf_lite_prefill_decode", "audio"]
        var found: Set<String> = []
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath)) {
            defer { try? handle.close() }
            let chunkSize = 8 * 1024 * 1024
            var carry = Data()
            var scanned = 0
            let needles = markers.map { ($0, Data($0.utf8)) }
            while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
                let window = carry + chunk
                for (name, needle) in needles where !found.contains(name) {
                    if window.range(of: needle) != nil { found.insert(name) }
                }
                carry = chunk.suffix(64)
                scanned += chunk.count
                if found.count == markers.count { break }
            }
            print("   scanned \(scanned / 1_048_576) MB of the bundle")
        }
        print("   sections present: \(found.sorted())")
        print("   → bundle contains an AUDIO encoder: \(found.contains("tf_lite_audio_encoder_hw"))")
        print("   → (sanity) contains the vision encoder: \(found.contains("tf_lite_vision_encoder"))")

        LiteRTTransport.enableExperimentalFeatures()

        // (b) Ask for an audio LoRA. If the runtime rejects the rank, audio
        // weights are expected as a separate artefact this bundle lacks.
        for rank in [4, 16] {
            do {
                let config = try LiteRTLM.EngineConfig(
                    modelPath: modelPath, backend: .gpu, audioBackend: .cpu(),
                    maxNumTokens: 2048,
                    cacheDir: FileManager.default.temporaryDirectory.path,
                    audioLoraRank: rank
                )
                let engine = LiteRTLM.Engine(engineConfig: config)
                try await engine.initialize()
                print("   audioLoraRank \(rank): engine initialized OK")
            } catch {
                print("   audioLoraRank \(rank): FAILED — \(error)")
            }
        }

        // (c) Same audio, as bytes rather than a path.
        guard let wav = await makeSpokenWAV("Repeat after me: purple elephant seventeen.",
                                            named: "probe-bytes.wav"),
              let bytes = try? Data(contentsOf: wav) else {
            print("   ⚠️ no fixture for the bytes arm.")
            return
        }
        let config = try LiteRTLM.EngineConfig(
            modelPath: modelPath, backend: .gpu, audioBackend: .cpu(),
            maxNumTokens: 2048, cacheDir: FileManager.default.temporaryDirectory.path
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        let conversation = try await engine.createConversation()
        let instruction = "Do exactly what the audio asks. If there is no audio, say exactly: NO AUDIO."
        do {
            let reply = try await conversation.sendMessage(
                LiteRTLM.Message(of: .audioData(bytes), .text(instruction), role: .user)
            ).toString
            print("   .audioData (\(bytes.count) bytes) → \(reply)")
            print("   → bytes arm heard it: \(reply.lowercased().contains("purple"))")
        } catch {
            print("   .audioData FAILED — \(error)")
        }
    }

    /// THE LOW-LEVEL ROUTE. Bypasses the JSON message path entirely and feeds
    /// the runtime's own `kLiteRtLmInputDataTypeAudio` / `…AudioEnd` inputs via
    /// `litert_lm_session_generate_content` (see `Engine+RawAudio.swift`).
    ///
    /// Two formats, because the header says only "raw bytes": the WAV container
    /// and headerless PCM samples. Runtime logging is turned all the way up, so
    /// if the engine is refusing the audio it gets a chance to say so — the JSON
    /// path's defining feature was saying nothing at all.
    @Test("low-level input-data API: can the weights hear?", .timeLimit(.minutes(10)))
    func rawAudioInputPath() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── raw audio ── ⚠️ no local model installed.")
            return
        }
        guard let wav = await makeSpokenWAV("Repeat after me: purple elephant seventeen.",
                                            named: "probe-raw.wav"),
              let wavBytes = try? Data(contentsOf: wav) else {
            print("   ⚠️ no fixture.")
            return
        }
        // Headerless PCM: the same samples with the 44-byte RIFF header removed.
        let pcmBytes = wavBytes.count > 44 ? wavBytes.dropFirst(44) : Data()

        print("── raw audio (low-level API) ──")
        print("   wav: \(wavBytes.count) bytes · headerless pcm: \(pcmBytes.count) bytes")

        LiteRTTransport.enableExperimentalFeatures()
        LiteRTLM.Engine.enableVerboseLogging()

        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu,
            audioBackend: .cpu(),
            maxNumTokens: 2048,
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()

        // CONTROL MATRIX. `apply_prompt_template` on, versus supplying Gemma's
        // turn markers by hand with it off — the Conversation layer has
        // `renderMessageIntoString`, which implies the template is rendered
        // ABOVE this API rather than inside it.
        let plain = "What is the capital of France?"
        let gemmaTurns = "<start_of_turn>user\n\(plain)<end_of_turn>\n<start_of_turn>model\n"
        var control: LiteRTLM.Engine.RawResult?
        for (label, text, template) in [
            ("plain + template on",   plain,      true),
            ("plain + template off",  plain,      false),
            ("turn markers + off",    gemmaTurns, false),
            ("turn markers + on",     gemmaTurns, true),
        ] {
            let r = try await engine.lowLevelText(prompt: text, applyTemplate: template)
            print("   CONTROL \(label) → candidates=\(r.candidates) · \"\(r.text.prefix(80))\"")
            if !r.isEmpty, control == nil { control = r }
        }
        guard control != nil else {
            print("   ⚠️  no text combination produces output — the low-level route is not usable this way,")
            print("      so audio results below would be unattributable. Stopping.")
            return
        }
        print("   ✓ route is sound; audio is now the only variable")

        // Now the audio matrix. The control above proves the route works, so a
        // failure here is the runtime refusing the audio, not the harness.
        let prompt = "Do exactly what the audio asks. If there is no audio, say exactly: NO AUDIO."
        for (label, bytes) in [("wav", wavBytes), ("pcm", Data(pcmBytes))] {
            for layout in LiteRTLM.Engine.AudioLayout.allCases {
                let r = try await engine.lowLevelAudio(audio: bytes, prompt: prompt, layout: layout)
                print("   \(label) · \(r.route) → candidates=\(r.candidates) · \"\(r.text.prefix(90))\"")
                if r.text.lowercased().contains("purple") { print("      *** HEARD IT ***") }
            }
        }

        // Second engine: audio on the GPU rather than the CPU, in case the
        // refusal is about the executor and not the weights.
        let gpuAudioConfig = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu,
            audioBackend: .gpu,
            maxNumTokens: 2048,
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        do {
            let gpuEngine = LiteRTLM.Engine(engineConfig: gpuAudioConfig)
            try await gpuEngine.initialize()
            let r = try await gpuEngine.lowLevelAudio(audio: wavBytes, prompt: prompt, layout: .insideTurn)
            print("   audioBackend=.gpu · \(r.route) → candidates=\(r.candidates) · \"\(r.text.prefix(90))\"")
        } catch {
            print("   audioBackend=.gpu → engine init/threw: \(error)")
        }
    }

    /// WHAT DOES THE BUNDLE ITSELF SAY?
    ///
    /// The section table lives in the first few KB (`LlmMetadataProto` at
    /// 16384..28576 per litert-torch#1039). Dumping the printable strings from
    /// it is the cheapest way to learn what the audio stack expects — sample
    /// rate, adapter rank, feature type — instead of guessing.
    @Test("read the bundle's own metadata", .timeLimit(.minutes(5)))
    func bundleMetadata() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── metadata ── ⚠️ no local model installed."); return
        }
        guard let handle = try? FileHandle(forReadingFrom: LocalModelStorage.file(for: model)) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return }

        // Printable ASCII runs of 4+ chars — `strings(1)`, essentially.
        var runs: [String] = []
        var current: [UInt8] = []
        for byte in head {
            if byte >= 32, byte < 127 { current.append(byte) }
            else {
                if current.count >= 4, let s = String(bytes: current, encoding: .ascii) { runs.append(s) }
                current = []
            }
        }
        if current.count >= 4, let s = String(bytes: current, encoding: .ascii) { runs.append(s) }

        print("── bundle metadata (\(runs.count) strings in the first 64 KB) ──")
        let interesting = runs.filter { r in
            let l = r.lowercased()
            return ["audio", "rank", "lora", "sample", "mel", "frame", "hz", "adapter", "encoder", "token"]
                .contains { l.contains($0) }
        }
        for r in interesting.prefix(60) { print("   \(r)") }
        print("── all section-ish names ──")
        for r in runs where r.hasPrefix("tf_lite") || r.contains("Proto") || r.contains("Tokenizer") {
            print("   \(r)")
        }
    }

    /// DOES THE AUDIO SURVIVE TEMPLATING?
    ///
    /// The bundle's chat template renders `{'type':'audio'}` as `<|audio|>`,
    /// which is exactly what `Content.audioFile` serializes. `renderMessageIntoString`
    /// shows what the runtime actually made of the message — which splits
    /// "dropped in Swift/JSON" from "dropped inside the audio encoder", and
    /// those have completely different fixes.
    @Test("does audio survive the chat template?", .timeLimit(.minutes(10)))
    func audioSurvivesTemplating() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── templating ── ⚠️ no local model installed."); return
        }
        guard let wav = await makeSpokenWAV("Repeat after me: purple elephant seventeen.",
                                            named: "probe-tmpl.wav"),
              let bytes = try? Data(contentsOf: wav) else { return }

        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu, audioBackend: .cpu(),
            maxNumTokens: 2048, cacheDir: FileManager.default.temporaryDirectory.path)
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        let conversation = try await engine.createConversation()

        print("── templating ──")
        for (label, message) in [
            ("text only",   LiteRTLM.Message("hello there", role: .user)),
            ("audio file",  LiteRTLM.Message(of: .audioFile(wav.path), .text("what did I say?"), role: .user)),
            ("audio bytes", LiteRTLM.Message(of: .audioData(bytes), .text("what did I say?"), role: .user)),
        ] {
            do {
                let rendered = try conversation.renderMessageIntoString(message)
                // The audio blob would drown the log, so report shape not content.
                let hasToken = rendered.contains("<|audio|>") || rendered.contains("<|audio>")
                print("   \(label): \(rendered.count) chars · contains <|audio|>: \(hasToken)")
                let preview = rendered.count > 300
                    ? String(rendered.prefix(150)) + " … " + String(rendered.suffix(150))
                    : rendered
                print("      \(preview.replacingOccurrences(of: "\n", with: "\\n"))")
            } catch {
                print("   \(label): render THREW \(error)")
            }
        }
    }

    /// ASK IT THE TASK IT WAS TRAINED ON.
    ///
    /// Every previous attempt used an adversarial instruction — "do what the
    /// audio asks; if there is no audio say NO AUDIO" — which is a compound
    /// conditional for a 2B model, and "NO AUDIO" is the easy way out of a
    /// prompt it doesn't follow. Meanwhile the logs show the audio front-end
    /// running: `AudioLiteRtCompiledModelExecutor created`, `Gemma4DataProcessor`,
    /// mel filterbank at 16 kHz / 128 channels.
    ///
    /// Gemma 4 E2B is trained for ASR. So: just ask it to transcribe.
    @Test("plain transcription prompts", .timeLimit(.minutes(10)))
    func plainTranscriptionPrompts() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── plain prompts ── ⚠️ no local model installed."); return
        }
        let secret = "purple elephant seventeen"
        guard let wav = await makeSpokenWAV("Repeat after me: \(secret).", named: "probe-plain.wav"),
              let bytes = try? Data(contentsOf: wav) else { return }

        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu, audioBackend: .cpu(),
            maxNumTokens: 2048, cacheDir: FileManager.default.temporaryDirectory.path)
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()

        print("── plain prompts ── spoken: \"\(secret)\"")
        let prompts = [
            "Transcribe this audio.",
            "Transcribe the audio.",
            "What did I say?",
            "Write down exactly what you hear.",
            "",                       // audio alone, no instruction at all
        ]
        for prompt in prompts {
            // Fresh conversation each time: a previous turn's answer in context
            // would let it copy itself rather than listen.
            let conversation = try await engine.createConversation()
            let message = prompt.isEmpty
                ? LiteRTLM.Message(of: .audioFile(wav.path), role: .user)
                : LiteRTLM.Message(of: .audioFile(wav.path), .text(prompt), role: .user)
            do {
                let reply = try await conversation.sendMessage(message).toString
                let heard = reply.lowercased().contains("purple")
                print("   \"\(prompt.isEmpty ? "<audio only>" : prompt)\" → \(reply.prefix(160))")
                if heard { print("      *** HEARD IT ***") }
            } catch {
                print("   \"\(prompt)\" → THREW \(error)")
            }
        }

        // And the same through raw bytes, in case the file path is the problem.
        let conversation = try await engine.createConversation()
        let reply = try await conversation.sendMessage(
            LiteRTLM.Message(of: .audioData(bytes), .text("Transcribe this audio."), role: .user)).toString
        print("   [audioData] \"Transcribe this audio.\" → \(reply.prefix(160))")
        if reply.lowercased().contains("purple") { print("      *** HEARD IT ***") }
    }

    /// WHAT CAN IT ACTUALLY DO, AND WHERE DOES IT BREAK?
    ///
    /// Transcription is proven. This maps the product surface around it —
    /// Gemma 4's audio tower is trained for ASR *and* speech translation, so
    /// the question is what else the same weights give us for free, and what
    /// the hard edges are (the documented 30 s cap, latency against Apple's
    /// effectively-instant dictation, memory while a chat is live).
    @Test("capabilities and limits", .timeLimit(.minutes(20)))
    func capabilitiesAndLimits() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── capabilities ── ⚠️ no local model installed."); return
        }
        print("── capabilities & limits ── model: \(model.id)")
        print("   available memory before load: \(availableMemoryDescription())")

        // Fixtures of increasing length. 40 s deliberately exceeds the stated
        // 30 s ceiling — the question is whether it errors, truncates silently,
        // or copes.
        let short = "Repeat after me: purple elephant seventeen."
        let medium = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. "
            + "How razorback jumping frogs can level six piqued gymnasts."
        let long = String(repeating: "The rain in Spain falls mainly on the plain. ", count: 22)

        guard let shortURL = await makeSpokenWAV(short, named: "cap-short.wav"),
              let mediumURL = await makeSpokenWAV(medium, named: "cap-medium.wav"),
              let longURL = await makeSpokenWAV(long, named: "cap-long.wav") else {
            print("   ⚠️ fixtures failed"); return
        }
        func seconds(_ url: URL) -> Double {
            let bytes = (try? Data(contentsOf: url).count) ?? 44
            return Double(bytes - 44) / (16000 * 2)   // 16 kHz mono int16
        }
        print("   fixtures: short \(String(format: "%.1f", seconds(shortURL)))s · "
              + "medium \(String(format: "%.1f", seconds(mediumURL)))s · "
              + "long \(String(format: "%.1f", seconds(longURL)))s")

        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu, audioBackend: .cpu(),
            maxNumTokens: 4096, cacheDir: FileManager.default.temporaryDirectory.path)
        let engine = LiteRTLM.Engine(engineConfig: config)
        let loadStart = ContinuousClock.now
        try await engine.initialize()
        print("   engine load: \(loadStart.duration(to: .now)) · available memory after: \(availableMemoryDescription())")

        func ask(_ label: String, _ url: URL, _ prompt: String) async {
            do {
                let conversation = try await engine.createConversation()
                let start = ContinuousClock.now
                let reply = try await conversation.sendMessage(
                    LiteRTLM.Message(of: .audioFile(url.path), .text(prompt), role: .user)).toString
                let took = start.duration(to: .now)
                let audio = seconds(url)
                let secs = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
                print("   [\(label)] \(String(format: "%.2f", secs))s for \(String(format: "%.1f", audio))s audio "
                      + "(\(String(format: "%.2fx", audio / max(secs, 0.001))) realtime)")
                print("      → \(reply.replacingOccurrences(of: "\n", with: " ").prefix(220))")
            } catch {
                print("   [\(label)] THREW: \(error)")
            }
        }

        print("── 1. LATENCY by input length ──")
        await ask("short",  shortURL,  "Transcribe this audio.")
        await ask("medium", mediumURL, "Transcribe this audio.")

        print("── 2. THE 30-SECOND CEILING ──")
        await ask("long/40s", longURL, "Transcribe this audio.")

        print("── 3. SPEECH TRANSLATION (the other trained task) ──")
        await ask("→french",  mediumURL, "Translate what you hear into French.")
        await ask("→spanish", shortURL,  "Translate what you hear into Spanish.")

        print("── 4. UNDERSTANDING, NOT JUST TRANSCRIBING ──")
        await ask("summarise", mediumURL, "Summarise what the speaker said in one short sentence.")
        await ask("question",  mediumURL, "What animal is mentioned in this audio? Answer with one word.")
        await ask("language",  shortURL,  "What language is being spoken? Answer with one word.")

        print("   available memory at end: \(availableMemoryDescription())")
    }

    /// IS THERE ACTUALLY A 30-SECOND CEILING?
    ///
    /// The earlier "it truncates silently" result used a fixture that was the
    /// SAME SENTENCE repeated 22 times. A model handed 22 identical sentences
    /// may well answer with one — because that is what was said — and that is
    /// indistinguishable from truncation. Same confound as every other wrong
    /// call this session: no control.
    ///
    /// The runtime disagrees with me too:
    ///   "Max sequence length is not used for AudioLiteRtCompiledModelExecutor,
    ///    which can handle variable length input."
    ///
    /// So: a long fixture of DISTINCT, numbered sentences, and count how many
    /// survive. If sentence twenty comes back, there is no 30 s ceiling.
    @Test("how long can it actually listen?", .timeLimit(.minutes(20)))
    func howLongCanItListen() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── duration ── ⚠️ no local model installed."); return
        }
        // Distinct, countable, and hard to confuse with each other.
        let animals = ["fox", "badger", "otter", "heron", "weasel", "marten", "stoat", "shrew",
                       "vole", "lynx", "raven", "adder", "newt", "pike", "grebe", "hare",
                       "mole", "wren", "crane", "eel", "toad", "finch", "owl", "bat"]
        func fixture(sentences: Int) -> String {
            (0..<sentences).map { "Sentence number \($0 + 1) mentions the \(animals[$0 % animals.count])." }
                .joined(separator: " ")
        }

        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu, audioBackend: .cpu(),
            maxNumTokens: 4096, cacheDir: FileManager.default.temporaryDirectory.path)
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()

        print("── duration ceiling ──")
        for count in [6, 14, 24, 40] {
            guard let url = await makeSpokenWAV(fixture(sentences: count), named: "dur-\(count).wav"),
                  let data = try? Data(contentsOf: url) else { continue }
            let seconds = Double(data.count - 44) / (16000 * 2)
            let conversation = try await engine.createConversation()
            let start = ContinuousClock.now
            let reply = (try? await conversation.sendMessage(
                LiteRTLM.Message(of: .audioFile(url.path), .text("Transcribe this audio."), role: .user)
            ).toString) ?? "<threw>"
            let took = start.duration(to: .now)
            let secs = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18

            // How far into the audio did it actually get?
            let lower = reply.lowercased()
            let survived = (1...count).filter { n in
                lower.contains("number \(n) ") || lower.contains("number \(n).")
                    || lower.contains(animals[(n - 1) % animals.count])
            }
            let last = survived.last ?? 0
            print("   \(count) sentences · \(String(format: "%.1f", seconds))s audio → \(String(format: "%.1f", secs))s")
            print("      recovered \(survived.count)/\(count), furthest = sentence \(last) "
                  + "(≈\(String(format: "%.0f", seconds * Double(last) / Double(count)))s in)")
            print("      \(reply.replacingOccurrences(of: "\n", with: " ").prefix(150))")
        }
    }

    /// Control: the same engine and the same question as TEXT. Proves the model
    /// and the harness are working, so a failure above is about audio and not
    /// about everything else.
    @Test("control — same question as text", .timeLimit(.minutes(10)))
    func textControl() async throws {
        guard let model = LocalModelCatalog.all.first(where: { LocalModelStorage.isInstalled($0) }) else {
            print("── text control ── ⚠️ no local model installed.")
            return
        }
        LiteRTTransport.enableExperimentalFeatures()
        let config = try LiteRTLM.EngineConfig(
            modelPath: LocalModelStorage.file(for: model).path,
            backend: .gpu,
            maxNumTokens: 2048,
            cacheDir: FileManager.default.temporaryDirectory.path
        )
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        let conversation = try await engine.createConversation()
        let reply = try await conversation.sendMessage(LiteRTLM.Message("What is the capital of France?"))
        print("── text control ──")
        print("   reply: \(reply.toString)")
    }
}
