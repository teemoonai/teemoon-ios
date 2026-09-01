//
//  EnclaveGrouping.swift
//  teemoon
//
//  Running images grouped by the enclave whose quote measures them.
//  The view draws the groups; this decides membership, order, and which
//  audit links are in scope. See EnclaveGroupingTests.
//

import Foundation

@MainActor
struct EnclaveGrouping {
    var attestation: AttestationRecord?
    var imageProvenance: ProvenanceService.ManifestProvenance?
    var modelLayerManifest: String?
    var modelLayerVerification: ModelLayerVerification?
    var audit: AuditIndex = .shared

    var exposure: PlaintextExposure {
        PlaintextExposure.analyze(
            innerComposeYAML: modelLayerManifest,
            outerComposeYAML: attestation?.gpuNodeComposeManifest)
    }

    /// Model enclave first (primary — key bound + plaintext), then gateway.
    /// Empty when there's no provenance data yet.
    func groups() -> [EnclaveGroup] {
        let (verified, thirdParty) = provenanceLists
        let failures = provenanceFailures
        guard !verified.isEmpty || !failures.isEmpty || attestation?.gpuNodeComposeHash != nil else {
            return []
        }
        var groups: [EnclaveGroup] = []
        if let model = group(
            host: "model", role: "model enclave", primary: true,
            mrConfig: attestation?.gpuNodeComposeHash,
            quoteVerified: attestation?.modelQuoteVerification?.isVerified,
            verified: verified, thirdParty: thirdParty, failures: failures,
            includeLocalEngine: true,
            exposure: exposure) {
            groups.append(model)
        }
        if let gateway = group(
            host: "gateway", role: "gateway enclave", primary: false,
            mrConfig: attestation?.composeHash,
            quoteVerified: attestation?.quoteVerification?.isVerified,
            verified: verified, thirdParty: thirdParty, failures: failures,
            includeLocalEngine: false, exposure: nil) {
            groups.append(gateway)
        }
        return groups
    }

    var provenanceLists: (verified: [ProvenanceService.ImageRef], thirdParty: [ProvenanceService.ImageRef]) {
        switch imageProvenance {
        case .allVerified(let v, let t):   return (v, t)
        case .incomplete(let v, _, let t): return (v, t)
        case nil:                          return ([], [])
        }
    }

    var provenanceFailures: [ProvenanceService.Failure] {
        if case .incomplete(_, let failures, _) = imageProvenance { return failures }
        return []
    }

    /// Empty-host images fall to the model group so they're shown once, not dropped.
    static func belongs(_ r: ProvenanceService.ImageRef, host: String, primary: Bool) -> Bool {
        r.hosts.contains(host) || (r.hosts.isEmpty && primary)
    }

    func group(
        host: String, role: String, primary: Bool,
        mrConfig: String?, quoteVerified: Bool?,
        verified: [ProvenanceService.ImageRef], thirdParty: [ProvenanceService.ImageRef],
        failures: [ProvenanceService.Failure],
        includeLocalEngine: Bool,
        exposure: PlaintextExposure?
    ) -> EnclaveGroup? {
        func belongs(_ r: ProvenanceService.ImageRef) -> Bool {
            Self.belongs(r, host: host, primary: primary)
        }
        var entries: [ImageEntry] = failures.filter { belongs($0.ref) }.map(Self.unverifiedEntry)
        if includeLocalEngine, let engine = localEngineEntry() {
            entries.append(engine)
        }
        entries += verified.filter(belongs).map(Self.registryEntry)
        entries += thirdParty.filter(belongs).map(Self.thirdPartyEntry)
        // In-enclave build (`:local`) is `FROM <base>@sha256:…`; drop the
        // standalone base row so its audit stays on the engine row.
        if includeLocalEngine,
           entries.contains(where: { $0.kind == .local }),
           let base = modelLayerManifest.flatMap({
               ProvenanceService.dockerfileBaseImage(inManifest: $0) }) {
            entries.removeAll { $0.kind != .local && $0.digestFull == "sha256:\(base.digest)" }
        }
        // Tag-pinned images come only from the hash-verified inner compose.
        if exposure != nil, let inner = modelLayerManifest {
            entries += ProvenanceService.tagPinnedImageRefs(inManifest: inner)
                .map(Self.tagPinnedEntry)
        }
        // Image audits are model-enclave only: the same digest on the gateway
        // is a different deployment the review does not cover.
        for i in entries.indices where entries[i].kind != .local {
            entries[i].auditURL = audit.scopedImageAuditURL(
                inScope: exposure != nil,
                image: entries[i].name, digestFull: entries[i].digestFull)
            if exposure != nil, entries[i].auditURL == nil,
               entries[i].kind == .tagPinned, let tag = entries[i].tag {
                entries[i].auditURL = audit.tagAuditURL(image: entries[i].name, tag: tag)
            }
            if exposure != nil, let df = entries[i].digestFull,
               let src = audit.imageSourceLink(image: entries[i].name, digest: df) {
                entries[i].links.append(RunLink(title: src.title, url: src.url.absoluteString))
            }
            if exposure != nil,
               (entries[i].kind == .thirdParty || entries[i].kind == .tagPinned),
               let p = audit.projectPointer(image: entries[i].name) {
                entries[i].projectPointer = ProjectLink(
                    name: p.name, repo: p.repo, status: p.status, url: p.url)
            }
        }
        if let exposure {
            for i in entries.indices {
                entries[i].plaintextRole = exposure.role(forImage: entries[i].name)
            }
            if exposure.touchers.contains(where: { $0.role == .modelServer }),
               !entries.contains(where: { $0.plaintextRole == .modelServer }),
               let i = entries.firstIndex(where: { $0.kind == .local }) {
                entries[i].plaintextRole = .modelServer
            }
            for i in entries.indices where entries[i].plaintextRole == nil {
                entries[i].capability = exposure.capability(forImage: entries[i].name)
            }
            entries = entries.enumerated()
                .sorted { (Self.band($0.element), $0.offset) < (Self.band($1.element), $1.offset) }
                .map(\.element)
            if let inner = modelLayerManifest {
                for i in entries.indices {
                    guard let touchRole = entries[i].plaintextRole else { continue }
                    let link = touchRole == .modelServer ? modelComposeYAMLLink() : nil
                    entries[i].configLines = MeasuredConfig
                        .forRole(touchRole, innerComposeYAML: inner, yamlLink: link)?
                        .lines ?? []
                }
            }
        }
        if host == "model", let osHash = attestation?.modelOSImageHash, !osHash.isEmpty {
            entries.insert(guestOSEntry(osHash: osHash), at: 0)
        }
        for i in entries.indices {
            let tiered = entries[i].plaintextRole != nil || entries[i].capability != nil
                || entries[i].kind == .guestOS
            if !tiered, let url = entries[i].auditURL {
                let cls = audit.verdictClass(for: url)
                entries[i].links.append(RunLink(
                    title: cls.map { "audit · \($0.label)" } ?? "audit",
                    url: url.absoluteString))
            }
        }
        guard !entries.isEmpty || mrConfig != nil else { return nil }
        let measurementCaption: String? = (exposure != nil)
            ? attestation?.gpuNodeComposeManifest
                .flatMap { MeasuredConfig.allowedEnvsCaption(outerManifest: $0) }
            : nil
        let configAuditURL = mrConfig.flatMap { audit.measuredAuditURL(composeHash: $0) }
        let recipeCard: EnclaveGroup.RecipeCard?
        if exposure != nil {
            let inner = modelLayerManifest
            for i in entries.indices {
                entries[i].isRecipe = isRecipeImage(
                    digestFull: entries[i].digestFull,
                    tagRef: entries[i].kind == .tagPinned
                        ? (entries[i].tag.map { "\(entries[i].name):\($0)" } ?? entries[i].name)
                        : nil,
                    isLocalEngine: entries[i].kind == .local,
                    isGuestOS: entries[i].kind == .guestOS,
                    innerComposeYAML: inner)
            }
            recipeCard = EnclaveGroup.RecipeCard(
                fileSHA: attestation?.modelFileHash,
                yamlLink: modelComposeYAMLLink(),
                verification: modelLayerVerification,
                auditURL: attestation?.modelComposePath.flatMap { p in
                    attestation?.modelFileHash.flatMap {
                        audit.manifestAuditURL(path: p, fileSHA256: $0)
                    }
                })
        } else {
            recipeCard = nil
        }
        var egress: [NodeFinding] = []
        if exposure != nil {
            var pages: [(url: URL, source: String)] = entries.compactMap { e in
                guard let u = e.auditURL else { return nil }
                if e.kind == .guestOS { return (u, "guest OS") }
                let short = e.name.split(separator: "/").last.map(String.init) ?? e.name
                let suffix = e.digestFull.map { " @\(AuditIndex.bareDigest($0).prefix(8))" } ?? ""
                return (u, short + suffix)
            }
            if let u = recipeCard?.auditURL { pages.append((u, "recipe")) }
            if let u = configAuditURL { pages.append((u, "deployment config")) }
            var seen = Set<String>()
            for page in pages {
                guard let path = AuditIndex.pagePath(for: page.url),
                      seen.insert(path).inserted else { continue }
                for f in audit.findings(for: page.url) {
                    egress.append(NodeFinding(
                        id: "\(path)#\(f.anchor)",
                        severity: f.severity, deployed: f.deployed,
                        qualifier: f.qualifier, title: f.title,
                        source: page.source,
                        url: URL(string: "\(page.url.absoluteString)#\(f.anchor)") ?? page.url))
                }
            }
        }
        return EnclaveGroup(
            id: role, role: role, primary: primary,
            binding: "the hardware seals a fingerprint (mr_config) of this enclave's compose file into its quote — proof it booted exactly the images below, and the operator can't swap in anything else without changing that fingerprint.",
            deployment: primary ? attestation?.deploymentCaption : nil,
            mrConfig: mrConfig, quoteVerified: quoteVerified, images: entries,
            plaintextCaption: exposure?.groupCaption,
            measurementCaption: measurementCaption,
            configAuditURL: configAuditURL,
            recipe: recipeCard,
            egressFindings: egress)
    }

    /// Unverified first, then plaintext touchers, then capability tiers. Stable within a band.
    static func band(_ e: ImageEntry) -> Int {
        if e.kind == .unverified { return 0 }
        switch e.plaintextRole {
        case .e2eeTerminator: return 1
        case .modelServer:    return 2
        case nil:             break
        }
        switch e.capability {
        case .processAccess:   return 3
        case .devicePrivilege: return 4
        case .logAccess:       return 5
        case nil:              return 6
        }
    }

    func modelComposeYAMLLink() -> RunLink? {
        guard let path = attestation?.modelComposePath,
              let commit = attestation?.modelComposeCommit else { return nil }
        let url = "https://github.com/\(ProvenanceService.modelComposeRepo)/blob/\(commit)/\(path)"
        return RunLink(title: "yaml @ \(commit.prefix(7))", url: url)
    }

    func localEngineEntry() -> ImageEntry? {
        guard let path = attestation?.modelComposePath,
              let commit = attestation?.modelComposeCommit else { return nil }
        guard let inner = modelLayerManifest,
              ProvenanceService.hasInEnclaveEngineBuild(inManifest: inner) else { return nil }
        let base = ProvenanceService.dockerfileBaseImage(inManifest: inner)
        let name = base?.image ?? (path.split(separator: "/").last.map(String.init) ?? path)
        let composeURL = "https://github.com/\(ProvenanceService.modelComposeRepo)/blob/\(commit)/\(path)"
        let versionLabel = (attestation?.modelComposeTag.map { "\($0) → \(commit.prefix(7))" }) ?? String(commit.prefix(7))
        var links: [RunLink] = []
        if let b = base, let src = audit.imageSourceLink(image: b.image, digest: b.digest) {
            links.append(RunLink(title: src.title, url: src.url.absoluteString))
        }
        links.append(RunLink(title: "\(versionLabel) · patch", url: composeURL))
        let auditURL = base.flatMap { audit.imageAuditURL(image: $0.image, digest: $0.digest) }
        let note = base.map { _ in
            "the running engine — this base image built in-enclave with the compose's visible patch (the yaml above). No registry digest of its own; its source is the base at the pinned commit plus that patch."
        } ?? "built in-enclave from the attested compose (pinned base + visible patch) — no registry digest."
        return ImageEntry(
            id: "local·\(name)", name: name, kind: .local, digest: nil,
            note: note, links: links, auditURL: auditURL)
    }

    static func registryEntry(_ r: ProvenanceService.ImageRef) -> ImageEntry {
        var links: [RunLink] = []
        if let repo = r.sourceRepo, let commit = r.sourceCommit {
            let tag = r.sourceRef?
                .replacingOccurrences(of: "refs/tags/", with: "")
                .replacingOccurrences(of: "refs/heads/", with: "")
            let label = tag.map { "\($0) → \(commit.prefix(7))" } ?? String(commit.prefix(7))
            links.append(RunLink(title: label, url: "\(repo)/tree/\(commit)"))
        }
        links.append(RunLink(title: "sigstore", url: "https://search.sigstore.dev/?hash=\(r.digest)"))
        return ImageEntry(
            id: "reg·\(r.image)·\(r.digest.prefix(8))", name: r.image, kind: .registry,
            digest: "sha256:\(r.digest.prefix(12))…", digestFull: "sha256:\(r.digest)", note: nil, links: links)
    }

    static func unverifiedEntry(_ f: ProvenanceService.Failure) -> ImageEntry {
        let why = f.reason.failureReason ?? "could not be traced to a published near.ai build"
        var links = [RunLink(title: "sigstore", url: "https://search.sigstore.dev/?hash=\(f.ref.digest)")]
        if let repo = ProvenanceService.githubRepo(forImage: f.ref.image) {
            links.insert(RunLink(
                title: "attestation api",
                url: "https://api.github.com/repos/\(repo)/attestations/sha256:\(f.ref.digest)"), at: 0)
        }
        return ImageEntry(
            id: "unv·\(f.ref.image)·\(f.ref.digest.prefix(8))", name: f.ref.image, kind: .unverified,
            digest: "sha256:\(f.ref.digest.prefix(12))…", digestFull: "sha256:\(f.ref.digest)",
            note: "couldn\u{2019}t verify: \(why).",
            links: links)
    }

    static func thirdPartyEntry(_ r: ProvenanceService.ImageRef) -> ImageEntry {
        ImageEntry(
            id: "3p·\(r.image)·\(r.digest.prefix(8))", name: r.image, kind: .thirdParty,
            digest: "sha256:\(r.digest.prefix(12))…", digestFull: "sha256:\(r.digest)",
            note: "digest-pinned by the attested manifest — no first-party build attestation.",
            links: [])
    }

    static func tagPinnedEntry(_ ref: String) -> ImageEntry {
        var name = ref
        var tag: String? = nil
        if let colon = ref.lastIndex(of: ":"),
           !ref[ref.index(after: colon)...].contains("/") {
            name = String(ref[..<colon])
            tag = String(ref[ref.index(after: colon)...])
        }
        return ImageEntry(
            id: "tag·\(ref)", name: name, kind: .tagPinned,
            tag: tag,
            note: "the action log pins this image\u{2019}s tag, not its contents — the registry can serve different bytes under the same tag, so what\u{2019}s actually running can drift with no trace in this attestation chain. not verifiable on this device.")
    }

    func guestOSEntry(osHash: String) -> ImageEntry {
        ImageEntry(
            id: "os·\(osHash.prefix(8))", name: "nearai/private-ml-sdk", kind: .guestOS,
            digest: "os_image sha256:\(osHash.prefix(12))…", digestFull: "sha256:\(osHash)",
            note: "the confidential-VM guest image (kernel + rootfs) this enclave boots on — near.ai\u{2019}s private-ml-sdk build, measured into the quote as os_image_hash.",
            auditURL: audit.osAuditURL(osImageHash: osHash))
    }
}
