//
//  AttestationService+Routing.swift
//  teemoon
//
//  Which GPU node report we may trust, and which direct-host slugs to
//  try when the endpoints directory is down.
//

import Foundation

extension AttestationService {
    /// Whether a GPU node report may be trusted for `expectedModel`, given the
    /// model the node says it serves and where the directory maps that served
    /// id. The LB behind a direct host occasionally hands out a node running a
    /// different model (observed live: glm-5-1 answering with GLM-5.2's
    /// stack); trusting it stamps the wrong model's compose/artifact into the
    /// record — the record passes the session read gate (it's stamped with the
    /// *requested* model) and the sheet brands the wrong model. Rules:
    ///  - no expectation, or the node doesn't say (older nodes): accept;
    ///  - case-insensitive id match: accept;
    ///  - served id is a directory ALIAS of the expected one — both resolve to
    ///    the SAME near.ai host (e.g. z-ai/glm-5.2 vs zai-org/GLM-5.2-FP8): accept;
    ///  - anything else is a misrouted node: reject.
    ///
    /// The alias check compares the served host to the EXPECTED model's host —
    /// NOT to whatever host we happened to query. Comparing against the queried
    /// host was a hole: a fallback/misroute that landed us on a DIFFERENT
    /// model's host let that model authenticate itself (its served id maps to
    /// the host we queried), so an unrelated/previous model's attested stack got
    /// accepted and branded as the selected model. Anchoring on the expected
    /// model's host means a node on any other model's host is rejected regardless
    /// of which host the request reached.
    static func gpuReportServesExpectedModel(
        served: String?, expected: String, expectedModelHost: String?, servedModelHost: String?
    ) -> Bool {
        guard !expected.isEmpty, let served, !served.isEmpty else { return true }
        if served.caseInsensitiveCompare(expected) == .orderedSame { return true }
        if let expectedModelHost, let servedModelHost, expectedModelHost == servedModelHost { return true }
        return false
    }

    /// Best-effort direct-host slug candidates derived from a model id, e.g.
    /// `zai-org/GLM-5.1-FP8` → `glm-5-1`, `Qwen/Qwen3.5-122B-A10B` → `qwen35-122b`.
    /// near.ai's slugs are not a clean function of the id (GLM maps `.`→`-`,
    /// Qwen/DeepSeek drop the `.`), so several variants are generated; the
    /// `model_name` check picks the correct one and discards the rest.
    static func derivedDirectHostSlugs(forModel model: String) -> [String] {
        let name = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        // Drop trailing quantization / precision / active-param / date tags.
        var base = name
        let dropSuffixes = #"(-fp8|-fp16|-bf16|-int8|-int4|-a\d+b|-\d{4})+$"#
        if let re = try? NSRegularExpression(pattern: dropSuffixes) {
            base = re.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: "")
        }
        var slugs: [String] = []
        for variant in [base.replacingOccurrences(of: ".", with: "-"),  // GLM: 5.1 → 5-1
                        base.replacingOccurrences(of: ".", with: ""),   // Qwen/DeepSeek: 3.5 → 35
                        base] {
            let slug = variant.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            if !slug.isEmpty, !slugs.contains(slug) { slugs.append(slug) }
        }
        return slugs
    }
}
