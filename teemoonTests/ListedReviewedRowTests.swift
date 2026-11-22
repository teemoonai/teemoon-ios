//
//  ListedReviewedRowTests.swift
//  teemoonTests
//
//  Audit 1.1.1 A5: every enclave near.ai lists for a model holds the key a sealed request goes to, but the trust
//  sheet's "reviewed" row (ModelNodeAudit) described only the READ enclave's compose and what its host runs. Live
//  glm-5.3-flash lists three enclaves under one key on three composes; one host (gpu13) also runs LEAKS-conditional
//  software and a private third-party image no one can review. Decided 2026-11-19: each listed enclave is
//  scoped by everything its host runs, with an off-path LEAKS page not LEAKS for this chat (expected.json chat_path),
//  and anything unreviewable reads "not everything here has been reviewed yet". The row is the worst across them
//  all: leaks > incomplete > reviewedWithCaveat > reviewed. Display only: the send gate never reads the audits index.
//

import Foundation
import Testing
@testable import teemoon

@Suite("The reviewed row covers every listed enclave (A5)")
@MainActor
struct ListedReviewedRowTests {
    static let engine = String(repeating: "cd", count: 32)
    static let os = String(repeating: "05", count: 32)
    static let composeA = String(repeating: "a1", count: 32)
    static let composeB = String(repeating: "b2", count: 32)
    static let unreviewedCompose = String(repeating: "ee", count: 32)
    static let glmSHA = String(repeating: "11", count: 32)
    static let smallSHA = String(repeating: "22", count: 32)
    /// A revision the audits have no page for: what a private third-party image's revision looks like in the index.
    static let sageSHA = String(repeating: "33", count: 32)
    static let privSHA = String(repeating: "44", count: 32)
    static let privFile = "prod/GLM-5.3-Flash-private.yaml"
    static let glmFile = "prod/GLM-5.3-Flash.yaml"
    static let smallFile = "prod/small-models.yaml"
    static let leakSentence = "the FLUX service logs every prompt."

    static func page(_ url: URL) -> String { String(url.absoluteString.dropFirst(AuditIndex.webBase.count + 1)) }

    static func audit() throws -> AuditIndex {
        var index = AuditIndex.Index(
            schema: 1, images: ["docker.io/nearaidev/engine": [engine]], sources: nil, projects: nil, tagAudits: nil,
            manifests: ["\(ProvenanceService.modelComposeRepo)/\(glmFile)": [glmSHA],
                        "\(ProvenanceService.modelComposeRepo)/\(smallFile)": [smallSHA],
                        "\(ProvenanceService.modelComposeRepo)/\(privFile)": [privSHA]],
            measured: [composeA, composeB], os: [os], verdicts: nil)
        let bare = AuditIndex(fixedIndex: index)
        let engineURL = try #require(bare.imageAuditURL(image: "nearaidev/engine", digest: engine))
        let small = try #require(bare.manifestAuditURL(path: smallFile, fileSHA256: smallSHA))
        var classes = [page(engineURL): "private",
                       page(try #require(bare.manifestAuditURL(path: glmFile, fileSHA256: glmSHA))): "qualified-pass",
                       page(try #require(bare.osAuditURL(osImageHash: os))): "qualified-pass",
                       page(small): "leaks",
                       page(try #require(bare.manifestAuditURL(path: privFile, fileSHA256: privSHA))): "private"]
        for c in [composeA, composeB] { classes[page(try #require(bare.measuredAuditURL(composeHash: c)))] = "qualified-pass" }
        index.verdictClass = classes
        index.exposure = [page(small): .init(summary: leakSentence, scope_kind: "recipe", services: ["model-flux"])]
        return AuditIndex(fixedIndex: index, loadedAt: Date())
    }

    /// The read enclave: one plaintext toucher with a private review. Reviewed on its own.
    static func readGroup(_ audit: AuditIndex) throws -> EnclaveGroup {
        var row = ImageEntry(id: "engine", name: "nearaidev/engine", kind: .registry)
        row.plaintextRole = .modelServer
        row.auditURL = try #require(audit.imageAuditURL(image: "nearaidev/engine", digest: engine))
        return EnclaveGroup(id: "model", role: "model enclave", primary: true, binding: "", mrConfig: nil,
                            quoteVerified: true, images: [row])
    }

    static func enclave(_ compose: String) -> ModelCandidates.Enclave {
        ModelCandidates.Enclave(instanceID: "i-\(compose.prefix(4))", composeHash: compose, appID: "app", keyProviderID: nil,
                                mrKMS: nil, result: .clean, osImageHash: os)
    }

    static func source(_ file: String, _ sha: String) -> ActionLogReading.Source { .init(commit: "c0ffee", file: file, fileSHA256: sha) }

    static func row(_ service: String, _ file: String, _ sha: String) -> TrustScope.RunningRow {
        .init(service: .init(service: service, source: source(file, sha), tag: nil, since: nil), outcome: .verified)
    }

    /// A listed host serving glm on its own path; `also` runs beside it; `path` adds hops.
    static func scope(also: [TrustScope.RunningRow] = [], onPath: [TrustScope.RunningRow] = []) -> TrustScope {
        let glm = [row("nginx", glmFile, glmSHA), row("proxy-glm53", glmFile, glmSHA), row("model-glm53", glmFile, glmSHA)]
        let hops = (glm + onPath).map { ChatPath.Hop(service: $0.service.service, source: $0.service.source, image: nil) }
        return TrustScope(binding: .bound, boot: .matches, running: glm + onPath + also, chatPath: .path(hops))
    }

    static func row(_ enclaves: [ModelCandidates.Enclave]?, _ scopes: [TrustScope]?, listFailed: Bool = false)
        throws -> (state: EverydayAuditState?, leaksExposure: String?) {
        let audit = try audit()
        return ModelNodeAudit.state(groups: [try readGroup(audit)], hasAttestation: true,
                                    listed: enclaves.map { ModelCandidates.Listed(enclaves: $0) }, listFailed: listFailed,
                                    listedScopes: scopes, audit: audit)
    }

    @Test func theReadEnclaveAloneIsReviewed() throws {
        #expect(try Self.row(nil, nil).state == .reviewed, "precondition: no list, the read enclave's row as before")
    }

    @Test func everyListedEnclaveReviewedIsReviewed() throws {
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.composeB)], [Self.scope(), Self.scope()])
        #expect(r.state == .reviewed)
        #expect(r.leaksExposure == nil)
    }

    @Test func oneListedOnAnUnreviewedComposeIsIncomplete() throws {
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.unreviewedCompose)], [Self.scope(), Self.scope()])
        #expect(r.state == .incomplete, "a key holder on a compose the audits never read is not reviewed")
    }

    @Test func oneListedWhoseHostRunsAnOnPathLeakIsLeaks() throws {
        let flux = Self.row("model-flux", Self.smallFile, Self.smallSHA)
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.composeB)], [Self.scope(), Self.scope(onPath: [flux])])
        #expect(r.state == .leaks)
        #expect(r.leaksExposure == Self.leakSentence, "the reviewer's own sentence, from the listed enclave's page")
    }

    /// Audit 1.1.1: "private" is the index's BEST class token (no plaintext copy leaves at the deployed flags), not a
    /// private image. An on-path revision with it never demotes the row.
    @Test func anOnPathPrivateReviewKeepsTheRowReviewed() throws {
        let priv = Self.row("model-glm53-private", Self.privFile, Self.privSHA)
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.composeB)], [Self.scope(), Self.scope(onPath: [priv])])
        #expect(r.state == .reviewed)
        #expect(AuditIndex.VerdictClass(rawValue: "private") == .privateReview, "the index token, not an English word")
    }

    @Test func anOffPathLeakOnAListedHostIsNotLeaks() throws {
        let flux = Self.row("model-flux", Self.smallFile, Self.smallSHA)
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.composeB)], [Self.scope(), Self.scope(also: [flux])])
        #expect(r.state == .reviewed, "expected.json chat_path: a LEAKS page whose services miss the path is not this chat's")
    }

    @Test func aLeakOnAListedHostWithNoResolvedPathCounts() throws {
        let flux = Self.row("model-flux", Self.smallFile, Self.smallSHA)
        var unsure = Self.scope(also: [flux])
        unsure.chatPath = .ambiguous("no server_name matches")
        let r = try Self.row([Self.enclave(Self.composeA)], [unsure])
        #expect(r.state == .leaks, "ambiguous counts every LEAKS page on the CVM")
    }

    @Test func anUnreviewablePrivateImageOnAListedHostIsIncomplete() throws {
        let sage = Self.row("sage", Self.smallFile, Self.sageSHA)
        let r = try Self.row([Self.enclave(Self.composeA), Self.enclave(Self.composeB)], [Self.scope(), Self.scope(also: [sage])])
        #expect(r.state == .incomplete, "whole host: a service off the path with no review still runs beside the key")
    }

    @Test func listedInputsPendingAreNotReviewed() throws {
        let both = [Self.enclave(Self.composeA), Self.enclave(Self.composeB)]
        #expect(try Self.row(both, nil).state == .incomplete, "trust scopes not in yet")
        #expect(try Self.row(both, [Self.scope()]).state == .incomplete, "one enclave's scope missing")
        #expect(try Self.row(nil, nil, listFailed: true).state == .incomplete, "a list that failed names no holder")
    }

    @Test func aListedLogTeemoonCouldNotReadIsNotReviewed() throws {
        let r = try Self.row([Self.enclave(Self.composeA)], [TrustScope(binding: .notBound, boot: .absent)])
        #expect(r.state == .incomplete, "no bound log: what the host runs is unknown")
    }
}
