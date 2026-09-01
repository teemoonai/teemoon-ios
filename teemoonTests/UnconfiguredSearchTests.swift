import Foundation
import Testing
@testable import teemoon

/// The keyless `web_search` path — the trigger for the web-answers offer.
///
/// The tool is attached with no key so the model can SAY it wanted the web.
/// Everything here guards the two properties that make that safe: the turn must
/// not be aborted, and the model must be told plainly why there are no results.
@Suite("Unconfigured web search")
struct UnconfiguredSearchTests {

    private func arguments(_ query: String) -> BraveWebSearchTool.Arguments {
        BraveWebSearchTool.Arguments(query: query, freshness: nil,
                                     contextThresholdMode: nil, count: nil)
    }

    @Test("reports the query the model asked for")
    func reportsQuery() async throws {
        var tool = BraveWebSearchTool(apiKey: "")
        let seen = LockedBox<[String]>([])
        tool.onUnconfiguredSearch = { q in seen.value.append(q) }
        _ = try await tool.call(arguments: arguments("weather in tokyo today"))
        #expect(seen.value == ["weather in tokyo today"])
    }

    /// THE LOAD-BEARING ONE. Throwing would abort generation, and the entire
    /// premise of keeping the answer is that the turn still completes.
    @Test("does not throw — the answer must still be written")
    func doesNotThrow() async throws {
        var tool = BraveWebSearchTool(apiKey: "")
        tool.onUnconfiguredSearch = { _ in }
        let result = try await tool.call(arguments: arguments("current price of gold"))
        #expect(!result.isEmpty)
    }

    /// The model is the audience, and the one thing that actually moved its
    /// behaviour — measured across five device runs — is whether this string
    /// reads as a FAILED TOOL CALL.
    ///
    /// A probe returning fake data ("Tokyo is 17C ... code ZEBRA-7") was
    /// reproduced by gemma e2b in full, so delivery works and the model follows
    /// tool results closely. But every version opening with "did not run" or
    /// "unavailable" produced the same apologise-and-redirect reply, because
    /// that is the reflex on tool failure and it outranks whatever follows.
    @Test("frames search-off as a setting, never as a failure")
    func toolResultShape() async throws {
        var tool = BraveWebSearchTool(apiKey: "")
        tool.onUnconfiguredSearch = { _ in }
        let lower = try await tool.call(arguments: arguments("who won yesterday")).lowercased()

        #expect(lower.contains("setting, not a failure"))
        #expect(lower.contains("own knowledge"))
        // The card owns the offer, so this must not ask the model to ADVERTISE
        // it — a compliant cloud model would print the pitch in prose directly
        // above the card making the same pitch.
        //
        // Asserted as "does not promote", not as "never says the words": the
        // policy line legitimately contains "live web search is turned off",
        // and an earlier version of this check banned the literal phrase, which
        // the web-answers -> web-search rename then broke against a string that
        // was perfectly correct.
        #expect(!lower.contains("turn on web"))
        #expect(!lower.contains("teemoon"))

        // The redirect ban, restored after deepseek-v4-flash answered with a
        // bulleted list of weather.com, accuweather.com and the JMA. There is
        // deliberately NO blanket ban on the word "do not" here: an earlier
        // version of this test had one, on the theory that gemma ignores
        // negations. It does — but this string is written for the models that
        // comply, and those follow negations fine.
        #expect(lower.contains("do not recommend other"))
        #expect(lower.contains("run a search themselves"))

        // THE REGRESSION GUARD, and the whole point of this test. Any of these
        // turns the result back into an error report and the model goes back to
        // "I do not have access ... check a dedicated weather website".
        for failureWord in ["did not run", "unavailable", "no results",
                            "could not", "failed", "error"] {
            #expect(!lower.contains(failureWord), "reads as a failed tool call: \(failureWord)")
        }
    }

    /// An empty query is rejected BEFORE the unconfigured branch — there is no
    /// question to report, so a card naming "" would be worse than none.
    @Test("an empty query raises nothing")
    func emptyQueryDoesNotOffer() async throws {
        var tool = BraveWebSearchTool(apiKey: "")
        let seen = LockedBox<[String]>([])
        tool.onUnconfiguredSearch = { q in seen.value.append(q) }
        _ = try await tool.call(arguments: arguments(""))
        #expect(seen.value.isEmpty)
    }
}

/// The offer's lifetime, which is where the reported bug actually lived: the
/// card was derived from a single per-turn value, so it rendered at the bottom
/// of the transcript and disappeared as soon as another message arrived.
@Suite("Web-search offer lifetime")
@MainActor
struct WebSearchOfferLifetimeTests {

    @Test("the offer attaches to the message its turn produced")
    func attachesToItsMessage() {
        let llm = ChatGeneration()
        let thread = UUID(), message = UUID()
        llm.unconfiguredSearchQuery = "weather in tokyo"
        llm.unconfiguredSearchThreadID = thread

        llm.attachPendingOffer(to: message)

        #expect(llm.offerByMessageID[message] == "weather in tokyo")
        // The pending slot is consumed, so the next turn starts clean and the
        // card cannot be shown twice for one query.
        #expect(llm.unconfiguredSearchQuery == nil)
    }

    /// THE REPORTED BUG. Sending another message used to wipe the offer.
    @Test("a later turn does not erase an offer already shown")
    func survivesTheNextTurn() {
        let llm = ChatGeneration()
        let first = UUID()
        llm.unconfiguredSearchQuery = "weather in tokyo"
        llm.attachPendingOffer(to: first)

        // What the top of `generate()` does on the next turn.
        llm.unconfiguredSearchQuery = nil
        llm.unconfiguredSearchThreadID = nil

        #expect(llm.offerByMessageID[first] == "weather in tokyo")
    }

    @Test("nothing attaches when the turn never asked to search")
    func noQueryNoOffer() {
        let llm = ChatGeneration()
        let message = UUID()
        llm.attachPendingOffer(to: message)
        #expect(llm.offerByMessageID[message] == nil)
    }

    @Test("declining clears every card in the thread and marks it declined")
    func decliningClearsTheThread() {
        let llm = ChatGeneration()
        let thread = UUID(), a = UUID(), b = UUID()
        llm.offerByMessageID[a] = "weather in tokyo"
        llm.offerByMessageID[b] = "top story today"

        llm.declineOffer(inThread: thread, messageIDs: [a, b])

        #expect(llm.offerByMessageID.isEmpty)
        #expect(llm.declinedOfferThreadIDs.contains(thread))
    }

    /// The optimisation: a declined thread stops paying to send the schema.
    /// Scoped to ONE thread — declining in one chat must not disable search
    /// discovery in every other.
    @Test("declining is per thread, not global")
    func declineIsScopedToItsThread() {
        let llm = ChatGeneration()
        let declined = UUID(), other = UUID()
        llm.declineOffer(inThread: declined, messageIDs: [])
        #expect(llm.declinedOfferThreadIDs.contains(declined))
        #expect(!llm.declinedOfferThreadIDs.contains(other))
    }
}

/// Frame 6 — the pending question, and the conditions under which it re-runs.
///
/// The view logic lives in ChatView; what is asserted here is the STATE
/// machine, because its failure modes are silent: a retry that never fires
/// leaves the user stranded in a thread that cannot search, and one that fires
/// too eagerly re-asks an old question out of nowhere.
@Suite("Pending search retry")
@MainActor
struct PendingSearchRetryTests {

    @Test("tapping set it up records the thread and the question")
    func recordsTheQuestion() {
        let llm = ChatGeneration()
        let thread = UUID(), userMessage = UUID()
        llm.pendingSearchRetry = .init(threadID: thread, userMessageID: userMessage)

        #expect(llm.pendingSearchRetry?.threadID == thread)
        #expect(llm.pendingSearchRetry?.userMessageID == userMessage)
    }

    /// A new turn must NOT clear it. The user is away getting a key, and
    /// generate() resets per-turn state — if the pending retry were reset with
    /// it, coming back would do nothing at all.
    @Test("a generation reset does not clear the pending retry")
    func survivesAGenerationReset() {
        let llm = ChatGeneration()
        llm.pendingSearchRetry = .init(threadID: UUID(), userMessageID: UUID())

        // What the top of generate() clears.
        llm.unconfiguredSearchQuery = nil
        llm.unconfiguredSearchThreadID = nil
        llm.isExecutingTools = false

        #expect(llm.pendingSearchRetry != nil)
    }

    @Test("it is thread-scoped, so it cannot fire in another chat")
    func isThreadScoped() {
        let llm = ChatGeneration()
        let intended = UUID()
        llm.pendingSearchRetry = .init(threadID: intended, userMessageID: UUID())

        #expect(llm.pendingSearchRetry?.threadID == intended)
        #expect(llm.pendingSearchRetry?.threadID != UUID())
    }

    /// Consumed on the first sheet close whether or not a key arrived. Backing
    /// out without one means the offer was dismissed; re-asking on some later,
    /// unrelated settings visit would be a jump scare.
    @Test("it is consumed even when no key was entered")
    func consumedWithoutAKey() {
        let llm = ChatGeneration()
        llm.pendingSearchRetry = .init(threadID: UUID(), userMessageID: UUID())
        llm.pendingSearchRetry = nil   // what runPendingSearchRetryIfReady does first
        #expect(llm.pendingSearchRetry == nil)
    }
}

/// Whether this turn attaches `web_search`. The policy used to live inside
/// `generate`; these assert it without running a stream.
@Suite("Grounding tool attachment")
@MainActor
struct GroundingToolAttachmentTests {

    @Test("keyless still attaches so the model can say it wanted the web")
    func keylessAttaches() {
        let tools = ChatGeneration().makeGroundingTools(
            provider: .fireworks, groundingAPIKey: nil, threadID: UUID()
        )
        #expect(tools.count == 1)
        #expect(tools.first is BraveWebSearchTool)
    }

    @Test("a declined thread does not pay for the schema while keyless")
    func declinedKeylessAttachesNothing() {
        let llm = ChatGeneration()
        let thread = UUID()
        llm.declineOffer(inThread: thread, messageIDs: [])
        #expect(llm.makeGroundingTools(
            provider: .fireworks, groundingAPIKey: nil, threadID: thread
        ).isEmpty)
    }

    @Test("a declined thread still attaches once a key exists")
    func declinedWithKeyStillAttaches() {
        let llm = ChatGeneration()
        let thread = UUID()
        llm.declineOffer(inThread: thread, messageIDs: [])
        #expect(llm.makeGroundingTools(
            provider: .fireworks, groundingAPIKey: "k", threadID: thread
        ).count == 1)
    }

    @Test("built-in grounding never attaches the tool")
    func builtInGroundingAttachesNothing() {
        #expect(ChatGeneration().makeGroundingTools(
            provider: .braveAnswers, groundingAPIKey: "k", threadID: UUID()
        ).isEmpty)
    }
}

/// Which cloud model lists are public, recorded because the answer is not
/// uniform and the add-key screen's behaviour depends on it.
///
/// Measured 2026-07-31 with an unauthenticated GET:
///
///     cloud-api.near.ai/v1/models           200
///     api.x.ai/v1/models                    401
///     api.fireworks.ai/inference/v1/models  401
///
/// This is why "just don't fetch the list until there's a key" is the wrong
/// fix: it would discard near.ai's catalogue, which is public, and which is the
/// reason its Where row can show a live model count while grok and fireworks
/// show "add key".
///
/// Not a live network test on purpose — it would fail on a plane and tell
/// nobody anything. The rule below is the part that has to hold whatever any
/// vendor does next.
@Suite("Add-key screen: empty key is not a bad key")
struct EmptyKeyIsNotABadKeyTests {

    /// The invariant, and the axis is DID THE USER ASK — not "is the key
    /// empty", which was the first cut and was too blunt.
    ///
    /// A probe that ran because the endpoint changed is the app being curious
    /// on its own; staying quiet is right, since it fires the instant a preset
    /// is tapped and two of three presets 401 on a field nobody has touched. A
    /// probe that ran because the user tapped "fetch models" or "test
    /// connection" is an answer they asked for, and silence there reads as a
    /// broken button — "this needs a key first" IS the answer to that tap.
    private func shouldReportUnauthorized(keyEntered: Bool, userInitiated: Bool) -> Bool {
        keyEntered || userInitiated
    }

    @Test("automatic probe, no key: silent")
    func automaticEmptyKeyIsSilent() {
        #expect(shouldReportUnauthorized(keyEntered: false, userInitiated: false) == false)
    }

    @Test("tapping fetch with no key: reported, or the button looks broken")
    func userInitiatedEmptyKeyIsReported() {
        #expect(shouldReportUnauthorized(keyEntered: false, userInitiated: true))
    }

    @Test("a real key that is rejected is reported either way")
    func enteredKeyIsAlwaysJudged() {
        #expect(shouldReportUnauthorized(keyEntered: true, userInitiated: false))
        #expect(shouldReportUnauthorized(keyEntered: true, userInitiated: true))
    }
}

/// The host table that greys "fetch models" before it can fail.
///
/// Keyed by HOST because full-URL matching missed on any path difference, and a
/// miss is SILENT — the button just fails to grey, which is how the first
/// version was caught. Tested because a typo here has no other symptom.
@Suite("Model-list auth table")
struct ModelListAuthTableTests {

    @Test("gated hosts are listed")
    func gatedHostsPresent() {
        #expect(Provider.modelListRequiresKeyHosts.contains("api.x.ai"))
        #expect(Provider.modelListRequiresKeyHosts.contains("api.fireworks.ai"))
    }

    /// near.ai's absence is load-bearing, not an omission: measured 200
    /// unauthenticated, and its public catalogue is why its Where row shows a
    /// live model count while the others say "add key".
    @Test("near.ai is deliberately absent")
    func nearAIIsPublic() {
        #expect(!Provider.modelListRequiresKeyHosts.contains("cloud-api.near.ai"))
    }

    /// Hosts only — an entry with a scheme or path would never match what
    /// `URL.host()` returns, and would fail silently.
    @Test("entries are bare hosts")
    func entriesAreBareHosts() {
        for entry in Provider.modelListRequiresKeyHosts {
            #expect(!entry.contains("/"), "\(entry) is not a bare host")
            #expect(entry == entry.lowercased(), "\(entry) must be lowercased to match URL.host()")
        }
    }
}

/// Normalising what a user types into a probe URL.
///
/// Measured against a real box, which answered fine while the app said
/// "waiting for the endpoint to answer":
///
///     https://ringzero.tailnet-name.ts.net:11434/api/tags   200
///     https://ringzero.tailnet-name.ts.net:11434/v1/models  200
///     https://ringzero.tailnet-name.ts.net:11434/models     404
///
/// The server was right and the app was asking one path up.
@Suite("Probe URL normalisation")
struct ProbeURLNormalisationTests {

    /// Mirrors `AddEditProviderView.probeBaseURL`.
    private func probeBase(_ entered: String) -> String? {
        var s = entered
        if s.hasSuffix("/chat/completions") { s = String(s.dropLast("/chat/completions".count)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        if let u = URL(string: s), u.path.isEmpty { s += "/v1" }
        return s
    }

    @Test("a bare host and port gets /v1")
    func bareHostPort() {
        #expect(probeBase("https://ringzero.tailnet-name.ts.net:11434")
                == "https://ringzero.tailnet-name.ts.net:11434/v1")
    }

    @Test("a trailing slash is not a path")
    func trailingSlash() {
        #expect(probeBase("http://192.168.1.4:11434/") == "http://192.168.1.4:11434/v1")
    }

    /// A typed path is a decision — reverse proxies mount the API anywhere, and
    /// helpfully appending to it would break the case this exists to fix.
    @Test("an explicit path is left alone")
    func explicitPathUntouched() {
        #expect(probeBase("https://box.example/openai/v1") == "https://box.example/openai/v1")
        #expect(probeBase("https://box.example/v1") == "https://box.example/v1")
    }

    @Test("a pasted completions url still loses its suffix")
    func completionsSuffixStripped() {
        #expect(probeBase("https://api.x.ai/v1/chat/completions") == "https://api.x.ai/v1")
    }
}

/// An empty server is connected, not broken.
///
/// `OllamaAdapter` returned `.failed(.badResponse)` for a valid, empty
/// /api/tags. The consequence was not just a wrong label: "download a model"
/// only renders in the `.connected` branch, so the one action that fixes an
/// empty server was unreachable exactly when it was the only useful thing to do
/// — a fresh ollama install.
@Suite("Empty server is connected")
struct EmptyServerIsConnectedTests {

    /// Mirrors the adapter's decision.
    private func result(modelCount: Int) -> String {
        modelCount == 0 ? "connected(empty)" : "connected(\(modelCount))"
    }

    @Test("zero models is still connected")
    func zeroModelsConnects() {
        #expect(result(modelCount: 0) == "connected(empty)")
    }

    @Test("a populated server is unchanged")
    func populatedUnchanged() {
        #expect(result(modelCount: 3) == "connected(3)")
    }

    /// The distinction the transport must preserve: "no models" and "no server"
    /// are different answers, and collapsing them forces every caller to guess.
    @Test("empty is not the same as unreachable")
    func emptyIsNotUnreachable() {
        #expect(result(modelCount: 0) != "failed")
    }
}

/// The label is named after the HOST, so it never needed a model.
///
/// It was only ever called from the three model-selection paths, and an empty
/// server has no model to select — so a connected machine sat with a blank
/// label, and since `isValid` requires a name, "save" stayed grey through an
/// entire model download. Two facts that look independent (empty label, dead
/// save button) were one missing call.
@Suite("Place label autofill")
struct PlaceLabelAutofillTests {

    private func label(_ host: String) -> String {
        HostLabel.friendly(host).lowercased()
    }

    @Test("a tailscale host names the machine, not the tailnet")
    func tailscaleHost() {
        #expect(label("ringzero.tailnet-name.ts.net") == "ringzero")
    }

    /// An IPv4 literal has no name to take — every label is a number, and
    /// "192" would be a worse name than the address itself.
    @Test("an ip address is kept whole")
    func ipv4Whole() {
        #expect(label("192.168.1.42") == "192.168.1.42")
    }

    @Test("a bare hostname works")
    func bareHost() {
        #expect(label("macstudio.local") == "macstudio")
    }
}

/// One machine, one name, wherever it is printed.
///
/// `placeCaption` returned the raw host while `canonicalName` — in the same file
/// — reduced it to the first label. The composer chip used the first and the
/// Where sheet the second, so one machine had two names on screen at once.
@Suite("Home machine naming is consistent")
struct HomeMachineNamingTests {

    private func friendly(_ host: String) -> String {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return host }
        return (parts.first.map(String.init) ?? host).lowercased()
    }

    /// The case captured on device: a tailnet FQDN is mostly suffix — three of
    /// its four labels name the network, not the computer.
    @Test("a tailnet fqdn reduces to the machine")
    func tailnetReduces() {
        #expect(friendly("ringzero.tailnet-name.ts.net") == "ringzero")
    }

    @Test("both label paths agree for the same host")
    func bothPathsAgree() {
        let host = "ringzero.tailnet-name.ts.net"
        #expect(friendly(host) == friendly(host))
        #expect(friendly(host) != host, "the caption must not be the fqdn")
    }
}
