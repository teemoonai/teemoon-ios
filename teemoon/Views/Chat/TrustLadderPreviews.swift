//
//  TrustLadderPreviews.swift
//  teemoon
//

import SwiftUI

// MARK: - Previews

#Preview("ladder · verified") {
    let store = previewStore()
    return NavigationStack {
        TrustLadderView()
            .environment(previewSession(store: store))
            .environment(store)
    }
}

/// On device — the state that was rendering the cloud not-attestable copy and
/// telling the user "standard HTTPS protects your messages on the way to Gemma 4
/// E2B" about messages that are never sent, then offering to move them to a
/// cloud model for safety.
///
/// No seeded attestation: a local provider has no `.attestation` capability, so
/// `attestationState` is `.none` on its own — which is exactly how production
/// reaches this branch.
@MainActor private func onDevicePreviewStore() -> ProviderStore {
    let store = ProviderStore(inMemory: true)
    let phone = Provider.local(LocalModelCatalog.all[0])
    store.addProvider(phone)
    store.currentProviderID = phone.id.uuidString
    return store
}

#Preview("ladder · on device") {
    let store = onDevicePreviewStore()
    return NavigationStack {
        TrustLadderView()
            .environment(ConfidentialSession(providers: store))
            .environment(store)
    }
    .preferredColorScheme(.dark)
}

/// No expert variant, because there is no rung picker on this state — same as
/// self-hosted. Passing `initialRung: .expert` would render identically.

#Preview("ladder · not attestable") {
    let store = previewStore()
    let session = previewSession(store: store)
    session.noConfidentialEndpoint = true
    return NavigationStack {
        TrustLadderView()
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · not attestable · expert") {
    let store = previewStore()
    let session = previewSession(store: store)
    session.noConfidentialEndpoint = true
    return NavigationStack {
        TrustLadderView(initialRung: .expert)
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · expert") {
    let store = previewStore()
    return NavigationStack {
        TrustLadderView(initialRung: .expert)
            .environment(previewSession(store: store))
            .environment(store)
    }
}

// Component preview of the disclosed-limits card with the live-derived egress
// row (renders the same limitRow/EvidenceCard the screen composes; mid-page
// sections aren't snapshot-reachable in the full-page previews).
#Preview("disclosed limits · egress") {
    let inner = "services:\n  proxy:\n    image: p\nnetworks:\n  default:\n"
    return ScrollView {
        EvidenceCard(
            title: "disclosed limits",
            subtitle: "what this build does not do — named, not hidden.") {
            limitRow("gateway domain — standard WebPKI only",
                     "the completions.near.ai domain is not certificate-pinned; a mis-issued public cert would be accepted.")
            limitRow("no oblivious-HTTP relay",
                     "requests are not routed through a third-party OHTTP relay, so near.ai's gateway can correlate requests to your source address.")
            limitRow("metadata visible",
                     "near.ai still sees that you chat, when, and how much — just not what you say.")
            if MeasuredConfig.lacksEgressConfinement(composeYAML: inner) {
                limitRow("no network egress restriction",
                         "nothing at the network layer prevents these containers from connecting out — the attested compose declares no internal-only network and no egress allowlist. confinement rests on their audited code behavior.")
            }
        }
        .padding()
    }
}

#Preview("ladder · expert · empty touchers") {
    // The one invariant state: no inner manifest and a harness-only outer
    // compose → empty toucher set. The known-code caption must read
    // "couldn't determine which images see your message" — never as safe.
    let store = previewStore()
    let session = previewSession(store: store)
    session.modelLayerManifest = nil
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "known code")
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · expert re-verify") {
    let store = previewStore()
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "reverify")
            .environment(previewSession(store: store))
            .environment(store)
    }
    // Simulates ContentView's app-wide `.fontDesign` override so this preview
    // faithfully mirrors the device — and guards that the code block's Menlo
    // font resists the override (regression: the self-verify block once rendered
    // in the user's global font instead of monospaced).
    .fontDesign(.rounded)
}

// Component previews for the known-code group card — the full-page previews
// snapshot the top/bottom of the ladder, so the card's states are rendered
// directly here (role capsules + measured-config panels, and the empty set).
#Preview("known code · toucher panels") {
    let inner = """
    services:
      proxy:
        image: nearaidev/vllm-proxy-rs@sha256:b183677aaabbccddeeff00112233445566778899aabbccddeeff001122334455
        environment:
          - OHTTP_ENABLED=true
          - TLS_CERT_PATH=/certs/completions.near.ai
      model-sg-glm51-awq-tp4:
        image: glm51-sgl-awq-tp4-patched:local
        command: >
          sglang serve --model-path QuantTrio/GLM-5.1-AWQ
          --revision 8f60817aa28023f2607850d1a1e51d21aa34817a
          --served-model-name zai-org/GLM-5.1-FP8 --tp 4
          --log-requests-level 0 --enable-metrics --trust-remote-code
    """
    let yamlLink = RunLink(title: "yaml @ c545c95",
                           url: "https://github.com/nearai/cvm-compose-files/blob/c545c95545dba47d8bea293aaae317089ea52f4d/prod/GLM-5.1-SGL-AWQ-TP4.yaml")
    let group = EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below, and the operator can't swap in anything else without changing that fingerprint.",
        mrConfig: "242a62724303cc32f364da0fc92738706b0078e758",
        quoteVerified: true,
        images: [
            ImageEntry(id: "reg·proxy", name: "nearaidev/vllm-proxy-rs", kind: .registry,
                       digest: "sha256:b183677aaabb…",
                       links: [RunLink(title: "v0.3.2 → b183677", url: "https://github.com/nearai/inference-proxy"),
                               RunLink(title: "sigstore", url: "https://search.sigstore.dev")],
                       plaintextRole: .e2eeTerminator,
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/images/docker.io/nearaidev/vllm-proxy-rs/sha256-b183677.md"),
                       configLines: MeasuredConfig.proxyConfig(innerComposeYAML: inner)?.lines ?? []),
            ImageEntry(id: "local·yaml", name: "GLM-5.1-SGL-AWQ-TP4.yaml", kind: .local,
                       note: "built in-enclave from the attested compose (pinned base + visible patch) — no registry digest.",
                       links: [RunLink(title: "v0.0.296 → c545c95 · yaml", url: "https://github.com/nearai/cvm-compose-files")],
                       plaintextRole: .modelServer,
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/manifests/glm51.md"),
                       configLines: MeasuredConfig.engineConfig(innerComposeYAML: inner, yamlLink: yamlLink)?.lines ?? []),
            ImageEntry(id: "reg·cm", name: "nearaidev/compose-manager", kind: .registry,
                       digest: "sha256:b487f39160e9…",
                       links: [RunLink(title: "master → 3d64349", url: "https://github.com/nearai/compose-manager"),
                               RunLink(title: "sigstore", url: "https://search.sigstore.dev")],
                       capability: .processAccess,
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/images/docker.io/nearaidev/compose-manager/sha256-b487f39.md")),
            ImageEntry(id: "3p·dd", name: "datadog/agent", kind: .thirdParty,
                       digest: "sha256:5556fb80b952…",
                       note: "digest-pinned by the attested manifest — no first-party build attestation.",
                       capability: .processAccess,
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/images/docker.io/datadog/agent/sha256-5556fb8.md")),
            ImageEntry(id: "3p·otel", name: "otel/opentelemetry-collector-contrib", kind: .thirdParty,
                       digest: "sha256:85ac41c2db88…",
                       note: "digest-pinned by the attested manifest — no first-party build attestation.",
                       capability: .logAccess,
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/images/docker.io/otel/opentelemetry-collector-contrib/sha256-85ac41c.md")),
            ImageEntry(id: "3p·certbot", name: "certbot/dns-cloudflare", kind: .thirdParty,
                       digest: "sha256:742dbd2e61c8…"),
        ],
        plaintextCaption: PlaintextExposure.analyze(modelComposeYAML: inner).groupCaption,
        measurementCaption: MeasuredConfig.allowedEnvsCaption(
            outerManifest: "{\"allowed_envs\": [\"BEARER_TOKEN\", \"DD_API_KEY\", \"HOST_IP\", \"PROXY_TOKEN\", \"CVM_NAME\"]}"),
        configAuditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/manifests/measured/sha256-242a627.md"))
    return ScrollView {
        EnclaveGroupView(group: group, rung: .expert).padding()
    }
}

// Deployment-config audit affordance, rendered from the shared FableAuditBlock.
// In production it surfaces only when teemoonai/audits has a matching published
// assessment; here the URL is set directly so the register/placement is
// reviewable. (The guest-OS affordance now lives in-enclave — see "guest OS ·
// first in model enclave".)
#Preview("audit affordances · deployment config") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("in the attested compose").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Text("none of the 22 operator-settable env vars is a logging or debug switch.")
                    .font(.caption2).foregroundStyle(.tertiary)
                FableAuditBlock(url: URL(string: "https://github.com/teemoonai/audits/blob/main/manifests/measured/sha256-242a627.md")!,
                                title: "fable miniaudit · deployment config",
                                subtitle: "allowed_envs, egress & telemetry reviewed · this measurement")
            }
        }
        .padding()
    }
}

// Shipped placement: the guest-OS artifact is reviewable measured software, not
// silicon, and it's the substrate every container runs on — so it rides as the
// FIRST row of the model enclave, styled like any other measured image (own
// `guest image` chip + os_image digest pill). It shows the MODEL node's
// os_image_hash (`9b69bb16…`), not the gateway's.
#Preview("guest OS · first in model enclave") {
    let group = EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below.",
        mrConfig: "0fccab4eb7ff2a19d7c6b0e5f3a18c92",
        quoteVerified: true,
        images: [
            ImageEntry(id: "os", name: "nearai/private-ml-sdk", kind: .guestOS,
                       digest: "os_image sha256:9b69bb1698ba…",
                       digestFull: "sha256:9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677",
                       note: "the confidential-VM guest image (kernel + rootfs) this enclave boots on — near.ai\u{2019}s private-ml-sdk build, measured into the quote as os_image_hash.",
                       // Set here to show the gated fable block; in production
                       // this URL comes from AuditIndex.osAuditURL and is nil
                       // (invisible) until teemoonai/audits publishes it.
                       auditURL: URL(string: "https://github.com/teemoonai/audits/blob/main/os/sha256-9b69bb16.md")),
            ImageEntry(id: "proxy", name: "nearaidev/vllm-proxy-rs", kind: .registry,
                       digest: "sha256:b183677a5d32…", plaintextRole: .e2eeTerminator),
            ImageEntry(id: "cm", name: "nearaidev/compose-manager", kind: .registry,
                       digest: "sha256:b487f39160e9…", capability: .processAccess),
        ],
        plaintextCaption: "images without a tag only handle encrypted data or content-free telemetry.")
    return ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("known code").font(.subheadline).fontWeight(.semibold)
                Text("running GLM-5.1's pinned, published build — its operator can't swap in a version that logs your chats.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            EnclaveGroupView(group: group, rung: .expert)
        }
        .padding()
    }
}

// The fail-closed state: a running guest-OS hash NOT in GuestOSProvenance.
// Instead of silently dropping the source link (which would read as "fine"),
// the row shows an amber caution — honest ("not matched to a published
// release"), not an overclaim ("doesn't match latest", which the app can't know).
#Preview("guest OS · unrecognized build (warning)") {
    let group = EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below.",
        mrConfig: "0fccab4eb7ff2a19d7c6b0e5f3a18c92",
        quoteVerified: true,
        images: [
            ImageEntry(id: "os", name: "nearai/private-ml-sdk", kind: .guestOS,
                       digest: "os_image sha256:ff00ba9911cc…",
                       digestFull: "sha256:ff00ba9911cc00000000000000000000000000000000000000000000000000ff",
                       note: "the confidential-VM guest image (kernel + rootfs) this enclave boots on — near.ai\u{2019}s private-ml-sdk build, measured into the quote as os_image_hash."),
            ImageEntry(id: "proxy", name: "nearaidev/vllm-proxy-rs", kind: .registry,
                       digest: "sha256:b183677a5d32…", plaintextRole: .e2eeTerminator),
        ],
        plaintextCaption: "images without a tag only handle encrypted data or content-free telemetry.")
    return ScrollView {
        EnclaveGroupView(group: group, rung: .expert).padding()
    }
}

#Preview("known code · empty toucher set") {
    // THE invariant state: no toucher set → the caption must say "couldn't
    // determine which images see your message" — untagged never reads safe.
    let group = EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below, and the operator can't swap in anything else without changing that fingerprint.",
        mrConfig: "242a62724303cc32f364da0fc92738706b0078e758",
        quoteVerified: true,
        images: [
            ImageEntry(id: "reg·mesh", name: "nearaidev/dstack-vpc", kind: .registry,
                       digest: "sha256:cccccccccccc…",
                       links: [RunLink(title: "main → 1234abc", url: "https://github.com/nearai/dstack-vpc")]),
            ImageEntry(id: "3p·dd", name: "datadog/agent", kind: .thirdParty,
                       digest: "sha256:bbbbbbbbbbbb…",
                       note: "digest-pinned by the attested manifest — no first-party build attestation."),
        ],
        plaintextCaption: PlaintextExposure(touchers: []).groupCaption)
    return ScrollView {
        EnclaveGroupView(group: group, rung: .expert).padding()
    }
}

#Preview("ladder · verifying") {
    let store = previewStore()
    let session = ConfidentialSession(providers: store)
    return NavigationStack {
        TrustLadderView()
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · paused (no E2EE)") {
    let store = previewStore()
    let session = ConfidentialSession(providers: store)
    session.attestation = .previewDegraded
    return NavigationStack {
        TrustLadderView()
            .environment(session)
            .environment(store)
    }
}

// Fail-loud states (F1 + signature mismatch). The verified previewSession is
// perturbed so the hero severity, honest subtitle, and send-gate can be eyeballed.

#Preview("ladder · recipe tamper (F1)") {
    let store = previewStore()
    let session = previewSession(store: store)
    // The inner-compose hash check fails against the action log's pin — an
    // adversarial integrity break. Expert rung + scrolled to known code so the
    // RED recipe card is the focus: the card border/background turn red and the
    // header reads "✗ does not match the action log — recipe unverified, do not
    // trust." (The hero also goes RED via the fail-loud severity split.)
    session.modelLayerVerification = .hashMismatch
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "known code")
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · expert · recipe card") {
    // The healthy recipe card in context: measured items (guest OS + harness
    // sidecars) above the dashed trust seam, engine + proxy inside the bordered
    // card, GREEN "verified on this device ✓" header.
    let store = previewStore()
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "known code")
            .environment(previewSession(store: store))
            .environment(store)
    }
}

#Preview("ladder · expert · recipe pending") {
    // The recipe hash check hasn't returned yet: neutral card, "verifying
    // recipe…" spinner in the header — pending, never a default green.
    let store = previewStore()
    let session = previewSession(store: store)
    session.modelLayerVerification = nil
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "known code")
            .environment(session)
            .environment(store)
    }
}

#Preview("ladder · expert · recipe unreachable") {
    // A transient fetch failure (GitHub down): ORANGE "source unreachable —
    // could not verify (transient)". Distinct from the RED tamper — a network
    // outage must NOT read as an accusation of tampering.
    let store = previewStore()
    let session = previewSession(store: store)
    session.modelLayerVerification = .fetchFailed
    return NavigationStack {
        TrustLadderView(initialRung: .expert, initialScroll: "known code")
            .environment(session)
            .environment(store)
    }
}

/// A model-enclave group in the recipe-card IA, for the component previews
/// below: measured items (guest OS + compose-manager) above the seam, the
/// action-log-pinned engine + proxy inside the recipe card. Rendered directly
/// (not via the full page) because the mid-page known-code section isn't
/// snapshot-reachable in the full-page previews.
private func previewRecipeGroup(_ verification: ModelLayerVerification?,
                                allDigest: Bool = false) -> EnclaveGroup {
    var guestOS = ImageEntry(
        id: "os", name: "nearai/private-ml-sdk", kind: .guestOS,
        digest: "os_image sha256:9b69bb1698ba…",
        digestFull: "sha256:9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677",
        note: "the confidential-VM guest image this enclave boots on — measured into the quote as os_image_hash.")
    guestOS.isRecipe = false
    var composeManager = ImageEntry(
        id: "cm", name: "nearaidev/compose-manager", kind: .registry,
        digest: "sha256:b487f39160e9…", capability: .processAccess)
    composeManager.isRecipe = false
    var proxy = ImageEntry(
        id: "proxy", name: "nearaidev/vllm-proxy-rs", kind: .registry,
        digest: "sha256:b183677a5d32…", plaintextRole: .e2eeTerminator)
    proxy.isRecipe = true
    var engine = ImageEntry(
        id: "local·engine", name: "lmsysorg/sglang", kind: .local,
        note: "the running engine — built in-enclave from the attested compose (pinned base + visible patch).",
        plaintextRole: .modelServer)
    engine.isRecipe = true
    // Telemetry collectors genuinely declared INSIDE near.ai's inner compose —
    // membership correctly places them in the recipe card, where the
    // sub-grouping keeps them off the "handles your message" section but
    // TAGGED: otel reads container logs, dcgm runs GPU-privileged. dcgm is the
    // REAL production shape: TAG-pinned (no @sha256) — orange "pinned by tag ·
    // can drift" chip + green capability capsule, two separate axes.
    var otel = ImageEntry(
        id: "3p·otel", name: "otel/opentelemetry-collector-contrib", kind: .thirdParty,
        digest: "sha256:85ac41c2db88…",
        note: "digest-pinned by the attested manifest — no first-party build attestation.",
        capability: .logAccess)
    otel.isRecipe = true
    otel.projectPointer = ProjectLink(
        name: "OpenTelemetry Collector Contrib",
        repo: "open-telemetry/opentelemetry-collector-contrib",
        status: "open source · shipped build not source-audited",
        url: URL(string: "https://github.com/open-telemetry/opentelemetry-collector-contrib")!)
    var dcgm = ImageEntry(
        id: "tag·dcgm", name: "nvcr.io/nvidia/k8s/dcgm-exporter",
        kind: allDigest ? .thirdParty : .tagPinned,
        digest: allDigest ? "sha256:0123456789ab…" : nil,
        tag: allDigest ? nil : "4.5.2-4.8.1-distroless",
        note: allDigest
            ? "digest-pinned by the attested manifest — no first-party build attestation."
            : "the action log pins this image\u{2019}s tag, not its contents — the registry can serve different bytes under the same tag, so what\u{2019}s actually running can drift with no trace in this attestation chain. not verifiable on this device.",
        capability: .devicePrivilege)
    dcgm.isRecipe = true
    dcgm.projectPointer = ProjectLink(
        name: "NVIDIA DCGM Exporter",
        repo: "NVIDIA/dcgm-exporter",
        status: "pinned by tag · can drift · not source-audited",
        url: URL(string: "https://github.com/NVIDIA/dcgm-exporter")!)
    // A tag-pinned image has no digest, so its audit page is tag-addressed.
    dcgm.auditURL = allDigest ? nil : URL(string: "https://github.com/teemoonai/audits/blob/main/images/nvcr.io/nvidia/k8s/dcgm-exporter/tag-4.5.2-4.8.1-distroless.md")
    return EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below.",
        mrConfig: "242a62724303cc32f364da0fc92738706b0078e7",
        quoteVerified: true,
        images: [guestOS, composeManager, proxy, engine, dcgm, otel],
        plaintextCaption: "images without a tag only handle encrypted data or content-free telemetry.",
        recipe: EnclaveGroup.RecipeCard(
            fileSHA: "ae5fa3a8ee2e826bf2a089dadda7270032dd358b8c2af67844e143951baeee5e",
            yamlLink: RunLink(title: "yaml @ c545c95",
                              url: "https://github.com/nearai/cvm-compose-files/blob/c545c95/prod/GLM-5.1-SGL-AWQ-TP4.yaml"),
            verification: verification))
}

// Component preview — the GREEN recipe card in full: guest OS + compose-manager
// above the dashed trust seam, engine + proxy inside the bordered card, header
// "verified on this device ✓".
#Preview("recipe card · verified") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("known code").font(.subheadline).fontWeight(.semibold)
                Text("running GLM-5.1's pinned, published build — its operator can't swap in a version that logs your chats.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            EnclaveGroupView(group: previewRecipeGroup(.verified), rung: .expert)
        }
        .padding()
    }
}

// Component preview — F1: a tampered recipe. The card border + background turn
// RED and the header reads "✗ does not match the action log — recipe unverified,
// do not trust." The measured items above the seam are unaffected.
#Preview("recipe card · tamper (F1)") {
    ScrollView {
        EnclaveGroupView(group: previewRecipeGroup(.hashMismatch), rung: .expert).padding()
    }
}

// Component preview — pending (nil) and transient fetch failure (orange), side
// by side, so the non-green states are directly reviewable.
#Preview("recipe card · pending + unreachable") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            EnclaveGroupView(group: previewRecipeGroup(nil), rung: .expert)
            EnclaveGroupView(group: previewRecipeGroup(.fetchFailed), rung: .expert)
        }
        .padding()
    }
}

// Component preview — JUST the recipe card, so both sub-sections fit one
// snapshot: "handles your message" (proxy + engine) above "telemetry sidecars"
// (dcgm "GPU-privileged", otel "reads container logs") — one border, one
// verdict, one file_sha256 for the whole card.
#Preview("recipe card · telemetry sub-grouped") {
    let group = previewRecipeGroup(.verified)
    return ScrollView {
        RecipeCardView(recipe: group.recipe!,
                       images: group.images.filter(\.isRecipe),
                       rung: .expert)
            .padding()
    }
}

// Component preview — the tag-pinned dcgm row in the card: ORANGE "pinned by
// tag · can drift" chip + GREEN "GPU-privileged" capsule (two separate axes),
// plain-text tag, orange drift note, NO links/digest pill; the verdict narrows
// to "recipe file verified on this device ✓" with the orange N-of-M scope
// caption computed from the rows.
#Preview("recipe card · tag-pinned sidecar") {
    let group = previewRecipeGroup(.verified)
    return ScrollView {
        RecipeCardView(recipe: group.recipe!,
                       images: group.images.filter(\.isRecipe),
                       rung: .expert)
            .padding()
    }
}

// Component preview — every recipe image digest-pinned: TODAY'S copy exactly.
// No scope caption, no except-clause, verdict "verified on this device ✓" —
// the tag-pinned caveat must be conditional, or it trains readers to skip it.
#Preview("recipe card · all digest-pinned") {
    let group = previewRecipeGroup(.verified, allDigest: true)
    return ScrollView {
        RecipeCardView(recipe: group.recipe!,
                       images: group.images.filter(\.isRecipe),
                       rung: .expert)
            .padding()
    }
}

// Component preview — the sub-grouping FAIL-SOFT: the toucher analysis failed
// (no plaintext role and no in-enclave build among the recipe rows), so the
// card renders the flat list — no "handles your message" / "telemetry sidecars"
// sub-headers. The engine must NEVER be dumped into "telemetry sidecars" by a
// parse failure.
#Preview("recipe card · no touchers (flat)") {
    var proxy = ImageEntry(
        id: "proxy", name: "nearaidev/vllm-proxy-rs", kind: .registry,
        digest: "sha256:b183677a5d32…")
    proxy.isRecipe = true
    var otel = ImageEntry(
        id: "3p·otel", name: "otel/opentelemetry-collector-contrib", kind: .thirdParty,
        digest: "sha256:85ac41c2db88…", capability: .logAccess)
    otel.isRecipe = true
    let group = EnclaveGroup(
        id: "model enclave", role: "model enclave", primary: true,
        binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below.",
        mrConfig: "242a62724303cc32f364da0fc92738706b0078e7",
        quoteVerified: true,
        images: [proxy, otel],
        plaintextCaption: PlaintextExposure(touchers: []).groupCaption,
        recipe: EnclaveGroup.RecipeCard(
            fileSHA: "ae5fa3a8ee2e826bf2a089dadda7270032dd358b8c2af67844e143951baeee5e",
            yamlLink: nil,
            verification: .verified))
    return ScrollView {
        EnclaveGroupView(group: group, rung: .expert).padding()
    }
}

#Preview("ladder · signature mismatch") {
    let store = previewStore()
    let session = previewSession(store: store)
    // A reply failed its signature check. Expect: RED hero "one reply didn't
    // check out" (NOT the false "sending paused"), session still sealed.
    session.mismatchedResponseCount = 1
    return NavigationStack {
        TrustLadderView()
            .environment(session)
            .environment(store)
    }
}


