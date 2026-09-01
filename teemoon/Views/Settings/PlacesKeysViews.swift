//
//  PlacesKeysViews.swift
//  teemoon
//
//  Settings garage for places & keys — manage downloads, hosts, and cloud
//  credentials. Daily model switching lives on the chat Where chip, not here.
//
//  Related: SettingsView, WhereSheetView, AddEditProviderView.
//

import SwiftUI

// MARK: - Hub

/// Entry under Settings: on this phone · your machines · cloud keys.
struct PlacesKeysHubView: View {
    @Environment(ProviderStore.self) private var providerStore

    private var phoneCount: Int {
        // Reserved for on-device providers.
        providerStore.providers.filter { WhereLocality.of($0) == .phone }.count
    }

    private var machineCount: Int {
        providerStore.providers.filter { WhereLocality.of($0) == .home }.count
    }

    private var cloudCount: Int {
        providerStore.providers.filter { WhereLocality.of($0) == .cloud }.count
    }

    var body: some View {
        Form {
            Section {
                // NO "on this phone" ROW: it has no api key and is not a
                // home endpoint that can be deleted, so it does not belong on a
                // screen about places you connect to and the credentials that
                // open them. The comment this replaces made exactly that
                // argument and then kept the row anyway, on the grounds that it
                // was "the sole path to downloads from Settings".
                //
                // That grounds is gone. The Where sheet now does all four jobs
                // `LocalModelsView` existed for — downloading from `get`,
                // deleting weights by swipe, the "may not fit in memory"
                // caution, and download-failure text — so this row led to a
                // screen that duplicated one a tap away.
                //
                // `LocalModelsView` is DELETED, not merely orphaned. A review
                // confirmed the last thing it still seemed to own — "you can see
                // what models are downloaded and installed on phone in where ->
                // phone" — so it was a second screen for a job already done a
                // tap away.
                NavigationLink {
                    MachinesPlaceManageView()
                } label: {
                    placeRow(
                        title: "home machines",
                        systemImage: "desktopcomputer",
                        badge: machineCount == 0 ? "none" : "\(machineCount)"
                    )
                }

                NavigationLink {
                    CloudKeysManageView()
                } label: {
                    placeRow(
                        title: "cloud keys",
                        systemImage: "key",
                        badge: cloudCount == 0 ? "none" : "\(cloudCount)"
                    )
                }
            } footer: {
                Text("to switch model mid-chat, \(PointerVerb.act) the model chip above the message field — not here.")
                    .textCase(.lowercase)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("places & keys")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func placeRow(title: String, systemImage: String, badge: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .textCase(.lowercase)
            Spacer()
            Text(badge)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
        }
    }
}

// MARK: - Shared manage row (no daily “use” / checkmark)

private struct PlaceManageRow: View {
    @Environment(ProviderStore.self) private var providerStore
    let provider: Provider
    /// Preview/test seam. The real answer reads the Keychain, which is empty in a
    /// canvas — so without this every cloud row renders "needs key" and the state
    /// that matters most on this screen is the one that can never be looked at.
    var hasKeyOverride: ((Provider) -> Bool)?
    /// Nil for rows with nothing to edit — a downloaded model has no host, no
    /// key and no model to change, so it renders flat. Previously it took a
    /// no-op closure and was disabled, which kept the "edit" affordance on
    /// screen: it looked tappable and did nothing.
    var onEdit: (() -> Void)?

    var body: some View {
        if let onEdit {
            Button(action: onEdit) { content(showsEdit: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), edit")
        } else {
            content(showsEdit: false)
                .accessibilityLabel(accessibilityText)
        }
    }

    private func content(showsEdit: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: WhereProviderPresentation.systemImage(for: provider))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .textCase(.lowercase)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                        .lineLimit(2)
                }
            }
            Spacer()
            if showsEdit {
                Text("edit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
            }
        }
        .contentShape(Rectangle())
    }

    /// The PLACE, never the record's label.
    ///
    /// This was `provider.name` — an auto-label generated as "<provider> <model>"
    /// when the key is saved and never refreshed — so a key row was titled
    /// "fireworks Qwen3.7 Plus" while that key was running deepseek. Both lines of a
    /// key row named a model, one of them wrong, which is why keys looked like they
    /// belonged to models. They never did: the Keychain entry hangs off `Server.id`,
    /// one record per endpoint, and the record outlives its models (§2.1).
    private var title: String {
        WhereProviderPresentation.canonicalName(for: provider)
    }

    /// Facts about the PLACE — what this screen manages. The current model is
    /// deliberately absent: it is chosen on the Where chip, it changes far more often
    /// than anything here, and printing it is what made this screen look like a model
    /// picker with a key attached.
    private var subtitle: String? {
        switch WhereLocality.of(provider) {
        case .phone:
            // A downloaded model's provider IS the model, so the title already said
            // it — "gemma 4 e2b / gemma 4 e2b · on this device" printed it twice.
            return WhereProviderPresentation.placeCaption(for: provider)

        case .home:
            // The host is the title here, so the subtitle carries what else is worth
            // knowing about the machine: what it runs, and how much.
            let kind = providerStore.storedKind(of: provider).map { k -> String in
                switch k {
                case .ollama:   return "ollama"
                case .lmStudio: return "lm studio"
                case .unknown:  return "openai-compatible"
                }
            }
            // KEY STATE HERE TOO. A home server can need one — llama.cpp and vLLM
            // both take `--api-key`, and a reverse-proxied Ollama can demand a bearer
            // token — and teemoon discovers it from a 401 (`authRequirement =
            // .needed`), so a keyed machine is a normal record, not an exotic one.
            // Omitted, a machine whose key was revoked read "ollama · 2 models" and
            // looked healthy while every request 401'd. `keyState` is nil unless the
            // record claims a key, so the keyless common case prints nothing extra.
            return [kind, modelCount, keyState].compactMap { $0 }.joined(separator: " · ")

        case .cloud:
            // Endpoint, how many models are equipped on it, and whether the key is
            // actually there — the three things you would act on.
            let host = provider.openAIBaseURL?.host?.lowercased()
            return [host, modelCount, keyState].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var modelCount: String? {
        let n = provider.equipped.count
        guard n > 0 else { return "no models" }
        return n == 1 ? "1 model" : "\(n) models"
    }

    /// BOTH lookups, the way `hasKey` does it: keys are stored per provider instance,
    /// so a key added from one screen lives under a different id than a preset's, and
    /// checking one id reports "needs key" for a provider that has one.
    private var keyState: String? {
        guard provider.requiresAPIKey else { return nil }
        if let hasKeyOverride { return hasKeyOverride(provider) ? "key set" : "needs key" }
        let byID = providerStore.credential(for: provider)
            .trimmingCharacters(in: .whitespaces)
        if !byID.isEmpty { return "key set" }
        let byEndpoint = (providerStore.credential(forEndpoint: provider.endpoint) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return byEndpoint.isEmpty ? "needs key" : "key set"
    }

    private var accessibilityText: String {
        [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Machines (home)

struct MachinesPlaceManageView: View {
    @Environment(ProviderStore.self) private var providerStore
    @State private var showAdd = false
    @State private var editing: Provider?
    /// The machine a swipe has proposed forgetting, pending confirmation.
    ///
    /// A machine has no key to lose, so this is cheaper than deleting a cloud
    /// setup — but it still takes its equipped models with it, and Where puts
    /// the same action behind a confirmation. One action, one level of
    /// protection, wherever it is reached from.
    @State private var pendingDelete: Provider?

    private var machines: [Provider] {
        providerStore.providers.filter { WhereLocality.of($0) == .home }
    }

    var body: some View {
        Form {
            Section {
                if machines.isEmpty {
                    Text("no computers connected.")
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                } else {
                    ForEach(machines) { provider in
                        PlaceManageRow(provider: provider) {
                            editing = provider
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                // CONFIRM, the way the Where sheet does.
                                //
                                // This destroyed a setup and its Keychain entry
                                // on one careless thumb, while the same action
                                // in Where sits behind a long press AND an
                                // alert — Where's reasoning being that removing
                                // a setup is rarer than removing a model from it
                                // and irreversible for a key pasted from
                                // somewhere else. Both were true here too; only
                                // the protection was missing.
                                pendingDelete = provider
                            } label: {
                                Label("delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("computers")
                    .textCase(.lowercase)
            } footer: {
                Text("edit host and models here. pick which one runs from the where chip in chat.")
                    .textCase(.lowercase)
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("connect a computer", systemImage: "plus")
                        .textCase(.lowercase)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("home machines")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAdd) {
            // THE SAME DESTINATION AS WHERE'S "connect a computer", which is
            // what the button above says. Without `startsCustom` this opened on
            // the preset grid with near.ai selected — a cloud vendor offered to
            // someone who just asked to add a machine on their own network, and
            // an answer to a question they had already given by tapping this
            // row rather than "cloud keys".
            // IDENTICAL to Where's "connect a computer" — no scope override,
            // so `.full`, so the model section appears.
            //
            // `.serverAndKey` hides that section, which is right for "add cloud
            // key" (a preset carries its own default and the picker turned a key
            // form into a model chooser) and wrong for a machine you host
            // yourself, where which model to run IS the question. Two buttons
            // with the same label were opening two different screens.
            AddEditProviderView(
                mode: .add,
                startsCustom: true,
                customStart: .computer
            )
        }
        .sheet(item: $editing) { provider in
            AddEditProviderView(scope: .serverAndKey, mode: .edit(provider))
        }
        // Same words as the Where sheet's, including the clause about the key —
        // one action, described one way, wherever it is reached from.
        .alert(item: $pendingDelete) { provider in
            Alert(
                title: Text("delete \(WhereProviderPresentation.canonicalName(for: provider))?"),
                message: Text(provider.requiresAPIKey
                              ? "this removes the setup and its api key. you'll have to paste the key again to use it."
                              : "this removes the setup. you can add it again later."),
                primaryButton: .destructive(Text("delete")) {
                    providerStore.removeProvider(provider)
                    Haptics.play()
                },
                secondaryButton: .cancel(Text("keep"))
            )
        }
    }
}

// MARK: - Cloud keys

struct CloudKeysManageView: View {
    @Environment(ProviderStore.self) private var providerStore
    /// Preview seam — see `PlaceManageRow.hasKeyOverride`.
    var hasKey: ((Provider) -> Bool)?
    @State private var showAdd = false
    @State private var editing: Provider?
    /// The setup a swipe has proposed deleting, pending confirmation.
    @State private var pendingDelete: Provider?

    private var cloud: [Provider] {
        providerStore.providers.filter { WhereLocality.of($0) == .cloud }
    }

    var body: some View {
        Form {
            Section {
                if cloud.isEmpty {
                    Text("no cloud keys yet.")
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                } else {
                    ForEach(cloud) { provider in
                        PlaceManageRow(provider: provider, hasKeyOverride: hasKey) {
                            editing = provider
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                // CONFIRM, the way the Where sheet does.
                                //
                                // This destroyed a setup and its Keychain entry
                                // on one careless thumb, while the same action
                                // in Where sits behind a long press AND an
                                // alert — Where's reasoning being that removing
                                // a setup is rarer than removing a model from it
                                // and irreversible for a key pasted from
                                // somewhere else. Both were true here too; only
                                // the protection was missing.
                                pendingDelete = provider
                            } label: {
                                Label("delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("saved")
                    .textCase(.lowercase)
            } footer: {
                Text("add, rotate, or revoke keys. current model per setup is chosen in chat → where.")
                    .textCase(.lowercase)
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("add cloud key", systemImage: "plus")
                        .textCase(.lowercase)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("cloud keys")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAdd) {
            AddEditProviderView(scope: .serverAndKey, mode: .add)
        }
        .sheet(item: $editing) { provider in
            AddEditProviderView(scope: .serverAndKey, mode: .edit(provider))
        }
        // Same words as the Where sheet's, including the clause about the key —
        // one action, described one way, wherever it is reached from.
        .alert(item: $pendingDelete) { provider in
            Alert(
                title: Text("delete \(WhereProviderPresentation.canonicalName(for: provider))?"),
                message: Text(provider.requiresAPIKey
                              ? "this removes the setup and its api key. you'll have to paste the key again to use it."
                              : "this removes the setup. you can add it again later."),
                primaryButton: .destructive(Text("delete")) {
                    providerStore.removeProvider(provider)
                    Haptics.play()
                },
                secondaryButton: .cancel(Text("keep"))
            )
        }
    }
}

#if os(iOS)
#Preview("places hub") {
    let store = ProviderStore(inMemory: true)
    store.providers = [.local(LocalModelCatalog.all[0]), .nearAI, .grok]
    return NavigationStack {
        PlacesKeysHubView()
            .environment(store)
    }
}

/// The hub's phone room, with something in it. The "download a model" row is
/// the door: this view can otherwise describe an empty phone but never fill
/// one, since the Where sheet's phone tier is where downloads happen.
#Preview("cloud keys") {
    let store = ProviderStore(inMemory: true)
    var near = Provider.nearAI
    near.name = "near.ai glm 5.2"                     // the auto-label, as saved
    near.equippedModels = ["z-ai/glm-5.2", "z-ai/glm-5.1", "deepseek/deepseek-v3.2"]
    var fireworks = Provider.fireworks
    fireworks.name = "fireworks Qwen3.7 Plus"         // stale: it runs deepseek now
    // `equipped` folds in the ACTIVE model, so the active one has to be in the list
    // or the count reads one higher than the fixture claims.
    fireworks.model = "accounts/fireworks/models/deepseek-v4-flash"
    fireworks.equippedModels = ["accounts/fireworks/models/deepseek-v4-flash"]
    var grok = Provider.grok
    grok.name = "grok"
    grok.model = "grok-4.5"
    grok.equippedModels = ["grok-4.5"]
    store.providers = [near, fireworks, grok]
    return NavigationStack {
        // near.ai and fireworks are keyed; grok was added and never keyed, which is
        // the state this row exists to make visible.
        CloudKeysManageView(hasKey: { $0.id != Provider.grok.id })
            .environment(store)
    }
}

#Preview("home machines") {
    let store = ProviderStore(inMemory: true)
    var ringzero = Provider(name: "ringzero gemma4:e2b-it-qat",
                            endpoint: "https://ringzero.tailnet-name.ts.net:11434/v1",
                            model: "gemma4:e4b", requiresAPIKey: false)
    ringzero.equippedModels = ["gemma4:e4b", "qwen3.5:4b"]
    var secondMac = Provider(name: "second mac qwen3:14b",
                          endpoint: "http://100.100.0.12:11434/v1",
                          model: "qwen3:14b", requiresAPIKey: false)
    secondMac.equippedModels = ["qwen3:14b"]
    // A KEYED machine — llama.cpp started with `--api-key`, or an Ollama behind a
    // proxy that wants a bearer token. Its key is missing here, which is the state
    // that used to render as a healthy row while every request 401'd.
    var guarded = Provider(name: "llama.cpp",
                           endpoint: "http://192.168.1.50:8080/v1",
                           model: "qwen3.5-7b", requiresAPIKey: true)
    guarded.equippedModels = ["qwen3.5-7b"]
    store.providers = [ringzero, secondMac, guarded]
    return NavigationStack {
        MachinesPlaceManageView()
            .environment(store)
    }
}
#endif
