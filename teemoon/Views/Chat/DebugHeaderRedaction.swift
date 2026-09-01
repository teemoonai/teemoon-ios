//
//  DebugHeaderRedaction.swift
//  teemoon

import Foundation

/// Credential handling for the debug panel — two different rules for two
/// different exposures.
///
/// - `value` hides credentials ON SCREEN, and only when the app is being
///   driven for capture (`--uitesting`).
/// - `copyValue` / `copyHeaderBlock` / `copyURLString` hide them on the
///   PASTEBOARD, unconditionally, in every build.
///
/// The screen case:
///
/// The panel prints request headers verbatim, `Authorization` included, and the
/// marketing site invites people to open it ("settings → developer → debug
/// panel · open it any time to verify"). A screenshot of it therefore carries a
/// live bearer token — which is not hypothetical: teemoon.ai shipped
/// `debug-redacted.png` with `Authorization: Bearer sk-…` legible on it, the
/// filename notwithstanding. Only the body had ever been redacted.
///
/// `value` is scoped to `--uitesting` on purpose. A developer reading their own
/// panel wants the real header — that is the point of the panel — so this
/// changes nothing for them. It makes a CAPTURE structurally incapable of
/// carrying a key, rather than relying on someone remembering to paint over it
/// afterwards.
///
/// The copy case is NOT scoped, and must not be: see `copyValue`.
enum DebugHeaderRedaction {
    private static let active = ProcessInfo.processInfo.arguments.contains("--uitesting")

    /// Header names whose values are credentials. Matched case-insensitively
    /// because header casing is not guaranteed.
    private static let secretHeaders = ["authorization", "x-subscription-token", "x-api-key", "api-key"]

    static func value(_ value: String, for name: String) -> String {
        guard active, secretHeaders.contains(name.lowercased()) else { return value }
        // Keep the SHAPE — a reader should still see that a bearer token was
        // sent and roughly how long it is, since "is the key actually going
        // out?" is a real question the panel answers.
        if let scheme = value.split(separator: " ", maxSplits: 1).first, value.contains(" ") {
            return "\(scheme) ••••••••••••••••"
        }
        return "••••••••••••••••"
    }

    // MARK: - Copy path (redacted in EVERY build)

    /// Redaction for the value of one header, on the COPY path.
    ///
    /// Unconditional — no `--uitesting` gate. The two things are not the same
    /// risk and must not share a switch:
    ///
    /// - READING the panel is the developer looking at their own screen, in
    ///   their own hands, at a key they already possess. That stays verbatim
    ///   on purpose: "is the key actually going out, and is it the right one?"
    ///   is the question the panel exists to answer.
    /// - COPYING it puts a live credential on the system pasteboard, which
    ///   syncs to every signed-in Mac and iPad, is readable by whatever app is
    ///   foregrounded next, and — since "Copy Debug Info" is what someone taps
    ///   to paste a failure into an issue, a chat, or a support thread — is
    ///   very often on its way to a stranger. The error card that hosts this
    ///   menu appears on ANY provider error, not only in developer mode.
    ///
    /// Keeps scheme + last 4 so a pasted report still answers "which key was
    /// this?" against the panel on the reporter's own screen.
    static func copyValue(_ value: String, for name: String) -> String {
        guard secretHeaders.contains(name.lowercased()) else { return value }
        return mask(value)
    }

    /// `Bearer ••••…f456` — scheme kept, secret reduced to its last 4.
    /// A secret too short to have a meaningful tail is masked whole rather
    /// than leaking most of itself as a "hint".
    private static func mask(_ value: String) -> String {
        var scheme = ""
        var secret = value[...]
        if value.contains(" "), let head = value.split(separator: " ", maxSplits: 1).first {
            scheme = "\(head) "
            secret = value.dropFirst(head.count + 1)
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "\(scheme)••••" }
        return "\(scheme)••••…\(trimmed.suffix(4))"
    }

    /// The `--- Headers ---` block exactly as it goes on the pasteboard.
    /// Single choke point: both debug cards' `debugText` route through here,
    /// so a header dictionary cannot reach the clipboard un-redacted.
    static func copyHeaderBlock(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(copyValue($0.value, for: $0.key))" }
            .joined(separator: "\n")
    }

    /// Query-parameter names that carry credentials. No adapter in-tree puts a
    /// key in the query string today (they all use headers), but a custom or
    /// self-hosted base URL is user-typed and some vendors' do — and a URL is
    /// the one field of the dump that is copied verbatim by habit.
    private static let secretQueryParams: Set<String> = [
        "key", "api_key", "apikey", "api-key", "access_token", "accesstoken",
        "token", "auth", "auth_token", "subscription_token", "password", "secret"
    ]

    /// Redacts credential-bearing query parameters in a URL, on the copy path.
    /// Non-URL / query-less strings pass through untouched.
    /// String surgery rather than `URLComponents`: re-serialising through
    /// `queryItems` percent-encodes the mask itself, so a redacted key pastes
    /// as `%E2%80%A2%E2%80%A2…` — technically safe, unreadable in a bug report.
    static func copyURLString(_ urlString: String) -> String {
        guard let mark = urlString.firstIndex(of: "?") else { return urlString }
        let base = String(urlString[..<mark])
        var query = String(urlString[urlString.index(after: mark)...])
        var fragment = ""
        if let hash = query.firstIndex(of: "#") {
            fragment = String(query[hash...])
            query = String(query[..<hash])
        }
        var touched = false
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2, !halves[1].isEmpty else { return String(pair) }
            let name = String(halves[0]).removingPercentEncoding ?? String(halves[0])
            guard secretQueryParams.contains(name.lowercased()) else { return String(pair) }
            touched = true
            let value = String(halves[1]).removingPercentEncoding ?? String(halves[1])
            return "\(halves[0])=\(mask(value))"
        }
        guard touched else { return urlString }
        return base + "?" + pairs.joined(separator: "&") + fragment
    }
}
