//
//  ImageRowView.swift
//  teemoon
//

import SwiftUI

struct ImageRowView: View {
    let image: ImageEntry
    let rung: TrustRung

    /// 1 = sees plaintext (data path), 2 = can reach it by privilege, 3 = holds
    /// device privilege (SYS_ADMIN / GPU), 4 = reads logs. nil = ordinary row.
    /// Derived from the live capability tags — plus the guest OS, which is
    /// tier 1 by architecture: as the kernel it manages every container's
    /// memory, so it has the most complete view of plaintext of anything in
    /// the enclave (strictly above any docker.sock/log tier). This one tag is
    /// asserted, not compose-derived — see `capNote`.
    private var tier: Int? {
        if image.kind == .guestOS { return 1 }
        if image.plaintextRole != nil { return 1 }
        switch image.capability {
        case .processAccess:   return 2
        case .devicePrivilege: return 3
        case .logAccess:       return 4
        case nil:              return nil
        }
    }
    /// Green capsule label — unified "sees your message" for touchers (the
    /// specific role moves to the note below), the capability phrase otherwise.
    private var capsuleLabel: String? {
        if image.kind == .guestOS { return "sees your message" }
        if image.plaintextRole != nil { return "sees your message" }
        return image.capability?.capsule
    }
    private var capsuleGlyph: String {
        switch tier {
        case 2:  return "cpu"
        case 3:  return "memorychip"
        case 4:  return "doc.text"
        default: return "eye"
        }
    }
    /// The specific plaintext relationship, demoted to a note under the unified
    /// tier-1 capsule (only the touchers carry one).
    private var capNote: String? {
        // The guest OS sees plaintext for a DIFFERENT reason than the app
        // touchers: not because decrypting/serving is its job, but because it's
        // the platform they all run on — unavoidable for any OS, which is
        // exactly why its image is measured into the quote.
        if image.kind == .guestOS {
            return "as the kernel it manages every container\u{2019}s memory, so your plaintext is unavoidably visible to it — intrinsic to any OS, which is why its image is measured into the quote."
        }
        switch image.plaintextRole {
        case .e2eeTerminator: return "decrypts your request sealed to the model key."
        case .modelServer:    return "runs the model over your plaintext tokens."
        case nil:             return nil
        }
    }
    private var egress: String {
        switch tier {
        case 1:  return "plaintext egress"
        case 2:  return "process-access egress"
        case 3:  return "metrics egress"
        case 4:  return "log-forwarding egress"
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(image.name)
                    .font(.system(.footnote, design: .monospaced)).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                // The provenance-tier chip rides inline beside the name for
                // every non-local row (the local engine says "built in-enclave"
                // in its note instead). A red `unverified` chip always shows;
                // a tag-pinned row's chip is ORANGE (cannot-check — a tag pins
                // no bytes), never red (red = positive evidence of tamper, and
                // a tag-pinned image gave none).
                let unverified = image.kind == .unverified
                let tagPinned = image.kind == .tagPinned
                if image.kind != .local {
                    Text(image.kind.label)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(unverified ? AnyShapeStyle(Color.red.opacity(0.15))
                                    : tagPinned ? AnyShapeStyle(Color.orange.opacity(0.15))
                                                : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                        .foregroundStyle(unverified ? AnyShapeStyle(Color.red)
                                         : tagPinned ? AnyShapeStyle(Color.orange)
                                                     : AnyShapeStyle(.secondary))
                }
            }
            // Green plaintext-tier capsule — one soft teeVerified register at
            // every tier: these facts are the design working, not warnings.
            if let capsuleLabel {
                HStack(spacing: 5) {
                    Image(systemName: capsuleGlyph).font(.caption2)
                    Text(capsuleLabel).font(.caption2).fontWeight(.medium)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(teeVerified.opacity(0.15), in: Capsule())
                .foregroundStyle(teeVerified)
            }
            if let capNote {
                Text(capNote).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // fable miniaudit — a per-build source review, shown ONLY when a
            // published assessment covers this exact digest/manifest (an empty
            // teemoonai/audits index ⇒ no block; never a fabricated URL). The
            // guest OS gets its own framing (kernel/rootfs + disk-encryption
            // posture, keyed on the os_image measurement — not a container's
            // egress path).
            if rung.showsLinks, tier != nil, let url = image.auditURL {
                if image.kind == .guestOS {
                    FableAuditBlock(url: url,
                                    title: "fable miniaudit · guest OS",
                                    subtitle: "image + disk-encryption posture reviewed · this measurement",
                                    verdict: AuditIndex.shared.verdict(for: url),
                                    verdictClass: AuditIndex.shared.verdictClass(for: url))
                } else {
                    FableAuditBlock(url: url, subtitle: "source reviewed for \(egress) · this exact build",
                                    verdict: AuditIndex.shared.verdict(for: url),
                                    verdictClass: AuditIndex.shared.verdictClass(for: url))
                }
            }
            // The tag of a tag-pinned image — PLAIN secondary text, never a
            // ValuePill: the pill register means "externally verifiable
            // artifact", and a tag is a name, not a content hash.
            if image.kind == .tagPinned, let tag = image.tag {
                Text("tag \(tag) — a name, not a content hash")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = image.note {
                // Register matches the claim: red = tamper evidence
                // (unverified), ORANGE = structurally uncheckable (tag-pinned
                // drift), secondary = plain fact.
                Text(note).font(.caption)
                    .foregroundStyle(image.kind == .unverified ? AnyShapeStyle(Color.red)
                                     : image.kind == .tagPinned ? AnyShapeStyle(Color.orange)
                                                                : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rung.showsValues, let digest = image.digest {
                // The digest is THE externally verifiable artifact for an
                // image — the copy affordance yields the full sha256 (what a
                // reader pastes into sigstore / the GitHub API), while the
                // display stays truncated. Prose stays plain text.
                ValuePill(value: digest, fullValue: image.digestFull)
            }
            // Guest-OS verification register — DISTINCT from the per-image
            // provenance links (those resolve digest→commit LIVE each session;
            // this is a recorded, out-of-band digest match). Two states:
            //   • recorded match → a muted source link + "reproduce it yourself"
            //     caption. Never styled as a peer of the orange provenance links.
            //   • NOT recorded → an amber caution. Fail-closed here is NOT
            //     silence (silence-reads-as-safe is the anti-pattern this whole
            //     screen fights). We state what's true — no recorded match — and
            //     deliberately do NOT claim "doesn't match latest": the app has
            //     no live notion of "latest", so an unrecorded hash may simply be
            //     a release newer than its records.
            if image.kind == .guestOS {
                if let src = GuestOSProvenance.source(forOSImageHash: image.digestFull ?? ""),
                   let url = URL(string: src.releaseURL) {
                    VStack(alignment: .leading, spacing: 3) {
                        if rung.showsLinks {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Image(systemName: "shippingbox")
                                    Text("\(src.tag) · \(src.commit.prefix(7))")
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        Text("recorded match, not a live check: this measured hash equals the image digest that release publishes — reproducible by anyone (download it, compare digest.txt), unlike the per-image provenance links which the app re-derives each session.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 1)
                } else {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                        Text("teemoon hasn\u{2019}t matched this guest-OS build to a published near.ai release — it may be newer than this app\u{2019}s records, or a build outside the public releases. it can\u{2019}t confirm this is a known-good image.")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                }
            }
            // What the attested launch config forbids, live-parsed from the
            // hash-verified inner compose. Header names the evidence source
            // (design review: "measured configuration" read as a certification
            // stamp; "in the attested compose" says where the facts come from).
            // Soft verified register: working-as-intended facts, not checks
            // being re-run.
            if rung.showsValues && !image.configLines.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("in the attested compose")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(image.configLines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: line.state == .holds ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(line.state == .holds ? teeVerified : .orange)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.caption).fontWeight(.medium)
                                proofText(line.detail, tokenFont: .caption2.monospaced())
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if rung.showsLinks && !line.links.isEmpty {
                                    HStack(spacing: 14) {
                                        ForEach(line.links) { link in
                                            if let url = URL(string: link.url) {
                                                Link(destination: url) {
                                                    HStack(spacing: 3) {
                                                        Text(link.title)
                                                        Image(systemName: "arrow.up.right")
                                                    }
                                                    .font(.caption2.weight(.medium))
                                                }
                                            }
                                        }
                                    }
                                    .padding(.top, 1)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(teeVerified.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 2)
            }
            // Caveated upstream-project pointer (third-party sidecar). A MUTED
            // affordance in its own register — deliberately NOT one of the blue
            // provenance chips below: those are verified digest→commit links; a
            // third-party image has no such binding. The `status` line states
            // the limitation plainly (silence-reads-as-safe is the anti-pattern
            // this screen fights) — open-source-but-unreviewed, proprietary, or
            // tag-pinned — so the pointer can never be mistaken for a proof.
            if rung.showsLinks, let pp = image.projectPointer {
                VStack(alignment: .leading, spacing: 2) {
                    Link(destination: pp.url) {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                            Text("upstream · \(pp.name)")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    Text(pp.status)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
            }
            if rung.showsLinks && !image.links.isEmpty {
                HStack(spacing: 14) {
                    ForEach(image.links) { link in
                        if let url = URL(string: link.url) {
                            Link(destination: url) {
                                HStack(spacing: 3) {
                                    Text(link.title)
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(.caption2.weight(.medium))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}
