//
//  FableAuditBlock.swift
//  teemoon
//

import SwiftUI

/// The per-image "fable miniaudit" affordance — a point-in-time source review
/// of this exact build, in a distinct orange register (not a green attestation
/// check: it's a reproducible human privacy review, not a
/// per-session hardware proof). Rendered only when `AuditIndex` has a published
/// assessment for the running digest/manifest, so the link is never fabricated.
struct FableAuditBlock: View {
    let url: URL
    var title: String = "fable miniaudit"
    let subtitle: String

    /// What the review actually CONCLUDED, in the reviewer's own words, from
    /// `index.json`'s `verdicts` map. Without it the block said the same thing
    /// ("source reviewed for plaintext egress · this exact build") whether the
    /// page behind it read "PRIVATE at deployed flags" or "COMPROMISABLE by
    /// credentialed operator" or "one unauthenticated runtime logging switch
    /// remains live" — so the mere existence of an audit read as an all-clear.
    /// nil ⇒ fail closed to neutral copy, never to reassurance.
    var verdict: String? = nil

    /// Machine-readable class of that verdict (`verdictClass` in the index) —
    /// badges the block so a LEAKS review stops rendering identically to a
    /// PRIVATE one. nil (unrecorded, or a future class this build doesn't
    /// know) ⇒ no badge, neutral treatment — never a guessed one.
    var verdictClass: AuditIndex.VerdictClass? = nil

    private var badgeColor: Color {
        switch verdictClass {
        case .privateReview:      return teeVerified
        case .leaks:              return .red
        case .compromisable:      return .orange
        case .qualifiedPass:      return .teal
        case .inconclusive, nil:  return .gray
        }
    }

    /// The verdict with its inline markdown resolved — live verdict lines
    /// carry `**bold**` and backticks, and a plain `Text(String)` renders the
    /// asterisks literally.
    private var verdictAttr: AttributedString? {
        verdict.map {
            (try? AttributedString(
                markdown: $0,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString($0)
        }
    }

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.callout).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        if let cls = verdictClass {
                            Text(cls.label)
                                .font(.caption2.weight(.bold))
                                .textCase(.uppercase)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(badgeColor.opacity(0.16), in: Capsule())
                                .foregroundStyle(badgeColor)
                        }
                    }
                    if let attr = verdictAttr {
                        // The reviewer's conclusion replaces the fixed subtitle
                        // — boilerplate must never outrank the verdict. Clipped
                        // to three lines (live verdicts run past 500 chars);
                        // the full wording is the tap away this block already
                        // is. Clipping may not soften: the class badge above
                        // survives any truncation.
                        Text(attr)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(3).truncationMode(.tail)
                            .padding(.top, 2)
                    } else {
                        Text(subtitle)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("verdict not recorded — open the review")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.orange)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.top, 3)
    }
}
