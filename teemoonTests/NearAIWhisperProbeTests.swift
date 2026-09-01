//
//  NearAIWhisperProbeTests.swift
//  teemoonTests
//
//  IS THERE SUCH A THING AS VERIFIABLE TRANSCRIPTION?
//
//  Cloud transcription cannot be end-to-end
//  encrypted, because the E2EE codec seals JSON fields of `/chat/completions`
//  and no attested provider exposes a transcription endpoint. The second half
//  of that turns out to be wrong: near.ai's live catalogue lists
//
//      openai/whisper-large-v3   input_modalities: ["audio"]
//
//  alongside 49 text/vision models. If that endpoint works, and if it runs in
//  the same attested enclaves as the chat models, then teemoon can offer
//  something nobody else can — transcription the user can verify was
//  unreadable. That would make voice the SECOND feature carrying the trust
//  story, not an exception to it.
//
//  Runs on device because that is where a valid key lives (the `~/.NEAR_AI_API_KEY`
//  file on the Mac is stale, and `/v1/models` does not validate keys at all —
//  it answers 200 for a garbage bearer, which is its own small finding).
//
//  COSTS A FEW CENTS. Opt in:
//      VOICE_PROBE=1 xcodebuild test -destination 'platform=iOS,id=…' \
//        -only-testing:teemoonTests/NearAIWhisperProbeTests
//

import AVFoundation
import Foundation
import Testing

@testable import teemoon

/// Free-standing rather than a static on the suite: referencing the suite's own
/// members from inside its `@Suite` attribute is a circular macro reference and
/// does not compile.
func voiceProbeEnabled() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["VOICE_PROBE"] != nil || env["TEST_RUNNER_VOICE_PROBE"] != nil
}

@Suite("near.ai confidential transcription probe",
       .enabled(if: voiceProbeEnabled(), "set VOICE_PROBE=1 (device only, costs money)"))
struct NearAIWhisperProbeTests {

    /// 16 kHz mono PCM WAV, synthesized — no microphone, so this runs anywhere.
    private func spokenWAV(_ text: String) async -> Data? {
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
        for await b in stream { buffers.append(b) }
        withExtendedLifetime(synth) {}
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: first.format, to: target)
        else { return nil }

        let url = FileManager.default.temporaryDirectory.appending(component: "nearai-probe.wav")
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: target.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            for buffer in buffers {
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (target.sampleRate / buffer.format.sampleRate)) + 1024
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
        } catch { return nil }
        return try? Data(contentsOf: url)
    }

    private func multipartBody(wav: Data, model: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    @Test("does near.ai transcribe, and can it be verified?", .timeLimit(.minutes(5)))
    @MainActor
    func whisperOnNearAI() async throws {
        let provider = Provider.nearAI
        let key = ProviderStore().credential(for: provider)
        guard !key.isEmpty else {
            print("── near.ai whisper ── ⚠️ no key in the Keychain on this device; configure near.ai in the app first.")
            return
        }
        // The spoken phrase is deliberately unguessable, for the same reason the
        // Gemma probe needed one: a plausible transcript is not evidence.
        let secret = "purple elephant seventeen"
        guard let wav = await spokenWAV("Repeat after me: \(secret).") else {
            print("   ⚠️ could not synthesize the fixture.")
            return
        }
        print("── near.ai whisper ──")
        print("   fixture: \(wav.count) bytes, 16 kHz mono WAV")

        let boundary = "teemoon-probe-boundary"
        var request = URLRequest(url: URL(string: "https://cloud-api.near.ai/v1/audio/transcriptions")!,
                                 timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(wav: wav, model: "openai/whisper-large-v3", boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("   HTTP \(http?.statusCode ?? -1)")
        print("   body: \(body.prefix(600))")

        // THE ATTESTATION QUESTION, asked of the response itself. If the
        // transcription service publishes the same headers the chat path does,
        // the trust ladder can climb it too.
        let interesting = (http?.allHeaderFields ?? [:]).compactMap { k, v -> String? in
            let key = "\(k)".lowercased()
            guard key.contains("attest") || key.contains("quote") || key.contains("signature")
                    || key.contains("e2ee") || key.contains("pubkey") || key.contains("enclave")
            else { return nil }
            return "\(k): \(v)"
        }
        print("   trust-ish response headers: \(interesting.isEmpty ? ["none"] : interesting)")

        let heard = body.lowercased().contains("purple")
        print("── VERDICT ──")
        print("   transcribed the unguessable phrase: \(heard)")
    }

    /// Does the transcription host serve an attestation report at all? The chat
    /// path fetches one per model host; if the same shape exists here, verified
    /// transcription is reachable with the machinery teemoon already has.
    @Test("is the transcription endpoint attested?", .timeLimit(.minutes(3)))
    @MainActor
    func isTranscriptionAttested() async throws {
        let key = ProviderStore().credential(for: Provider.nearAI)
        guard !key.isEmpty else { print("── attestation ── ⚠️ no key."); return }

        // Same paths the confidential session probes for the chat models.
        let candidates = [
            "https://cloud-api.near.ai/v1/attestation/report",
            "https://cloud-api.near.ai/v1/attestation",
        ]
        print("── attestation surface ──")
        for path in candidates {
            var request = URLRequest(url: URL(string: path)!, timeoutInterval: 30)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                print("   \(path) → HTTP \(code): \(body)")
            } catch {
                print("   \(path) → error \(error.localizedDescription)")
            }
        }
    }
}
