//
//  ChatView+Previews.swift
//  teemoon
//

import SwiftUI

#Preview("No Security") {
    @FocusState var isPromptFocused: Bool
    let store = ProviderStore()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

#Preview("Encrypted") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let session: ConfidentialSession = {
        let c = ConfidentialSession(providers: store)
        c.attestation = .preview
        c.lastRequestUsedE2EE = true
        return c
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(session)
        .environment(ChatGeneration())
}

#Preview("Loading") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

#Preview("Degraded (no E2EE key)") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore()
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let session: ConfidentialSession = {
        let c = ConfidentialSession(providers: store)
        c.attestation = .previewDegraded
        return c
    }()
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false), showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(session)
        .environment(ChatGeneration())
}

/// Brave answers one question at a time (its API 422s on a second message), so
/// the composer says so once a conversation exists — otherwise a context-free
/// follow-up reads as the model losing the thread.
#Preview("Single-turn provider note") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore(inMemory: true)
        s.providers = [.braveAnswers]
        s.currentProviderID = Provider.braveAnswers.id.uuidString
        return s
    }()
    let thread: Thread = {
        let t = Thread()
        t.messages = [
            Message(role: .user, content: "what is the capital of france", thread: t),
            Message(role: .assistant, content: "**Paris** is the capital and most populous city of France.", thread: t),
        ]
        return t
    }()
    ChatView(currentThread: .constant(thread), isPromptFocused: $isPromptFocused,
             showChats: .constant(false), showSettings: .constant(false),
             showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}

/// A conversation long enough to run off the bottom of the screen, so the edge
/// where the list meets the composer is actually visible. What to look for: text
/// passing this edge should blur into the glass, not stay crisp (which ghosts it
/// through the capsule) and not fade to black (which erases it). Both fades, top
/// and bottom, are intentional. Note the preview cannot raise a keyboard — the
/// stranded-line case this guards against only reproduces on device.
#Preview("Long answer (bottom edge)") {
    @FocusState var isPromptFocused: Bool
    let store: ProviderStore = {
        let s = ProviderStore(inMemory: true)
        s.providers = [.nearAI]
        s.currentProviderID = Provider.nearAI.id.uuidString
        return s
    }()
    let thread: Thread = {
        let t = Thread()
        t.messages = [
            Message(role: .user, content: "why does the list crash on refresh", thread: t),
            Message(role: .assistant, content: """
            The crash is a **nil unwrap**: the view caches its data source on first \
            load, the refresh path replaces the underlying array, and the cached \
            reference now points at a value that no longer exists.

            The fix is one line: read the source through the accessor on every load.

            **One important distinction:** the bug is in the *caching*, not the \
            refresh. The refresh is entitled to swap the array; a cache that assumes \
            otherwise is holding state it never owned. Patching the refresh instead \
            would paper over it and break again the next time anything else swaps \
            the array.

            Three places to check before calling it fixed:
            - the first load, which populates the cache
            - the refresh, which invalidates it
            - the empty state, which never had a cache at all

            The distinction matters because the two fixes fail differently. Patching \
            the refresh hides the crash until a new call site appears; fixing the \
            cache removes the stale reference entirely, so there is nothing left \
            to go stale.
            """, thread: t),
        ]
        return t
    }()
    ChatView(currentThread: .constant(thread), isPromptFocused: $isPromptFocused,
             showChats: .constant(false), showSettings: .constant(false),
             showSettingsProviders: .constant(false), showSettingsSearch: .constant(false))
        .environment(AppSettings())
        .environment(store)
        .environment(ConfidentialSession(providers: store))
        .environment(ChatGeneration())
}
