//
//  RecipeCardView.swift
//  teemoon
//

import SwiftUI

/// The recipe card — the action-log-pinned engine + proxy wrapped in a bordered
/// box whose header carries the pinned `file_sha256`, a "yaml @ commit" source
/// link, and the on-device verify verdict. The verdict is the load-bearing
/// honesty signal: `.verified` → green "verified on this device ✓"; `.hashMismatch`
/// → the whole card goes RED with "✗ does not match the action log" (F1);
/// `.fetchFailed` → orange "source unreachable (transient)"; nil → pending.
struct RecipeCardView: View {
    let recipe: EnclaveGroup.RecipeCard
    let images: [ImageEntry]
    let rung: TrustRung

    /// A recipe-hash mismatch is an adversarial integrity break — the whole card
    /// turns red, never a quiet dropped row (silence reads as safe).
    private var isFailure: Bool { recipe.verification == .hashMismatch }

    /// The tint that colors the border/background and the verdict line.
    private var tint: Color {
        switch recipe.verification {
        case .some(.verified):    return teeVerified
        case .some(.hashMismatch): return .red
        case .some(.fetchFailed):  return .orange
        case .none:                return .secondary
        }
    }

    /// The tag-pinned rows in this card. Non-empty SCOPES the verdict: the
    /// recipe *file* hash matched, but a tag-pinned member's bytes aren't
    /// covered by that hash — the copy must not claim more than the check did.
    private var tagPinnedImages: [ImageEntry] { images.filter { $0.kind == .tagPinned } }

    /// The verdict line (icon + wrapping text). nil while the check is pending
    /// (rendered as a spinner instead). With tag-pinned rows present the green
    /// verdict narrows to "recipe FILE verified" — the file hash DID match
    /// (green stays; orange/red here would fabricate a failure), but the
    /// orange scope caption below names what that hash doesn't pin.
    private var verdict: (icon: String, text: String)? {
        switch recipe.verification {
        case .some(.verified):
            return ("checkmark.seal.fill",
                    tagPinnedImages.isEmpty ? "verified on this device \u{2713}"
                                            : "recipe file verified on this device \u{2713}")
        case .some(.hashMismatch):
            return ("xmark.octagon.fill",
                    "\u{2717} does not match the action log \u{2014} recipe unverified, do not trust")
        case .some(.fetchFailed):
            return ("exclamationmark.triangle.fill",
                    "source unreachable \u{2014} could not verify (transient)")
        case .none:
            return nil
        }
    }

    /// The one orange scope caption under a green verdict — CONDITIONAL on
    /// tag-pinned rows (an always-on caveat trains readers to skip it), with
    /// the counts computed from the actual row set.
    private var scopeCaption: String? {
        guard recipe.verification == .verified, !tagPinnedImages.isEmpty,
              !images.isEmpty else { return nil }
        let tagged = tagPinnedImages
        let names = tagged.map { $0.name.split(separator: "/").last.map(String.init) ?? $0.name }
            .joined(separator: ", ")
        let pinned = images.count - tagged.count
        let pronoun = tagged.count == 1 ? "its" : "their"
        let rows = tagged.count == 1 ? "its row" : "their rows"
        return "pins \(pinned) of \(images.count) images by content digest \u{2014} \(tagged.count) (\(names)) by tag only: \(pronoun) running bytes can change without changing the hash verified above. see \(rows)."
    }

    /// On the message's DATA PATH: a plaintext role, or the in-enclave engine
    /// build (whose base-image row carries the modelServer role via the
    /// exposure tagging, but `.local` is included by kind so a role-tagging
    /// gap can never demote the engine to "telemetry").
    private static func handlesMessage(_ image: ImageEntry) -> Bool {
        image.plaintextRole != nil || image.kind == .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // Two labeled sub-sections INSIDE the one card, partitioned by
            // DATA PATH — never by name. FAIL-SOFT: when no handler was
            // identified (toucher analysis parse failure) the partition is
            // nil and the rows render as today's flat list — never dump the
            // engine into "telemetry sidecars". A telemetry row with NO
            // capability tag still renders (partition keeps every non-handler;
            // the group's analysis-gap caption covers it) — an untagged row
            // is a detection gap, not a safe row.
            if let split = partitionRecipeRows(images, handlesMessage: Self.handlesMessage) {
                subHeader("handles your message")
                ForEach(split.handlers) { image in
                    ImageRowView(image: image, rung: rung)
                }
                if !split.telemetry.isEmpty {
                    subHeader("telemetry sidecars")
                    // "verified the same way" is false the moment a tag-pinned
                    // row exists — the except-clause is conditional so the
                    // all-digest caption stays unqualified.
                    Text(split.telemetry.contains(where: { $0.kind == .tagPinned })
                        ? "pinned by the same action log and verified the same way \u{2014} except rows marked \u{2018}pinned by tag\u{2019}, which the action log names but cannot pin by content \u{2014} not on your message\u{2019}s path, but each runs with real privileges inside the enclave: see each row\u{2019}s tag."
                        : "pinned by the same action log and verified the same way \u{2014} not on your message\u{2019}s path, but each runs with real privileges inside the enclave: see each row\u{2019}s tag.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Tag-pinned rows WITH a capability/toucher tag render as
                    // full rows (dcgm: privilege is exactly why it must be
                    // seen). The UNTAGGED tag-pinned remainder (today: zero)
                    // collapses into ONE summary caption — surfaced by name
                    // and count, never silently dropped (suppression reads as
                    // safe), but not N content-free rows either.
                    let collapsible: (ImageEntry) -> Bool = {
                        $0.kind == .tagPinned && $0.capability == nil && $0.plaintextRole == nil
                    }
                    ForEach(split.telemetry.filter { !collapsible($0) }) { image in
                        ImageRowView(image: image, rung: rung)
                    }
                    let collapsed = split.telemetry.filter(collapsible)
                    if !collapsed.isEmpty {
                        Text("\(collapsed.count) more pinned by tag only \u{2014} not individually verifiable here: \(collapsed.map(\.name).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(images) { image in
                    ImageRowView(image: image, rung: rung)
                }
            }
            // A mismatch drops the inner compose, so the card can be image-less.
            // Say so — an empty red card must not read as "nothing to see."
            if images.isEmpty && isFailure {
                Text("recipe contents unavailable — the fetched file didn’t match the pinned hash, so its images aren’t shown.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(isFailure ? 0.08 : 0.05),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(isFailure ? 0.9 : 0.35),
                              lineWidth: isFailure ? 1.5 : 1))
    }

    /// A sub-section LABEL — caption2/.secondary, deliberately not a verdict:
    /// the card has exactly one border, one verdict, one file_sha256.
    private func subHeader(_ label: String) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 2)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.caption).foregroundStyle(.secondary)
                Text("the running recipe").font(.footnote).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            // "the exact images … pinned" overclaims the moment a tag-pinned
            // member exists (a tag names, it doesn't pin) — narrow to
            // "declares" only then; the unqualified copy stays for the
            // all-digest case.
            Text(.init(tagPinnedImages.isEmpty
                ? "the exact images the signed action log pinned \u{2014} the engine + proxy that handle your message, plus their telemetry sidecars \u{2014} checked on this device against its `file_sha256`."
                : "the images the signed action log\u{2019}s recipe declares \u{2014} checked on this device against its `file_sha256`."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The verdict — full width so the mismatch sentence wraps rather
            // than truncating. Red when the recipe doesn't match; never silent.
            if let v = verdict {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: v.icon).font(.caption2)
                    Text(v.text).font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(tint)
                if let scopeCaption {
                    Text(scopeCaption)
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("verifying recipe\u{2026}")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if rung.showsValues, let sha = recipe.fileSHA, !sha.isEmpty {
                ValuePill(value: "file_sha256 \(sha.prefix(12))\u{2026}", fullValue: sha)
            }
            if rung.showsLinks, let link = recipe.yamlLink, let url = URL(string: link.url) {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text(link.title)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption2.weight(.medium))
                }
            }
            // The published review of this exact recipe version — the compose-
            // level counterpart of the per-image fable blocks (launch flags,
            // logging switches, network reachability). Keyed by the attested
            // path + file_sha256; absent ⇒ nothing shown, never fabricated.
            if rung.showsLinks, let url = recipe.auditURL {
                FableAuditBlock(url: url,
                                title: "fable miniaudit · recipe",
                                subtitle: "launch flags, logging & egress reviewed · this exact file",
                                verdict: AuditIndex.shared.verdict(for: url),
                                verdictClass: AuditIndex.shared.verdictClass(for: url))
            }
        }
    }
}
