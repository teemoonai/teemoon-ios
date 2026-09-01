//
//  Engine+RawAudio.swift
//  LiteRTLM
//
//  ADDED BY teemoon — not upstream. Delete if upstream ships an audio path.
//
//  WHY THIS EXISTS
//
//  `Content.audioData` / `.audioFile` go through `Conversation.sendMessage`,
//  which serializes to JSON and calls `litert_lm_conversation_send_message`.
//  Measured on device: audio sent that way is silently discarded — the model
//  answers as though none arrived, with no error at any layer.
//
//  The C API has a SEPARATE route the Swift wrapper never touches (not one
//  reference to `input_data` in the whole package):
//
//      kLiteRtLmInputDataTypeAudio / …AudioEnd
//      litert_lm_input_data_create(type, bytes, size)
//      litert_lm_session_run_prefill(session, inputs, n) → run_decode(session)
//
//  TWO THINGS THE FIRST ATTEMPT GOT WRONG, both found by the text-only control:
//    1. `litert_lm_engine_create_session(handle, nil)` takes the DEFAULT session
//       config, which does not apply the prompt template — so even text came
//       back empty. Gemma without its template is not being asked anything.
//    2. `generate_content` returned NULL where prefill+decode is the documented
//       sequence.
//
//  The control matters more than the feature here: without a text answer coming
//  out of this exact route, an audio silence is unattributable.
//

import CLiteRTLM
import Foundation
import OSLog

extension Engine {

    /// What came back, and by which route — so a caller can tell "the model said
    /// nothing" apart from "the call failed".
    public struct RawResult: Sendable {
        public let text: String
        public let route: String
        public let candidates: Int
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Builds a session that is actually asked a question: prompt template on,
    /// room to answer.
    private func makeSession(applyTemplate: Bool = true, audioLoraPath: String? = nil) throws -> (OpaquePointer, OpaquePointer?) {
        guard let handle else { throw LiteRTLMError.engine(.notInitialized) }
        guard let config = litert_lm_session_config_create() else {
            throw LiteRTLMError.engine(.failedToCreateSessionConfig)
        }
        // THE FIX. Without the template the model receives a bare token stream
        // with no turn markers and answers with nothing.
        litert_lm_session_config_set_apply_prompt_template(config, applyTemplate)
        litert_lm_session_config_set_max_output_tokens(config, 256)
        if let audioLoraPath {
            _ = litert_lm_session_config_set_audio_lora_path(config, audioLoraPath)
        }
        guard let session = litert_lm_engine_create_session(handle, config) else {
            litert_lm_session_config_delete(config)
            throw LiteRTLMError.engine(.failedToCreateConversation)
        }
        return (session, config)
    }

    /// `max_output_tokens` is documented as a per-DECODE-STEP cap, so one call
    /// to `run_decode` is not necessarily a whole answer — and an empty first
    /// step reads exactly like a model that said nothing. Loops until a step
    /// yields no new text.
    private func drainDecode(_ session: OpaquePointer, route: String, steps: Int = 16) -> RawResult {
        var accumulated = ""
        var lastCandidates = 0
        for step in 0..<steps {
            guard let responses = litert_lm_session_run_decode(session) else {
                return RawResult(text: accumulated.isEmpty ? "<NULL at step \(step)>" : accumulated,
                                 route: route, candidates: lastCandidates)
            }
            let n = Int(litert_lm_responses_get_num_candidates(responses))
            lastCandidates = n
            var chunk = ""
            if n > 0, let text = litert_lm_responses_get_response_text_at(responses, 0) {
                chunk = String(cString: text)
            }
            litert_lm_responses_delete(responses)
            if chunk.isEmpty { break }
            accumulated += chunk
        }
        return RawResult(text: accumulated, route: route, candidates: lastCandidates)
    }

    private func readResponses(_ responses: OpaquePointer?, route: String) -> RawResult {
        guard let responses else { return RawResult(text: "<NULL>", route: route, candidates: 0) }
        defer { litert_lm_responses_delete(responses) }
        let n = Int(litert_lm_responses_get_num_candidates(responses))
        guard n > 0, let text = litert_lm_responses_get_response_text_at(responses, 0) else {
            return RawResult(text: "", route: route, candidates: n)
        }
        return RawResult(text: String(cString: text), route: route, candidates: n)
    }

    /// THE CONTROL. Text only, through the same low-level route the audio uses.
    /// If this answers, the route is sound and audio is the only variable.
    public func lowLevelText(prompt: String, applyTemplate: Bool = true) throws -> RawResult {
        let (session, config) = try makeSession(applyTemplate: applyTemplate)
        defer {
            litert_lm_session_delete(session)
            if let config { litert_lm_session_config_delete(config) }
        }

        let bytes = Array(prompt.utf8)
        let input: OpaquePointer? = bytes.withUnsafeBytes {
            litert_lm_input_data_create(kLiteRtLmInputDataTypeText, $0.baseAddress, $0.count)
        }
        guard let input else { return RawResult(text: "<no input>", route: "text", candidates: 0) }
        defer { litert_lm_input_data_delete(input) }

        var inputs: [OpaquePointer?] = [input]
        let status = inputs.withUnsafeBufferPointer {
            litert_lm_session_run_prefill(session, $0.baseAddress, $0.count)
        }
        guard status == 0 else {
            return RawResult(text: "<prefill failed: \(status)>", route: "text", candidates: 0)
        }
        return drainDecode(session, route: "text template=\(applyTemplate)")
    }

    /// Audio through the low-level route.
    ///
    /// - Parameters:
    ///   - audio: raw bytes — the header says only that, so callers should try
    ///     both a WAV container and headerless PCM.
    ///   - prompt: text accompanying the audio.
    ///   - sendAudioEnd: whether to emit the `…AudioEnd` marker. A separate case
    ///     in the enum, and the JSON path has no way to express it — which is a
    ///     candidate reason that path produces nothing.
    ///   - audioLoraPath: optional audio LoRA, if one is ever shipped alongside.
    /// Where the audio sits relative to the text, since the turn-marker finding
    /// showed this API is unforgiving about exactly what it is handed.
    public enum AudioLayout: String, Sendable, CaseIterable {
        /// audio, end-marker, then the instruction
        case audioThenText
        /// just the audio, nothing else
        case audioOnly
        /// a rendered user turn opened, audio inside it, then the model marker
        case insideTurn
    }

    /// Audio through the low-level route.
    ///
    /// - Parameters:
    ///   - audio: raw bytes — the header says only that, so callers should try
    ///     both a WAV container and headerless PCM.
    ///   - prompt: text accompanying the audio.
    ///   - layout: where the audio sits relative to the text.
    ///   - sendAudioEnd: whether to emit the `…AudioEnd` marker. A separate case
    ///     in the enum, and the JSON path has no way to express it.
    public func lowLevelAudio(
        audio: Data,
        prompt: String,
        layout: AudioLayout = .audioThenText,
        sendAudioEnd: Bool = true,
        applyTemplate: Bool = false,
        audioLoraPath: String? = nil
    ) throws -> RawResult {
        let (session, config) = try makeSession(applyTemplate: applyTemplate, audioLoraPath: audioLoraPath)
        defer {
            litert_lm_session_delete(session)
            if let config { litert_lm_session_config_delete(config) }
        }

        var inputs: [OpaquePointer?] = []
        defer { for i in inputs where i != nil { litert_lm_input_data_delete(i) } }

        func addText(_ string: String) {
            let bytes = Array(string.utf8)
            let input: OpaquePointer? = bytes.withUnsafeBytes {
                litert_lm_input_data_create(kLiteRtLmInputDataTypeText, $0.baseAddress, $0.count)
            }
            if let input { inputs.append(input) }
        }
        func addAudio() -> Bool {
            let input: OpaquePointer? = audio.withUnsafeBytes {
                litert_lm_input_data_create(kLiteRtLmInputDataTypeAudio, $0.baseAddress, $0.count)
            }
            guard let input else { return false }
            inputs.append(input)
            if sendAudioEnd, let end = litert_lm_input_data_create(kLiteRtLmInputDataTypeAudioEnd, nil, 0) {
                inputs.append(end)
            }
            return true
        }

        switch layout {
        case .audioThenText:
            guard addAudio() else { return RawResult(text: "<audio rejected at creation>", route: layout.rawValue, candidates: 0) }
            addText(prompt)
        case .audioOnly:
            guard addAudio() else { return RawResult(text: "<audio rejected at creation>", route: layout.rawValue, candidates: 0) }
        case .insideTurn:
            addText("<start_of_turn>user\n")
            guard addAudio() else { return RawResult(text: "<audio rejected at creation>", route: layout.rawValue, candidates: 0) }
            addText("\n\(prompt)<end_of_turn>\n<start_of_turn>model\n")
        }

        let route = "\(layout.rawValue) end=\(sendAudioEnd)"
        let status = inputs.withUnsafeBufferPointer {
            litert_lm_session_run_prefill(session, $0.baseAddress, $0.count)
        }
        guard status == 0 else {
            return RawResult(text: "<prefill failed: \(status)>", route: route, candidates: 0)
        }
        return drainDecode(session, route: route)
    }

    /// Turns the runtime's own logging all the way up. Goes to os_log, so read it
    /// in Console.app — it does not appear in xcodebuild output.
    public static func enableVerboseLogging() {
        litert_lm_set_min_log_level(0)
    }
}
