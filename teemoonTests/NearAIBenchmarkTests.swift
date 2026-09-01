//  NearAIBenchmarkTests.swift
//  teemoonTests
//
//  Measures TTFT, generation time, and tok/s for near.ai direct vs gateway
//  across models that have a known direct completions URL.
//
//  To run:
//  1. In Xcode: Edit Scheme → Test → Arguments → Environment Variables
//     Add: NEAR_AI_API_KEY = <your key>
//  2. Run the test — results are written to /tmp/nearai-benchmark.txt

import Foundation
import Testing

// MARK: - Result types

private struct BenchmarkResult {
    let ttft: TimeInterval
    let total: TimeInterval
    let outputTokens: Int?          // from usage chunk; nil → char-count estimate used

    var generationTime: TimeInterval { max(0, total - ttft) }

    var tokensPerSecond: Double? {
        guard let t = outputTokens, generationTime > 0 else { return nil }
        return Double(t) / generationTime
    }
}

private struct Stats {
    let mean: Double
    let min: Double
    let max: Double

    init(_ values: [Double]) {
        mean = values.reduce(0, +) / Double(values.count)
        min  = values.min() ?? 0
        max  = values.max() ?? 0
    }
}

// MARK: - SSE streaming helper

/// Sends a streaming chat request and returns timing + token count.
private func streamRequest(
    baseURL: String,
    model: String,
    apiKey: String,
    messages: [[String: String]]
) async throws -> BenchmarkResult {
    guard let url = URL(string: "\(baseURL)/chat/completions") else {
        throw URLError(.badURL)
    }

    var req = URLRequest(url: url, timeoutInterval: 240)
    req.httpMethod = "POST"
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json",  forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "model":          model,
        "messages":       messages,
        "stream":         true,
        "stream_options": ["include_usage": true],
        "max_tokens":     512,
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    let start = Date()
    var firstTokenDate: Date?
    var completionTokens: Int?
    var charCount = 0

    let (bytes, _) = try await URLSession.shared.bytes(for: req)
    for try await line in bytes.lines {
        guard line.hasPrefix("data: ") else { continue }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]" else { break }
        
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        // usage chunk (near.ai may omit this even with stream_options)
        if let usage = json["usage"] as? [String: Any],
           let tok = usage["completion_tokens"] as? Int {
            completionTokens = tok
        }

        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty {
            if firstTokenDate == nil { firstTokenDate = Date() }
            charCount += content.count
        }
    }

    let end  = Date()
    let ttft = firstTokenDate.map { $0.timeIntervalSince(start) } ?? end.timeIntervalSince(start)

    return BenchmarkResult(
        ttft:          ttft,
        total:         end.timeIntervalSince(start),
        outputTokens:  completionTokens ?? (charCount > 0 ? charCount / 4 : nil)
    )
}

// MARK: - Benchmark suite

@Suite("near.ai Direct vs Gateway", .disabled("Costs money — to run, remove this trait locally and provide API keys (see README)"))
struct NearAIBenchmarkTests {

    private struct ModelConfig {
        let id:          String
        let name:        String
        let directBase:  String
    }

    private static let models: [ModelConfig] = [
        ModelConfig(id: "zai-org/GLM-5-FP8",                name: "GLM-5",     directBase: "https://glm-5.completions.near.ai/v1"),
        ModelConfig(id: "Qwen/Qwen3-30B-A3B-Instruct-2507", name: "Qwen3 30B", directBase: "https://qwen3-30b.completions.near.ai/v1"),
    ]

    private static let gatewayBase = "https://cloud-api.near.ai/v1"
    private static let iterations  = 3

    // Two prompt types: short isolates routing overhead (ttft), long tests decode throughput (tok/s)
    private static let prompts: [(label: String, messages: [[String: String]])] = [
        (
            label: "short",
            messages: [["role": "user", "content": "Reply with exactly one word: hello"]]
        ),
        (
            label: "long",
            messages: [["role": "user", "content": "Explain how transformer attention works in 300 words."]]
        ),
    ]

    /// Resolves the API key from (in priority order):
    /// 1. `NEAR_AI_API_KEY` environment variable
    /// 2. `~/.NEAR_AI_API_KEY` file on the host Mac
    private func resolveAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env["NEAR_AI_API_KEY"], !v.isEmpty { return v }
        // In the simulator NSHomeDirectory() is the app sandbox, not the Mac home.
        // SIMULATOR_HOST_HOME points to the real Mac home directory.
        let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        for name in [".NEAR_AI_API_KEY", ".nearai_api_key"] {
            let file = URL(fileURLWithPath: home).appendingPathComponent(name)
            if let v = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !v.isEmpty { return v }
        }
        return nil
    }

    @Test func directVsGateway() async throws {
        guard let apiKey = resolveAPIKey() else {
            Issue.record("API key not found. Set NEAR_AI_API_KEY env var, or create ~/.NEAR_AI_API_KEY containing your key.")
            return
        }

        var lines: [String] = []
        let log: (String) -> Void = { line in
            lines.append(line)
            print(line)
        }

        let sep = String(repeating: "─", count: 74)

        for model in Self.models {
            log("\n\(sep)")
            log("  \(model.name)  (\(model.id))")
            log(sep)

            for prompt in Self.prompts {
                log(String(format: "\n  prompt: %@", prompt.label))
                log("  run        total    ttft     gen    tokens     tok/s")

                var directResults:  [BenchmarkResult] = []
                var gatewayResults: [BenchmarkResult] = []

                for i in 1...Self.iterations {
                    let runDirect: Bool = !i.isMultiple(of: 2)
                    let firstBase  = runDirect ? model.directBase : Self.gatewayBase
                    let secondBase = runDirect ? Self.gatewayBase  : model.directBase
                    let firstTag   = runDirect ? "dir[\(i)]" : "gwy[\(i)]"
                    let secondTag  = runDirect ? "gwy[\(i)]" : "dir[\(i)]"

                    print("  → \(firstTag) starting…")
                    do {
                        let r = try await streamRequest(baseURL: firstBase, model: model.id, apiKey: apiKey, messages: prompt.messages)
                        if runDirect { directResults.append(r) } else { gatewayResults.append(r) }
                        log(row(firstTag, r))
                    } catch {
                        log("  \(firstTag) FAILED: \(error.localizedDescription)")
                    }

                    print("  → \(secondTag) starting…")
                    do {
                        let r = try await streamRequest(baseURL: secondBase, model: model.id, apiKey: apiKey, messages: prompt.messages)
                        if runDirect { gatewayResults.append(r) } else { directResults.append(r) }
                        log(row(secondTag, r))
                    } catch {
                        log("  \(secondTag) FAILED: \(error.localizedDescription)")
                    }
                }

                log("")
                if !directResults.isEmpty  { log(summary("direct",  directResults)) }
                if !gatewayResults.isEmpty { log(summary("gateway", gatewayResults)) }

                if !directResults.isEmpty && !gatewayResults.isEmpty {
                    let ttftDelta  = Stats(directResults.map(\.ttft)).mean  - Stats(gatewayResults.map(\.ttft)).mean
                    let totalDelta = Stats(directResults.map(\.total)).mean - Stats(gatewayResults.map(\.total)).mean
                    let sign: (Double) -> String = { $0 >= 0 ? "+" : "" }
                    log(String(format: "  delta (direct−gwy): ttft %@%.1fs  total %@%.1fs",
                               sign(ttftDelta), ttftDelta, sign(totalDelta), totalDelta))
                }
            }
        }

        log("\n\(sep)")

        // #file is the compile-time source path; walk up two levels to reach the project root
        // teemoon-ios/teemoonTests/NearAIBenchmarkTests.swift → teemoon-ios/
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "nearai-benchmark-\(timestamp).txt"
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // teemoonTests/
            .deletingLastPathComponent()  // project root
        let dirURL = projectRoot.appendingPathComponent("benchmark-results")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let outURL = dirURL.appendingPathComponent(filename)
        try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("\n📄 Results written to: \(outURL.path)")
    }

    private func row(_ label: String, _ r: BenchmarkResult) -> String {
        let tok = r.outputTokens.map { "\($0)" } ?? "~est"
        let tps = r.tokensPerSecond.map { String(format: "%.0f", $0) } ?? "~"
        return String(format: "  %-9@  %5.1fs   %5.1fs  %5.1fs  %8@  %8@",
                      label, r.total, r.ttft, r.generationTime, tok, tps)
    }

    private func summary(_ label: String, _ results: [BenchmarkResult]) -> String {
        let ttfts  = Stats(results.map(\.ttft))
        let totals = Stats(results.map(\.total))
        let tpss   = results.compactMap(\.tokensPerSecond)
        let tpsStr = tpss.isEmpty ? "n/a" : String(format: "%.0f", Stats(tpss).mean)
        return String(format: "  %-9@  mean: total %5.1fs (%.1f–%.1f)  ttft %5.1fs  tok/s %@",
                      label, totals.mean, totals.min, totals.max, ttfts.mean, tpsStr)
    }
}
