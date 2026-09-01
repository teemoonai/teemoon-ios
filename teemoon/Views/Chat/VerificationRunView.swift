//
//  VerificationRunView.swift
//  teemoon
//
//  The full-screen "verification run" pushed from the attestation verdict
//  sheet. Renders `AttestationSummary.verificationRun` — near.ai's documented
//  model / gateway / tls / chat verifications (plus teemoon's provenance
//  extra) as an executed, plain-language walkthrough with per-step results,
//  a "why" for each, doc links, the freshness proof (nonce echo), the signed
//  artifacts to re-verify independently, and the honest trust boundary.
//
//  Native to the app's design language: SwiftUI type tokens, semantic colors,
//  lowercase strings, Dynamic Type, standard list/disclosure components.
//

import SwiftUI

// UN-GATED with the trust ladder. This view IS the expert rung's
// "re-check the live service yourself" script — the thing a Mac is best
// placed to run, having a terminal and a filesystem in the same place.

struct VerificationRunView: View {
    @Environment(ConfidentialSession.self) private var session
    @Environment(ProviderStore.self) private var providerStore
    @Environment(\.dismiss) private var dismiss
    @State private var glossaryTerm: GlossaryEntry?
    @State private var scriptCopied = false
    @State private var showFullScript = false
    /// Set when a verification attempt has been running too long — surfaces
    /// the retry affordance in the hero.
    @State private var timedOut = false

    /// Built live from the session each render — so a check that resolves after
    /// the screen is pushed (e.g. TLS) updates here instead of staying pending.
    private var summary: AttestationSummary {
        AttestationSummary(
            attestation: session.attestation, state: session.attestationState, timedOut: timedOut,
            provider: providerStore.activeProvider,
            lastRequestUsedE2EE: session.lastRequestUsedE2EE, lastE2EEFailReason: session.lastE2EEFailReason,
            verifiedResponseCount: session.verifiedResponseCount, mismatchedResponseCount: session.mismatchedResponseCount,
            gatewayTrustResponseCount: session.gatewayTrustResponseCount,
            attestationFetchFailed: session.attestationFetchFailed, imageProvenance: session.imageProvenance,
            dcapVerification: session.dcapVerification, nrasVerification: session.gpuAttestation,
            tlsAttestation: session.tlsAttestation,
            modelLayerVerification: session.modelLayerVerification,
            degradeIsHardFailure: session.degradeIsHardFailure,
            e2eeIntact: session.e2eeBindingIntact)
    }

    private var reportText: String {
        summary.shareText(
            e2eeMessageCount: session.e2eeMessageCount,
            verifiedResponseCount: session.verifiedResponseCount,
            mismatchedResponseCount: session.mismatchedResponseCount,
            gatewayTrustResponseCount: session.gatewayTrustResponseCount)
    }

    var body: some View {
        ScrollViewReader { proxy in
            runList(proxy)
        }
    }

    /// The run list, extracted so the ScrollViewReader wrapper stays flat.
    private func runList(_ proxy: ScrollViewProxy) -> some View {
        List {
            heroSection
            primerSection
            runSection
            trustSection
                .id("lower-sections")
            verifySection
        }
        // inert in normal runs; -DesignTourBottom captures the lower sections
        .task {
            // DesignTour is an iOS-only capture harness (it drives `simctl
            // launch` flags). Its absence is not a behaviour difference — both
            // hooks are inert in a normal run on either platform.
            #if os(iOS)
            guard DesignTour.scrollToBottom else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            proxy.scrollTo("lower-sections", anchor: .top)
            #endif
        }
        // `groupedListStyle()` and `.barLeading` already exist in
        // PlatformChrome for exactly this — .insetGrouped and .topBarLeading are
        // hard compile errors on macOS, not styles that fall back.
        .groupedListStyle()
        .navigationTitle("verification")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            // The Mac presents this in a window with its own close control.
            ToolbarItem(placement: .barLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
            #endif
            ToolbarItem(placement: .automatic) {
                // labeled, so the consequential action isn't mistaken for a
                // page reload (design review)
                Button(action: rerun) {
                    Label("re-verify", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("re-run verification")
            }
        }
        .task(id: session.attestationState) {
            timedOut = false
            guard session.attestationState == .verifying else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled && session.attestationState == .verifying { timedOut = true }
        }
        .sheet(item: $glossaryTerm) { entry in
            GlossarySheet(entry: entry)
                .presentationDetents(DeviceLayout.current == .phone ? [.medium] : [.large])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: sections

    /// Compact verdict hero. The verdict is computed from the checks below —
    /// never greener than the worst row (summary.headerSeverity) — and the
    /// shield glyph changes with severity, not just its hue.
    private var heroSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: summary.headerIcon)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(heroColor)
                Text(summary.headerTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(summary.headerSubtitle)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if summary.state == .verifying && timedOut {
                    Button(action: rerun) {
                        Text("retry")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 24).padding(.vertical, 8)
                            .foregroundStyle(teeVerified)
                            .background(teeVerifiedSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    private func rerun() {
        timedOut = false
        session.refreshAttestation(keepExisting: true)
    }

    private var heroColor: Color {
        switch summary.headerSeverity {
        case .ok:       return teeVerified
        case .advisory: return .orange
        case .failed:   return .red
        case .neutral:  return .secondary
        }
    }

    private var primerSection: some View {
        Section {
            Button {
                glossaryTerm = GlossaryEntry.primer
            } label: {
                HStack(spacing: 12) {
                    // book icon tracks the verdict tint (prototype)
                    Image(systemName: "book").foregroundStyle(heroColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("new to this? how teemoon proves your privacy").font(.callout)
                        Text("a plain-language walkthrough").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        }
    }

    private var runSection: some View {
        Section {
            ForEach(summary.verificationRun) { section in
                RunSectionRow(section: section)
            }
        } header: {
            Text("verification")
        } footer: {
            Text("runs near.ai’s published checks on your live session — automatically.")
        }
    }

    // The prototype has no separate "proof it's fresh" section: nonce
    // freshness is surfaced inside the model check's "key + freshness" proof
    // row (`report_data` binds the encryption key + nonce), so a standalone
    // section would be redundant. Removed to match Claude Design.

    private var trustSection: some View {
        Section {
            trustRow("eye", "you trust that the model reads your messages in the clear **inside** the enclave — and that no one outside it (near.ai included) can.")
            trustRow("chevron.left.forwardslash.chevron.right", "you trust that near.ai’s open-source code is benign — it’s public, so anyone can read it.")
            trustRow("cpu", "you trust Intel’s and NVIDIA’s hardware roots and their attestation services.")
        } header: {
            Text("what you still trust")
        }
    }

    /// `text` is markdown so the prototype's emphasis (e.g. **inside**) renders.
    private func trustRow(_ icon: String, _ text: String) -> some View {
        Label {
            Text(.init(text)).font(.footnote).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tertiary)
        }
    }

    /// "take the proof with you" (export) + "check us with independent code"
    /// (near.ai's verifier). The docs link that used to sit between them was
    /// redundant with the per-check "read near.ai's guide" links. The script
    /// leads with copy — the full body is disclosed on demand, never clipped.
    private var verifySection: some View {
        Section {
            if let script = summary.selfVerifyScript {
                selfVerifyWell(script)
            }
            ShareLink(item: reportText) {
                Label("export attestation report", systemImage: "square.and.arrow.up").font(.callout)
            }
            Link(destination: URL(string: "https://github.com/nearai/nearai-cloud-verifier")!) {
                Label("near.ai cloud verifier (open source)", systemImage: "chevron.left.forwardslash.chevron.right").font(.callout)
            }
        } header: {
            Text("verify it yourself")
        } footer: {
            Text("the script embeds this session’s attested values and re-fetches fresh proofs to compare — on your own machine. don’t take our word for it.")
        }
    }

    /// The self-verify code well (prototype "verify it yourself"): a header
    /// bar (terminal · quick check · copy), the one-line command, and a
    /// "show full script" disclosure that reveals the whole heredoc in a
    /// horizontally-scrolling monospaced block — the copy button always
    /// copies the FULL pasteable script.
    @ViewBuilder private func selfVerifyWell(_ script: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal").font(.caption2)
                Text("quick check").font(.caption)
                Spacer(minLength: 8)
                Button {
                    Clipboard.copy(script)
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { scriptCopied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        await MainActor.run { withAnimation { scriptCopied = false } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(scriptCopied ? "copied" : "copy")
                        Image(systemName: scriptCopied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(scriptCopied ? teeVerified : Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            HStack {
                Text("python3 teemoon_verify.py")
                    .font(.system(.footnote, design: .monospaced)).fontDesign(.monospaced)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            Divider()
            DisclosureGroup(isExpanded: $showFullScript) {
                ScrollView(.horizontal) {
                    Text(script)
                        .font(.system(.caption2, design: .monospaced)).fontDesign(.monospaced)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.topLeading)
            } label: {
                Text(showFullScript ? "hide full script" : "show full script")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 6)
        }
        .background(PlatformTone.groupedBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PlatformTone.separator.opacity(0.5), lineWidth: 0.5))
        .padding(.vertical, 4)
    }
}

// MARK: - Section row

private struct RunSectionRow: View {
    let section: VerificationSection
    // collapsed by default; -DesignTourExpandAll opens every section so the
    // per-step rows are capturable headlessly
    #if os(iOS)
    @State private var isExpanded = DesignTour.expandAll
    #else
    @State private var isExpanded = false
    #endif

    /// The reason an advisory/failed check needs attention — the detail of
    /// its first flagged/failed step. Drives the colored banner (prototype).
    private var reason: String? {
        guard section.result == .flagged || section.result == .failed else { return nil }
        return section.steps.first { $0.status == .flag || $0.status == .fail }?.detail
    }

    private var resultColor: Color {
        switch section.result {
        case .passed:  return teeVerified
        case .flagged: return .orange
        case .failed:  return .red
        case .running, .notRun: return .secondary
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let reason {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: section.result.chipIcon).font(.footnote)
                    proofText(reason).font(.footnote).fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(resultColor)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(resultColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .padding(.vertical, 4)
            }
            ForEach(section.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(step.status).frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        if let url = step.url, let destination = URL(string: url) {
                            // the step itself navigates to the code that's running
                            Link(destination: destination) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text(step.label).font(.callout)
                                        Image(systemName: "arrow.up.right").font(.caption2)
                                    }
                                    proofText(step.detail).font(.footnote)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            Text(step.label).font(.callout)
                                .foregroundStyle(step.status == .pending ? .secondary : .primary)
                            proofText(step.detail).font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !step.links.isEmpty {
                            HStack(spacing: 12) {
                                ForEach(step.links) { link in
                                    if let destination = URL(string: link.url) {
                                        Link(destination: destination) {
                                            HStack(spacing: 2) {
                                                Text(link.title)
                                                Image(systemName: "arrow.up.right")
                                            }
                                            .font(.caption2)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Link(destination: URL(string: section.docURL)!) {
                Label("read near.ai’s guide", systemImage: "arrow.up.right.square").font(.caption)
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // title stays on one line; the "added by teemoon" tag sits
                    // beneath it, never orphaned in the wrap gap
                    Text(section.command).font(.callout).fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    ResultChip(result: section.result)
                }
                if section.isExtra {
                    Text("· added by teemoon").font(.caption).foregroundStyle(.tertiary)
                }
                Text(section.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func stepIcon(_ status: RunStepStatus) -> some View {
        switch status {
        case .pass:    Image(systemName: "checkmark.circle.fill").foregroundStyle(teeVerified)
        case .flag:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .running: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

private struct ResultChip: View {
    let result: SectionResult
    private var color: Color {
        switch result {
        case .passed:  return teeVerified
        case .flagged: return .orange
        case .failed:  return .red
        case .running, .notRun: return .secondary
        }
    }
    var body: some View {
        // glyph + word, never color alone (colorblind safety)
        HStack(spacing: 4) {
            Image(systemName: result.chipIcon).font(.caption2)
            Text(result.chipLabel).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// Renders a proof sentence whose backtick-marked spans are literal attested
/// tokens: the sentence wraps as plain footnote text, and only the tokens are
/// monospaced — so the attested value is what the eye lands on, and long
/// lines never clip silently.
func proofText(_ detail: String, tokenFont: Font = .footnote.monospaced()) -> Text {
    var result = Text(verbatim: "")
    for (i, segment) in detail.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
        let piece = Text(verbatim: String(segment))
        // odd segments are inside backticks → literal tokens
        result = result + (i.isMultiple(of: 2)
            ? piece.foregroundStyle(Color.secondary)
            : piece.font(tokenFont).foregroundStyle(Color.primary))
    }
    return result
}

// MARK: - Glossary

struct GlossaryEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let definition: String
    let url: String

    /// Chunked into three short beats with bolded key phrases — this sheet is
    /// aimed at the most anxious, least expert reader (design review: one
    /// dense wall of text at exactly their moment of anxiety).
    static let primer = GlossaryEntry(
        id: "primer", title: "how teemoon proves your privacy",
        definition: "your messages are processed inside a **sealed region of the chip** (a TEE) that even the machine’s operator can’t read into.\n\nbefore each conversation, teemoon checks **Intel- and NVIDIA-signed proofs** that the hardware is genuine, that it booted near.ai’s published open-source code, and that your connection is encrypted all the way into that sealed hardware.\n\nit runs the same checks near.ai documents — automatically, on your live data — and **shows you the signed values** so you can re-verify everything yourself.",
        url: "https://docs.near.ai/cloud/verification/")
}

struct GlossarySheet: View {
    let entry: GlossaryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // paragraphs render as separate beats; **…** spans bold
                    ForEach(entry.definition.components(separatedBy: "\n\n"), id: \.self) { beat in
                        Text(.init(beat)).font(.callout).foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: entry.url)!) {
                        Label("learn more", systemImage: "arrow.up.right").font(.callout)
                    }
                }
                .padding(16)
            }
            .navigationTitle(entry.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            #endif
        }
    }
}

// MARK: - Previews

/// A store with near.ai active, so provider-dependent rows (the self-verify
/// script) render in Canvas. Internal so screenshot previews can reuse it.
@MainActor func previewStore() -> ProviderStore {
    let store = ProviderStore(inMemory: true)
    let provider = Provider.nearAI
    store.addProvider(provider)
    store.currentProviderID = provider.id.uuidString
    return store
}

/// A session pre-populated with passing verification results, so the run
/// renders offline in Canvas (previews skip the live attestation pipeline).
/// Internal so screenshot previews can reuse it.
@MainActor func previewSession(store: ProviderStore, tls: TLSAttestation = .verified, allPass: Bool = true) -> ConfidentialSession {
    let session = ConfidentialSession(providers: store)
    // AttestationRecord.preview is stamped model "zai-org/GLM-5.1-FP8". The
    // session's read gate returns nil when `record.model != activeProvider.model`,
    // which makes the ladder sit on "verifying…" forever if the near.ai preset
    // still defaults to glm-5.2. Pin the provider FIRST.
    if var p = store.providers.first(where: { $0.id == Provider.nearAI.id }) {
        p.model = "zai-org/GLM-5.1-FP8"
        store.updateProvider(p)
    }
    // Plant fixtures; freeze before any path that would re-fetch and clobber
    // the GLM-5.1 AWQ/FP8 quant-drift artifact with live production YAML.
    session.freezeAttestationFixtures = true
    session.attestation = .preview
    var dcap = RecordDCAPVerification()
    dcap.gateway = .verified(tcbStatus: allPass ? .upToDate : .outOfDate, mrConfigIdHex: "01", reportDataHex: "")
    dcap.model = .verified(tcbStatus: .upToDate, mrConfigIdHex: "01", reportDataHex: "")
    session.dcapVerification = dcap
    session.gpuAttestation = .verified
    session.tlsAttestation = tls
    let cloudAPI = ProvenanceService.ImageRef(
        image: "nearaidev/cloud-api", digest: String(repeating: "a", count: 64),
        sourceRepo: "https://github.com/nearai/private-ml-sdk",
        sourceRef: "refs/tags/v0.5.1",
        sourceCommit: "84367f0253fa94aa6816d64210e5812215ee2622",
        hosts: ["gateway"])
    let mesh = ProvenanceService.ImageRef(
        image: "nearaidev/dstack-vpc", digest: String(repeating: "c", count: 64),
        sourceRepo: "https://github.com/nearai/dstack-vpc",
        sourceRef: "refs/heads/main",
        sourceCommit: "1234abc9253fa94aa6816d64210e5812215ee262",
        hosts: ["gateway", "model"])
    let sidecar = ProvenanceService.ImageRef(
        image: "datadog/agent", digest: String(repeating: "b", count: 64))
    let proxy = ProvenanceService.ImageRef(
        image: "nearaidev/vllm-proxy-rs", digest: String(repeating: "d", count: 64),
        sourceRepo: "https://github.com/nearai/inference-proxy",
        sourceRef: "refs/tags/v0.3.2",
        sourceCommit: "b183677a253fa94aa6816d64210e5812215ee262",
        hosts: ["model"])
    // Capability-tier examples (tiers 2 & 3): the deployer (pid:host in the
    // outer harness compose → process-access) and the telemetry collector
    // (container-log mount → log-access). Both model-enclave only.
    let composeManager = ProvenanceService.ImageRef(
        image: "nearaidev/compose-manager", digest: String(repeating: "e", count: 64),
        sourceRepo: "https://github.com/nearai/compose-manager",
        sourceRef: "refs/heads/master",
        sourceCommit: "3d64349a6c71a0711f9dd4f9d2897eefa4a0d8bc",
        hosts: ["model"])
    let otel = ProvenanceService.ImageRef(
        image: "otel/opentelemetry-collector-contrib", digest: String(repeating: "f", count: 64))
    session.imageProvenance = .allVerified(verified: [cloudAPI, mesh, proxy, composeManager], thirdParty: [sidecar, otel])
    session.modelLayerVerification = .verified
    // The hash-verified INNER model-layer compose (production shape): the
    // OHTTP-terminating proxy + the sglang engine, launched with the real
    // GLM-5.1 flags from the audited YAML. This is the document
    // PlaintextExposure and the measured-config panel read; the record's
    // outer manifest is harness-only, matching production.
    session.modelLayerManifest = """
    services:
      proxy:
        image: nearaidev/vllm-proxy-rs@sha256:\(String(repeating: "d", count: 64))
        environment:
          - OHTTP_ENABLED=true
          - TLS_CERT_PATH=/certs/completions.near.ai
      model-sg-glm51-awq-tp4-r1:
        image: glm51-sgl-awq-tp4-patched:local
        command: >
          sglang serve --model-path QuantTrio/GLM-5.1-AWQ
          --revision 8f60817aa28023f2607850d1a1e51d21aa34817a
          --served-model-name zai-org/GLM-5.1-FP8 --tp 4
          --log-requests-level 0 --enable-cache-report --enable-metrics
          --trust-remote-code
      nginx:
        image: nginx:1.25
    networks:
      default:
    """
    // Pinned artifact with a served-alias mismatch: served as FP8, actually AWQ.
    // This is the "they quantize without saying so" disclosure on the ladder
    // ("it's more compressed than the name says" / expert drift note).
    session.modelArtifact = ModelArtifact(
        modelPath: "QuantTrio/GLM-5.1-AWQ",
        revision: "8f60817aa28023f2607850d1a1e51d21aa34817a",
        servedName: "zai-org/GLM-5.1-FP8",
        quant: "AWQ")
    session.verifiedResponseCount = 3
    return session
}

#Preview("run — verified") {
    let store = previewStore()
    return NavigationStack {
        VerificationRunView()
            .environment(previewSession(store: store))
            .environment(store)
    }
}

#Preview("run — verifying") {
    let store = previewStore()
    let session = ConfidentialSession(providers: store)
    return NavigationStack {
        VerificationRunView()
            .environment(session)
            .environment(store)
    }
}

#Preview("run — tls not performed") {
    let store = previewStore()
    return NavigationStack {
        VerificationRunView()
            .environment(previewSession(store: store, tls: .notPerformed, allPass: false))
            .environment(store)
    }
}


