//
//  TrustLadderView+Sections.swift
//  teemoon
//

import SwiftUI

extension TrustLadderView {
    // MARK: known code

    /// Freshness of the audit index. Stale after a day; nil when there is no index.
    /// See AuditIndexStampTests.
    var auditIndexStamp: (text: String, stale: Bool)? {
        AuditIndexStamp.make(
            hasIndex: AuditIndex.shared.index != nil,
            updated: AuditIndex.shared.index?.updated,
            loadedAt: AuditIndex.shared.loadedAt,
            now: Date()
        )
    }

    var grouping: EnclaveGrouping {
        EnclaveGrouping(
            attestation: session.attestation,
            imageProvenance: session.imageProvenance,
            modelLayerManifest: session.modelLayerManifest,
            modelLayerVerification: session.modelLayerVerification
        )
    }


    /// The running images, grouped by the enclave whose quote measures them.
    /// "Is all the running code the published code" is a *per-quote* claim —
    /// each enclave's mr_config commits only to its own compose — so the two
    /// enclaves are shown as separate groups, each with its own binding.
    @ViewBuilder var knownCodeSection: some View {
        // Everyday omits the per-image code list entirely — the "the code is
        // public and checked" chain node already carries that reassurance in
        // plain language, so the full list would just be duplicate machinery.
        if rung != .everyday {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("known code").font(.subheadline).fontWeight(.semibold)
                    Text("running \(modelName)'s pinned, published build — its operator can't swap in a version that logs your chats.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(enclaveGroups) { group in
                    EnclaveGroupView(group: group, rung: rung)
                }
                if enclaveGroups.isEmpty {
                    Text(session.attestationState == .verifying
                         ? "resolving image provenance…"
                         : "no verified image set available.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // Freshness of the audit index behind every verdict above. The
                // 1h TTL + persisted snapshot otherwise let a user render
                // verdicts from an arbitrarily old cache with no indication.
                if let stamp = auditIndexStamp {
                    Text(stamp.text)
                        .font(.caption2)
                        .foregroundStyle(stamp.stale ? AnyShapeStyle(Color.orange)
                                                     : AnyShapeStyle(.tertiary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id("known code")
        }
    }

    /// Model enclave first, then gateway. See EnclaveGroupingTests.
    var enclaveGroups: [EnclaveGroup] { grouping.groups() }


    var providerDisplayName: String {
        providerStore.activeProvider?.name ?? "the provider"
    }


    // MARK: hardware / transport / signatures

    /// The root the whole chain sits on: genuine silicon, vouched for by Intel
    /// and NVIDIA — not by the provider. Full card at expert; one-line
    /// reassurance at everyday.
    @ViewBuilder var hardwareSection: some View {
        // Expert-only. Everyday drops the standalone hardware statement: the
        // hero already says "sealed hardware", and the "what you still trust"
        // line names the Intel/NVIDIA root of trust — a separate "runs on real
        // chips" reassurance was redundant and read as if genuineness were
        // unverified (it isn't).
        if rung == .expert, session.attestation != nil, summary.dcapState != nil || summary.showGPURow {
            EvidenceCard(
                title: "genuine hardware",
                subtitle: "real, tamper-resistant chips — vouched for by Intel and NVIDIA themselves, not by \(providerDisplayName).") {
                if summary.dcapState != nil {
                    EvidenceRow(label: "intel tdx quote", state: summary.dcapState, detail: summary.dcapDetail)
                }
                if summary.showGPURow {
                    EvidenceRow(label: (session.attestation?.gpuModelName ?? "nvidia gpu").lowercased(),
                                state: summary.nrasState ?? .pending, detail: summary.gpuTdxDetail)
                }
                // The guest OS moved OUT of this card: it's reviewable measured
                // software, not silicon, so it now rides as the first row of the
                // model enclave (see `guestOSEntry`), showing the MODEL node's
                // os_image_hash rather than the gateway's.
            }
            .id("hardware")
        }
    }

    /// Sealed transport — TLS terminates inside the enclave, its cert
    /// fingerprint bound into the quote. Complementary to E2EE (transport +
    /// metadata half). Hidden when there's no direct host (`.notPerformed`).
    @ViewBuilder var transportSection: some View {
        if rung == .expert, let tls = session.tlsAttestation {
            switch tls {
            case .verified:
                EvidenceCard(
                    title: "sealed transport",
                    subtitle: "the transport-layer half — complementary to E2EE, independently verifiable.") {
                    EvidenceRow(label: "tls into the enclave", state: .done,
                                detail: "the connection terminates inside the enclave — the tls cert fingerprint is bound into the attestation `report_data`.")
                }
            case .failed(let why):
                EvidenceCard(
                    title: "sealed transport",
                    subtitle: "the transport-layer half — complementary to E2EE, independently verifiable.") {
                    EvidenceRow(label: "tls into the enclave", state: .stuck, detail: why)
                }
            case .inconclusive(let why):
                EvidenceCard(
                    title: "sealed transport",
                    subtitle: "the transport-layer half — complementary to E2EE, independently verifiable.") {
                    EvidenceRow(label: "tls into the enclave", state: .stuck, detail: "\(why) — could not complete")
                }
            case .notPerformed:
                EmptyView()   // no direct host — not applicable
            }
        }
    }

    /// Disclosed limits — what this build does NOT do, named rather than hidden:
    /// the honest counterweight to the chain. (Response signatures are now folded
    /// into the chain's terminus node, so they're no longer a separate card.)
    /// Expert-only.
    @ViewBuilder var disclosedLimitsSection: some View {
        if rung == .expert {
            EvidenceCard(
                title: "disclosed limits",
                subtitle: "what this build does not do — named, not hidden.") {
                limitRow("gateway domain — standard WebPKI only",
                         "the completions.near.ai domain is not certificate-pinned; a mis-issued public cert would be accepted.")
                limitRow("no oblivious-HTTP relay",
                         "requests are not routed through a third-party OHTTP relay, so \(providerDisplayName)'s gateway can correlate requests to your source address.")
                limitRow("metadata visible",
                         "\(providerDisplayName) still sees that you chat, when, and how much — just not what you say.")
                // Derived live from the hash-verified inner compose's networks
                // section: the *absence* of confinement is shown only when the
                // document is present to establish it. If near.ai ever adds an
                // internal-only network / egress allowlist to the measured
                // compose, this row disappears (and should become a check).
                if let inner = session.modelLayerManifest,
                   MeasuredConfig.lacksEgressConfinement(composeYAML: inner) {
                    limitRow("no network egress restriction",
                             "nothing at the network layer prevents these containers from connecting out — the attested compose declares no internal-only network and no egress allowlist. confinement rests on their audited code behavior.")
                }
            }
        }
    }


    // MARK: residual trust + re-verify

    /// The honest boundary — what verification can't remove. Shown at every
    /// rung; this is the one place the word "trust" is correct.
    @ViewBuilder var residualTrustSection: some View {
        if rung == .everyday {
            // One plain sentence — the boundary is never dropped (that's the
            // anti-overpromise guardrail), but the three technical items fold
            // into a single idea for a lay reader. Full breakdown at expert.
            EvidenceCard(
                title: "what you still trust",
                subtitle: "the one part no proof can remove.") {
                // Not "that the chips are genuine" — attestation already proves
                // that (the quotes chain to Intel's and NVIDIA's own CAs). What
                // no proof removes is trusting Intel and NVIDIA *themselves*:
                // that their sealed hardware really protects the way they claim.
                trustRow("shield.lefthalf.filled", "you're still trusting that the published open-source code is honest, and that Intel's and NVIDIA's sealed chips really protect your data the way they promise.")
            }
        } else {
            EvidenceCard(
                title: "what you still trust",
                subtitle: "verification shrinks what you trust — it can't take it to zero. this is the part no proof removes.") {
                trustRow("eye", "the model reads your messages in the clear **inside** the enclave — and no one outside it (\(providerDisplayName) included) can.")
                trustRow("chevron.left.forwardslash.chevron.right", "\(providerDisplayName)'s open-source code is benign — it's public, so anyone can audit it.")
                trustRow("cpu", "Intel's and NVIDIA's hardware roots and their attestation services.")
            }
        }
    }

    func trustRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.footnote).foregroundStyle(.tertiary).frame(width: 18)
            Text(.init(text)).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Re-run the published checks yourself: the generated self-verify script
    /// (embedding this session's attested values), a portable report, and the
    /// provider's own open-source verifier. Expert-only — everyday stays calm
    /// reassurance, and the "show me the proof as… expert" control is the path
    /// here, so verifiability is offered, not hidden.
    @ViewBuilder var reverifySection: some View {
        if rung == .expert {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("re-check the live service yourself").font(.subheadline).fontWeight(.semibold)
                Text("copy this into your terminal to re-verify on your own machine, with your own fresh nonces.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let script = summary.selfVerifyScript { SelfVerifyScriptCard(script: script) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("reverify")
        }
    }

}
