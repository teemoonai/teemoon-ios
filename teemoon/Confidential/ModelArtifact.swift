//
//  ModelArtifact.swift
//  teemoon
//
//  The pinned model artifact, parsed from the hash-verified model-layer compose
//  YAML (the inner `*.yaml` the compose-manager launches inside the model
//  enclave). This is the difference between what the app is *told* it's talking
//  to — the served alias, which the provider controls and can misstate — and
//  what is *actually* loaded: a specific HuggingFace repo at an immutable
//  revision, with a real quantization.
//
//  The payoff is drift detection: when the served alias advertises a different
//  quantization than the pinned weights actually are (e.g. served as
//  `…-FP8` while the pinned path is `QuantTrio/GLM-5.1-AWQ`), the alias
//  understates the quantization — honest disclosure the user would otherwise
//  have to read the compose to discover.
//
//  Pure and testable: `parse(fromComposeYAML:)` takes text, returns a value.
//

import Foundation

struct ModelArtifact: Equatable, Sendable {
    /// The pinned weights: a HuggingFace repo path, e.g. "QuantTrio/GLM-5.1-AWQ".
    let modelPath: String
    /// The immutable revision the weights are pinned to (HF commit), if given.
    let revision: String?
    /// The alias the provider serves this model under — the string apps see,
    /// e.g. "zai-org/GLM-5.1-FP8". Provider-controlled; may mislead.
    let servedName: String?
    /// Quantization derived from the *pinned model path* (never the alias),
    /// e.g. "AWQ". nil when the path carries no recognizable quant tag.
    let quant: String?

    /// Known quantization tags, matched on token boundaries so "FP8" never
    /// matches inside "FP16". Longer, more specific tokens are listed so a
    /// boundary hit is unambiguous.
    private static let quantTokens: Set<String> = [
        "AWQ", "GPTQ", "GGUF", "EETQ", "MXFP4",
        "FP8", "FP16", "FP4", "BF16",
        "INT8", "INT4", "W4A16", "W8A8", "W4A8",
    ]

    /// The clean model name for display — the pinned path with its vendor
    /// prefix and quant suffix stripped: "QuantTrio/GLM-5.1-AWQ" → "GLM-5.1".
    var baseModelName: String {
        let afterSlash = modelPath.split(separator: "/").last.map(String.init) ?? modelPath
        guard let q = quant else { return afterSlash }
        for sep in ["-", "_"] {
            let suffix = "\(sep)\(q)"
            if afterSlash.uppercased().hasSuffix(suffix.uppercased()) {
                return String(afterSlash.dropLast(suffix.count))
            }
        }
        return afterSlash
    }

    /// The quantization tag the *served alias* implies (may differ from the
    /// real one — that difference is the drift).
    var servedQuant: String? {
        servedName.flatMap { Self.quantTag(in: $0) }
    }

    /// True when the served alias advertises a different quantization than the
    /// pinned weights actually are. Informational, not a failure.
    var quantDrift: Bool {
        guard let quant, let servedQuant else { return false }
        return quant.uppercased() != servedQuant.uppercased()
    }

    /// One-line disclosure of the drift, for display.
    var driftNote: String? {
        guard quantDrift, let quant, let served = servedName else { return nil }
        return "served as `\(served)`, but the pinned weights are `\(modelPath)` (\(quant))."
    }

    // MARK: Parsing

    /// Extracts the model artifact from a compose YAML by reading the inference
    /// server's launch flags — `--model-path`, `--revision`,
    /// `--served-model-name` — wherever they appear (inline command string or
    /// YAML list form, with or without `=`). Returns nil if no `--model-path`
    /// is present (nothing to pin to).
    static func parse(fromComposeYAML yaml: String) -> ModelArtifact? {
        let tokens = flatten(yaml)
        guard let modelPath = value(of: "--model-path", in: tokens) else { return nil }
        return ModelArtifact(
            modelPath: modelPath,
            revision: value(of: "--revision", in: tokens),
            servedName: value(of: "--served-model-name", in: tokens),
            quant: quantTag(in: modelPath))
    }

    /// Every model server declared in the compose — one `ModelArtifact` per
    /// `--model-path`. near.ai runs several models through one reused node via
    /// COMBINED composes (e.g. `dsv4-qwen36-gemma4.yaml` runs DeepSeek + Qwen +
    /// Gemma), so a `parse` that took the first `--model-path` mis-identified the
    /// model. Each `--model-path` is paired with the `--served-model-name` /
    /// `--revision` that follow it, up to the next `--model-path`.
    static func parseAll(fromComposeYAML yaml: String) -> [ModelArtifact] {
        let tokens = flatten(yaml)
        // A model server declares its weights in one of two forms:
        //   • `--model-path <repo>`            (sglang / older vLLM), or
        //   • `vllm serve <repo>` (positional)  (newer vLLM — e.g. gemma-4).
        // Collect each declaration's (token index, repo path); a compose that
        // mixes forms (combined multi-model nodes do) yields one per server.
        var decls: [(start: Int, path: String)] = []
        for i in tokens.indices {
            let t = tokens[i]
            if t == "--model-path", i + 1 < tokens.count {
                decls.append((i, tokens[i + 1]))
            } else if t.hasPrefix("--model-path=") {
                decls.append((i, String(t.dropFirst("--model-path=".count))))
            } else if t == "serve", i > 0, tokens[i - 1] == "vllm",
                      i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") {
                decls.append((i, tokens[i + 1]))
            }
        }
        return decls.enumerated().map { k, decl in
            let end = k + 1 < decls.count ? decls[k + 1].start : tokens.count
            let slice = Array(tokens[decl.start..<end])
            return ModelArtifact(
                modelPath: decl.path,
                revision: value(of: "--revision", in: slice),
                servedName: value(of: "--served-model-name", in: slice),
                quant: quantTag(in: decl.path))
        }
    }

    /// The artifact for the REQUESTED model on a (possibly multi-model) node:
    /// the server whose `--served-model-name` is `requested` — exact first, then
    /// same-vendor to tolerate alias spellings (`z-ai` vs `zai-org`). Falls back
    /// to the first server when nothing matches or `requested` is nil, so it is
    /// never worse than `parse`.
    static func parse(fromComposeYAML yaml: String, servingModel requested: String?) -> ModelArtifact? {
        let all = parseAll(fromComposeYAML: yaml)
        guard !all.isEmpty else { return nil }
        guard let requested else { return all.first }
        if let exact = all.first(where: {
            $0.servedName?.caseInsensitiveCompare(requested) == .orderedSame
        }) { return exact }
        if let sameVendor = all.first(where: {
            ($0.servedName).map { !NearAIModelCatalog.differentVendor($0, requested) } ?? false
        }) { return sameVendor }
        return all.first
    }

    /// Flattens compose YAML into an ordered token stream: strips the leading
    /// list marker (`- `) from each line, then splits on whitespace and trims
    /// surrounding quotes/commas. Handles both the list form (flag and value on
    /// separate items) and an inline command string.
    private static func flatten(_ yaml: String) -> [String] {
        var tokens: [String] = []
        for rawLine in yaml.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            else if line == "-" { continue }
            for part in line.split(separator: " ") {
                let t = String(part).trimmingCharacters(in: CharacterSet(charactersIn: "\"',[]"))
                if !t.isEmpty { tokens.append(t) }
            }
        }
        return tokens
    }

    /// The value following `flag` in the token stream, supporting both
    /// `--flag value` (separate tokens) and `--flag=value`.
    private static func value(of flag: String, in tokens: [String]) -> String? {
        for (i, t) in tokens.enumerated() {
            if t == flag, i + 1 < tokens.count { return tokens[i + 1] }
            if t.hasPrefix("\(flag)=") { return String(t.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// The recognized quantization tag inside a repo/alias string, matched on
    /// non-alphanumeric boundaries so "FP8" won't match inside "FP16".
    static func quantTag(in s: String) -> String? {
        let parts = Set(
            s.uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init))
        // Prefer a deterministic order so multi-tag strings resolve stably.
        return quantTokens.sorted().first { parts.contains($0) }
    }
}
