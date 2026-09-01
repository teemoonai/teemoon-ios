//
//  AuditIndex.swift
//  teemoon
//
//  Digest-gated links to the published source audits (teemoonai/audits).
//  The repo's path layout is a frozen contract: every code-addressed path is
//  a pure function of ATTESTED fields (image ref + digest, manifest path +
//  file_sha256, measured compose_hash) — see the repo README's path spec.
//  Links are shown ONLY when the exact running identity appears in the
//  fetched index.json, so an audit link can never overclaim: no entry in the
//  index, no link.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.teemoon", category: "audits")

@Observable
@MainActor
final class AuditIndex {
    static let shared = AuditIndex()

    /// Permanent coordinates (org/repo/branch are API — see the repo README).
    static let webBase = "https://github.com/teemoonai/audits/blob/main"
    static let indexURL = URL(string: "https://raw.githubusercontent.com/teemoonai/audits/main/index.json")!

    /// The upstream source a third-party image build was compiled from — the
    /// exact repo+commit the RUNNING digest maps to (from its audit). Lets the
    /// app pin a source link to the version actually on the server, even though
    /// third-party images carry no near.ai build attestation to derive it from.
    struct SourceRef: Decodable, Equatable {
        let repo: String      // "sgl-project/sglang"
        let commit: String    // full git sha
    }

    /// A CAVEATED upstream pointer for a third-party image — deliberately NOT a
    /// `SourceRef`. A `SourceRef` is a VERIFIED digest→commit pin (the
    /// attestation proves the digest, the audit binds it to a build): rendered
    /// as a peer of the engine's source link. A `Project` is the opposite — a
    /// third-party image with NO digest→commit binding and, per its audit, an
    /// un-reviewed (or proprietary, or tag-pinned) source. It carries its own
    /// `status` caveat so the row can never read as verified. Keyed by image
    /// ref (not digest), so it works for a tag-pinned image too.
    struct Project: Decodable, Equatable {
        let name: String      // "OpenTelemetry Collector Contrib"
        let repo: String      // "open-telemetry/opentelemetry-collector-contrib"
        let status: String    // "open source · shipped build not source-audited"
    }

    struct Index: Decodable, Equatable {
        let schema: Int
        /// normalized image ref → assessed digests (hex, no prefix)
        let images: [String: [String]]
        /// normalized image ref → digest → upstream source pin. Optional so an
        /// index.json predating this field still decodes.
        let sources: [String: [String: SourceRef]]?
        /// normalized image ref → caveated upstream project pointer. Optional so
        /// an index.json predating this field still decodes.
        let projects: [String: Project]?
        /// normalized image ref → assessed TAGS, for images pinned by tag (no
        /// digest to key on). Gates a tag-addressed audit page — an additive
        /// sibling to the frozen digest path spec. Optional so an older
        /// index.json still decodes.
        let tagAudits: [String: [String]]?
        /// "<owner>/<repo>/<path>.yaml" → assessed file_sha256 values
        let manifests: [String: [String]]
        /// assessed measured compose_hash values
        let measured: [String]
        /// assessed dstack guest-OS image hashes. Optional so an index.json
        /// predating this field still decodes (decodeIfPresent → missing key →
        /// nil → no OS link).
        let os: [String]?
        /// repo-relative page path → that page's own `## verdict:` line,
        /// verbatim. Optional so an older index.json still decodes.
        ///
        /// A link on its own cannot say what a review FOUND. The published
        /// verdicts range from "PRIVATE at deployed flags" through
        /// "COMPROMISABLE by credentialed operator" to "INCONCLUSIVE — no build
        /// attestation exists"; rendering all of them under one fixed reassuring
        /// subtitle ("source reviewed for plaintext egress") tells a user on a
        /// build with a live CRITICAL exactly what it tells a user on a clean
        /// one. That is the same absence-reads-as-safety failure the plaintext
        /// group caption is written to avoid. Never synthesized here — the
        /// string is the reviewer's own wording.
        let verdicts: [String: String]?
        /// ISO date the index was last regenerated upstream ("updated") —
        /// surfaced as the staleness line. Optional (older index.json).
        var updated: String? = nil
        /// page path → verdict class token the page's verdict line opens with
        /// ("private" / "leaks" / "compromisable" / "qualified-pass" /
        /// "inconclusive"), derived mechanically by the repo's indexer from the
        /// reviewer's own wording. Lets the client badge and color-code without
        /// parsing prose. Optional; an unlisted page renders neutral.
        var verdictClass: [String: String]? = nil
        /// page path → the page's own `### SEVERITY (deployed: …) — title`
        /// finding headings, machine-read by the repo's indexer (never
        /// synthesized). Powers the per-node plaintext-egress rollup. Optional.
        var findings: [String: [Finding]]? = nil
    }

    /// One machine-read finding heading from a published review page. All
    /// fields are the reviewer's own words, extracted (not summarized) by the
    /// repo's indexer.
    struct Finding: Decodable, Equatable {
        /// "critical" | "high" | "medium" | "low" | "info"
        let severity: String
        /// The reviewer's deployed-state for the finding: "on" (live at the
        /// attested config), "off", "armed" (fires on a trigger, e.g. crash) —
        /// nil when the heading carried none (mechanism/structural findings).
        let deployed: String?
        /// The raw heading qualifier, e.g. "deployed: ON, unconditional".
        let qualifier: String?
        let title: String
        /// GitHub anchor of the finding's own heading — deep-links the row to
        /// its evidence (file:line citations) via `<page>#<anchor>`.
        let anchor: String
    }

    /// The five verdict classes the audits repo publishes. Raw values match
    /// index.json exactly; an unknown future class fails to `nil` → neutral
    /// treatment, never a guessed badge.
    enum VerdictClass: String, Equatable {
        case privateReview = "private"
        case leaks
        case compromisable
        case qualifiedPass = "qualified-pass"
        case inconclusive

        /// Display label (badge text).
        var label: String {
            switch self {
            case .privateReview: return "private"
            case .leaks:         return "leaks"
            case .compromisable: return "compromisable"
            case .qualifiedPass: return "qualified pass"
            case .inconclusive:  return "inconclusive"
            }
        }
    }

    /// nil until an index has loaded (this session or from the persisted
    /// snapshot); all link accessors return nil until then — fail closed.
    private(set) var index: Index?

    /// When the CONTENT currently in `index` was fetched from the network —
    /// persisted beside the snapshot, so an offline launch knows the age of
    /// what it's rendering. nil = unknown (treated as stale, never as fresh).
    private(set) var loadedAt: Date?

    @ObservationIgnored private var lastLoad: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private static let persistKey = "ai.teemoon.auditIndex.json"
    private static let persistDateKey = "ai.teemoon.auditIndex.fetchedAt"
    private let ttl: TimeInterval = 3600

    /// Decode + validate. `schema` is a compatibility promise: this reader
    /// implements schema 1, and the repo evolves it only by ADDITIVE optional
    /// keys — so an unknown key is fine, but a different schema NUMBER means
    /// the layout changed in a way this code predates. Fail closed to "no
    /// index" (no links) rather than render links from a layout we can't read.
    nonisolated static func decodeIndex(_ data: Data) -> Index? {
        guard let idx = try? JSONDecoder().decode(Index.self, from: data),
              idx.schema == 1 else { return nil }
        return idx
    }

    /// Test seam: inject a fixed index (skips network + persistence).
    init(fixedIndex: Index? = nil) {
        if let fixedIndex {
            index = fixedIndex
            lastLoad = .distantFuture
        }
    }

    /// Loads/refreshes the index (bounded, failure-tolerant). Persisted
    /// snapshot seeds offline launches; a fetch failure keeps whatever we had.
    func loadIfNeeded() {
        if ConfidentialSession.isRunningInPreview { return }
        if let last = lastLoad, Date().timeIntervalSince(last) < ttl, index != nil { return }
        if index == nil,
           let saved = UserDefaults.standard.data(forKey: Self.persistKey),
           let parsed = Self.decodeIndex(saved) {
            index = parsed
            loadedAt = UserDefaults.standard.object(forKey: Self.persistDateKey) as? Date
        }
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard let (data, response) = try? await URLSession.shared.data(from: Self.indexURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = Self.decodeIndex(data) else {
                logger.info("[audits] index unavailable — links stay \(self?.index == nil ? "hidden" : "cached", privacy: .public)")
                return
            }
            let now = Date()
            self?.index = parsed
            self?.lastLoad = now
            self?.loadedAt = now
            UserDefaults.standard.set(data, forKey: Self.persistKey)
            UserDefaults.standard.set(now, forKey: Self.persistDateKey)
            logger.info("[audits] index loaded — \(parsed.images.count) image ref(s), \(parsed.manifests.count) manifest(s)")
        }
    }

    // MARK: gated link accessors (nil = not assessed → no link, never overclaim)

    /// Audit page for an image build. `image` as it appears in the attested
    /// compose (tag allowed); `digest` hex with or without "sha256:".
    func imageAuditURL(image: String, digest: String) -> URL? {
        guard let index else { return nil }
        let ref = Self.normalizedRef(image)
        let hex = Self.bareDigest(digest)
        guard index.images[ref]?.contains(hex) == true else { return nil }
        return URL(string: "\(Self.webBase)/images/\(ref)/sha256-\(hex).md")
    }

    /// `imageAuditURL` with the ENCLAVE SCOPE GATE in front of it.
    ///
    /// The teemoonai/audits review covers an image as deployed in the MODEL
    /// compose, which is the plaintext-side, in-scope enclave. The identical
    /// digest also runs gateway-side over ciphertext (datadog/agent and
    /// otel-collector-contrib do this today), and that deployment is NOT what
    /// the review assessed. Surfacing the same link there would overclaim.
    ///
    /// `inScope` is a parameter rather than something read from ambient state so
    /// the gate stays a pure function — which is the whole reason it is testable.
    ///
    /// THIS USED TO BE A STATIC ON `TrustLadderView`, which is inside
    /// `#if os(iOS)`. Nothing about a scope gate is iOS-specific: it takes an
    /// index and three values and returns a URL. Living on the view meant the
    /// macOS build could not see it, and AuditLinkScopingTests — the regression
    /// guard for a real leak — could not run there either. Logic that a platform
    /// guard hides is logic that platform never checks.
    func scopedImageAuditURL(inScope: Bool, image: String, digestFull: String?) -> URL? {
        guard inScope, let digestFull else { return nil }
        return imageAuditURL(image: image, digest: digestFull)
    }

    /// Pinned upstream source for a running image digest — repo + commit the
    /// build was compiled from (per its audit). Title names the upstream repo so
    /// a third-party engine reads honestly (e.g. `sgl-project/sglang @ 8805f4c`).
    /// nil when not recorded → no link, never a guess.
    func imageSourceLink(image: String, digest: String) -> (title: String, url: URL)? {
        guard let index else { return nil }
        let ref = Self.normalizedRef(image)
        let hex = Self.bareDigest(digest)
        guard let s = index.sources?[ref]?[hex],
              let url = URL(string: "https://github.com/\(s.repo)/tree/\(s.commit)") else { return nil }
        return ("\(s.repo) @ \(s.commit.prefix(7))", url)
    }

    /// Caveated upstream pointer for a third-party image — a link to the
    /// project it comes from, plus the audit's honest `status` caveat. This is
    /// NOT `imageSourceLink`: there is no digest→commit binding here, so it must
    /// never render as a verified source. The caller shows `status` so the row
    /// reads exactly as strong as the evidence is (open-source-but-unreviewed,
    /// proprietary, or tag-pinned-and-driftable — never "verified"). Keyed by
    /// image ref, so it resolves for a tag-pinned image with no digest.
    /// nil when not recorded → no link, never a guess.
    func projectPointer(image: String) -> (name: String, repo: String, status: String, url: URL)? {
        guard let index else { return nil }
        let ref = Self.normalizedRef(image)
        guard let p = index.projects?[ref],
              let url = URL(string: "https://github.com/\(p.repo)") else { return nil }
        return (p.name, p.repo, p.status, url)
    }

    /// Audit page for a TAG-pinned image, which has no digest to key on. An
    /// additive sibling to the frozen digest path spec: `images/<ref>/tag-<tag>.md`,
    /// gated by `tagAudits` so it only ever resolves for an assessed tag. The
    /// review it lands on is config-level and says so — the running bytes under
    /// a tag can still drift. nil when not recorded → no link.
    func tagAuditURL(image: String, tag: String) -> URL? {
        guard let index else { return nil }
        let ref = Self.normalizedRef(image)
        guard index.tagAudits?[ref]?.contains(tag) == true else { return nil }
        return URL(string: "\(Self.webBase)/images/\(ref)/tag-\(tag).md")
    }

    /// Audit page for an inner-stack manifest version, keyed by the action
    /// log's repo-relative path and file_sha256.
    func manifestAuditURL(path: String, fileSHA256: String) -> URL? {
        guard let index else { return nil }
        let key = "\(ProvenanceService.modelComposeRepo)/\(path)"
        let hex = Self.bareDigest(fileSHA256)
        guard index.manifests[key]?.contains(hex) == true else { return nil }
        return URL(string: "\(Self.webBase)/manifests/\(Self.stripYAMLExtension(key))/sha256-\(hex).md")
    }

    /// Audit page for a hardware-measured compose (gateway or node harness).
    func measuredAuditURL(composeHash: String) -> URL? {
        guard let index else { return nil }
        let hex = Self.bareDigest(composeHash)
        guard index.measured.contains(hex) else { return nil }
        return URL(string: "\(Self.webBase)/manifests/measured/sha256-\(hex).md")
    }

    /// Audit page for the dstack guest-OS image measured into the boot.
    func osAuditURL(osImageHash: String) -> URL? {
        guard let index else { return nil }
        let hex = Self.bareDigest(osImageHash)
        guard index.os?.contains(hex) == true else { return nil }
        return URL(string: "\(Self.webBase)/os/sha256-\(hex).md")
    }

    /// The reviewer's own verdict line for the page an audit URL points at, or
    /// nil when the index records none. Looked up by stripping `webBase`, so it
    /// works for every accessor above without threading a second return value
    /// through each one.
    ///
    /// Callers MUST fail closed on nil: show neutral copy, never copy that
    /// implies the review came back clean. "A page exists" and "the review found
    /// nothing" are different facts, and only this lookup distinguishes them.
    func verdict(for url: URL) -> String? {
        guard let path = Self.pagePath(for: url) else { return nil }
        return index?.verdicts?[path]
    }

    /// The verdict CLASS for the page an audit URL points at — the
    /// machine-readable counterpart of `verdict(for:)`, from `verdictClass`.
    /// nil when unrecorded, or when the recorded token is one this build
    /// doesn't know (a future class must render neutral, never a guessed
    /// badge). Same fail-closed rule as the verdict itself.
    func verdictClass(for url: URL) -> VerdictClass? {
        guard let path = Self.pagePath(for: url),
              let raw = index?.verdictClass?[path] else { return nil }
        return VerdictClass(rawValue: raw)
    }

    /// The machine-read findings of the page an audit URL points at, in the
    /// page's own order. Empty when the index records none — which means "the
    /// page's findings weren't machine-readable", NOT "the review found
    /// nothing"; the verdict line remains the page's own summary either way.
    func findings(for url: URL) -> [Finding] {
        guard let path = Self.pagePath(for: url) else { return [] }
        return index?.findings?[path] ?? []
    }

    /// Repo-relative page path for a URL under `webBase` (the key every
    /// per-page index map uses). nil for foreign URLs — never matched.
    static func pagePath(for url: URL) -> String? {
        let prefix = webBase + "/"
        let s = url.absoluteString
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }

    // MARK: the frozen path spec (pure; mirrors the repo README exactly)

    /// docker-ref normalization: strip any tag (the digest is the identity),
    /// qualify bare Docker Hub refs with "docker.io/", official single-name
    /// images with "library/". Registries are recognized by a dot or port in
    /// the first path component.
    nonisolated static func normalizedRef(_ image: String) -> String {
        var ref = image
        // strip a trailing ":tag" — only when the colon is in the LAST path
        // component (a colon in the first component would be a registry port)
        if let colon = ref.lastIndex(of: ":"),
           !ref[colon...].contains("/") {
            ref = String(ref[..<colon])
        }
        let first = ref.split(separator: "/").first.map(String.init) ?? ref
        let hasRegistry = first.contains(".") || first.contains(":")
        if !hasRegistry {
            ref = ref.contains("/") ? "docker.io/\(ref)" : "docker.io/library/\(ref)"
        }
        return ref
    }

    nonisolated static func bareDigest(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }

    nonisolated static func stripYAMLExtension(_ path: String) -> String {
        path.hasSuffix(".yaml") ? String(path.dropLast(".yaml".count)) : path
    }
}
