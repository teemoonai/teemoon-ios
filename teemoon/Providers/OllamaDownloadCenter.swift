//
//  OllamaDownloadCenter.swift
//  teemoon
//
//  App-level owner of in-flight Ollama model pulls, so a download survives
//  leaving the download sheet AND survives the app being backgrounded. The pull
//  itself runs on the SERVER (Ollama), so teemoon only streams progress — and iOS
//  suspends that stream when backgrounded, which surfaces as "network connection
//  was lost". Because Ollama's layers are resumable, the fix is to treat a dropped
//  stream as transient and RE-ATTACH (re-issue the pull, which resumes), rather
//  than failing. A global banner (DownloadBanner) observes this so the user can
//  keep using teemoon and get an in-app "ready" notice when it finishes.
//

import SwiftUI

@MainActor
@Observable
final class OllamaDownloadCenter {

    struct Download: Identifiable, Equatable {
        let id: String            // normalized model ref (also the /api/pull target)
        let baseURL: URL
        var status: String        // human phase text ("downloading…", "reconnecting…")
        var fraction: Double?     // 0…1, or nil while indeterminate
        var bytes: String?        // "1.2 / 4.7 gb"
        var phase: Phase = .active

        enum Phase: Equatable { case active, reconnecting, done, failed(String) }
        var isFinished: Bool { phase == .done || { if case .failed = phase { return true } else { return false } }() }
    }

    private(set) var downloads: [Download] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Active or reconnecting pulls (drive the progress banner).
    var inProgress: [Download] { downloads.filter { $0.phase == .active || $0.phase == .reconnecting } }
    func download(for ref: String) -> Download? { downloads.first { $0.id == ref } }
    func isDownloading(_ ref: String) -> Bool { tasks[OllamaAdapter.normalizePullRef(ref)] != nil }

    /// Start (or no-op if already running) a resilient server-side pull.
    func start(ref rawRef: String, baseURL: URL) {
        let ref = OllamaAdapter.normalizePullRef(rawRef)
        guard !ref.isEmpty, tasks[ref] == nil else { return }
        upsert(Download(id: ref, baseURL: baseURL, status: "starting…",
                        fraction: nil, bytes: nil, phase: .active))
        tasks[ref] = Task { [weak self] in await self?.run(ref: ref, baseURL: baseURL) }
    }

    /// Cancel a pull (teemoon stops streaming; the server may keep the partial,
    /// which a later pull resumes). Removes it from the list.
    func cancel(ref: String) {
        let ref = OllamaAdapter.normalizePullRef(ref)
        tasks[ref]?.cancel(); tasks[ref] = nil
        downloads.removeAll { $0.id == ref }
    }

    /// Dismiss a finished (done/failed) banner entry.
    func dismiss(ref: String) { downloads.removeAll { $0.id == ref && $0.isFinished } }

    // MARK: - Resilient pull loop

    private func run(ref: String, baseURL: URL) async {
        var noProgressRetries = 0
        var lastCompleted: Int64 = -1        // max bytes seen — persists across re-attaches
        var lastError: String?
        while !Task.isCancelled {
            var succeeded = false
            var advanced = false
            do {
                for try await p in OllamaAdapter.pullModel(ref, baseURL: baseURL) {
                    if Task.isCancelled { return }
                    if p.isSuccess { succeeded = true; break }
                    if let c = p.completed, c > lastCompleted {   // REAL byte progress
                        lastCompleted = c; advanced = true; noProgressRetries = 0
                    }
                    updateProgress(ref: ref, p: p)
                }
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription             // e.g. backgrounding → networkConnectionLost
            }
            if succeeded { finish(ref: ref); return }
            // Stream ended or errored without "success". The server keeps the
            // resumable blob, so re-attach — but only tolerate a bounded number of
            // attempts that make NO byte progress (a status line like "pulling
            // manifest" is NOT progress), so a pull that can't finalize fails with a
            // message instead of looping forever.
            if !advanced {
                noProgressRetries += 1
                if noProgressRetries >= 8 {
                    markFailed(ref: ref, msg: Self.friendlyPullError(lastError))
                    return
                }
            }
            markReconnecting(ref: ref)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Mutations (all @MainActor)

    private func upsert(_ d: Download) {
        if let i = downloads.firstIndex(where: { $0.id == d.id }) { downloads[i] = d }
        else { downloads.append(d) }
    }
    private func mutate(_ ref: String, _ body: (inout Download) -> Void) {
        guard let i = downloads.firstIndex(where: { $0.id == ref }) else { return }
        body(&downloads[i])
    }
    private func updateProgress(ref: String, p: OllamaPullProgress) {
        mutate(ref) {
            $0.phase = .active
            $0.status = p.status ?? "downloading…"
            $0.fraction = p.fractionCompleted
            $0.bytes = Self.byteLabel(completed: p.completed, total: p.total)
        }
    }
    private func markReconnecting(ref: String) {
        mutate(ref) { $0.phase = .reconnecting; $0.status = "reconnecting…" }
    }
    private func markFailed(ref: String, msg: String) {
        tasks[ref] = nil
        mutate(ref) { $0.phase = .failed(msg); $0.status = "failed" }
    }
    private func finish(ref: String) {
        tasks[ref] = nil
        mutate(ref) { $0.phase = .done; $0.status = "ready"; $0.fraction = 1 }
    }

    /// What went wrong with a pull, in terms a user can act on.
    ///
    /// Ollama's own pull errors are not user-facing text. Measured against a live
    /// server (2026-07-30):
    ///
    ///   a misspelled name  → "pull model manifest: file does not exist"
    ///   a pasted junk url  → "pull model manifest: file does not exist"
    ///   a missing hf repo  → "pull model manifest: realm host \"huggingface.co\"
    ///                          does not match original host \"hf.co\""
    ///
    /// The first says nothing about what to do and the second is actively
    /// misleading — it reads as teemoon getting a hostname wrong, and it is what
    /// Ollama says when the repo simply isn't there. Only TERSE errors were being
    /// rewritten ("400:"), so both of these reached the user verbatim.
    enum PullFailure: Equatable {
        /// No model by that name, anywhere. A typo, or a link that wasn't a model.
        case noSuchModel
        /// The HF repo doesn't exist, is gated, or isn't a GGUF repo.
        case huggingFaceRepoUnavailable
        /// The repo is there but the pull isn't allowed without accepting terms.
        case gated
        /// Reachable, refused, no detail — the case `friendlyPullError` was written for.
        case sourceRefused(code: String?)
        /// Anything else, passed through: an unrecognised message is still evidence.
        case other(String)

        /// The line under "failed".
        var message: String {
            switch self {
            case .noSuchModel:
                return "teemoon couldn't find that model. open ollama.com or hugging face, find the model, and copy the link from its page."
            case .huggingFaceRepoUnavailable:
                return "hugging face doesn't have that repo, or it isn't a gguf repo. open the repo page and copy its link — ollama can only pull gguf."
            case .gated:
                return "that repo is gated. accept its licence on hugging face first, then try again."
            case .sourceRefused(let code):
                let suffix = code.map { " (\($0))" } ?? ""
                return "the server couldn't fetch this model from its source\(suffix). the repo may be gated, split into multiple files, or not ollama-compatible."
            case .other(let raw):
                return raw
            }
        }

        /// The footer. Quant advice is only advice when the model EXISTS — telling
        /// someone who mistyped a name to "append :Q4_K_M" sends them to fix the
        /// wrong half of the string.
        var hint: String? {
            switch self {
            case .noSuchModel:
                return "the link has to come from the model's own page — a search or a list page won't work."
            case .huggingFaceRepoUnavailable, .sourceRefused:
                return "a specific quant can help — e.g. append `:Q4_K_M` to the ref — or pick a different model above."
            case .gated, .other:
                return nil
            }
        }
    }

    /// Classifies a raw pull error. Matching is on the phrases Ollama actually
    /// emits, lowercased, so a wording change degrades to `.other` (the raw
    /// message) rather than to a confident wrong explanation.
    nonisolated static func classifyPullError(_ raw: String?) -> PullFailure {
        let r = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = r.lowercased()

        if r.isEmpty || r.range(of: #"^\d{3}:?$"#, options: .regularExpression) != nil {
            let code = r.isEmpty ? nil : r.replacingOccurrences(of: ":", with: "")
            return .sourceRefused(code: code)
        }
        // Ordered: "realm host" is also a manifest error, and it has more to say.
        if lower.contains("realm host") || lower.contains("does not match original host") {
            return .huggingFaceRepoUnavailable
        }
        if lower.contains("file does not exist")
            || lower.contains("model not found")
            || lower.contains("manifest unknown")
            || lower.contains("404") {
            return .noSuchModel
        }
        if lower.contains("unauthorized") || lower.contains("403")
            || lower.contains("access denied") || lower.contains("gated") {
            return .gated
        }
        return .other(r)
    }

    /// The user-facing message for a raw pull error. Kept as the one-line entry
    /// point every existing caller already uses.
    nonisolated static func friendlyPullError(_ raw: String?) -> String {
        classifyPullError(raw).message
    }

    /// Preview/test seed — populate download state without starting real pulls.
    ///
    /// NOT `#if DEBUG`, and that is the point: `#Preview` bodies compile in RELEASE
    /// too, so a DEBUG-only seam called from one breaks the archive while every debug
    /// build and every test stays green. Three previews call this, and `main` failed
    /// to build Release because of it. Its siblings — `LocalEngineResidency.previewing`,
    /// `HomeServerProbe.previewing` — are unguarded for the same reason; this was the
    /// odd one out.
    static func seeded(_ ds: [Download]) -> OllamaDownloadCenter {
        let c = OllamaDownloadCenter()
        c.downloads = ds
        return c
    }

    /// "1.2 / 4.7 gb" when a total is known, else nil.
    static func byteLabel(completed: Int64?, total: Int64?) -> String? {
        guard let total, total > 0 else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000_000) }
        guard let completed else { return "\(gb(total)) gb" }
        return "\(gb(completed)) / \(gb(total)) gb"
    }
}
