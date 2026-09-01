//
//  DebugCopyRedactionTests.swift
//  teemoonTests
//
//  Regression pins for the debug card's COPY path: "Copy Debug Info" used to
//  put the live `Authorization` header on the system pasteboard in every
//  shipping build (redaction was gated to `--uitesting`, i.e. off for real
//  users), and the card that hosts the menu appears on ANY provider error.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Debug copy redaction")
@MainActor
struct DebugCopyRedactionTests {

    /// A key shaped like the real thing — long, with a distinctive tail so a
    /// leak of "just the end" is still caught by the whole-string assertion.
    // Unmistakably fake (audit rule 1.5): a plausible-looking hex literal here
    // would trip every secret scanner pointed at the public repo.
    static let liveKey = "sk-or-v1-fake00000000000000000000000000000000000000000000000000000-1f18"

    private var headers: [String: String] {
        [
            "Authorization": "Bearer \(Self.liveKey)",
            "X-Api-Key": Self.liveKey,
            "x-subscription-token": Self.liveKey,
            "Content-Type": "application/json",
            "User-Agent": "teemoon/1.0"
        ]
    }

    /// The panel is deliberately unredacted ON SCREEN (a developer reading
    /// their own key is the point of it) — so the display path must not have
    /// been "fixed" along with the copy path.
    private var displayPathIsVerbatim: Bool {
        !ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    // MARK: - The header block

    @Test func headerBlock_dropsEveryCredential_keepsEverythingElse() {
        let block = DebugHeaderRedaction.copyHeaderBlock(headers)

        #expect(!block.contains(Self.liveKey))
        // Not even a long prefix of it — a "first 20 chars" style redaction
        // would still hand over most of a key.
        #expect(!block.contains(Self.liveKey.prefix(16)))

        // Non-secret headers survive verbatim: a redacted dump has to stay a
        // useful bug report.
        #expect(block.contains("Content-Type: application/json"))
        #expect(block.contains("User-Agent: teemoon/1.0"))

        // Shape kept, so the reporter can still match it against their panel.
        #expect(block.contains("Bearer ••••…1f18"))
        #expect(block.contains("X-Api-Key: ••••…1f18"))
        #expect(block.contains("x-subscription-token: ••••…1f18"))
    }

    @Test func headerNameMatching_isCaseInsensitive() {
        for name in ["AUTHORIZATION", "authorization", "Authorization"] {
            let out = DebugHeaderRedaction.copyValue("Bearer \(Self.liveKey)", for: name)
            #expect(!out.contains(Self.liveKey), "leaked under header name \(name)")
        }
    }

    @Test func nonSecretHeader_passesThroughUntouched() {
        #expect(DebugHeaderRedaction.copyValue("application/json", for: "Content-Type")
                == "application/json")
    }

    @Test func shortSecret_isMaskedWhole() {
        // Too short for a 4-char tail to be a hint rather than the secret.
        #expect(DebugHeaderRedaction.copyValue("Bearer abc", for: "Authorization") == "Bearer ••••")
        #expect(DebugHeaderRedaction.copyValue("abc", for: "X-Api-Key") == "••••")
    }

    @Test func schemelessSecret_keepsNoScheme() {
        #expect(DebugHeaderRedaction.copyValue(Self.liveKey, for: "api-key") == "••••…1f18")
    }

    // MARK: - The URL

    @Test func urlQueryCredentials_areRedacted_othersSurvive() {
        let url = "https://api.example.com/v1/chat?model=glm-5.2&api_key=QQQQWWWWEEEERRRRTTTT&stream=true"
        let out = DebugHeaderRedaction.copyURLString(url)

        #expect(!out.contains("QQQQWWWWEEEERRRRTTTT"))
        #expect(out.contains("api_key=••••…TTTT"))
        #expect(out.contains("model=glm-5.2"))
        #expect(out.contains("stream=true"))
        #expect(out.hasPrefix("https://api.example.com/v1/chat?"))
    }

    @Test func urlWithoutSecrets_isByteIdentical() {
        let plain = "https://cloud-api.near.ai/v1/chat/completions"
        #expect(DebugHeaderRedaction.copyURLString(plain) == plain)
        let withQuery = "https://api.example.com/search?q=hello&count=10"
        #expect(DebugHeaderRedaction.copyURLString(withQuery) == withQuery)
    }

    // MARK: - End to end, through the views that own the menu

    @Test func errorCardCopy_carriesNoLiveToken() {
        let error = LLMError(
            source: .provider(name: "near.ai glm 5.2"),
            userMessage: LLMError.providerMessage(httpStatus: 401, provider: "near.ai"),
            httpStatus: 401,
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions?api_key=\(Self.liveKey)"),
            requestHeaders: headers,
            requestBodyJSON: "{\"model\":\"z-ai/glm-5.2\"}",
            messageHistory: nil,
            responseBody: "{\"error\":{\"message\":\"Invalid API key\"}}",
            underlyingError: nil
        )
        let copied = ErrorMessageView(error: error).debugText

        #expect(!copied.contains(Self.liveKey))
        // Still a report: the sections a triager needs are all there.
        #expect(copied.contains("--- Headers ---"))
        #expect(copied.contains("Content-Type: application/json"))
        #expect(copied.contains("--- Request Body ---"))
        #expect(copied.contains("z-ai/glm-5.2"))
        #expect(copied.contains("HTTP 401"))

        // And the on-screen value is untouched — decision 0.9.
        if displayPathIsVerbatim {
            #expect(DebugHeaderRedaction.value("Bearer \(Self.liveKey)", for: "Authorization")
                    == "Bearer \(Self.liveKey)")
        }
    }

    @Test func requestCardCopy_carriesNoLiveToken() {
        let info = LastRequestDebugInfo(
            providerName: "near.ai",
            modelID: "zai-org/GLM-5.1-FP8",
            url: URL(string: "https://cloud-api.near.ai/v1/chat/completions"),
            requestHeaders: headers,
            requestBodyJSON: "{\"model\":\"zai-org/GLM-5.1-FP8\"}",
            responseBody: "hello",
            toolCalls: [],
            threadID: UUID(),
            totalDuration: 2.341,
            timeToFirstToken: 0.612,
            outputTokens: 187,
            isE2EEActive: false,
            teeVerification: nil
        )
        let copied = RequestDebugView(info: info).debugText

        #expect(!copied.contains(Self.liveKey))
        #expect(copied.contains("--- Headers ---"))
        #expect(copied.contains("User-Agent: teemoon/1.0"))
        #expect(copied.contains("zai-org/GLM-5.1-FP8"))
    }
}
