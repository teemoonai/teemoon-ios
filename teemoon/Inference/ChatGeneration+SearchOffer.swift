//
//  ChatGeneration+SearchOffer.swift
//  teemoon
//
//  When to attach Brave web search, and how a keyless call becomes the
//  offer card. Kept off ChatGeneration.swift so orchestration is not
//  also the search-offer policy.
//

import Foundation
import ModelBackend

extension ChatGeneration {

    /// Hands the turn's pending query to the assistant message that resulted
    /// from it. Called once the message exists, which is the first moment the
    /// two can be connected.
    func attachPendingOffer(to messageID: UUID) {
        guard let query = unconfiguredSearchQuery else { return }
        offerByMessageID[messageID] = query
        unconfiguredSearchQuery = nil
        unconfiguredSearchThreadID = nil
    }

    /// Declines for the whole thread: clears any cards already showing in it
    /// and marks it so later turns neither offer again nor pay for the schema.
    func declineOffer(inThread threadID: UUID, messageIDs: [UUID]) {
        declinedOfferThreadIDs.insert(threadID)
        for id in messageIDs { offerByMessageID.removeValue(forKey: id) }
        unconfiguredSearchQuery = nil
        unconfiguredSearchThreadID = nil
    }

    /// The Brave search tool for this turn, or none.
    ///
    /// Gate on the *model's* capability, not just the provider's: never hand a
    /// web_search tool to a model that can't call tools (proactive — no hot-path
    /// 400 retry). Unknown-capability models (generic endpoints) stay optimistic.
    /// ATTACHED EVEN WITH NO KEY. The two guards are unchanged — providers
    /// that ground natively (brave answers) and models that can't call tools
    /// are still excluded — but the key is no longer one of them.
    ///
    /// Keyless, the tool cannot search; what it can do is let the model SAY
    /// it wanted to. That call is the trigger for the offer card, and it is a
    /// fact rather than a guess about the prompt's wording.
    ///
    /// DECLINED THREADS DO NOT PAY FOR THE SCHEMA. Once the user has said
    /// "not now", the keyless tool has no job left: it cannot search, and
    /// the card it exists to trigger will not be shown in this thread again.
    /// Every turn would otherwise re-send the full web_search schema —
    /// prefill the user pays for, on device, forever, for nothing.
    ///
    /// Gated on the key being ABSENT. A configured provider always gets the
    /// tool: declining an offer to set up search says nothing about whether
    /// search should run once it exists.
    func makeGroundingTools(
        provider: Provider,
        groundingAPIKey: String?,
        threadID: UUID
    ) -> [any Tool] {
        let offerDeclined = declinedOfferThreadIDs.contains(threadID)
        let keyless = (groundingAPIKey ?? "").isEmpty
        guard !provider.capabilities.contains(.builtInGrounding),
              provider.modelSupportsTools,
              !(keyless && offerDeclined)
        else { return [] }

        let groundingKey = groundingAPIKey ?? ""
        // Every provider gets the FULL grounding payload, self-hosted or not.
        //
        // Self-hosted endpoints used to get `.compact` (3 sources instead of
        // 10) on the theory that they pay for every extra prompt token again
        // in local prefill. Measured on an M-series GPU, that is false:
        // moving gemma4:e2b from 538 to 4038 input tokens changed prefill
        // from 0.02s to 0.02s. Latency is dominated by DECODE, which is
        // serial, not by prefill, which is parallel — and the full arm
        // decoded FEWER tokens (346 vs 386) because a model hedges less when
        // its sources agree, so the larger payload was marginally faster end
        // to end.
        //
        // The other two justifications fail too. Brave grounding bills per
        // QUERY, not per source, so the smaller payload saved no money. And
        // `SourceSelectionTests` — scoring against live third parties rather
        // than against Brave's own payload — had `.full` win 6 of 6 cells on
        // answer accuracy, with `.compact` winning none.
        //
        // `GroundingBudget.compact` is gone entirely, not merely switched
        // off — an unused policy still has to be read and kept correct by
        // everyone who touches this path. If a smaller payload is ever
        // needed (a CPU-only server, where prefill genuinely IS expensive,
        // or a model whose context can't take 2,600 tokens on top of
        // persona and history), reintroduce it keyed on the CONTEXT WINDOW,
        // which teemoon knows from the catalogue — not on `isSelfHosted`,
        // which was a proxy for the wrong thing.
        // On-device models pay for prefill of these results themselves, and
        // that cost is superlinear (10 sources = 13s on an iPhone 16 Pro vs
        // 3.6s for 5). See GroundingBudget.onDeviceURLCap.
        var searchTool = BraveWebSearchTool(apiKey: groundingKey, onDevice: provider.isLocal)
        searchTool.onUnconfiguredSearch = { [weak self] query in
            Task { @MainActor [weak self] in
                // FIRST query only. A model that asks twice wanted the web
                // once; two cards for one turn reads as a malfunction.
                guard let self, self.unconfiguredSearchQuery == nil else { return }
                self.unconfiguredSearchQuery = query
                self.unconfiguredSearchThreadID = threadID
            }
        }
        return [searchTool]
    }
}
