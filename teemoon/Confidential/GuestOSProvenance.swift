//
//  GuestOSProvenance.swift
//  teemoon
//
//  Maps a model node's measured guest-OS hash (`os_image_hash`) to the exact
//  published `nearai/private-ml-sdk` release it was proven to come from.
//
//  Unlike container images — whose digest→commit provenance the app resolves
//  live via GitHub build attestations — the guest OS has no such attestation:
//  `os_image_hash` is a boot measurement, not an OCI digest. The only way to
//  tie it to source is the reproduce-and-match check documented in
//  To reproduce: download a release, read the `digest.txt`
//  it ships (which IS the `os_image_hash`), and compare.
//
//  So this is a **small, verified, fail-closed** table: an entry exists only
//  for a hash whose match to a published release was actually confirmed. An
//  unknown hash yields no source link (never a looks-like-proof link to an
//  unpinned repo). When near.ai ships a new guest image, the row shows the new
//  hash with no source link until someone re-runs the match and adds it here.
//
import Foundation

enum GuestOSProvenance {

    /// A published private-ml-sdk release a measured `os_image_hash` maps to.
    struct Source {
        /// Release tag, e.g. `v0.5.5`.
        let tag: String
        /// Full git revision the release was built from (`metadata.json`
        /// `git_revision` / `reproduce.sh` checkout).
        let commit: String
        /// The release page — carries the prebuilt image (whose `digest.txt`
        /// equals this hash), `reproduce.sh`, and the commit reference, so a
        /// user can re-run the match themselves.
        let releaseURL: String
    }

    /// Verified `os_image_hash` (bare sha256 hex) → published release.
    ///
    /// Each entry was confirmed by downloading the release's prod image and
    /// matching its `digest.txt` to this exact hash (2026-07-20). Add a row
    /// only after actually running that match — never by assumption.
    static let bySHA: [String: Source] = [
        // GLM-5.1 fleet model node, live 2026-07-20.
        "9b69bb1698bacbb6985409a2c272bcb892e09cdcea63d5399c6768b67d3ff677":
            Source(tag: "v0.5.5",
                   commit: "25c25025c556ab2f797eeda3bab433f38a8ffb7a",
                   releaseURL: "https://github.com/nearai/private-ml-sdk/releases/tag/v0.5.5"),
    ]

    /// The verified source for a measured guest-OS hash, or nil (fail-closed).
    /// Accepts a bare hex or a `sha256:`-prefixed value, case-insensitively.
    static func source(forOSImageHash hash: String) -> Source? {
        let bare = hash
            .replacingOccurrences(of: "sha256:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return bySHA[bare]
    }
}
