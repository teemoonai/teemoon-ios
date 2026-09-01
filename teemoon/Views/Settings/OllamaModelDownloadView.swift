//
//  OllamaModelDownloadView.swift
//  teemoon
//
//  Server-side model pull for an Ollama endpoint. The real starting point for a
//  local-model user is a HuggingFace GGUF repo — HF's "Use this model → Ollama"
//  dropdown hands them `hf.co/{user}/{repo}[:{quant}]`. So this is PASTE-FIRST:
//  paste that ref (or a browser URL, or a bare Ollama name) and teemoon triggers
//  the pull. The download runs on the SERVER, owned by the app-level
//  OllamaDownloadCenter — so you can close this sheet (or background teemoon) and
//  it keeps going, surfacing as a disabled "downloading" row in the provider's
//  model list that becomes selectable when ready.
//

import SwiftUI

struct OllamaModelDownloadView: View {
    /// The probe base URL (…/v1); OllamaAdapter derives the /api root from it.
    let baseURL: URL
    /// Called with the pulled model's ref when it finishes *while this sheet is
    /// open*, so the parent can re-fetch the list and select the new model.
    var onCompleted: ((String) -> Void)? = nil
    /// Called with the normalized ref the moment a pull STARTS.
    ///
    /// The parent needs this to show the model as arriving wherever it lists
    /// models — a phone download does that already, because tapping it creates the
    /// provider up front and the row renders its own progress. A server-side pull
    /// had no equivalent: nothing existed to render until the bytes landed, so
    /// closing this sheet made an in-flight multi-gigabyte pull invisible.
    var onStarted: ((String) -> Void)? = nil
    /// What the server already has, as `/api/tags` spells it.
    ///
    /// Nothing checked this before: the shortlist would recommend a model the machine
    /// had had for weeks, and a re-pull looked exactly like a first one. Both callers
    /// already hold the list — the Where sheet from `HomeServerProbe`, settings from
    /// its own probe — so it was only ever a matter of passing it in.
    var installed: [String] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(OllamaDownloadCenter.self) private var center

    @State private var ref: String
    /// The normalized ref this sheet started, so we can track its progress.
    @State private var startedRef: String?
    /// Set when the pasted text is knowably not a model — see `startPull`.
    @State private var refProblem: String?

    /// Preview/test seam: the picked state can't be reached in a canvas, because
    /// reaching it means tapping a row.
    init(baseURL: URL,
         onCompleted: ((String) -> Void)? = nil,
         onStarted: ((String) -> Void)? = nil,
         installed: [String] = [],
         initialRef: String = "",
         initialProblem: String? = nil) {
        self.baseURL = baseURL
        self.onCompleted = onCompleted
        self.onStarted = onStarted
        self.installed = installed
        _ref = State(initialValue: initialRef)
        _refProblem = State(initialValue: initialProblem)
    }

    /// The recommendations, LEADING the sheet — see `shortlistSection`.
    private let shortlist = OllamaModelShortlist.recommended

    /// The pull this sheet is showing: the one it started, or — failing that — one
    /// the center already knows about for whatever ref is in the field.
    ///
    /// The fallback is not preview scaffolding. `startedRef` is set by tapping
    /// download and lives in this view, so closing the sheet mid-pull and reopening
    /// it showed no progress at all, for a download that was still running; and a ref
    /// that failed a minute ago came back looking untried. The center outlives the
    /// sheet precisely so the pull can, and this is the sheet reading it.
    private var current: OllamaDownloadCenter.Download? {
        if let startedRef { return center.download(for: startedRef) }
        let normalized = OllamaAdapter.normalizePullRef(trimmedRef)
        return normalized.isEmpty ? nil : center.download(for: normalized)
    }
    private var isPulling: Bool {
        guard let p = current?.phase else { return false }
        return p == .active || p == .reconnecting
    }
    private var trimmedRef: String { ref.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                // RECOMMENDATIONS FIRST, then the field, then browse.
                //
                // This sheet was paste-first, on the argument that the real starting
                // point is a HuggingFace ref from HF's own "Use this model → Ollama"
                // dropdown. That argument holds for someone who arrived with a model
                // in mind, and describes nobody else: the field cannot be filled by
                // a user who doesn't already know what to type, and the sheet opened
                // by asking them to type it. The shortlist asks the one question they
                // can answer about their own machine instead — how much GPU memory
                // it has — and answers it with a name. Paste keeps its place directly
                // under it, for the case it was built for.
                if !isPulling { shortlistSection }
                bringYourOwnSection
                // DIRECTLY under the field, not last. Progress belongs next to the
                // action that started it — and a FAILURE has to: `isPulling` is false
                // once a pull fails, so every other section came back and pushed the
                // explanation below the fold. You tapped download, it failed, and the
                // reason was off-screen.
                if let d = current, d.phase != .done { progressSection(d) }
            }
            .formStyle(.grouped)
            .navigationTitle("download a model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(isPulling ? "close" : "cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("download") { startPull() }
                        .fontWeight(.semibold)
                        .disabled(trimmedRef.isEmpty || isPulling)
                }
                #elseif os(macOS)
                ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("download") { startPull() }.disabled(trimmedRef.isEmpty || isPulling)
                }
                #endif
            }
            // Finished while the sheet is open → select it and close.
            .onChange(of: current?.phase) { _, phase in
                if phase == .done, let r = startedRef {
                    onCompleted?(r)
                    dismiss()
                }
            }
        }
    }

    // MARK: Sections

    /// Variant B: the two halves of one action, in one box.
    ///
    /// Browsing is the FIRST HALF of a round trip — leave, find a model, copy its
    /// link, come back, paste — and as three separate sections nothing said so. Worse,
    /// the field sat ABOVE the links, so the flow read upward. Links first, field
    /// last, and a footer that names the step between them.
    @ViewBuilder
    private var bringYourOwnSection: some View {
        Section {
            if !isPulling {
                browseLink("ollama.com", "curated · tools and vision badges",
                           "https://ollama.com/search")
                browseLink("hugging face — gguf", "any community quant",
                           "https://huggingface.co/models?library=gguf&sort=trending")
            }
            TextField("paste the link here", text: $ref)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .disabled(isPulling)
                .submitLabel(.go)
                .onSubmit(startPull)          // Return starts the pull
                .onChange(of: ref) { _, _ in refProblem = nil }
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
            if let refProblem {
                Label(refProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    // Red: the reference is wrong and the pull cannot proceed.
                    .foregroundStyle(.red)
                    .textCase(.lowercase)
            } else if let have = installedID(trimmedRef) {
                // NOT an error, and not blocked: re-pulling is how a moving tag like
                // `:latest` gets updated. It just shouldn't look like a fresh
                // download when it isn't one.
                Label("`\(have)` is already on this machine — downloading again just checks for a newer build.",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .textCase(.lowercase)
            }
        } header: {
            Text("or bring any other model").textCase(.lowercase)
        } footer: {
            // Shorter than it was. The old footer explained the two ref formats AND
            // the whole server-side download model in one paragraph, at the top of
            // the sheet, before the reader had chosen anything — and the second half
            // is repeated verbatim by the progress section, which is where it
            // matters, once a pull is actually running.
            // Says LINK first, because that is the thing a phone user has:
            // `normalizePullRef` takes an ollama.com or hugging face page url and
            // reduces it to the ref `/api/pull` wants, so nobody has to find the
            // model's name in a code block on the page.
            // LINKS ONLY, deliberately. A bare ollama name still works — the
            // shortlist rows put one in this field, and `normalizePullRef` accepts
            // them — but naming that path made the sentence carry two grammars at
            // once ("a name like `qwen3.5`, or `hf.co/user/repo`, or a link"), and
            // the name is the half a phone user cannot produce without reading a
            // code block on the page they just left. Keep the capability, drop the
            // instruction.
            Text("open one of those, find a model, and copy the link from its page.")
        }
    }

    @ViewBuilder
    private func browseLink(_ title: String, _ subtitle: String, _ urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).foregroundStyle(Color.primary).textCase(.lowercase)
                        Text(subtitle).font(.caption)
                            .foregroundStyle(Color.secondary).textCase(.lowercase)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.footnote).foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// "pick by the memory you can spare" — the question a user can answer about
    /// their own machine, turned into a model name.
    ///
    /// The caption is RECOMMENDED VRAM, which is a property of the model at Q4 and
    /// not a guess about the user's hardware; the trailing figure is the download,
    /// which is exactly knowable. Both matter and they are different numbers: 31B
    /// fetches 20 GB and wants 32 to run comfortably.
    @ViewBuilder
    private var shortlistSection: some View {
        Section {
            ForEach(shortlist) { model in
                Button {
                    ref = model.tag
                    Haptics.play()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.tag)
                                .foregroundStyle(Color.primary)
                                .textCase(.lowercase)
                            HStack(spacing: 6) {
                                if model.isMixtureOfExperts {
                                    Text("MoE")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                                        )
                                        .foregroundStyle(Color.secondary)
                                }
                                // One metadata run, `·` separated, per the house
                                // convention (`WhereProviderPresentation.metadataRun`).
                                // Both figures are labelled: two bare numbers in the
                                // same unit, one of them a range, is what made the
                                // row ambiguous in the first place.
                                // "installed" REPLACES the download size, because
                                // for a model already on the machine the size is the
                                // one number that no longer describes anything the
                                // user is about to do.
                                Text(installedID(model.tag) == nil
                                     ? "\(model.vramLabel) · \(model.downloadLabel) download"
                                     : "\(model.vramLabel) · installed")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .textCase(.lowercase)
                            }
                        }
                        Spacer(minLength: 6)
                        // The right edge belongs to the CHECKMARK, and to nothing
                        // else. The download size sat here, which cost twice: the
                        // selected row pushed it left to make room, so the sizes
                        // stopped aligning down the column (9.6 and 20 flush right,
                        // 18 indented), and a figure in the selection slot reads as
                        // if it were the selection. Both numbers are metadata about
                        // the model, so both belong on the model's caption line.
                        if trimmedRef == model.tag {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("pick by the memory you can spare").textCase(.lowercase)
        } footer: {
            // Says what the two numbers ARE, because a row showing "18 gb" and
            // "16–24 gb vram" invites reading one as a correction of the other.
            // And names the quant: every tag here pulls Q4, which is what those
            // recommendations were measured against.
            Text("vram is what the model wants at q4 — the low end is tight, the high end comfortable. the other figure is the download.")
                .textCase(.lowercase)
        }
    }

    @ViewBuilder
    private func progressSection(_ d: OllamaDownloadCenter.Download) -> some View {
        if case .failed(let msg) = d.phase {
            let failure = OllamaDownloadCenter.classifyPullError(msg)
            Section {
                HStack {
                    Text("failed").font(.footnote).foregroundStyle(.red).textCase(.lowercase)
                    Spacer()
                    if let b = d.bytes {
                        Text(b).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                // The CLASSIFIED message, not Ollama's raw one — see `PullFailure`.
                // `msg` already ran through `friendlyPullError` on its way in, so
                // re-classifying is cheap and keeps the hint in step with it.
                Text(failure.message).font(.caption).foregroundStyle(Color.secondary)
                HStack(spacing: 20) {
                    Button { center.start(ref: d.id, baseURL: baseURL) } label: {
                        Label("retry", systemImage: "arrow.clockwise").textCase(.lowercase)
                    }
                    Button(role: .destructive) { center.dismiss(ref: d.id); startedRef = nil } label: {
                        Text("dismiss").textCase(.lowercase)
                    }
                    .tint(.red)
                }
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
            } footer: {
                // Follows the failure. Quant advice is advice only when the model
                // exists; someone who mistyped a name needs to fix the name.
                if let hint = failure.hint { Text(hint) }
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let f = d.fraction, d.phase == .active {
                        ProgressView(value: f)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(d.status).font(.footnote).foregroundStyle(.secondary).textCase(.lowercase)
                        Spacer()
                        if let b = d.bytes {
                            Text(b).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)

                Button(role: .destructive) { center.cancel(ref: d.id); startedRef = nil } label: {
                    Text("stop").textCase(.lowercase)
                }
                .tint(.red)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
            } footer: {
                Text("the pull runs on the server — close this sheet and keep using teemoon; it keeps downloading.")
            }
        }
    }

    // MARK: Pull

    /// The server's own id for a ref it already has, or nil.
    private func installedID(_ ref: String) -> String? {
        guard !installed.isEmpty else { return nil }
        return OllamaAdapter.installedMatch(ref, in: installed)
    }

    private func startPull() {
        // The mistake this screen invites: its own browse buttons open ollama.com's
        // SEARCH page and hugging face's model LISTING, so the url in the clipboard
        // is often a search, not a model. Pulling it fails with "file does not
        // exist" a few seconds later, which reads as "your model is missing" rather
        // than "that was the wrong link". Caught here, before anything starts.
        if let problem = OllamaAdapter.refProblem(ref) {
            refProblem = problem
            return
        }
        refProblem = nil
        let normalized = OllamaAdapter.normalizePullRef(ref)
        guard !normalized.isEmpty else { return }
        center.start(ref: normalized, baseURL: baseURL)
        startedRef = normalized
        // Announced at START, not just completion. `onCompleted` only fires while
        // this sheet is open, so dismissing it left the pull running with nothing
        // anywhere else in the app to show for it — no row, no progress, and the
        // model appearing only after some later probe happened to notice it.
        onStarted?(normalized)
        Haptics.play()
        // AND LEAVE. The row this pull now belongs to is on the screen underneath —
        // equipped, selected, rendering the same bar with the same cancel — so
        // staying here showed the identical download twice and left the user on a
        // sheet whose own footer told them to close it. Feedback: "this screen showing a
        // progress bar seems redundant".
        //
        // The sheet keeps its progress and failure sections for the case that still
        // needs them: reopening it with that ref in the field, where `current` finds
        // the pull the center is already running.
        dismiss()
    }
}

#Preview("Download — idle") {
    OllamaModelDownloadView(baseURL: URL(string: "http://127.0.0.1:11434/v1")!)
        .environment(OllamaDownloadCenter())
}

/// A row PICKED, which is the state the sheet exists to produce: the tag is in the
/// field, the checkmark says which row put it there, and `download` is live.
///
/// Worth its own preview because the two are one interaction split across two
/// sections — tapping a recommendation fills a field forty points below it, and
/// nothing but the checkmark says so.
#Preview("Download — recommendation picked") {
    OllamaModelDownloadView(
        baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
        initialRef: OllamaModelShortlist.recommended[1].tag   // the MoE row
    )
    .environment(OllamaDownloadCenter())
}

/// The two pull failures asked about in review, side by side.
///
/// LEFT: a name that doesn't exist. Ollama says "pull model manifest: file does not
/// exist" and used to say exactly that to the user; the card now names the problem
/// and the hint points at the name rather than at a quant suffix.
///
/// RIGHT: caught BEFORE any pull. The browse buttons on this screen open ollama.com's
/// search page, so a search url is the most likely thing in the clipboard — and it
/// would otherwise cost a round trip to the server to learn it wasn't a model.
#Preview("Download — failures", traits: .fixedLayout(width: 840, height: 900)) {
    let base = URL(string: "http://127.0.0.1:11434/v1")!
    return HStack(spacing: 0) {
        OllamaModelDownloadView(baseURL: base, initialRef: "gemma-4-turbo")
            .environment(OllamaDownloadCenter.seeded([
                .init(id: "gemma-4-turbo", baseURL: base, status: "failed",
                      fraction: nil, bytes: nil,
                      phase: .failed("pull model manifest: file does not exist"))
            ]))
        Divider()
        OllamaModelDownloadView(
            baseURL: base,
            initialRef: "https://ollama.com/search?q=gemma",
            initialProblem: OllamaAdapter.refProblem("https://ollama.com/search?q=gemma")
        )
        .environment(OllamaDownloadCenter())
    }
}

/// A machine that already has two of the three recommendations, and a pasted link for
/// the third — which it also has.
///
/// Nothing checked this before, so the sheet recommended models the server had had for
/// weeks and a re-pull looked exactly like a first download. Re-pulling is still
/// ALLOWED (that is how a moving tag like `:latest` updates), so the already-installed
/// states are stated, never blocked.
#Preview("Download — already installed", traits: .fixedLayout(width: 402, height: 900)) {
    OllamaModelDownloadView(
        baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
        installed: ["gemma4:26b", "gemma4:latest", "qwen3.5:4b"],
        initialRef: "https://ollama.com/library/gemma4"      // → gemma4:latest
    )
    .environment(OllamaDownloadCenter())
}
