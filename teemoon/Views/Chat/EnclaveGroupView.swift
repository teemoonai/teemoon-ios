//
//  EnclaveGroupView.swift
//  teemoon
//

import SwiftUI

struct EnclaveGroupView: View {
    let group: EnclaveGroup
    let rung: TrustRung

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(group.role).font(.footnote).fontWeight(.semibold)
                if group.primary {
                    Text("primary · own quote")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(teeVerified.opacity(0.15), in: Capsule())
                        .foregroundStyle(teeVerified)
                }
                Spacer(minLength: 0)
                // Tri-state: a FAILED quote must show a red counter-signal, not
                // silently drop the seal (false and nil were visually identical —
                // a hardware-quote failure read as "still pending").
                switch group.quoteVerified {
                case .some(true):
                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(teeVerified)
                case .some(false):
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.seal.fill")
                        Text("quote failed").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.red)
                case .none:
                    EmptyView()
                }
            }
            Text(group.binding).font(.caption).foregroundStyle(.secondary)
            if let deployment = group.deployment {
                Text(deployment)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if rung.showsValues, let mr = group.mrConfig {
                ValuePill(value: "mr_config \(mr.prefix(12))…", fullValue: mr)
            }
            // Recipe IA (model enclave only): the images split at a dashed trust
            // seam. Measured items (guest OS + hardware-measured harness
            // sidecars) render as a flat list above the seam; the action-log-
            // pinned recipe (engine + proxy) is wrapped in a bordered card whose
            // header carries the pinned file_sha256, the yaml source link, and
            // the on-device verify verdict (F1's red render lives there). The
            // gateway has no action log → `recipe == nil` → the shipped flat
            // list, unchanged. Each row keeps its per-row capsule either way.
            if let recipe = group.recipe {
                let measured = group.images.filter { !$0.isRecipe }
                let recipeImages = group.images.filter { $0.isRecipe }
                ForEach(measured) { image in
                    ImageRowView(image: image, rung: rung)
                }
                // The seam + recipe are load-bearing — NEVER silently drop them
                // (that's this screen's "silence reads as safe" anti-pattern). The
                // card renders whenever there's an action-log pin, a verdict, or
                // recipe images — even empty (a hash mismatch drops the contents
                // but the red header must still show). Only a genuine ABSENCE of
                // any action-log pin gets the explicit "not verifiable" notice.
                let hasPinOrVerdict = !recipeImages.isEmpty || recipe.fileSHA != nil || recipe.verification != nil
                if !measured.isEmpty { TrustSeamDivider() }
                if hasPinOrVerdict {
                    RecipeCardView(recipe: recipe, images: recipeImages, rung: rung)
                } else {
                    NoActionLogNotice()
                }
            } else {
                ForEach(group.images) { image in
                    ImageRowView(image: image, rung: rung)
                }
            }
            // The one caption stating the counterpart of the role tags. It
            // must render even (especially) when no image is tagged — an
            // untagged list with no caption would read as "nothing here sees
            // your message", which the analysis may simply not know.
            if let caption = group.plaintextCaption {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            // How the measured-config panels above are bound — deliberately
            // NOT "hardware-measured" (that covers the outer harness only).
            if group.images.contains(where: { !$0.configLines.isEmpty }) {
                Text(MeasuredConfig.bindingNote)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // allowed_envs invariant (outer measured compose) — only when the
            // manifest actually exposed the list.
            if let caption = group.measurementCaption {
                proofText(caption, tokenFont: .caption2.monospaced())
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The per-node plaintext-egress rollup — every machine-read finding
            // from the reviews this attestation keys into, live-at-deployed-
            // flags first. Empty ⇒ nothing rendered (the fable blocks above
            // still carry each page's verdict; an empty rollup means "no
            // machine-readable findings indexed", never "all clear").
            if rung.showsLinks, !group.egressFindings.isEmpty {
                NodeEgressSection(findings: group.egressFindings)
            }
            // Deployment-config audit — the counterpart, at the compose level,
            // of the per-image fable blocks: it reviews the allowed_envs /
            // egress / telemetry governance this measurement pins.
            if rung.showsLinks, let url = group.configAuditURL {
                FableAuditBlock(url: url,
                                title: "fable miniaudit · deployment config",
                                subtitle: "allowed_envs, egress & telemetry reviewed · this measurement",
                                verdict: AuditIndex.shared.verdict(for: url),
                                verdictClass: AuditIndex.shared.verdictClass(for: url))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformTone.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}
