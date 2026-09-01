//
//  MeasuredConfigTests.swift
//  teemoonTests
//
//  Covers the measured-configuration panel parsing: the sglang flag checks,
//  the vllm-proxy-rs OHTTP check, the
//  allowed_envs group invariant, egress-confinement absence — and the two
//  copy rules the design pins ("not configured to log" never "can't log";
//  binding is action-log + hash-check, never claimed as hardware-measured).
//

import Testing
@testable import teemoon

struct MeasuredConfigTests {

    /// Production-shaped inner compose with the real GLM-5.1 launch command
    /// (verbatim flags from the audited YAML @ c545c955): logging off, no
    /// dump flags, pinned revision — and the literal proxy env.
    private let innerCompose = """
    services:
      proxy:
        image: nearaidev/vllm-proxy-rs@sha256:b183677aaabbccddeeff00112233445566778899aabbccddeeff001122334455
        environment:
          - OHTTP_ENABLED=true
          - TLS_CERT_PATH=/certs/completions.near.ai
      model-sg-glm51-awq-tp4:
        image: glm51-sgl-awq-tp4-patched:local
        command: >
          sglang serve --model-path QuantTrio/GLM-5.1-AWQ
          --revision 8f60817aa28023f2607850d1a1e51d21aa34817a
          --served-model-name zai-org/GLM-5.1-FP8 --tp 4
          --log-requests-level 0 --mem-fraction-static 0.85
          --enable-cache-report --enable-metrics --trust-remote-code
      nginx:
        image: nginx:1.25
    networks:
      default:
    """

    // MARK: engine (sglang)

    @Test func engineChecksHoldOnProductionCommand() throws {
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: innerCompose))
        #expect(cfg.lines.count == 3)
        #expect(cfg.lines.allSatisfy { $0.state == .holds })
        let logging = try #require(cfg.lines.first { $0.id == "logging" })
        #expect(logging.title == "request logging off")
        #expect(logging.detail.contains("--log-requests-level 0"))
        let revision = try #require(cfg.lines.first { $0.id == "revision" })
        #expect(revision.detail.contains("8f60817aa280"))
    }

    /// `--log-requests-level` shares a prefix with `--log-requests` — the
    /// level flag alone must NOT read as logging enabled.
    @Test func logRequestsLevelZeroIsNotLoggingOn() throws {
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: innerCompose))
        #expect(cfg.lines.first { $0.id == "logging" }?.state == .holds)
    }

    @Test func explicitLogRequestsFlagIsSurfaced() throws {
        let yaml = """
        services:
          engine:
            image: eng:local
            command: [sglang, serve, --model-path, x/y, --log-requests, --revision, abc123]
        """
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: yaml))
        let logging = try #require(cfg.lines.first { $0.id == "logging" })
        #expect(logging.state == .attention)
        #expect(logging.detail.contains("--log-requests"))
    }

    @Test func dumpFlagsAreNamedLiterally() throws {
        let yaml = """
        services:
          engine:
            image: eng:local
            command: sglang serve --model-path x/y --crash-dump-folder /tmp/dumps
        """
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: yaml))
        let dumps = try #require(cfg.lines.first { $0.id == "dumps" })
        #expect(dumps.state == .attention)
        #expect(dumps.detail.contains("--crash-dump-folder"))
    }

    @Test func missingRevisionIsSurfaced() throws {
        let yaml = """
        services:
          engine:
            image: eng:local
            command: sglang serve --model-path x/y
        """
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: yaml))
        #expect(cfg.lines.first { $0.id == "revision" }?.state == .attention)
    }

    /// No engine block → no panel, never a fabricated one.
    @Test func noEngineBlockYieldsNil() {
        #expect(MeasuredConfig.engineConfig(innerComposeYAML: "services:\n  web:\n    image: nginx") == nil)
    }

    /// The yaml link (existing RunLink machinery) rides on the logging line.
    @Test func yamlLinkAttachesToLoggingLine() throws {
        let link = RunLink(title: "yaml @ c545c95", url: "https://github.com/nearai/cvm-compose-files/blob/c545c955/prod/GLM-5.1.yaml")
        let cfg = try #require(MeasuredConfig.engineConfig(innerComposeYAML: innerCompose, yamlLink: link))
        #expect(cfg.lines.first { $0.id == "logging" }?.links == [link])
    }

    // MARK: proxy (vllm-proxy-rs)

    @Test func proxyOHTTPEnabledHolds() throws {
        let cfg = try #require(MeasuredConfig.proxyConfig(innerComposeYAML: innerCompose))
        let ohttp = try #require(cfg.lines.first { $0.id == "ohttp" })
        #expect(ohttp.state == .holds)
        #expect(ohttp.detail.contains("OHTTP_ENABLED=true"))
    }

    @Test func proxyOHTTPAbsentIsHonest() throws {
        let yaml = """
        services:
          proxy:
            image: nearaidev/vllm-proxy-rs@sha256:aa
            environment:
              - TLS_CERT_PATH=/certs/x
        """
        let cfg = try #require(MeasuredConfig.proxyConfig(innerComposeYAML: yaml))
        #expect(cfg.lines.first { $0.id == "ohttp" }?.state == .attention)
    }

    // MARK: copy rules (pinned)

    /// Never "can't log" — sglang's unauthenticated /configure_logging makes
    /// that false. The claim is configuration + the cost of changing it.
    @Test func copyNeverSaysCantLog() throws {
        let engine = try #require(MeasuredConfig.engineConfig(innerComposeYAML: innerCompose))
        let proxy = try #require(MeasuredConfig.proxyConfig(innerComposeYAML: innerCompose))
        let all = (engine.lines + proxy.lines).map { $0.title + " " + $0.detail }.joined(separator: " ")
            + " " + MeasuredConfig.reconfigureQualifier + " " + MeasuredConfig.bindingNote
        let lowered = all.lowercased()
        #expect(!lowered.contains("can't log"))
        #expect(!lowered.contains("cannot log"))
        #expect(MeasuredConfig.reconfigureQualifier.contains("not configured to log"))
        #expect(MeasuredConfig.reconfigureQualifier.contains("measurement change or a signed action-log trace"))
    }

    /// The inner document is action-log-pinned + hash-checked — never claimed
    /// as hardware-measured (mr_config covers the outer harness only).
    @Test func bindingNoteNeverClaimsHardwareMeasured() {
        #expect(MeasuredConfig.bindingNote.contains("pinned by the attested action log"))
        #expect(MeasuredConfig.bindingNote.contains("hash-checked"))
        #expect(!MeasuredConfig.bindingNote.lowercased().contains("hardware-measured"))
    }

    // MARK: allowed_envs (group invariant, outer measured compose)

    @Test func allowedEnvsParsesJSONForm() throws {
        let outer = """
        {"manifest_version": 2, "allowed_envs": ["BEARER_TOKEN", "DD_API_KEY", "HOST_IP"], "docker_compose_file": "…"}
        """
        let envs = try #require(MeasuredConfig.allowedEnvs(inOuterManifest: outer))
        #expect(envs == ["BEARER_TOKEN", "DD_API_KEY", "HOST_IP"])
        #expect(MeasuredConfig.loggingSuspects(inAllowedEnvs: envs).isEmpty)
    }

    @Test func allowedEnvsParsesYAMLListForm() throws {
        let outer = """
        allowed_envs:
          - BEARER_TOKEN
          - CM_MIN_TAG_AGE_HOURS
          - DD_API_KEY
        other_key: x
        """
        let envs = try #require(MeasuredConfig.allowedEnvs(inOuterManifest: outer))
        #expect(envs.count == 3)
        #expect(envs.contains("CM_MIN_TAG_AGE_HOURS"))
    }

    @Test func loggingSuspectsAreFlagged() {
        let suspects = MeasuredConfig.loggingSuspects(
            inAllowedEnvs: ["BEARER_TOKEN", "LOG_LEVEL", "RUST_DEBUG", "AWS_REGION"])
        #expect(suspects == ["LOG_LEVEL", "RUST_DEBUG"])
    }

    @Test func allowedEnvsCaptionStatesTheInvariant() throws {
        let outer = "{\"allowed_envs\": [\"BEARER_TOKEN\", \"DD_API_KEY\"]}"
        let caption = try #require(MeasuredConfig.allowedEnvsCaption(outerManifest: outer))
        #expect(caption.contains("none of the 2 operator-settable env vars"))
        #expect(caption.contains("measurement or a signed action-log trace"))
    }

    @Test func allowedEnvsCaptionNamesSuspects() throws {
        let outer = "{\"allowed_envs\": [\"LOG_LEVEL\"]}"
        let caption = try #require(MeasuredConfig.allowedEnvsCaption(outerManifest: outer))
        #expect(caption.contains("`LOG_LEVEL`"))
    }

    /// No allowed_envs section → no claim at all.
    @Test func noAllowedEnvsMeansNoCaption() {
        #expect(MeasuredConfig.allowedEnvsCaption(outerManifest: "services:\n  a:\n    image: x") == nil)
    }

    // MARK: egress (disclosed limit, §5)

    /// The production shape: a flat network, no internal: true anywhere —
    /// the absence of egress confinement is established, not assumed.
    @Test func egressAbsenceIsDerivedFromNetworks() {
        #expect(MeasuredConfig.lacksEgressConfinement(composeYAML: innerCompose))
    }

    /// If near.ai ever adds `internal: true`, the disclosed limit must stop
    /// rendering (it would become a check instead).
    @Test func internalTrueMeansConfinementPresent() {
        let confined = """
        services:
          engine:
            image: eng:local
            networks: [backend]
        networks:
          backend:
            internal: true
        """
        #expect(!MeasuredConfig.lacksEgressConfinement(composeYAML: confined))
    }
}
