import AppIntents
import SwiftData
import SwiftUI

/// Siri/Shortcuts entry point.
///
/// Uses the same `ConfidentialSession` turn API as the chat UI (`prepareTurn`
/// / `generate` / `finishTurn`), so an attested provider is sealed and
/// verified. The thread is still ephemeral — intents do not share the app's
/// SwiftData store — so the reply is spoken and discarded.
struct RequestLLMIntent: AppIntent {
    static var title: LocalizedStringResource = "new chat"
    static var description: LocalizedStringResource = "start a new chat"
    
    @Parameter(title: "Continuous Chat", default: true)
    var continuous: Bool
    
    @Parameter(title: "message", requestValueDialog: IntentDialog("chat"))
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("new chat with \(\.$prompt)") {
            // shortcuts additional parameters
            \.$continuous
        }
    }
    
    var maxCharacters: Int? {
        if continuous {
            return 300
        }
        
        return nil
    }
    
    var systemPrompt: String {
        if continuous {
            return "\n you never reply with more than FOUR sentences even if asked to."
        }
        
        return ""
    }
    
    // Held across continuous-mode re-prompts to carry the multi-turn context,
    // and intentionally never inserted into the store — the reply is spoken and
    // discarded (see the type header).
    let thread = Thread()

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let llm = ChatGeneration()
        let settings = AppSettings()
        let providers = ProviderStore()
        let session = ConfidentialSession(providers: providers)
        
        if prompt.isEmpty {
            if let output = thread.messages.last?.content {
                // Empty input ends a continuous-mode chat; repeat the last reply.
                return .result(value: output, dialog: "Okay, ending here.")
            } else {
                throw $prompt.requestValue("chat")
            }
        }

        guard let provider = providers.activeProvider else {
            let error = "No provider configured. Open the app and set up a provider first."
            return .result(value: error, dialog: "\(error)")
        }

        let teeContext = await session.prepareTurn()
        // Fail-closed send gate: the chat UI consults
        // `session.sendPolicy` before generating; this headless entry point
        // must consult the SAME canonical gate. A record merely EXISTING is
        // not a verified record — without this check a session whose
        // attestation failed verification (or produced no E2EE key) still
        // sent via Siri. Nothing is sent on refusal; no outcome is recorded
        // because no request was made.
        if let refusal = Self.refusalDialog(
            policy: session.sendPolicy,
            providerIsAttested: provider.capabilities.contains(.attestation),
            canSeal: teeContext?.e2eePeer != nil
        ) {
            return .result(value: refusal, dialog: "\(refusal)")
        }
        let message = Message(role: .user, content: prompt, thread: thread,
                              isE2EE: session.canSeal)
        thread.messages.append(message)
        // Siri/Shortcuts is chat-mutation site 5 (see ChatSearchService); it
        // can't route through ChatViewModel. A no-op today — the index drops
        // this detached, never-persisted thread — kept so a future persisting
        // intent isn't silently unindexed.
        await MainActor.run { ChatSearchService.shared.didWrite(message) }
        var output = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: settings.systemPrompt + systemPrompt,
            groundingAPIKey: provider.capabilities.contains(.builtInGrounding)
                ? nil : settings.groundingAPIKey,
            apiKey: providers.credential(for: provider),
            teeContext: teeContext
        )
        await Task.yield()
        session.finishTurn(debugInfo: llm.lastRequestDebugInfo, error: llm.lastError)

        // A failed request leaves `output` empty; without this Siri would speak
        // an empty string (silence), and continuous mode would ask a blank
        // follow-up. Say what went wrong and stop.
        if let dialog = Self.failureDialog(errorMessage: llm.lastError?.userMessage,
                                           output: output) {
            return .result(value: dialog, dialog: "\(dialog)")
        }

        let maxCharacters = maxCharacters ?? .max
        if output.count > maxCharacters {
            output = String(output.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "..."
        }
        
        let responseMessage = Message(role: .assistant, content: output, thread: thread)
        thread.messages.append(responseMessage)
        await MainActor.run { ChatSearchService.shared.didWrite(responseMessage) }

        if continuous {
            throw $prompt.requestValue("\(output)")
        }
        
        return .result(value: output, dialog: "\(output)")
    }

    static var openAppWhenRun: Bool = false

    /// The intent's refuse/proceed decision, pure so the regression tests can
    /// pin it. Returns the spoken refusal, or nil to proceed to `generate`.
    ///
    /// - `.block` refuses, same as the chat UI.
    /// - `.confirm` ALSO refuses: a headless Siri intent cannot show the
    ///   confirmation modal, so confirm-to-proceed degrades to refuse.
    /// - An attestation-capable provider without an E2EE peer refuses too —
    ///   the transport would run with a nil codec and send plaintext under an
    ///   E2EE promise (see `ChatViewModel.mustRefuseUnsealedSend`).
    /// - Non-attested providers proceed normally (their policy is `.allow`
    ///   and `canSeal` is not required of them).
    static func refusalDialog(policy: TrustSendPolicy,
                              providerIsAttested: Bool,
                              canSeal: Bool) -> String? {
        if policy != .allow || (providerIsAttested && !canSeal) {
            return "This chat can't be verified right now — open teemoon to check the connection."
        }
        return nil
    }

    /// The spoken message when a Siri turn produced nothing usable, or nil to
    /// speak the reply. Pure so a test can pin it: a failed request must say
    /// something — an empty string is spoken as silence, and in continuous mode
    /// becomes a blank follow-up question.
    static func failureDialog(errorMessage: String?, output: String) -> String? {
        if let errorMessage { return "Sorry — \(errorMessage)" }
        if output.isEmpty { return "No response came back. Please try again." }
        return nil
    }
}

struct NewChatShortcut: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RequestLLMIntent(),
            phrases: [
                "Start a new chat with \(.applicationName)",
                "Start a \(.applicationName) chat",
                "Chat with \(.applicationName)",
                "Ask \(.applicationName) a question"
            ],
            shortTitle: "new chat",
            systemImageName: "bubble"
        )
    }
}
