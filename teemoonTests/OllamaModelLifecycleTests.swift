//
//  OllamaModelLifecycleTests.swift
//  teemoonTests
//
//  The DESTRUCTIVE tier of the local smoke suite: pulling a model onto the
//  server and deleting it again, through the same adapter calls the app uses.
//
//  OPT-IN, and deliberately hard to run by accident. It writes to and deletes
//  from a real Ollama library, so:
//
//    * it does nothing unless LOCAL_SMOKE_DESTRUCTIVE=1
//    * it only ever touches the model named in LOCAL_SMOKE_THROWAWAY_MODEL
//      (default: a ~350 MB one, small enough that a failed run wastes seconds
//      and not gigabytes on a machine with ~27 GB free)
//    * it REFUSES to delete anything that was already installed before it ran,
//      so a fat-fingered model name can never remove work you care about
//
//  That last rule is the important one. A test that deletes is one typo away
//  from deleting the wrong thing, and the guard is cheaper than the apology.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Ollama model lifecycle (destructive, opt-in)", .serialized)
struct OllamaModelLifecycleTests {

    static let baseURL = URL(string: "http://127.0.0.1:11434/v1")!

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var enabled: Bool { env["LOCAL_SMOKE_DESTRUCTIVE"] == "1" }
    /// Small on purpose. all-minilm is an embedding model (~46 MB) — teemoon
    /// filters it out of chat pickers, which is fine: this exercises the pull and
    /// delete plumbing, not inference.
    private static var throwaway: String { env["LOCAL_SMOKE_THROWAWAY_MODEL"] ?? "all-minilm:latest" }

    private func installedModels() async -> [String] {
        guard case .connected(let models) = await OllamaAdapter.listModels(baseURL: Self.baseURL)
        else { return [] }
        return models.map(\.id)
    }

    private func serverIsUp() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        req.timeoutInterval = 3
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    @Test func pullThenDeleteRoundTrip() async throws {
        guard Self.enabled else {
            print("[destructive] set LOCAL_SMOKE_DESTRUCTIVE=1 to run — skipping")
            return
        }
        guard await serverIsUp() else {
            Issue.record("destructive tier requested but Ollama is not running")
            return
        }

        let target = Self.throwaway
        let before = await installedModels()

        // THE GUARD: never delete something that predates this test. If the
        // throwaway name collides with an installed model, stop — do not proceed
        // to a delete that would destroy it.
        if before.contains(where: { $0 == target || $0.hasPrefix(target.split(separator: ":").first.map(String.init) ?? target) }) {
            Issue.record("""
                "\(target)" (or its base name) is ALREADY installed. Refusing to run: \
                this test deletes what it pulls, and that would remove a model it did \
                not create. Set LOCAL_SMOKE_THROWAWAY_MODEL to something absent.
                """)
            return
        }

        // 1 — pull. Progress arrives as NDJSON; we only need it to terminate.
        var sawProgress = false
        var pullFailed: Error?
        do {
            for try await progress in OllamaAdapter.pullModel(target, baseURL: Self.baseURL) {
                sawProgress = true
                if progress.status == "success" { break }
            }
        } catch { pullFailed = error }

        if let pullFailed {
            Issue.record("pull of \(target) failed: \(pullFailed)")
            return
        }
        #expect(sawProgress, "pull produced no progress lines at all")

        let afterPull = await installedModels()
        #expect(afterPull.count > before.count || afterPull.contains(where: { $0.hasPrefix(target.split(separator: ":").first.map(String.init) ?? target) }),
                "pull reported success but the model is not in the library: \(afterPull)")

        // 2 — delete it again, and prove the library is back where it started.
        // Resolve the id Ollama actually recorded rather than assuming the ref
        // round-trips: a pulled name can gain or normalise a tag.
        let pulled = Set(afterPull).subtracting(before)
        let toDelete = pulled.first ?? target
        try await OllamaAdapter.deleteModel(toDelete, baseURL: Self.baseURL)

        let afterDelete = await installedModels()
        #expect(!afterDelete.contains(toDelete), "\(toDelete) survived the delete")
        #expect(Set(afterDelete) == Set(before),
                "the library did not return to its original state — before: \(before), after: \(afterDelete)")
    }

    /// Deleting something absent must fail loudly rather than report success —
    /// the swipe-to-delete row depends on that to show an error.
    @Test func deletingAModelThatIsNotThereThrows() async throws {
        guard Self.enabled else { return }
        guard await serverIsUp() else { return }
        await #expect(throws: (any Error).self) {
            try await OllamaAdapter.deleteModel("teemoon-does-not-exist:v0", baseURL: Self.baseURL)
        }
    }
}
