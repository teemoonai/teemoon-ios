//
//  FableAuditBlock.swift
//  teemoon
//

import SwiftUI

/// What the block says with no recorded verdict: never the "source reviewed … · this exact build" subtitle,
/// which reads as an all-clear (trust-audit-links-gated d, the maintainer 2026-11-06).
enum FableAuditCopy {
    static let unrecorded = "verdict not recorded — open the review"
    static func unrecordedLine(verdict: String?) -> String? { verdict == nil ? unrecorded : nil }
}

/// The per-image "fable miniaudit" affordance — a point-in-time source review
/// of this exact build, in a distinct orange register (not a green attestation
/// check: it's a reproducible human privacy review, not a
/// per-session hardware proof). Rendered only when `AuditIndex` has a published
/// assessment for the running digest/manifest, so the link is never fabricated.
struct FableAuditBlock: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let url: URL
    var title: String = "fable miniaudit"

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

    private var glyph: some View {
        Image(systemName: "doc.text.magnifyingglass").font(.callout).foregroundStyle(.orange)
    }

    private var arrow: some View {
        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.orange)
    }

    var body: some View {
        Link(destination: url) {
            // At the accessibility sizes the glyphs join the header, so the verdict gets the block's whole width.
            let inline = typeSize.isAccessibilitySize
            HStack(spacing: 9) {
                if !inline { glyph }
                VStack(alignment: .leading, spacing: 1) {
                    // Wraps whole pieces: an HStack hyphenated "au-dit" and the badge at accessibility sizes.
                    FlowLayout(spacing: 6) {
                        if inline { glyph }
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
                        if inline { arrow }
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
                            .lineLimitGrowing(3).truncationMode(.tail)
                            .padding(.top, 2)
                    } else if let line = FableAuditCopy.unrecordedLine(verdict: verdict) {
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if !inline { arrow }
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
