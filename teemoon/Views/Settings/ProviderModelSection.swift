//
//  ProviderModelSection.swift
//  teemoon
//
//  The verify-first heart of the add/edit provider screen: fetch-models button
//  that doubles as the connection test, the resulting model picker, and one
//  inline line on failure. Fixed-model providers (Brave) get a connection check
//  instead — there is nothing to pick, fetch, or refresh.
//

import SwiftUI

struct ProviderModelSection: View {
    @Bindable var form: AddEditProviderModel
    /// In-flight pulls for THIS endpoint, shown as disabled progress rows right in
    /// the model list (replaces the old global banner). Active/reconnecting only —
    /// a finished pull re-probes into a normal installed row. Computed by the
    /// parent, which also watches the count to re-probe when one finishes.
    let downloads: [OllamaDownloadCenter.Download]
    let onCancelDownload: (OllamaDownloadCenter.Download) -> Void

    var body: some View {
        if form.fixedModelID != nil { connectionCheckSection } else { modelListSection }
    }

    /// Fixed-model providers: no picker, no "fetch models" — just whether the key
    /// works. (Brave has no `/models` endpoint, so the old model section offered
    /// an empty list and a refresh button that fetched nothing.)
    @ViewBuilder
    private var connectionCheckSection: some View {
        Section {
            switch form.conn {
            case .testing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("checking…").foregroundStyle(.secondary).textCase(.lowercase)
                }
            case .connected:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(.green)
                    Text("key accepted").foregroundStyle(.secondary).textCase(.lowercase)
                    Spacer()
                    // No retry on success. "check again" next to a green tick
                    // invites the user to re-run a check that already passed,
                    // which can only produce the same answer or a worse one —
                    // and offering it makes the tick look provisional. Editing
                    // the key or the endpoint re-probes on its own.
                }
            case .idle, .failed:
                Button {
                    // Also user-initiated: "test connection" that reports
                    // nothing when there is no key is the same broken button as
                    // a silent "fetch models".
                    Task { await form.probe(userInitiated: true) }
                } label: {
                    Label("test connection", systemImage: "arrow.triangle.2.circlepath")
                        .textCase(.lowercase)
                        .opacity(form.probeBlockedOnMissingKey ? 0.4 : 1)
                }
                // Was `apiKey.isEmpty` outright, which greyed this out for
                // endpoints that need no key at all — a self-hosted ollama has
                // nothing to type and could not be tested. Gated on the LEARNED
                // requirement instead, so it only greys where a 401 has
                // actually been seen.
                .disabled(form.probeBaseURL == nil || form.probeBlockedOnMissingKey)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
                if case .failed(let kind) = form.conn { inlineError(kind) }
            }
        } header: {
            Text("connection").textCase(.lowercase)
        } footer: {
            Text("this endpoint answers directly — there is no model to choose")
                .textCase(.lowercase)
        }
    }

    @ViewBuilder
    private var modelListSection: some View {
        Section {
            downloadingRows   // in-flight pulls sit at the TOP — the most active item
            switch form.conn {
            case .testing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("connecting…").foregroundStyle(.secondary).textCase(.lowercase)
                }

            case .idle, .failed:
                if form.fetchedModels.isEmpty {
                    if !form.hasProbed {
                        // NOTHING YET. Feedback: the model section "shows too
                        // quickly... it should only show up once the user clicks
                        // fetch models". The fetch button below stays — hiding
                        // the whole section would hide the control that fills
                        // it — but the row it would fill does not appear until
                        // there is a reason for it.
                        EmptyView()
                    } else if form.supportsModelBrowsing {
                        // Browsable preset: the model comes from the catalogue, not a raw
                        // field — don't flash the preset's raw id ("z-ai/glm-5.2") while the
                        // probe loads the picker; a "connecting…" row follows in .testing.
                        EmptyView()
                    } else {
                        // Manual fallback (soft-gate): type a model even without a fetch.
                        TextField("model", text: $form.model)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .autocapitalization(.none)
                            #endif
                    }
                } else {
                    modelPicker
                }
                fetchButton
                if case .failed(let kind) = form.conn { inlineError(kind) }

            case .connected:
                if form.fetchedModels.isEmpty {
                    // Connected with nothing installed — a fresh ollama. Say so
                    // rather than showing an empty picker, and let the download
                    // button below be the obvious next move.
                    Text(form.isOllama ? "no models installed on this server yet"
                                       : "this server returned no models")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                } else {
                    modelPicker
                }
                fetchButton   // acts as "refresh models"
                if form.isOllama { downloadModelButton }
            }
        } header: {
            Text("model")
        } footer: {
            // The row above is the SELECTION, not a fixed recommendation — so the
            // note is conditional on the two coinciding. Naming it in the header
            // would go stale the moment the user picks something else, and
            // freezing the row to the recommendation would stop the sheet showing
            // what they actually chose.
            if let recommended = form.recommendedModelID, recommended == form.model {
                Text("recommended for this provider.")
            }
        }
    }

    @ViewBuilder
    private var downloadingRows: some View {
        ForEach(downloads) { d in
            DownloadingModelRow(download: d, onCancel: { onCancelDownload(d) })
        }
    }

    /// Ollama-only: server-side model pull (paste a HuggingFace ref or a library
    /// name). Distinct from the on-device download tier — this lands on the server.
    @ViewBuilder
    private var downloadModelButton: some View {
        Button {
            form.showDownloadSheet = true
        } label: {
            Label("download a model", systemImage: "arrow.down.circle")
                .textCase(.lowercase)
        }
        #if os(macOS)
        .buttonStyle(.borderless)
        #endif
    }

    @ViewBuilder
    private var modelPicker: some View {
        ForEach(form.recommendedModels) { m in
            Button {
                form.model = m.id
                form.autofillLabel(from: m)
                Haptics.play()
            } label: {
                // Same one-line layout as the browser catalog: name → tier badge →
                // price·context on the right (+ warm / checkmark for the inline picker).
                HStack(spacing: 6) {
                    Text(m.displayName).tint(.primary).textCase(.lowercase).lineLimit(1)
                    if form.showsInlineTiers {
                        confidentialityTag(NearAIModelCatalog.confidentiality(forID: m.id)).fixedSize()
                    }
                    if form.loadedModelIDs.contains(m.id) {
                        // ambient "warm" (loaded in server memory) — a dot, not a badge.
                        HStack(spacing: 4) {
                            WarmDot()
                            Text("warm").font(.caption2).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 6)
                    let sub = m.metaLabel      // same right-hand line as the browser
                    if !sub.isEmpty {
                        Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).fixedSize()
                    }
                    if form.model == m.id {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
            #if os(iOS)
            // Ollama only: swipe a model row to delete it from the server (confirmed).
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if form.isOllama {
                    Button(role: .destructive) { form.pendingDelete = m } label: {
                        Label("delete", systemImage: "trash")
                    }
                    .tint(.red)   // override the app's orange accent for a destructive action
                }
            }
            #endif
            // .plain so the price/context subtitle renders in true gray, not the row
            // Button's accent tint (the "orange subtitle" bug).
            #if os(macOS)
            .buttonStyle(.borderless)
            #else
            .buttonStyle(.plain)
            #endif
        }
        if form.fetchedModels.count > 3 {
            Button { form.showModelBrowser = true } label: {
                HStack {
                    Text("all \(form.fetchedModels.count) models").tint(.primary).textCase(.lowercase)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
        }
    }

    @ViewBuilder
    private var fetchButton: some View {
        Button {
            // USER-INITIATED: report whatever comes back, including a 401 on an
            // empty key. Swallowing it here would make the button look broken —
            // the one case where "this needs a key first" is exactly the answer
            // the tap was asking for.
            Task { await form.probe(userInitiated: true) }
        } label: {
            Label(form.fetchedModels.isEmpty ? "fetch models" : "refresh models",
                  systemImage: "arrow.triangle.2.circlepath")
                .textCase(.lowercase)
                // EXPLICIT DIM. `.disabled()` alone barely changes a Form row —
                // Feedback: "disabled row looks very similar to enabled row" — so
                // the control was unusable and looked usable, which is the one
                // combination guaranteed to read as a bug.
                //
                // 40%, the same figure the web chip's disabled state uses. One
                // dim across the app, meaning one thing: you cannot tap this.
                .opacity(form.probeBlockedOnMissingKey ? 0.4 : 1)
        }
        // Greyed rather than tappable-and-scolding. Reporting "needs a key" on
        // tap was the previous step and is still right for the cases this
        // cannot foresee — but where the app ALREADY knows the request cannot
        // succeed, disabling says so before the tap instead of after it.
        .disabled(form.probeBaseURL == nil || form.probeBlockedOnMissingKey)
        #if os(macOS)
        .buttonStyle(.borderless)
        #endif
    }

    /// The failure, stated. NO retry button.
    ///
    /// It carried a "try again" that duplicated whatever button it appeared under —
    /// "refresh models" in the model section, "test connection" in the connection one.
    /// Noted on the add-key screen: the refresh button is already there. Two controls
    /// running the same `probe()` a line apart read as two different remedies, and the
    /// user has to work out which.
    @ViewBuilder
    private func inlineError(_ kind: EndpointModelCatalog.FailureKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(.red)
            Text(form.failureMessage(kind)).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Trust-tier badge — the "ink ladder": e2ee is filled + shield (proven),
/// attested-unverified is a hairline outline (a claim without the substance),
/// proxied is bare text (least ink for the least protection). One green
/// (teeVerified ≈ #30d158) means a proof ran and held; everything else is gray.
/// File-level so the browser and the inline add-provider rows render it identically.
@ViewBuilder
func confidentialityTag(_ tier: NearAIModelCatalog.Confidentiality) -> some View {
    switch tier {
    case .teeOwn:
        HStack(spacing: 3) {
            Image(systemName: "checkmark.shield.fill")
            Text("e2ee")
        }
        .font(.caption2).fontWeight(.medium)
        .foregroundStyle(teeVerified)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(teeVerified.opacity(0.12)))
    case .teeThirdParty:
        // NOT "unverified" — that reads as "we checked and it failed", when the
        // fact is the opposite: it IS attested, just on hardware that isn't
        // near.ai's own. Name the fact, not a verdict.
        Text("tee · third-party")
            .font(.caption2).fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
    case .proxied:
        Text("proxied")
            .font(.caption2).fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

}
