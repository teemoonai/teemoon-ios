//
//  TrustLadderSupport.swift
//  teemoon
//
//  Evidence rows, known-code models, and Canvas previews for TrustLadderView.
//  Types are internal so the ladder can render them from another file.
//

import SwiftUI

// MARK: - Evidence card + row

/// One disclosed-limit row. File-scope (not a view method) so the component
/// previews render the exact same rows the live card uses.
func limitRow(_ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        // Neutral grey, not an orange warning: these are disclosed boundaries
        // of the guarantee, not problems — an alarm here would misread as
        // "something's wrong" on an otherwise-verified screen.
        Image(systemName: "minus.circle")
            .font(.body).foregroundStyle(.secondary).frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout).fontWeight(.medium)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

struct EvidenceCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PlatformTone.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EvidenceRow: View {
    let label: String
    let state: StepState?
    let detail: String
    var value: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.callout).fontWeight(.medium)
                proofText(detail).font(.footnote).fixedSize(horizontal: false, vertical: true)
                if let value { ValuePill(value: value) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .some(.done):  Image(systemName: "checkmark.circle.fill").foregroundStyle(teeVerified)
        case .some(.stuck): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .some(.live), .some(.pending), .none: ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Known-code models + views

/// One enclave's code: the quote/mr_config that measures it, and its images.
struct EnclaveGroup: Identifiable {
    let id: String
    let role: String
    let primary: Bool
    let binding: String
    /// Deployment-recency caption from the signed action log (model enclave
    /// only — the gateway exposes no action log). nil = no timestamps.
    var deployment: String? = nil
    let mrConfig: String?
    let quoteVerified: Bool?
    let images: [ImageEntry]
    /// The one caption stating the counterpart of the plaintext-role tags —
    /// positive when the toucher set is known, "couldn't determine…" when it
    /// isn't (the absence-of-badge-never-reads-as-safe invariant). Only the
    /// model-enclave group carries it.
    var plaintextCaption: String? = nil
    /// The allowed_envs invariant from the OUTER measured compose: whether any
    /// operator-settable env is a logging/debug switch. nil = not derivable.
    var measurementCaption: String? = nil
    /// Digest-gated audit of this enclave's measured `app_compose` — the
    /// deployment-config governance (allowed_envs / egress / telemetry). nil
    /// when no published assessment covers this measurement.
    var configAuditURL: URL? = nil
    /// Recipe-card metadata — model enclave only (the enclave with a signed
    /// action log). When present, `EnclaveGroupView` splits the images at a
    /// dashed trust seam: measured items (guest OS + harness sidecars) above,
    /// and the action-log-pinned recipe (engine + proxy) wrapped in a bordered
    /// card whose header carries the pinned `file_sha256`, the yaml source link,
    /// and the on-device verify verdict. nil for the gateway (no action log →
    /// no card, stays a flat list).
    var recipe: RecipeCard? = nil
    /// The per-node plaintext-egress rollup: machine-read findings from every
    /// review this attestation keys into (images, recipe, measured harness,
    /// guest OS), each deep-linked to its evidence anchor. Model enclave only;
    /// empty = no machine-readable findings indexed (NOT "nothing found").
    var egressFindings: [NodeFinding] = []

    /// Header evidence for the recipe card — the exact inner compose the signed
    /// action log pinned, and whether it checked out on this device.
    struct RecipeCard {
        /// The action log's pinned SHA-256 of the inner compose file.
        let fileSHA: String?
        /// "yaml @ <commit>" link to the exact inner compose at the attested commit.
        let yamlLink: RunLink?
        /// On-device verdict of the inner-compose hash check (nil = still pending).
        let verification: ModelLayerVerification?
        /// The published review of this exact inner-compose version, keyed by
        /// the attested path + file_sha256 (`manifestAuditURL`). nil = no
        /// published assessment → nothing shown.
        var auditURL: URL? = nil
    }
}

/// Classifies a running image as *recipe* (pinned by the model enclave's signed
/// action log — belongs inside the recipe card) vs *measured/other* (the
/// hardware-measured harness sidecars + guest OS, which sit above the trust
/// seam). Pure + `internal` so it's unit-testable without the private view types.
///
/// - The in-enclave engine build (`isLocalEngine`) is ALWAYS recipe: the inner
///   compose is literally its build recipe, even though its base-image name
///   won't appear verbatim in the YAML.
/// - The guest OS is NEVER recipe: it's the measured substrate the enclave boots
///   on, not something the action log's compose launches.
/// - Everything else is recipe exactly when its image name appears in the
///   hash-verified inner compose YAML — the document the action log pinned. The
///   harness sidecars (compose-manager, datadog, otel) live in the OUTER measured
///   compose, so they're absent from this document and stay measured/other.
/// - A DIGESTLESS entry is recipe when its full tag ref (`tagRef`) is DECLARED
///   as a service `image:` in that document — the tag-membership rule that
///   keeps a tag-pinned sidecar (dcgm) INSIDE the card instead of stranding it
///   above the seam with the hardware-measured harness. Parsed per-service,
///   never a substring, for the same label-trap reason as the digest rule.
func isRecipeImage(digestFull: String?, tagRef: String? = nil,
                   isLocalEngine: Bool, isGuestOS: Bool,
                   innerComposeYAML: String?) -> Bool {
    if isLocalEngine { return true }   // the :local engine has no registry digest; it IS the recipe
    if isGuestOS { return false }      // measured at boot, never action-log-pinned
    guard let yaml = innerComposeYAML else { return false }
    if let digestFull, !digestFull.isEmpty {
        // Digest membership in the VERIFIED inner manifest: an image is part of the
        // action-log-pinned recipe iff its exact @sha256 digest is actually DECLARED
        // there. NEVER a name substring — near.ai's compose is saturated with
        // telemetry LABELS (`nearai.otel.*`, `com.datadoghq.*`) on the model/proxy
        // services, so a substring match falsely pulls a measured harness sidecar
        // (e.g. the otel collector) into the recipe card while its sibling (datadog)
        // stays out — a real trust-model misrepresentation observed live on Qwen-3.6.
        let bare = digestFull.hasPrefix("sha256:") ? String(digestFull.dropFirst("sha256:".count)) : digestFull
        return ProvenanceService.imageRefs(inManifest: yaml).contains { $0.digest.caseInsensitiveCompare(bare) == .orderedSame }
    }
    if let tagRef, !tagRef.isEmpty {
        return ProvenanceService.tagPinnedImageRefs(inManifest: yaml).contains(tagRef)
    }
    return false
}

/// Partitions the recipe card's rows by DATA PATH — never by name: `handlers`
/// are the rows on the message's path (a plaintext role, or the in-enclave
/// engine build); `telemetry` is EVERYTHING else — including rows with no
/// capability tag. An untagged telemetry row is a signal-detection gap that
/// must still render (the group's analysis-gap caption covers it); suppressing
/// it would read as "safe". Returns nil when no handler was identified: that's
/// a toucher-analysis parse failure, and the caller must fall back to the flat
/// in-card list rather than dump the engine into "telemetry sidecars".
/// Generic + pure so the fail-soft rule and the never-suppress invariant are
/// unit-testable without the private view types.
func partitionRecipeRows<T>(_ items: [T], handlesMessage: (T) -> Bool)
    -> (handlers: [T], telemetry: [T])? {
    let handlers = items.filter(handlesMessage)
    guard !handlers.isEmpty else { return nil }
    return (handlers, items.filter { !handlesMessage($0) })
}

/// One machine-read finding from a published review, resolved against the page
/// it came from — the row unit of the per-node "plaintext egress" rollup.
/// Internal + plain data so the ordering/split rules are unit-testable.
struct NodeFinding: Identifiable, Equatable {
    let id: String
    /// "critical" | "high" | "medium" | "low" | "info". Unknown values keep
    /// their text and sink to the bottom of the ordering — never dropped.
    let severity: String
    /// "on" | "off" | "armed" | nil — the reviewer's deployed-state.
    let deployed: String?
    /// Raw heading qualifier for the provenance line ("deployed: ON, unconditional").
    let qualifier: String?
    let title: String
    /// Short provenance label ("sglang @8ece90ad" / "recipe" / "deployment
    /// config" / "guest OS").
    let source: String
    /// The finding's own evidence section: `<page>#<anchor>`.
    let url: URL
}

/// Severity order for the rollup (critical first). Unknown severities rank
/// after info — visible at the bottom, never silently dropped.
func severityRank(_ severity: String) -> Int {
    switch severity {
    case "critical": return 0
    case "high":     return 1
    case "medium":   return 2
    case "low":      return 3
    case "info":     return 4
    default:         return 5
    }
}

/// Splits a node's findings for display: `live` = the reviewer marked the
/// finding ON at the deployed config — what a reader must see first; `latent`
/// = every other non-info finding (off switches, crash-armed paths, structural
/// mechanisms); `info` collapses behind a count. Severity-sorted, stable
/// within a band. Pure so the never-drop and ordering rules are testable.
func splitNodeFindings(_ findings: [NodeFinding])
    -> (live: [NodeFinding], latent: [NodeFinding], info: [NodeFinding]) {
    let sorted = findings.enumerated()
        .sorted { (severityRank($0.element.severity), $0.offset)
                < (severityRank($1.element.severity), $1.offset) }
        .map(\.element)
    let live   = sorted.filter { $0.deployed == "on" && $0.severity != "info" }
    let latent = sorted.filter { $0.deployed != "on" && $0.severity != "info" }
    let info   = sorted.filter { $0.severity == "info" }
    return (live, latent, info)
}

/// One image in an enclave's compose. `kind` distinguishes a pulled registry
/// image (has provenance) from one built in-enclave (`:local`) or a third-party
/// sidecar (digest-pinned only) — each honestly shows only what it can prove.
struct ImageEntry: Identifiable {
    enum Kind { case registry, local, thirdParty, unverified, guestOS, tagPinned
        var label: String {
            switch self {
            case .registry:   return "registry image"
            case .local:      return "built in-enclave"
            case .thirdParty: return "third-party · digest-pinned"
            case .unverified: return "unverified"
            case .guestOS:    return "guest OS"
            // ORANGE (cannot-check), never red (positive evidence of tamper):
            // a tag names a build but pins no bytes — structurally uncheckable
            // from here, same register as a fetch failure.
            case .tagPinned:  return "pinned by tag · can drift"
            }
        }
    }
    let id: String
    let name: String
    let kind: Kind
    var digest: String? = nil
    /// Full sha256 for the copy affordance (display stays truncated).
    var digestFull: String? = nil
    /// The tag of a `.tagPinned` (digestless) image — rendered as PLAIN text,
    /// never a ValuePill: the pill register means "externally verifiable
    /// artifact", and a tag is a name, not a content hash. nil for a tagless
    /// ref (implicit :latest) and for every other kind.
    var tag: String? = nil
    var note: String? = nil
    var links: [RunLink] = []
    /// Non-nil when this image sees the user's message decrypted (per the
    /// attested compose) — rendered as a soft role capsule. Working as
    /// intended, not a warning. (tier 1)
    var plaintextRole: PlaintextExposure.Role? = nil
    /// Non-nil when this image can REACH plaintext by attested privilege
    /// (docker.sock / pid:host → processAccess; container-log mounts →
    /// logAccess) though it never sits on the data path. Model enclave only;
    /// derived live, never both this and `plaintextRole`. (tiers 2 & 3)
    var capability: PlaintextExposure.Capability? = nil
    /// Digest/manifest-gated source-audit page for this exact build, when one
    /// is published in teemoonai/audits. Tiered rows surface it in the fable
    /// miniaudit block; nil = no published assessment → nothing shown (never
    /// a fabricated URL).
    var auditURL: URL? = nil
    /// A CAVEATED upstream-project pointer for a third-party sidecar (otel /
    /// datadog / dcgm) — resolved live from `AuditIndex.projectPointer`. NOT a
    /// peer of the engine's verified source link: it carries the audit's honest
    /// `status` caveat (open-source-but-unreviewed / proprietary / tag-pinned)
    /// and renders in a muted, explicitly-not-verified register. nil for every
    /// row that has no recorded project pointer.
    var projectPointer: ProjectLink? = nil
    /// Measured-configuration lines for a plaintext toucher, live-parsed from
    /// the hash-verified inner compose. Empty for non-touchers (and whenever
    /// the inner document isn't available — no unbacked claims).
    var configLines: [MeasuredConfig.Line] = []
    /// Whether this image is part of the action-log-pinned *recipe* (the engine
    /// + proxy the inner compose launches) vs the hardware-measured harness /
    /// guest OS. Drives the recipe-card split in `EnclaveGroupView` (model
    /// enclave only). Set via `isRecipeImage`; false for the gateway (flat list).
    var isRecipe: Bool = false
}

/// A caveated upstream-project pointer for a third-party sidecar — the project
/// it comes from plus the audit's honest review-status. Deliberately separate
/// from `RunLink` so the row can render it in a muted, not-verified register
/// (it is NOT a peer of the engine's provenance links).
struct ProjectLink {
    let name: String
    let repo: String
    let status: String
    let url: URL
}
