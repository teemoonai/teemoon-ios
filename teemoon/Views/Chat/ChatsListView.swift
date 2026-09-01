//
//  ChatsListView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/5/24.
//

import StoreKit
import SwiftData
import SwiftUI

// MARK: - Date Bucketing

private enum DateBucket: String, CaseIterable {
    case today = "today"
    case yesterday = "yesterday"
    case earlierThisWeek = "earlier this week"
    case earlier = "earlier"

    static func bucket(for date: Date) -> DateBucket {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: .now))!
        if date >= weekAgo { return .earlierThisWeek }
        return .earlier
    }
}

private struct BucketedSection: Identifiable {
    let title: String
    let threads: [Thread]
    var id: String { title }
}

// MARK: - ChatRowView

private struct ChatRowView: View {
    let thread: Thread
    let bucket: DateBucket
    /// `snippet()` output for the passage that matched, when this row is a
    /// search result. nil in the ordinary list, which shows the assistant
    /// preview instead.
    var matchSnippet: String? = nil

    private var title: String {
        thread.sortedMessages.first?.content ?? "untitled"
    }

    private var preview: String? {
        thread.sortedMessages.last(where: { $0.role == .assistant })?.content
    }

    private var compactTime: String {
        let date = thread.timestamp
        switch bucket {
        case .today:
            return date.formatted(date: .omitted, time: .shortened)
        case .yesterday:
            return date.formatted(date: .omitted, time: .shortened)
        case .earlierThisWeek:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        case .earlier:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: ControlMetrics.sidebarTitleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(compactTime)
                    .font(.system(size: ControlMetrics.sidebarDateSize).monospacedDigit())
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            // A search result shows WHY it matched. The ordinary list shows the
            // last assistant reply — the old behaviour, unchanged when the
            // search box is empty.
            if let matchSnippet {
                // Centred, not verbatim: SQLite's window is measured in tokens
                // and this label is measured in lines, so a late match gets
                // truncated away. See ChatSearchHighlight.centred.
                Text(ChatSearchHighlight.attributed(ChatSearchHighlight.centred(matchSnippet)))
                    .font(.system(size: ControlMetrics.sidebarPreviewSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: ControlMetrics.sidebarPreviewSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - ChatsListView

struct ChatsListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) var dismiss
    @Binding var currentThread: Thread?
    @FocusState.Binding var isPromptFocused: Bool
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Thread.timestamp, order: .reverse) var threads: [Thread]
    @State var search = ""
    /// True only after the index DECLINED to answer (nil hits) — the sole
    /// state in which the in-memory fallback scan may run.
    @State private var indexUnavailable = false
    /// Ranked hits from the FTS index, or nil when the index could not answer.
    ///
    /// nil is NOT "no matches" — it means fall back to the in-memory filter
    /// below. Showing an empty list would state that the user's history does
    /// not contain the term, which on a missing or still-reconciling index is
    /// simply false.
    @State private var searchHits: [ChatSearchResult]?
    /// The query `searchHits` answers. Results outlive the query that produced
    /// them by a debounce interval, and rendering them against a NEWER query is
    /// how a row appears whose term is nowhere in the thread and whose snippet
    /// highlights a word the user is no longer looking for.
    @State private var hitsQuery = ""
    @State var selection: Thread?
    /// Non-nil while the confirmation for a destructive delete is up.
    @State private var threadPendingDeletion: Thread?
    #if os(macOS)
    /// Driven by Edit ▸ find (⌘F).
    @FocusState private var isSearchFocused: Bool
    #endif

    @Environment(\.requestReview) private var requestReview

    var body: some View {
        NavigationStack {
            ZStack {
                List(selection: $selection) {
                    #if os(macOS)
                    Section {} // adds some space below the search bar on mac
                    #endif
                    ForEach(bucketedSections) { section in
                        Section {
                            ForEach(section.threads, id: \.id) { thread in
                                ChatRowView(thread: thread,
                                            bucket: DateBucket.bucket(for: thread.timestamp),
                                            matchSnippet: snippet(for: thread))
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        // The swipe ROUTES THROUGH the same
                                        // confirmation as every other door:
                                        // there is no trash and no undo (see
                                        // the delete-key comment below), so a
                                        // full swipe must not be the one
                                        // unconfirmed way to lose a chat.
                                        Button(role: .destructive) {
                                            threadPendingDeletion = thread
                                        } label: {
                                            Label("delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                    #if os(macOS)
                                    .contextMenu {
                                        Button {
                                            threadPendingDeletion = thread
                                        } label: {
                                            Text("delete…")
                                        }
                                    }
                                    #endif
                                    .tag(thread)
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.7))
                                .textCase(.uppercase)
                                .kerning(0.6)
                        }
                    }
                }
                .onChange(of: selection) {
                    setCurrentThread(selection)
                }
                #if os(macOS)
                // THE DELETE KEY, AND THE CONFIRMATION THAT HAS TO COME WITH IT.
                //
                // Selecting a row in a Mac sidebar and pressing ⌫ deletes it —
                // Notes, Mail, Finder, Photos. teemoon offered no keyboard route
                // at all; the only way to remove a chat was right-click ▸ delete.
                //
                // The two arrive TOGETHER on purpose. `deleteThread` calls
                // `modelContext.delete` and there is no trash, no undo, and no
                // export — the conversation is gone from the device. Adding a
                // one-keystroke path to that without asking would not be polish,
                // it would be a new way to lose data, and the apps this imitates
                // all have somewhere to recover from. Until teemoon does, the
                // question is the safety net.
                //
                // The context-menu item routes through the same confirmation and
                // gained its ellipsis, which is what "…" means in a Mac menu:
                // this opens something before it acts.
                .onDeleteCommand {
                    guard let selection else { return }
                    threadPendingDeletion = selection
                }
                #endif
                .alert(
                    "delete this chat?",
                    isPresented: Binding(
                        get: { threadPendingDeletion != nil },
                        set: { if !$0 { threadPendingDeletion = nil } }
                    ),
                    presenting: threadPendingDeletion
                ) { thread in
                    Button("delete", role: .destructive) {
                        deleteThread(thread)
                        threadPendingDeletion = nil
                    }
                    Button("cancel", role: .cancel) { threadPendingDeletion = nil }
                } message: { _ in
                    Text("this conversation is removed from this device. it cannot be undone.")
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #elseif os(macOS) || os(visionOS)
                .listStyle(.sidebar)
                #endif
                if filteredThreads.count == 0 {
                    ContentUnavailableView {
                        Label(threads.count == 0 ? "no chats yet" : "no results", systemImage: "message")
                    }
                }
            }
            .navigationTitle("chats")
                .task {
                    // Restore the sheet's last query — @State dies with the
                    // sheet on iPhone; the session's search should not.
                    // Hits are fetched BEFORE the query is exposed: a
                    // non-empty `search` with no hits yet is what sent the
                    // old body down the full-store fallback scan.
                    guard search.isEmpty else { return }
                    let restored = ChatListSearchMemory.shared.query
                    guard !restored.isEmpty else { return }
                    let hits = await ChatSearchService.shared.search(
                        restored, granularity: .threads, limit: 500)
                    searchHits = hits
                    indexUnavailable = hits == nil
                    hitsQuery = restored
                    search = restored
                }
                .task(id: search) { await runSearch(search) }
                .onChange(of: search) { _, now in ChatListSearchMemory.shared.query = now }
            #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "search")
            #elseif os(macOS)
                .searchable(text: $search, placement: .sidebar, prompt: "search")
                // ⌘F lands here. The command is declared in the App scene, which
                // cannot reach this view's focus state, so it arrives by
                // notification — the same route File ▸ New Chat uses.
                .searchFocused($isSearchFocused)
                .onReceive(NotificationCenter.default.publisher(for: .teemoonFocusSearch)) { _ in
                    isSearchFocused = true
                }
            #endif
                .toolbar {
                    #if os(iOS) || os(visionOS)
                    if DeviceLayout.current == .phone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark")
                            }
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            selection = nil
                            // create new thread
                            setCurrentThread(nil)
                            // Same notification the Mac + / ⌘N path posts, so
                            // the composer draft (private to ChatView) clears.
                            NotificationCenter.default.post(name: .teemoonNewChat, object: nil)

                            // ask for review if appropriate
                            requestReviewIfAppropriate()
                        }) {
                            Image(systemName: "plus")
                        }
                        .keyboardShortcut("N", modifiers: [.command])
                        #if os(visionOS)
                            .buttonStyle(.bordered)
                        #endif
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            selection = nil
                            // create new thread
                            setCurrentThread(nil)

                            // ...and empty the composer, which this button could
                            // not do on its own: the draft is private state
                            // inside ChatView. File ▸ New Chat is documented as
                            // having "the same effect" as this button, and that
                            // was true — both carried the old draft into the new
                            // chat. Posting the same notification is what makes
                            // the claim hold.
                            NotificationCenter.default.post(name: .teemoonNewChat, object: nil)

                            // ask for review if appropriate
                            requestReviewIfAppropriate()
                        }) {
                            Label("new", systemImage: "plus")
                        }
                        .keyboardShortcut("N", modifiers: [.command])
                    }
                    #endif
                }
        }
        #if !os(visionOS)
        .tint(settings.appTintColor.getColor())
        #endif
        .environment(\.dynamicTypeSize, settings.appFontSize.getFontSize())
    }

    private var filteredThreads: [Thread] {
        guard !search.isEmpty else { return threads }
        // STALE RANKED HITS BEAT A LIVE FULL SCAN. During the debounce gap
        // (every keystroke, and every sheet open with a restored query)
        // `hitsQuery` trails `search` — the old code fell back to scanning
        // every message of every thread SYNCHRONOUSLY IN BODY, which is the
        // measured 0.8s freeze on the real store (hangstacks 2026-08-30).
        // Render the previous ranked hits instead; the fresh ones land within
        // ~150ms. The full scan runs only when the index cannot answer.
        if let searchHits {
            let byID = Dictionary(threads.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
            return searchHits.compactMap { byID[$0.threadID] }
        }
        if indexUnavailable { return fallbackFilteredThreads }
        return threads // awaiting the index's first answer — never scan here
    }

    /// What search was before there was an index: correct, and slow enough that
    /// it faults every message of every thread on each keystroke. Kept as the
    /// degraded path, never as the primary one.
    private var fallbackFilteredThreads: [Thread] {
        threads.filter { thread in
            thread.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(search)
            }
        }
    }

    /// The best-matching passage for a thread, when the hit came from the index.
    private func snippet(for thread: Thread) -> String? {
        if indexUnavailable {
            // Fallback rows still have to show WHY they matched. Without this a
            // degraded result renders the assistant preview, which reads as a
            // result whose keyword is nowhere in it.
            return ChatSearchHighlight.excerpt(matching: search,
                                               in: thread.sortedMessages.map(\.content))
        }
        guard hitsQuery == search else { return nil } // fresh hits are ~150ms out
        return searchHits?.first { $0.threadID == thread.id }?.snippet
    }

    /// Debounced so a fast typist runs one query, not one per keystroke. The
    /// query itself is ~1 ms; this is about not thrashing SwiftData and the
    /// main thread behind it.
    private func runSearch(_ query: String) async {
        guard !query.isEmpty else { searchHits = nil; indexUnavailable = false; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        // 500, not 100: presence beats a tidy count. A thread whose only
        // match is buried in one long reply ranks LAST under bm25's length
        // normalization, and a 100-thread cut made it vanish entirely.
        let hits = await ChatSearchService.shared.search(query, granularity: .threads, limit: 500)
        guard !Task.isCancelled else { return }
        searchHits = hits
        indexUnavailable = hits == nil
        hitsQuery = query
    }

    private var bucketedSections: [BucketedSection] {
        // A search is a RANKED list — bm25 order is the product, and
        // regrouping it into date buckets buried the best match under weak
        // recent ones. Buckets are for browsing; they return the moment the
        // query clears.
        if !search.isEmpty {
            let hits = filteredThreads
            return hits.isEmpty ? [] : [BucketedSection(title: "results", threads: hits)]
        }
        var grouped: [DateBucket: [Thread]] = [:]
        for thread in filteredThreads {
            let bucket = DateBucket.bucket(for: thread.timestamp)
            grouped[bucket, default: []].append(thread)
        }
        return DateBucket.allCases.compactMap { bucket in
            guard let threads = grouped[bucket], !threads.isEmpty else { return nil }
            return BucketedSection(title: bucket.rawValue, threads: threads)
        }
    }

    func requestReviewIfAppropriate() {
        if settings.numberOfVisits - settings.numberOfVisitsOfLastRequest >= 5 {
            requestReview() // can only be prompted if the user hasn't given a review in the last year, so it will prompt again when apple deems appropriate
            settings.numberOfVisitsOfLastRequest = settings.numberOfVisits
        }
    }

    private func deleteThread(_ thread: Thread) {
        if let currentThread = currentThread {
            if currentThread.id == thread.id {
                setCurrentThread(nil)
            }
        }
        // Drop the index rows now rather than after the delay below: the id is
        // already known, and the search field must not offer a row that is on
        // its way out.
        ChatSearchService.shared.didDeleteThread(thread.id)
        // Adding a delay fixes a crash on iOS following a deletion
        let delay = DeviceLayout.current == .phone ? 1.0 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Delete means delete: the messages cascade app-side — a bare
            // `delete(thread)` here NULLIFIED them into invisible orphans.
            // See ThreadDeletion.
            ThreadDeletion.delete(thread, in: modelContext)
        }
    }

    private func setCurrentThread(_ thread: Thread? = nil) {
        // Opened from a live search: hand the matching message to the
        // transcript, so it lands ON the passage the snippet promised
        // instead of at the bottom of the thread.
        if let thread, hitsQuery == search,
           let hit = searchHits?.first(where: { $0.threadID == thread.id }) {
            let content = thread.messages.first { $0.id == hit.messageID }?.content ?? ""
            TranscriptDeepLink.shared.deposit(
                threadID: thread.id,
                messageID: hit.messageID,
                fraction: TranscriptDeepLink.matchFraction(snippet: hit.snippet,
                                                           content: content))
        }
        currentThread = thread
        #if os(iOS)
        dismiss()
        #endif
        Haptics.play()
    }
}

#Preview {
    @FocusState var isPromptFocused: Bool
    ChatsListView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused)
        .environment(AppSettings())
        .modelContainer(for: [Thread.self, Message.self], inMemory: true)
}

/// The row in search-result mode. It needs a live FTS index to reach in the
/// app, so this feeds it `snippet()`-shaped strings directly — including the
/// partial-word case the trailing `*` produces, which is the one that would
/// look wrong if the delimiters were parsed sloppily.
#Preview("search results") {
    let open = ChatSearchIndex.highlightOpen
    let close = ChatSearchIndex.highlightClose
    let thread = Thread()
    return List {
        Section("results") {
            ChatRowView(thread: thread, bucket: .today,
                        matchSnippet: "…booked the \(open)appliance\(close) repair for Tuesday…")
            ChatRowView(thread: thread, bucket: .yesterday,
                        matchSnippet: "\(open)Applianc\(close)es were delivered before the \(open)applianc\(close)e fitter arrived…")
            ChatRowView(thread: thread, bucket: .earlier,
                        matchSnippet: "no delimiters in this one at all")
            // THE SUSPECTED FAILURE: snippet() returns up to 18 tokens, but the
            // row is lineLimit(2). When the match lands late in that window it
            // is truncated off-screen and the row reads as an unhighlighted,
            // unrelated result — while the STRING is perfectly correct, which is
            // why every string-level test passes.
            ChatRowView(thread: thread, bucket: .today,
                        matchSnippet: "…the engineer confirmed the parts were ordered and the warranty covers labour but not call-out fees so the \(open)appliance\(close)…")
        }
    }
    .environment(AppSettings())
    .modelContainer(for: [Thread.self, Message.self], inMemory: true)
}
