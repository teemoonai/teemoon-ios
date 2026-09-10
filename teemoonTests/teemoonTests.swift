import Foundation
import Testing
import SwiftData
import ModelBackend
@testable import teemoon

// Foundation also defines a `Thread` type — disambiguate with a typealias.
typealias ChatThread = teemoon.Thread

// MARK: - processThinkingContent

@Suite("processThinkingContent")
struct ProcessThinkingContentTests {

    @Test func completeBlock_returnsThinkingAndAnswer() {
        let (thinking, answer) = MessageView.processThinkingContent("<think>I am reasoning.</think>The answer is 42.")
        #expect(thinking == "I am reasoning.")
        #expect(answer == "The answer is 42.")
    }

    @Test func openBlock_noCloseTag_returnsThinkingOnly() {
        let (thinking, answer) = MessageView.processThinkingContent("<think>Still thinking...")
        #expect(thinking == "Still thinking...")
        #expect(answer == nil)
    }

    @Test func noThinkTag_returnsContentAsAnswer() {
        let (thinking, answer) = MessageView.processThinkingContent("Hello, world!")
        #expect(thinking == nil)
        #expect(answer == "Hello, world!")
    }

    @Test func emptyAfterThink_returnsNilAnswer() {
        let (thinking, answer) = MessageView.processThinkingContent("<think>some thought</think>")
        #expect(thinking == "some thought")
        #expect(answer == nil)
    }

    @Test func whitespaceIsTrimmed() {
        let (thinking, answer) = MessageView.processThinkingContent("<think>  reasoning  </think>  answer  ")
        #expect(thinking == "reasoning")
        #expect(answer == "answer")
    }

    @Test func multilineThinkBlock_parsedCorrectly() {
        let input = "<think>\nline one\nline two\n</think>Final answer."
        let (thinking, answer) = MessageView.processThinkingContent(input)
        #expect(thinking == "line one\nline two")
        #expect(answer == "Final answer.")
    }
}

// MARK: - ChatGeneration guard: already running returns empty

@Suite("ChatGeneration")
struct ChatGenerationTests {

    @MainActor
    func makeThread(userMessage: String) throws -> (thread: ChatThread, container: ModelContainer) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ChatThread.self, Message.self, configurations: config)
        let context = container.mainContext
        let thread = ChatThread()
        context.insert(thread)
        let message = Message(role: .user, content: userMessage, thread: thread)
        context.insert(message)
        try context.save()
        return (thread, container)
    }

    @Test
    func endpointWithoutScheme_failsURLParsing() {
        // Regression: entering "192.168.88.7:1234/v1" without http:// caused a runtime error.
        // Provider.openAIBaseURL returns nil for schemeless URLs.
        let provider = Provider(id: UUID(), name: "test", endpoint: "192.168.88.7:1234/v1", model: "test")
        #expect(provider.openAIBaseURL == nil)
    }

    @Test
    func endpointWithScheme_parsesSuccessfully() {
        let provider = Provider(id: UUID(), name: "test", endpoint: "http://192.168.88.7:1234/v1", model: "test")
        #expect(provider.openAIBaseURL != nil)
        #expect(provider.openAIBaseURL?.host == "192.168.88.7")
    }

    @Test
    func splitEndpoint_https() {
        let (scheme, host) = AddEditProviderView.splitEndpoint("https://api.openai.com/v1")
        #expect(scheme == .https)
        #expect(host == "api.openai.com/v1")
    }

    @Test
    func splitEndpoint_http() {
        let (scheme, host) = AddEditProviderView.splitEndpoint("http://192.168.1.1:8080/v1")
        #expect(scheme == .http)
        #expect(host == "192.168.1.1:8080/v1")
    }

    @Test
    func splitEndpoint_noScheme_defaultsToHttps() {
        let (scheme, host) = AddEditProviderView.splitEndpoint("192.168.1.1:8080/v1")
        #expect(scheme == .https)
        #expect(host == "192.168.1.1:8080/v1")
    }

    @Test @MainActor
    func alreadyRunning_returnsEmpty() async throws {
        let (thread, container) = try makeThread(userMessage: "hello")
        let llm = ChatGeneration()
        llm.running = true

        let provider = Provider.braveAnswers
        let result = await llm.generate(provider: provider, thread: thread, systemPrompt: "", groundingAPIKey: nil, apiKey: "")
        withExtendedLifetime(container) {}
        #expect(result == "")
    }

    /// The send path used to construct a live model and hit the Keychain.
    /// A stub transport through `makeLanguageModel` is how `generate` is
    /// tested without either.
    @Test @MainActor
    func generateStreamsThroughAStubTransport() async throws {
        let (thread, container) = try makeThread(userMessage: "hello")
        defer { withExtendedLifetime(container) {} }

        let transport = ScriptedTransport(turns: [TurnOutput(content: "hi from the stub")])
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(
                transport: transport,
                priorMessages: prior,
                events: events
            )
        }

        var provider = Provider.braveAnswers
        provider.endpoint = "https://api.example.com/v1"
        let result = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: "",
            groundingAPIKey: nil,
            apiKey: "sk-test"
        )
        #expect(result == "hi from the stub")
        #expect(llm.output == "hi from the stub")
        #expect(llm.lastError == nil)
    }

    /// Stop pressed while nothing has arrived. `stop()` used to set a flag the
    /// consume loop read on the NEXT snapshot; with none coming — engine load,
    /// prefill, a decode queued behind an abandoned one — `running` never
    /// cleared, so the stop button greyed (`cancelled`) and never gave the
    /// composer back. Seen on every on-device stop before the first token.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func stopBeforeTheFirstSnapshotEndsTheTurn() async throws {
        let (thread, container) = try makeThread(userMessage: "hello")
        defer { withExtendedLifetime(container) {} }

        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: StalledTransport(), priorMessages: prior, events: events)
        }
        var provider = Provider.braveAnswers
        provider.endpoint = "https://api.example.com/v1"

        let turn = Task {
            await llm.generate(provider: provider, thread: thread, systemPrompt: "",
                               groundingAPIKey: nil, apiKey: "sk-test")
        }
        // Let the turn reach the stream and block there.
        try await Task.sleep(for: .milliseconds(200))
        #expect(llm.running)

        let pressed = ContinuousClock.now
        llm.stop()
        let result = await turn.value
        let took = pressed.duration(to: .now)

        #expect(result == "")
        #expect(!llm.running, "the turn is still running \(took) after stop")
        #expect(took < .seconds(2), "stop took \(took) to end a turn that had nothing to wait for")
        // A stop is not a failure: no banner.
        #expect(llm.lastError == nil)
    }

    /// A turn cut off from below (the app left the foreground) is an
    /// interruption: no error card, and the thread is remembered so the app can
    /// re-ask when it returns. A turn the USER stopped is not remembered — they
    /// asked for it to stop. Before this, the interrupted case showed "returned
    /// an empty response" and left an orphaned request the next question was
    /// answered as ("hello" got the potato essay).
    @Test @MainActor
    func interruptionFromBelowIsRememberedButNotAUserStop() async throws {
        let (thread, container) = try makeThread(userMessage: "write an essay")
        defer { withExtendedLifetime(container) {} }
        var provider = Provider.braveAnswers
        provider.endpoint = "https://api.example.com/v1"

        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: InterruptedTransport(), priorMessages: prior, events: events)
        }
        _ = await llm.generate(provider: provider, thread: thread, systemPrompt: "",
                               groundingAPIKey: nil, apiKey: "sk-test")
        #expect(llm.lastError == nil, "an interruption is not a failure")
        #expect(llm.interruptedThreadID == thread.id)

        // The view-model hands the orphaned user message back exactly once.
        let vm = ChatViewModel()
        let first = vm.interruptedUserMessage(in: thread, llm: llm)
        #expect(first?.role == .user && first?.content == "write an essay")
        #expect(vm.interruptedUserMessage(in: thread, llm: llm) == nil, "consumed on first read")

        // A user stop on a stalled turn: remembered? No.
        let stopped = ChatGeneration()
        stopped.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(transport: StalledTransport(), priorMessages: prior, events: events)
        }
        let turn = Task {
            await stopped.generate(provider: provider, thread: thread, systemPrompt: "",
                                   groundingAPIKey: nil, apiKey: "sk-test")
        }
        try await Task.sleep(for: .milliseconds(200))
        stopped.stop()
        _ = await turn.value
        #expect(stopped.interruptedThreadID == nil, "a user stop must not be auto-resumed")
        #expect(vm.interruptedUserMessage(in: thread, llm: stopped) == nil)
    }

    /// An empty reply with no error is invisible: the VM will not persist a
    /// blank assistant message, and with `lastError` nil there is no banner.
    @Test @MainActor
    func emptyReplyBecomesAStatedFailure() async throws {
        let (thread, container) = try makeThread(userMessage: "hello")
        defer { withExtendedLifetime(container) {} }

        let transport = ScriptedTransport(turns: [TurnOutput(content: "")])
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(
                transport: transport,
                priorMessages: prior,
                events: events
            )
        }
        var provider = Provider.braveAnswers
        provider.endpoint = "https://api.example.com/v1"
        let result = await llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: "",
            groundingAPIKey: nil,
            apiKey: "sk-test"
        )
        #expect(result.isEmpty)
        #expect(llm.lastError != nil)
        #expect(llm.lastError?.userMessage.contains("empty response") == true)
        #expect(llm.lastErrorThreadID == thread.id)
    }

    @Test @MainActor
    func waitUntilStopped_returnsImmediatelyWhenIdle() async {
        let llm = ChatGeneration()
        #expect(!llm.running)
        await llm.waitUntilStopped(timeout: .milliseconds(200))
        #expect(!llm.running)
    }

    @Test @MainActor
    func waitUntilStopped_returnsWhenGenerateClearsRunning() async throws {
        let (thread, container) = try makeThread(userMessage: "hello")
        defer { withExtendedLifetime(container) {} }

        let transport = DelayedScriptedTransport(turns: [TurnOutput(content: "done")],
                                                 delay: .milliseconds(80))
        let llm = ChatGeneration()
        llm.makeLanguageModel = { _, _, prior, _, events in
            TransportLanguageModel(
                transport: transport,
                priorMessages: prior,
                events: events
            )
        }
        var provider = Provider.braveAnswers
        provider.endpoint = "https://api.example.com/v1"

        async let result = llm.generate(
            provider: provider,
            thread: thread,
            systemPrompt: "",
            groundingAPIKey: nil,
            apiKey: "sk-test"
        )
        try await Task.sleep(for: .milliseconds(15))
        #expect(llm.running)
        await llm.waitUntilStopped(timeout: .seconds(2))
        #expect(!llm.running)
        #expect(await result == "done")
    }
}

// MARK: - Send-path stub (tests only)

private final class ScriptedTransport: GenerationTransport, @unchecked Sendable {
    private let turns: [TurnOutput]
    private var index = 0

    init(turns: [TurnOutput]) { self.turns = turns }

    /// The wire as the engine assembled it, per turn — the only place a test
    /// can see the LIVE prompt (it rides separately from `priorMessages`).
    private(set) var captured: [[[String: Any]]] = []

    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        captured.append(messages)
        let turn = index < turns.count ? turns[index] : TurnOutput(content: "")
        index += 1
        if !turn.content.isEmpty { onPartialContent(turn.content) }
        return turn
    }
}

/// A turn that never produces a snapshot — engine load, prefill, or a decode
/// queued behind an abandoned one — until the caller cancels it.
private struct StalledTransport: GenerationTransport {
    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        try await Task.sleep(for: .seconds(3600))
        return TurnOutput(content: "")
    }
}

/// A turn the transport itself abandons — what LiteRT does when the app
/// leaves the foreground and iOS revokes the GPU. Cancelled from BELOW, not
/// by the user.
private struct InterruptedTransport: GenerationTransport {
    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        throw CancellationError()
    }
}

private final class DelayedScriptedTransport: GenerationTransport, @unchecked Sendable {
    private let inner: ScriptedTransport
    private let delay: Duration

    init(turns: [TurnOutput], delay: Duration) {
        self.inner = ScriptedTransport(turns: turns)
        self.delay = delay
    }

    func runTurn(
        messages: [[String: Any]],
        includeTools: Bool,
        onPartialContent: @escaping @Sendable (String) -> Void
    ) async throws -> TurnOutput {
        try await Task.sleep(for: delay)
        return try await inner.runTurn(messages: messages, includeTools: includeTools,
                                       onPartialContent: onPartialContent)
    }
}

/// `LanguageModel` wrapper so `ChatGeneration.generate` can run a stub
/// `GenerationTransport` through the same engine production uses.
private struct TransportLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let transport: any GenerationTransport
    let priorMessages: [WireMessage]
    let events: StreamCallbacks

    private func engine(session: LanguageModelSession, prompt: Prompt) -> GenerationEngine {
        GenerationEngine(
            events: events,
            tools: session.tools,
            initialMessages: priorMessages,
            prompt: prompt.description,
            transport: transport
        )
    }

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        try await EngineBackedModel.respond(
            engine: engine(session: session, prompt: prompt), generating: type
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        EngineBackedModel.streamResponse(
            engine: engine(session: session, prompt: prompt), generating: type
        )
    }
}
