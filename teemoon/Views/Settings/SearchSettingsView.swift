//
//  SearchSettingsView.swift
//  teemoon
//
//  The one destination for web search setup. Both entrances land here — the
//  composer chip when it is unconfigured, and `set it up` on the offer card.
//
//  THE SCREEN CHANGES SHAPE BY STATE, which is the whole point. The design this
//  replaces (chosen-path frame 5) put a paste field in the primary position and
//  noted, accurately, that "for the newcomer the field is dead until they take
//  the row underneath it". That is the wrong way round: nearly everyone arriving
//  here came from the offer card and has no key, so the screen's most prominent
//  control was the one they cannot use. Getting a key leads when there isn't
//  one; the field leads when there is.
//

import SwiftUI

struct SearchSettingsView: View {
    /// Non-nil when this screen was DEEP-LINKED — from the composer chip or the
    /// offer card — rather than reached by browsing settings.
    ///
    /// It changes the exit. A deep-linked user never asked for the settings
    /// index, so a back chevron drops them somewhere they did not want and
    /// costs a second tap to escape. "done" closes the whole sheet and returns
    /// them to the thread they were in, which is what chosen-path frame 5 asked
    /// for: "exiting returns to the thread, not to Settings."
    ///
    /// Nil when pushed from the settings list, where back IS the right exit and
    /// removing it would strand the user.
    var onDone: (() -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStore.self) private var providerStore
    @State private var braveGroundingKey = ""
    @State private var showGroundingKey = false
    @State private var groundingKeyCopied = false

    private var activeProviderHasBuiltInGrounding: Bool {
        providerStore.activeProvider?.capabilities.contains(.builtInGrounding) ?? false
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            if activeProviderHasBuiltInGrounding {
                BuiltInGroundingSection()
            } else {
                SearchSetupSections(
                    key: $braveGroundingKey,
                    enabled: $settings.braveGroundingEnabled,
                    showKey: $showGroundingKey,
                    copied: $groundingKeyCopied
                )
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.search")
        .navigationTitle("web search")
        .navigationBarBackButtonHidden(onDone != nil)
        .toolbar {
            if let onDone {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("done", action: onDone)
                        .accessibilityIdentifier("search.done")
                }
                #endif
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { braveGroundingKey = settings.braveSearchKey }
        .onChange(of: braveGroundingKey) { _, newValue in
            settings.braveSearchKey = newValue
        }
    }
}

/// Brave Answers grounds natively, so there is nothing to configure and the
/// setup UI would be a second, contradictory switch.
private struct BuiltInGroundingSection: View {
    var body: some View {
        Section(footer: Text("brave answers searches the web itself. switch to another place to set up search for it.")) {
            HStack {
                Text("search is built in here")
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct SearchSetupSections: View {
    @Environment(\.openURL) private var openURL
    @FocusState private var editingKey: Bool
    /// Which layout is on screen — a SNAPSHOT, not a live read of `key`.
    ///
    /// Feedback: clearing the key made the view "automatically change to the add
    /// key view which was very abrupt and amateurish". Correct, and it was
    /// a direct consequence of driving the layout off `key.isEmpty`: deleting
    /// the last character rearranged the whole screen under the user's finger, mid-
    /// gesture, with the field being edited jumping down the page.
    ///
    /// A screen may reshape between visits. It must not reshape while you are
    /// typing in it. So this is re-evaluated on appear and when the field gives
    /// up focus — never on each keystroke.
    @State private var showsGetKeyPath = true
    /// Result of the last real request to brave, or nil before one has run.
    @State private var check: BraveWebSearchTool.KeyCheck?
    @State private var checking = false
    @Binding var key: String
    @Binding var enabled: Bool
    @Binding var showKey: Bool
    @Binding var copied: Bool

    private var hasKey: Bool { !key.isEmpty }

    var body: some View {
        // FIRST-TIME ORDER: what it is, then how to get one, then the field.
        // The field stays on screen rather than being hidden behind a
        // disclosure — someone who already copied a key must not have to go
        // looking for somewhere to put it.
        if showsGetKeyPath {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("the model looks things up on its own initiative")
                        .font(.system(size: 20, weight: .semibold))
                    // THE MODEL DECIDES. teemoon does not pre-fetch results for
                    // every message — the web_search tool is offered, and the
                    // model calls it with its own query when it judges that it
                    // needs to. Worth saying plainly because the consequence is
                    // the selling point: brave only ever sees the handful of
                    // queries the model actually asked for, not the
                    // conversation, and you are not billed for turns that did
                    // not need searching.
                    //
                    // WORDING IS DELIBERATE — "nothing reaches brave" names
                    // the party being kept out, chosen over "nothing is
                    // fetched", which describes efficiency. Recorded so nobody
                    // "fixes" it back later: this is a decision, not an
                    // oversight. Only the capitalisation was changed, and that
                    // is the brand's lowercase rule rather than taste.
                    //
                    // "on its own initiative" is the phrase that made "agentic"
                    // unnecessary — plain English for the same idea, with no
                    // term to teach first.
                    //
                    // "agentic" is the accurate word and the wrong one here,
                    // as are "reasons over the source" and "pre-fetched" — all
                    // three come from RAG documentation written for API buyers.
                    //
                    // Deliberately NOT listing what brave extracts ("tables,
                    // code blocks, structured data"). That is brave's claim
                    // about their API, not teemoon's about what a user sees:
                    // `parseSources` reads url, title, published and content out
                    // of the <source> XML and surfaces text. Promising structure
                    // the app does not render would be a claim we cannot keep.
                    //
                    // The API IS named, and named exactly: "brave's llm context
                    // api". Lowercased per the voice rule that acronyms are
                    // lowercase too. Naming it is worth the words — it is the
                    // only place a user can learn what teemoon actually calls,
                    // and it is searchable if they want to read brave's terms
                    // before handing over a key.
                    //
                    // It must be LLM CONTEXT and nothing else. Brave also ships
                    // AI Grounding (= Answers), which teemoon offers as a
                    // separate PROVIDER with hasBuiltInGrounding — a different
                    // endpoint reached a different way. "LLM Grounding API"
                    // blends the two names into a product that does not exist,
                    // and the benchmark claims floating around ("94.1% on
                    // SimpleQA") belong to Answers, not to this.
                    Text("when it needs more information, it calls brave's llm context api and receives the extracted page content — not just links. nothing is fetched unless the model decides it needs it.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // leading 20, NOT 0. At 0 the row's clip boundary cut the first
                // glyph off the headline — "let the model" rendered as "et the
                // model". 20 also lines the hero up with the section headers
                // below it, which is where it should have been anyway.
                // leading 16, matching where the section HEADERS below start.
                // At 20 the hero sat 4pt right of every other left edge on the
                // screen — close enough to read as a mistake rather than a
                // choice. (0 is not an option: it puts the first glyph on the
                // row's clip boundary and "let" drew as "et".)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            // The hero is INTRODUCING the row below it, so the default grouped
            // gap — which ran about three times every other gap on the screen —
            // read as a divorce rather than a paragraph break.
            .compactSectionSpacing()

            Section(footer: Text("$5 of free credit a month — about 1,000 searches. billed per search after that.")) {
                // A Button, not a Link. `Link` tints its ENTIRE content with
                // the accent, so the grey subtitle rendered accent-coloured and
                // the row read as two links. Same destination, colours honoured.
                Button {
                    openURL(URL(string: "https://brave.com/search/api/")!)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // THE FULL PATH, not the bare host. A link that
                            // says "brave.com" and lands on a specific API
                            // signup page is telling you less than it knows —
                            // and this one asks for a card, so the destination
                            // should be legible before the tap, not after.
                            Text("brave.com/search/api")
                                .font(.system(size: 16, weight: .semibold))
                                // R1: this row is the accent-carrying action on
                                // the screen, so it states its own colour.
                                .foregroundStyle(Color.accentColor)
                            // Three dot-separated clauses wrapped with "a"
                            // orphaned onto the second line. "on file" was the
                            // droppable one — a card IS on file once given.
                            Text("get a key · account and a card · a few minutes")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.getKey")
            }
        }

        Section {
            // The TOGGLE tracks the real key, because enabling search with no
            // key is meaningless — only the surrounding layout is snapshotted.
            if hasKey {
                Toggle(isOn: $enabled) {
                    Label("enabled", systemImage: "magnifyingglass")
                }
            }
            KeyField(key: $key, showKey: $showKey, copied: $copied)
                .focused($editingKey)
                // A return key that says "done" and actually dismisses.
                //
                // Pasting a 40-character key left the keyboard up with nothing
                // on it that meant "finished" — the only way out was tapping
                // empty space, which is not an affordance. Releasing focus is
                // also what triggers the key check (see the `onChange` below),
                // so this is the difference between the field validating when
                // you say you are done and validating whenever you happen to
                // tap elsewhere.
                .submitLabel(.done)
                .onSubmit { editingKey = false }

            if checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("checking with brave…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } else if let check, check != .valid {
                Label {
                    Text(KeyCheckCopy.message(for: check))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: KeyCheckCopy.icon(for: check))
                        .foregroundStyle(KeyCheckCopy.tint(for: check))
                }
                .foregroundStyle(.secondary)
            } else if check == .valid {
                Label("brave accepted this key", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        } header: {
            // No header at all before a key exists would leave the field
            // unlabelled directly under a button that goes somewhere else.
            Text(showsGetKeyPath ? "already have a key?" : "brave api key")
                .textCase(.lowercase)
        } footer: {
            Text("stored in the keychain on this device — not synced, so a new phone means doing this again. brave sees the search terms, never your conversation.")
        }
        .onAppear { showsGetKeyPath = key.isEmpty }
        .onChange(of: editingKey) { _, focused in
            // CHECK ON RELEASE, never per keystroke — a check per character
            // would spend a real search on every letter of a 40-character key.
            guard !focused, !key.isEmpty else { return }
            Task {
                checking = true
                check = await BraveWebSearchTool.checkKey(key)
                checking = false
                // Only a key brave ACCEPTED turns search on by itself. Out of
                // credit is still a real key worth keeping, but silently
                // enabling it would light the chip on a thing that cannot
                // search today.
                if check == .valid { enabled = true }
            }
        }
        .onChange(of: editingKey) { _, focused in
            // Settling only once the field is released, and animated, so the
            // change reads as a consequence of what you did rather than the
            // screen misbehaving.
            guard !focused else { return }
            withAnimation(.easeInOut(duration: 0.28)) { showsGetKeyPath = key.isEmpty }
        }
    }
}

/// The copy, lifted out of the view so a preview can render every outcome
/// side by side — which is how you notice that two of them are not about the
/// key at all.
enum KeyCheckCopy {
    /// Copy per outcome. Two of these are NOT about the key at all, and saying
    /// "that key didn't work" for either would send the user to re-type a key
    /// that is fine.
    static func message(for check: BraveWebSearchTool.KeyCheck) -> String {
        switch check {
        case .valid:
            return "brave accepted this key"
        case .rejected:
            return "brave didn't recognise this key. check for a missing character or a stray space — and that it's a search api key, not one from another brave product."
        case .outOfCredit:
            return "this key is real but has no credit left this month. it's saved; searches will work again when brave resets, or sooner if you raise the limit in their dashboard."
        case .unreachable:
            return "couldn't reach brave, so the key hasn't been checked. it's saved — this usually means no connection."
        case .braveUnavailable(let status):
            return "brave's api returned an error (\(status)), so the key hasn't been checked. it's saved; this is on their side."
        }
    }

    static func icon(for check: BraveWebSearchTool.KeyCheck) -> String {
        switch check {
        case .valid:            return "checkmark.circle.fill"
        case .rejected:         return "xmark.circle.fill"
        case .outOfCredit:      return "creditcard"
        case .unreachable,
             .braveUnavailable: return "wifi.exclamationmark"
        }
    }

    /// RED only for the one case the user can act on. The other two are
    /// conditions, not mistakes, and colouring them as failures would tell
    /// someone their key is broken when it is not.
    static func tint(for check: BraveWebSearchTool.KeyCheck) -> Color {
        switch check {
        case .rejected:         return .red
        case .valid:            return .green
        case .outOfCredit,
             .unreachable,
             .braveUnavailable: return .secondary
        }
    }
}

private struct KeyField: View {
    @Binding var key: String
    @Binding var showKey: Bool
    @Binding var copied: Bool

    var body: some View {
        HStack {
            if showKey {
                TextField("api key", text: $key, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .autocapitalization(.none)
                    #endif
            } else {
                SecureField("api key", text: $key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .autocapitalization(.none)
                    #endif
            }
            if !key.isEmpty {
                Button {
                    // Credential copy — local-only, self-expiring.
                    Clipboard.copySensitive(key)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                        .foregroundStyle(.secondary)
                }
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
            }
            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
        }
    }
}

// MARK: - Previews
//
// The two states are previewed through the section view directly, because the
// real screen reads its key from the Keychain and a preview cannot put one
// there. What is being judged is which control leads.

private struct PreviewShell: View {
    let title: String
    var asOwnSheet: Bool = false
    @State var key: String
    @State private var enabled = true
    @State var showKey = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                SearchSetupSections(key: $key, enabled: $enabled,
                                    showKey: $showKey, copied: $copied)
            }
            .formStyle(.grouped)
            .navigationTitle("web search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if asOwnSheet {
                    ToolbarItem(placement: .topBarLeading) { Button("done") {} }
                }
            }
            #endif
        }
        .environment(\.colorScheme, .dark)
    }
}

#Preview("search · no key yet", traits: .fixedLayout(width: 402, height: 700)) {
    PreviewShell(title: "no key", key: "")
}

#Preview("search · key saved", traits: .fixedLayout(width: 402, height: 700)) {
    PreviewShell(title: "has key", key: "BSA-xxxxxxxxxxxxxxxxxxxxxxxx")
}

/// Same state with the key revealed. Exists because `SecureField` renders its
/// dots as an empty row in a static preview snapshot, which makes a populated
/// field look like a lost one — this separates the artifact from a real bug.
#Preview("search · key saved, revealed", traits: .fixedLayout(width: 402, height: 700)) {
    PreviewShell(title: "has key", key: "BSA-xxxxxxxxxxxxxxxxxxxxxxxx", showKey: true)
}

/// THE PROPOSAL: presented DIRECTLY as its own sheet from the chip or the offer
/// card, instead of pushed inside the settings stack.
///
/// The picture is almost identical to the deep-linked version — which is the
/// honest argument for it. The win is not visual, it is that three problems
/// stop existing rather than being handled: no detent to choose (the sheet is
/// sized for this screen, not for a settings index), no back-vs-done question
/// (a leaf sheet has one exit), and no settings index sitting behind a screen
/// the user never asked to browse.
///
/// It DELETES `showSettingsSearch`, the `navigateToSearch` destination and the
/// detent selection — a simplification, not an addition.
#Preview("search · as its own sheet", traits: .fixedLayout(width: 402, height: 700)) {
    PreviewShell(title: "standalone", asOwnSheet: true, key: "")
}

/// EVERY OUTCOME AT ONCE, because the copy is the deliverable here. Two of
/// these say nothing about the key, and the difference has to be legible.
#Preview("search · key check outcomes", traits: .fixedLayout(width: 402, height: 620)) {
    let outcomes: [BraveWebSearchTool.KeyCheck] = [
        .valid, .rejected, .outOfCredit, .unreachable, .braveUnavailable(status: 503),
    ]
    return NavigationStack {
        Form {
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                Section {
                    Label {
                        Text(KeyCheckCopy.message(for: outcome))
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: KeyCheckCopy.icon(for: outcome))
                            .foregroundStyle(KeyCheckCopy.tint(for: outcome))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("key check")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    .environment(\.colorScheme, .dark)
}

#Preview("search · built in", traits: .fixedLayout(width: 402, height: 400)) {
    NavigationStack {
        Form { BuiltInGroundingSection() }
            .formStyle(.grouped)
            .navigationTitle("web search")
    }
    .environment(\.colorScheme, .dark)
}
