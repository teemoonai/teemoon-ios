//
//  ProviderStore+Healing.swift
//  teemoon
//
//  Identity repair: rewrite teemoon's own auto-labels, clear a wrong
//  requiresAPIKey flag, fold duplicate endpoints and machines. Kept
//  off ProviderStore.swift so CRUD is not also the migration.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "providers")

extension ProviderStore {

    // MARK: Auto-label healing

    /// Rewrites a record still carrying teemoon's own "<place> <model>" auto-label,
    /// leaving anything the user typed alone.
    ///
    /// The label is generated once, when a setup is saved, and never refreshed —
    /// deliberately, because it may have been typed. So a machine added while running
    /// `gemma4:e2b-it-qat` is still CALLED that after every later model change, and a
    /// key added with Qwen is called "fireworks Qwen3.7 Plus" while it runs deepseek.
    ///
    /// Every surface that prints a name inherits it. Three were patched separately
    /// this week — the debug card header, the Where rows, the places-&-keys rows all
    /// reach for `canonicalName` now — but the EDIT screen shows the stored name,
    /// because that is the field being edited, and there it reads as teemoon insisting
    /// a computer is a model. The name is the thing that is wrong; the fix belongs in
    /// the data.
    ///
    /// **Only rewrites a name teemoon can prove it wrote**: `<place> <model>`, where
    /// place is the host (self-hosted) or the preset's name, and model is one this
    /// record actually carries. "ringzero local server" survives, because "local
    /// server" is a human-typed name, not a model of that machine's.
    func healAutoLabels() {
        var healed: [String] = []
        for (index, provider) in providers.enumerated() {
            guard !provider.isLocal,
                  let place = Self.generatedLabelPlace(for: provider),
                  Self.isGeneratedLabel(provider.name, place: place, provider: provider),
                  provider.name.caseInsensitiveCompare(place) != .orderedSame
            else { continue }
            healed.append(provider.name + " → " + place)
            providers[index].name = place
        }
        guard !healed.isEmpty else { return }
        logger.info("""
            [providers] renamed \(healed.count, privacy: .public) record(s) off teemoon's \
            own place-and-model label: \(healed.joined(separator: ", "), privacy: .public)
            """)
    }

    /// The place half of a generated label: the host for a machine, the preset's name
    /// for a known cloud provider. nil for a custom cloud endpoint, which teemoon
    /// never generated a prefix for.
    static func generatedLabelPlace(for provider: Provider) -> String? {
        if provider.isSelfHosted, let host = provider.openAIBaseURL?.host {
            return HostLabel.friendly(host).lowercased()
        }
        if let preset = Provider.presets.first(where: {
            endpointKey($0.endpoint) == endpointKey(provider.endpoint)
        }) {
            return preset.name.lowercased()
        }
        return nil
    }

    /// Whether `name` is the label teemoon would have generated for this record: the
    /// place, a space, and a model this record carries — by id, by its last path
    /// component, or by a curated display name for that provider.
    static func isGeneratedLabel(_ name: String, place: String, provider: Provider) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(place.lowercased() + " ") else { return false }
        let suffix = String(trimmed.dropFirst(place.count + 1)).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return false }

        var candidates = Set<String>()
        var ids = provider.equipped
        if !provider.model.isEmpty { ids.append(provider.model) }
        for id in ids {
            candidates.insert(id.lowercased())
            candidates.insert(ModelCatalog.displayName(forID: id).lowercased())
            candidates.insert(ModelCatalog.compactName(forID: id).lowercased())
        }
        // Cloud presets label by the CATALOG's pretty name ("Qwen3.7 Plus"), which the
        // id alone does not produce.
        if let preset = Provider.presets.first(where: {
            endpointKey($0.endpoint) == endpointKey(provider.endpoint)
        }) {
            for model in KnownModel.models(for: preset.id) {
                candidates.insert(model.displayName.lowercased())
                candidates.insert(model.id.lowercased())
                candidates.insert(ModelCatalog.displayName(forID: model.id).lowercased())
            }
        }
        if candidates.contains(suffix.lowercased()) { return true }
        // A machine's label names whatever it ran THAT DAY, and the most stale labels
        // name a model the box no longer serves — which is the case that matters and
        // the one "must be one of its own models" rejected. A stale self-hosted label
        // can still say "ringzero gemma4:e2b-it-qat" after that model was deleted from
        // the machine.
        //
        // So for a self-hosted record, judge the SHAPE instead: a model ref is one
        // token with a tag or a namespace in it (`gemma4:e2b-it-qat`, `qwen3.5:4b`,
        // `hf.co/user/repo`). A name someone typed has spaces — "ringzero local
        // server", "ringzero in the closet" — and keeps its name.
        if provider.isSelfHosted, Self.looksLikeAModelRef(suffix) { return true }
        // The label was written from whatever catalogue was on screen at the time, and
        // a LIVE cloud catalogue spells a model differently from the shipped table:
        // "Kimi K2.6" against `kimi-k2p6`, "Qwen3.7 Plus" against `qwen3p7-plus`. Same
        // model, and the difference is punctuation plus Fireworks' `p`-for-`.`. Compare
        // on a key that ignores both, so the check still refuses "fireworks work
        // account" — which matches nothing at all.
        let fuzzy = Set(candidates.map(Self.fuzzyModelKey))
        return fuzzy.contains(Self.fuzzyModelKey(suffix))
    }

    /// Whether a label's suffix is shaped like a model reference rather than words.
    ///
    /// One token, no whitespace, carrying a tag or a namespace — which is every Ollama
    /// and HuggingFace ref and no phrase a person types for a computer.
    static func looksLikeAModelRef(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" "), t.count >= 3 else { return false }
        return t.contains(":") || t.contains("/")
    }

    /// A model name reduced to what identifies it: lowercase alphanumerics, with a `p`
    /// between two digits read as the decimal point it stands in for.
    static func fuzzyModelKey(_ s: String) -> String {
        let lower = Array(s.lowercased())
        var out = ""
        for (i, ch) in lower.enumerated() {
            if ch == "p", i > 0, i + 1 < lower.count,
               lower[i - 1].isNumber, lower[i + 1].isNumber {
                continue                    // k2p6 → k26, matching "k2.6"
            }
            if ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }

    /// Clears `requiresAPIKey` on self-hosted records that have no key stored.
    ///
    /// The add-provider form hardcoded `requiresAPIKey: true` for everything it
    /// saved, including keyless boxes. That is not cosmetic: `machineIdentity`
    /// is nil whenever the flag is set, so `mergeDuplicateMachines` could never
    /// see two records of one Tailscale-served Ollama as the same machine, and
    /// the Where sheet rendered the server twice with identical rows. Observed
    /// on device: one host, two records, three models each, six rows.
    ///
    /// Fixing the save site stops new ones; this heals the records already
    /// written, because they are what the user is looking at.
    ///
    /// **Only ever flips a record with NO stored credential.** A self-hosted
    /// endpoint that genuinely holds a key keeps its flag, so no merge that
    /// follows can be the thing that deletes a secret — the records this
    /// touches have none to lose.
    func healSelfHostedKeyFlags() {
        var healed: [String] = []
        for (index, provider) in providers.enumerated() {
            guard provider.requiresAPIKey, !provider.isLocal, provider.isSelfHosted else { continue }
            let stored = Self.migratedCredential(for: provider)
            guard stored.isEmpty else { continue }
            providers[index].requiresAPIKey = false
            healed.append(provider.name)
        }
        guard !healed.isEmpty else { return }
        logger.info("""
            [providers] cleared requiresAPIKey on \(healed.count, privacy: .public) keyless \
            self-hosted record(s): \(healed.joined(separator: ", "), privacy: .public)
            """)
    }

    /// Collapses records already written for the same endpoint.
    ///
    /// `addProvider` upserts, so this state can no longer be created — but it
    /// was creatable, and the records are what the user is looking at. Observed:
    /// rotating a near.ai key left two records for one endpoint, the stale one
    /// holding the revoked key and still offering a model the other lacked.
    ///
    /// **Which record survives is the whole safety question**, because the loser
    /// is dropped and only one of them holds a working credential:
    ///
    ///   1. the SELECTED record, if either is — it is the one demonstrably in
    ///      use, and after a rotation it is the one holding the new key;
    ///   2. otherwise whichever has a key stored, when only one does;
    ///   3. otherwise the first, which is arbitrary and harmless — neither has
    ///      anything to lose.
    ///
    /// The survivor takes the union of the equipped sets, so no model the user
    /// could previously run disappears. The loser's Keychain entry is deleted
    /// only when the survivor has one — dropping the last copy of a secret to
    /// tidy up a duplicate would be the one unrecoverable move here.
    func mergeDuplicateEndpoints() {
        var keptIndexByEndpoint: [String: Int] = [:]
        var kept: [Provider] = []
        var dropped: [Provider] = []
        var newCurrentProviderID: String?

        for provider in providers {
            // Every on-device provider shares the literal endpoint "on-device".
            guard !provider.isLocal else { kept.append(provider); continue }
            let key = Self.endpointKey(provider.endpoint)
            guard let index = keptIndexByEndpoint[key] else {
                keptIndexByEndpoint[key] = kept.count
                kept.append(provider)
                continue
            }

            let incumbent = kept[index]
            let incumbentIsCurrent = incumbent.id.uuidString == currentProviderID
            let challengerIsCurrent = provider.id.uuidString == currentProviderID
            let incumbentHasKey = !Self.migratedCredential(for: incumbent).isEmpty
            let challengerHasKey = !Self.migratedCredential(for: provider).isEmpty

            let challengerWins = challengerIsCurrent
                || (!incumbentIsCurrent && challengerHasKey && !incumbentHasKey)

            var survivor = challengerWins ? provider : incumbent
            let loser = challengerWins ? incumbent : provider
            var models = survivor.equipped
            for model in loser.equipped where !models.contains(model) { models.append(model) }
            survivor.equippedModels = models
            if loser.id.uuidString == currentProviderID {
                survivor.model = loser.model
                newCurrentProviderID = survivor.id.uuidString
            }
            kept[index] = survivor
            dropped.append(loser)
        }

        guard !dropped.isEmpty else { return }
        logger.info("""
            [providers] folded \(dropped.count, privacy: .public) duplicate endpoint record(s): \
            \(dropped.map(\.name).joined(separator: ", "), privacy: .public)
            """)
        providers = kept
        if let newCurrentProviderID { currentProviderID = newCurrentProviderID }
        noteMerge(of: dropped, reason: "one connection was saved more than once")
        for loser in dropped {
            // Same endpoint means the SAME ACCOUNT now, so a survivor with a key and
            // a loser with one are reading the same secret — there is nothing left to
            // orphan. The legacy UUID copy is all that can remain.
            let survivorHasKey = kept.first { Self.endpointKey($0.endpoint) == Self.endpointKey(loser.endpoint) }
                .map { !Self.migratedCredential(for: $0).isEmpty } ?? false
            if survivorHasKey {
                try? Keychain.delete(for: loser.id.uuidString)
            } else {
                logger.error("""
                    [providers] kept the orphaned key of \(loser.name, privacy: .public): the \
                    surviving record has none, and discarding the last copy is not recoverable
                    """)
            }
        }
    }

    /// Builds the one-time notice. Names the surviving setups rather than the
    /// dropped ones: the user is looking at what is still there, and "we removed
    /// X" invites hunting for something that was a duplicate of a row in front
    /// of them.
    func noteMerge(of dropped: [Provider], reason: String) {
        guard !dropped.isEmpty else { return }
        let count = dropped.count
        let subject = count == 1 ? "one duplicate setup" : "\(count) duplicate setups"
        mergeNotice = "teemoon merged \(subject) — \(reason). nothing you could run has been lost."
    }

    /// Test seam: the heals run at load, which an in-memory store skips.
    func healKeylessSelfHostedForTesting() { healSelfHostedKeyFlags() }
    func healAutoLabelsForTesting() { healAutoLabels() }
    func mergeDuplicateEndpointsForTesting() { mergeDuplicateEndpoints() }

    /// Collapses records that point at the same self-hosted machine.
    ///
    /// The Where sheet lists one row per equipped model per provider, and
    /// `syncHomeEquipped` makes a home provider's equipped set BE the server's
    /// model list — so a second record for the same endpoint renders the whole
    /// machine twice, with identical captions and no way to tell which row is
    /// which. Deduping on `id` alone never caught it: the duplicate is a
    /// different record of the same thing, not the same record twice.
    ///
    /// Merges rather than deletes: the survivor inherits any models only the
    /// other one had, so nothing the user could previously run disappears.
    /// Scoped by `machineIdentity` to KEYLESS self-hosted endpoints, so two
    /// cloud keys on one host — a legitimate setup — are never touched, and no
    /// credential is ever the thing being dropped.
    func mergeDuplicateMachines() {
        var keptIndexByMachine: [String: Int] = [:]
        var kept: [Provider] = []
        var removed: [Provider] = []
        // Deferred: assigning `currentProviderID` fires `onActiveProviderChanged`,
        // and doing that mid-loop would hand the callback a provider list that
        // still holds the record being dropped and a survivor whose model has not
        // been updated yet.
        var newCurrentProviderID: String?

        for provider in providers {
            guard let machine = provider.machineIdentity else {
                kept.append(provider)
                continue
            }
            guard let index = keptIndexByMachine[machine] else {
                keptIndexByMachine[machine] = kept.count
                kept.append(provider)
                continue
            }
            var survivor = kept[index]
            let extras = provider.equipped.filter { !survivor.equipped.contains($0) }
            if !extras.isEmpty { survivor.equippedModels = survivor.equipped + extras }
            // If the record being dropped is the one currently selected, the
            // survivor takes over what it was running — the user keeps their
            // model, and only the redundant record goes.
            if provider.id.uuidString == currentProviderID {
                survivor.model = provider.model
                newCurrentProviderID = survivor.id.uuidString
            }
            kept[index] = survivor
            removed.append(provider)
        }

        guard !removed.isEmpty else { return }
        logger.info("""
            [providers] merged \(removed.count) duplicate record(s) of \
            already-configured machine(s): \
            \(removed.map(\.name).joined(separator: ", "), privacy: .public)
            """)
        providers = kept
        if let newCurrentProviderID { currentProviderID = newCurrentProviderID }
        noteMerge(of: removed, reason: "the same computer was saved more than once")
        // The UUID copy only: the survivor of a machine merge shares this endpoint, so
        // deleting the endpoint account would delete the key that still answers.
        for provider in removed { try? Keychain.delete(for: provider.id.uuidString) }
    }
}
