//
//  LocalToolSupportSweepTests.swift
//  teemoonTests
//
//  Measures the claim `LocalModel.supportsTools` makes.
//
//  Every catalog entry says `true`, and until this file nothing had demonstrated
//  it for four of the six. That flag is not decorative: it becomes
//  `modelCapabilities: [.tools]` on the provider, which decides whether tools are
//  attached at all. Claiming it falsely means a model that cannot call gets
//  handed a web_search tool and answers from stale weights instead — a confident
//  wrong answer, which is worse than an honest "I can't check that".
//
//  So this measures each INSTALLED model the way the app runs it:
//  `LocalLanguageModel` + `LanguageModelSession` + `GenerationEngine`, real
//  persona, real defaults, a question phrased like a user's. Not the transport —
//  transport-level results have already been shown to disagree with the app.
//
//  It never downloads. Models that aren't on the device are reported as
//  unmeasured rather than silently skipped, because "no data" and "no tool
//  support" must not look the same.
//
//  REAL DEVICE ONLY (MLX aborts in the simulator):
//
//      TEST_RUNNER_LOCAL_TOOL_SWEEP=1 xcodebuild test … \
//        -only-testing:'teemoonTests/LocalToolSupportSweepTests/measuresToolCallRatePerInstalledModel()'
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

/// Hands back a plausible answer, with no network.
///
/// Plausible is the operative word: given a nonsense token where a price
/// belongs, a model runs the tool and then declines to repeat it, because
/// teemoon's persona forbids improvising. That reads as a tool failure and is
/// not one — see `LiteRTLiveTests`.
private struct SweepPlantedTool: Tool {
    let name = "web_search"
    let description = "Search the web for current, real-time information: recent events, "
        + "news, live prices, or anything that may have changed since training."
    let ran: LockedBox<Bool>

    @Generable struct Arguments: Sendable {
        @Guide(description: "The search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        ran.value = true
        return "Brent crude is trading at $147.63 per barrel as of this morning."
    }
}

@Suite("Local tool-support sweep (live)", .serialized)
struct LocalToolSupportSweepTests {

    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let env = ProcessInfo.processInfo.environment
        return env["LOCAL_TOOL_SWEEP"] != nil || env["TEST_RUNNER_LOCAL_TOOL_SWEEP"] != nil
        #endif
    }

    /// Seconds of sustained generation to allow one model before moving on.
    ///
    /// Not a correctness threshold — a budget for the *device*. 120 s is already
    /// far past the point where a model is usable in a chat, so a model that
    /// hits it has answered the question regardless of its call rate.
    static let thermalBudgetSeconds = 120.0

    /// Hard ceiling on a SINGLE generation, enforced by cancelling it.
    ///
    /// The between-prompts budget above is not enough on its own: Qwen3.5-4B
    /// produced one 173 s generation, so the phone had already done ~250 s of
    /// saturated GPU before the budget could stop anything — and that is the
    /// condition that drops the device off Wi-Fi mid-run.
    ///
    /// This works only because both token loops check `Task.isCancelled`
    /// (`MLXTransport`, `LiteRTTransport`), so cancelling genuinely stops the
    /// GPU rather than just abandoning the wait. A model that trips this is
    /// recorded as too slow, which is a real result: 45 s is already far outside
    /// anything usable in a chat.
    static let perTrialTimeoutSeconds = 45.0

    /// Questions a user would plausibly type, all of which need current
    /// information. No tool is named in any of them — naming it measures
    /// instruction-following, not the decision to search, and that distinction
    /// is exactly where the earlier transport tests flattered the models.
    static let prompts = [
        "What's the price of oil right now?",
        "Who won the F1 race this weekend?",
        "What's the latest news about the Fed's interest rate decision?",
    ]

    /// One generation through the app's own stack. Returns whether the tool ran.
    @MainActor
    private func trial(_ ref: LocalModelRef, prompt: String) async -> (ran: Bool, seconds: Double, reply: String) {
        let ran = LockedBox<Bool>(false)
        let lm = LocalLanguageModel(
            model: ref,
            priorMessages: [WireMessage(
                role: "system",
                content: ChatGeneration.resolvePromptTemplates(AppSettings.defaultSystemPrompt)
            )],
            events: StreamCallbacks(onSourcesFound: { _ in }, onQueriesFound: { _ in },
                                    onToolExecutionEnded: {}, onSuccess: { _ in })
            // Defaults everywhere else: overriding temperature or maxTokens here
            // would measure a configuration the app never ships.
        )
        let session = LanguageModelSession(model: lm, tools: [SweepPlantedTool(ran: ran)])

        let start = ContinuousClock.now
        var reply = ""

        // Race the generation against a deadline and CANCEL it if the deadline
        // wins — see `perTrialTimeoutSeconds`. Letting one model decode for
        // three minutes is how the device ends up off Wi-Fi.
        let generation = Task { @MainActor in
            var text = ""
            for try await snapshot in session.streamResponse(to: prompt) { text = snapshot.content }
            return text
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(Self.perTrialTimeoutSeconds))
            generation.cancel()
        }
        do {
            reply = try await generation.value
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            reply = generation.isCancelled
                ? "<cancelled: exceeded \(Int(Self.perTrialTimeoutSeconds))s>"
                : "<threw: \(error)>"
        }
        let seconds = Double(start.duration(to: .now).components.seconds)
            + Double(start.duration(to: .now).components.attoseconds) / 1e18
        return (ran.value, seconds, reply)
    }

    /// The sweep. Prints a table; asserts only that something was measurable.
    ///
    /// Deliberately not asserting a rate: the correct value of `supportsTools`
    /// is a judgement about a measured number, and encoding today's number as a
    /// threshold would turn a stochastic model behaviour into a flaky test.
    @Test(.enabled(if: Self.enabled, "set LOCAL_TOOL_SWEEP=1 (device only, slow)"),
          .timeLimit(.minutes(60)))
    @MainActor
    func measuresToolCallRatePerInstalledModel() async throws {
        var measured = 0
        var lines: [String] = []

        // Optional filter, so a run can target one model instead of every
        // installed one. Each model costs minutes of sustained GPU and heats the
        // phone, so re-measuring a model whose number has not changed is pure
        // cost:
        //
        //     TEST_RUNNER_SWEEP_ONLY=gemma-4-E4B
        //
        // Substring match against the id, so a short fragment is enough.
        let env = ProcessInfo.processInfo.environment
        let only = env["SWEEP_ONLY"] ?? env["TEST_RUNNER_SWEEP_ONLY"]

        for model in LocalModelCatalog.all {
            if let only, !model.id.localizedCaseInsensitiveContains(only) {
                lines.append("\(model.displayName.padded(24)) skipped (SWEEP_ONLY=\(only))")
                continue
            }
            guard LocalModelStorage.isInstalled(model) else {
                lines.append("\(model.displayName.padded(24)) NOT INSTALLED — unmeasured")
                continue
            }
            guard let ref = LocalModelStorage.ref(for: model.id) else {
                lines.append("\(model.displayName.padded(24)) installed but ref() returned nil — BUG")
                continue
            }

            var called = 0
            var totalSeconds = 0.0
            var attempted = 0
            var firstReply = ""
            for prompt in Self.prompts {
                let result = await trial(ref, prompt: prompt)
                attempted += 1
                if result.ran { called += 1 }
                totalSeconds += result.seconds
                if firstReply.isEmpty { firstReply = result.reply }
                print("[sweep] \(model.displayName) · \"\(prompt.prefix(34))…\" "
                      + "ran=\(result.ran) \(String(format: "%.1f", result.seconds))s")

                // STOP A MODEL THAT IS COOKING THE PHONE.
                //
                // Qwen3.5 4B took 78 s and then 173 s on two consecutive
                // prompts, and the test host died partway through the third —
                // the device dropped off Wi-Fi, which sustained local decoding
                // is already known to cause (see `LocalLanguageModel`:
                // "hot enough to take Wi-Fi and the app down with it").
                //
                // Losing the run is bad enough; losing the OTHER models'
                // results with it is worse, and that is what nearly happened.
                // A model this slow has already answered the question — it is
                // not usable interactively whatever its call rate.
                if totalSeconds > Self.thermalBudgetSeconds {
                    print("[sweep] \(model.displayName) exceeded the thermal budget — stopping early")
                    break
                }
            }
            measured += 1
            let mean = totalSeconds / Double(attempted)
            let partial = attempted < Self.prompts.count ? " (stopped early)" : ""
            lines.append("\(model.displayName.padded(24)) called \(called)/\(attempted)\(partial) "
                         + "· \(String(format: "%.1f", mean))s mean · declares supportsTools=\(model.supportsTools)")
            // Print the table so far after every model: a device that dies
            // mid-sweep should still leave usable data behind.
            print("[sweep] ── running totals ──")
            lines.forEach { print("[sweep] \($0)") }
            // A model that never called is the interesting case — show what it
            // said instead, since "refused sensibly" and "hallucinated an answer"
            // are very different failures.
            if called == 0 {
                lines.append("    └ said: \(firstReply.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))")
            }
        }

        print("\n[sweep] ── tool-call rate, through the app's own stack ──")
        lines.forEach { print("[sweep] \($0)") }

        // Only meaningful for an UNFILTERED run: a deliberately narrow
        // SWEEP_ONLY that matches nothing is a valid thing to ask for, not a
        // failure. Without this, filtering the sweep fails the sweep.
        if only == nil {
            #expect(measured > 0, "no catalog model is installed on this device — nothing was measured")
        }
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
