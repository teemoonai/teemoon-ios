//
//  TrustLadderView+Hero.swift
//  teemoon
//

import SwiftUI

extension TrustLadderView {
    // MARK: hero

    var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: summary.headerIcon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(heroColor)
            Text(heroTitle)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(heroSubtitle)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !metaLine.isEmpty {
                    Text(metaLine).font(.caption).foregroundStyle(.secondary)
                }
                Button(action: rerun) {
                    Label("re-verify", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var heroColor: Color {
        // A published LEAKS review demotes a green hero to advisory: the
        // cryptographic seal still passes (so never red — red is positive
        // evidence of an integrity break), but "only it can read this" cannot
        // render green over a review that found the operator's logs get a
        // copy. Audit `incomplete` deliberately does NOT touch the hero:
        // absence of review is not evidence against the seal, and the gray
        // chain node already carries it.
        if summary.headerSeverity == .ok, modelNodeAuditState == .leaks { return .orange }
        switch summary.headerSeverity {
        case .ok:       return teeVerified
        case .advisory: return .orange
        case .failed:   return .red
        case .neutral:  return .secondary
        }
    }

    var heroTitle: String { verdict.heroTitle }
    var heroSubtitle: String { verdict.heroSubtitle }

    var metaLine: String {
        guard session.attestationState != .verifying else { return "" }
        // Under "sending paused" a "verified just now" stamp contradicts the
        // verdict — the record was fetched, but verification did not pass.
        var parts = [isPaused ? "could not verify" : summary.timestampText]
        if let nonce = session.attestation?.modelNonce ?? session.attestation?.gatewayNonce, nonce.count >= 8 {
            parts.append("nonce \(nonce.prefix(4))…\(nonce.suffix(4))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func rerun() {
        timedOut = false
        session.refreshAttestation(keepExisting: true)
    }


    // MARK: chain

    func chainSection(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("how your words reach \(modelName) and come back — with no one else able to read them")
                .font(.subheadline).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            ChainRailView(nodes: chainNodes, rung: rung, onJump: { node in
                guard let target = node.jumpTarget ?? node.jumpTitle else { return }
                if rung == .everyday && node.jumpAtEveryday {
                    // Up the ladder, not out: flip to expert first, then scroll
                    // once the target section exists in the tree.
                    rung = .expert
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                    }
                } else {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
            })
        }
    }

    /// The plaintext→model chain. Two curated shapes disclosed by rung — the
    /// dispatcher picks. A broken link dims everything downstream in either.
    var chainNodes: [ChainNode] {
        rung == .everyday ? everydayChain : expertChain
    }

    /// Everyday: five nodes a non-technical reader absorbs in one pass.
    /// Authored by `TrustVerdict`; this only maps onto `ChainNode`.
    var everydayChain: [ChainNode] {
        var nodes = verdict.everydayClaims.map { claim -> ChainNode in
            ChainNode(
                id: claim.id,
                status: chainStatus(claim.status),
                title: claim.title,
                detail: claim.detail,
                jumpTitle: claim.jumpTitle,
                jumpTarget: claim.jumpTarget,
                jumpAtEveryday: claim.jumpAtEveryday
            )
        }
        dimDownstream(&nodes)
        return nodes
    }

    func chainStatus(_ status: TrustClaim.Status) -> ChainNode.Status {
        switch status {
        case .origin:  return .origin
        case .ok:      return .ok
        case .alert:   return .alert
        case .info:    return .info
        case .fail:    return .fail
        case .pending: return .pending
        }
    }

    /// The everyday audit node — one plain-language claim about what the
    /// reviewed code does with the UNLOCKED message, closing the gap the chain
    /// otherwise has: "sealed" covers the message in transit and says nothing
    /// about what happens after the model's side opens it.
    ///
    /// Derived from `verdictClass` ALONE (worst class wins): the reviewer
    /// already weighed deployed-ON findings into each page's class, so the
    /// client never re-judges findings at this rung. Same verdict as expert —
    /// only the reading level drops.
    /// Worst-verdict rollup for the model node — shared by the everyday audit
    /// node and the hero (a LEAKS review demotes a green hero to advisory).
    /// nil = no basis to speak: no attestation, no primary group, or no rows
    /// whose code reads the unlocked message.
    var modelNodeAuditState: EverydayAuditState? {
        guard session.attestation != nil,
              let group = enclaveGroups.first(where: { $0.primary }) else { return nil }
        // The rows whose code can read the unlocked message: the plaintext
        // touchers, the in-enclave engine, and the guest OS beneath them all.
        let relevant = group.images.filter {
            $0.plaintextRole != nil || $0.kind == .local || $0.kind == .guestOS
        }
        guard !relevant.isEmpty else { return nil }
        var urls = relevant.compactMap(\.auditURL)
        if let u = group.configAuditURL { urls.append(u) }
        if let u = group.recipe?.auditURL { urls.append(u) }
        let classes = urls.compactMap { AuditIndex.shared.verdictClass(for: $0) }
        let covered = relevant.allSatisfy { $0.auditURL != nil }
        return everydayAuditState(classes: classes, allTouchersCovered: covered)
    }

    /// Expert: the full technical spine, built from live session data. Only
    /// nodes that bind to a real check are included; once a node fails,
    /// everything below is dimmed (the chain visibly stops where proof stops).
    var expertChain: [ChainNode] {
        let att = session.attestation
        let verifying = session.attestationState == .verifying
        var nodes: [ChainNode] = []

        nodes.append(ChainNode(id: "msg", status: .origin,
            title: "your message", detail: "plaintext, on your device",
            everydayTitle: "your message",
            everydayDetail: "readable only here."))

        // Encryption target — the model's Ed25519 public key.
        if let key = att?.modelEd25519PubKey {
            nodes.append(ChainNode(id: "target", status: .ok,
                title: "encryption target · Ed25519 public key",
                detail: "your device seals this chat to \(modelName)'s public key before it ever leaves \(DeviceNoun.boundary).",
                value: "ed25519:\(key.hexString.prefix(12))…",
                copyValue: key.hexString,
                everydayTitle: "\(DeviceNoun.subject) locks this chat to \(modelName)",
                everydayDetail: "before anything leaves your device, it's sealed so only \(modelName) can open it."))
        } else {
            nodes.append(ChainNode(id: "target", status: verifying ? .pending : .fail,
                title: "encryption target · Ed25519 public key",
                detail: verifying ? "fetching the model's public key…"
                                  : "no Ed25519 key — the model's public key is unavailable, so this chat can't be sealed to it.",
                everydayTitle: verifying ? "locking this chat…" : "couldn't lock this chat",
                everydayDetail: verifying ? "getting \(modelName)'s key…"
                                          : "\(modelName)'s key wasn't available, so nothing was sealed to it."))
        }

        // Key binding — the load-bearing proof: that key sits in the model
        // quote's report_data.
        switch summary.e2eeKeyBound {
        case .some(true):
            nodes.append(ChainNode(id: "bound", status: .ok,
                title: "key bound in the model's TDX quote",
                detail: "that public key sits in `report_data` of \(modelName)'s hardware quote — the private half never leaves the enclave. no one else (gateway, operator, near.ai) can decrypt.",
                everydayTitle: "only \(modelName) holds the key",
                everydayDetail: "the key to open your chat lives inside \(modelName)'s sealed chip and never leaves it — not near.ai, not the network, nobody else can read your message."))
        case .some(false):
            nodes.append(ChainNode(id: "bound", status: .fail,
                title: "key binding · could not be established",
                detail: "the encryption key was NOT found in \(modelName)'s `report_data` — end-to-end encryption isn't established.",
                everydayTitle: "couldn't lock this chat",
                everydayDetail: "\(DeviceNoun.subject) couldn't confirm \(modelName) holds the key — so nothing has been sent."))
        case .none:
            nodes.append(ChainNode(id: "bound", status: .pending,
                title: "key bound in the model's TDX quote",
                detail: "checking the model quote…",
                everydayTitle: "checking the lock…",
                everydayDetail: "confirming \(modelName) holds the key…"))
        }

        // Model-layer YAML pins the exact weights. The quant is read from the
        // pinned model path, never the served alias — and when the alias
        // disagrees, the drift is surfaced (amber, informational — not a break).
        if let art = session.modelArtifact {
            let rev = art.revision.map { " @ \($0.prefix(7))" } ?? ""
            nodes.append(ChainNode(id: "yaml", status: .ok,
                title: "model-layer YAML pins the image",
                detail: "the inner compose pins the weights to an immutable revision — the quant tag (\(art.quant ?? "unspecified")) is read from the model path, never the served alias.",
                value: "\(art.modelPath)\(rev)",
                copyValue: art.revision.map { "\(art.modelPath)@\($0)" } ?? art.modelPath,
                everydayTitle: "it's the pinned, published \(modelName) build",
                everydayDetail: "the version is pinned to an immutable release and checked — a swap would show up as a provenance mismatch."))
            if let note = art.driftNote {
                nodes.append(ChainNode(id: "drift", status: .info,
                    title: "the served name differs from the pinned build",
                    detail: note,
                    everydayTitle: "it's more compressed than the name says",
                    everydayDetail: "answers may be slightly lower quality than the full-size model — your privacy isn't affected."))
            }
        }

        // Running images trace to public source (provenance rollup — the
        // per-image detail lives in the known-code section, coming next pass).
        switch summary.provenanceState {
        case .some(.done):
            nodes.append(ChainNode(id: "source", status: .ok,
                title: "the running code traces to public source",
                detail: summary.provenanceEvidence ?? "every near.ai image running the model verified against its published build.",
                jumpTitle: "known code",
                everydayTitle: "the code is public and checked",
                everydayDetail: "every piece of software running the model is open source, and teemoon checked it matches."))
        case .some(.stuck):
            nodes.append(ChainNode(id: "source", status: .fail,
                title: "image provenance · unverified",
                detail: summary.provenanceDetail,
                everydayTitle: "couldn't confirm the code",
                everydayDetail: "teemoon couldn't confirm the running software matches the published code."))
        case .some, .none:
            // Async check still in flight — PENDING, never a default green
            // (same temporal-honesty rule as the everyday identity node).
            nodes.append(ChainNode(id: "source", status: .pending,
                title: "checking the running code against public source",
                detail: "checking Sigstore / public attestations…",
                everydayTitle: "checking the code against its published source",
                everydayDetail: "checking the software against its published source…"))
        }

        // NB: no standalone "only <model> can decrypt" node here (matches Claude
        // Design). Confidentiality is stated once at its evidence — the
        // key-binding node above ("no one else … can decrypt") — and named
        // per-row in the known-code section (the "sees your message" capsules +
        // group caption). A separate chain node repeated the same claim without
        // new evidence, so it's intentionally absent. The "known code ↓" jump is
        // preserved on the `source` node above.

        // The return trip — every reply comes back signed. Chain terminus,
        // carrying the enclave signing address you can recover any reply against.
        if let addr = att?.signingAddress {
            switch summary.responseSigState {
            case .some(.stuck):
                nodes.append(ChainNode(id: "signed", status: .fail,
                    title: "a reply's signature didn't match",
                    detail: summary.responseSigDetail,
                    value: "\(addr.prefix(6))…\(addr.suffix(4))",
                    copyValue: addr))
            default:
                nodes.append(ChainNode(id: "signed", status: verifying ? .pending : .ok,
                    title: verifying ? "checking each reply's signature" : "every reply comes back signed",
                    detail: verifying ? "recovering each reply to the enclave signing key…"
                                      : "each reply is signed by a key that never leaves the enclave — recover any message to check it yourself.",
                    value: "\(addr.prefix(6))…\(addr.suffix(4))",
                    copyValue: addr))
            }
        } else if verifying {
            nodes.append(ChainNode(id: "signed", status: .pending,
                title: "checking each reply's signature",
                detail: "recovering each reply to the enclave signing key…"))
        }

        dimDownstream(&nodes)
        return nodes
    }

    /// Dim every node downstream of the first broken link — the chain visibly
    /// stops where the proof stops.
    func dimDownstream(_ nodes: inout [ChainNode]) {
        if let breakIdx = nodes.firstIndex(where: { $0.status == .fail }) {
            for i in nodes.indices where i > breakIdx { nodes[i].dimmed = true }
        }
    }


}
