//
//  NearImportView.swift
//  teemoon
//
//  The import sheet, laid out like Safari's import: a hero, a title, the file card, one button at the bottom.
//  Opened from Settings → chats and when a file is opened from Files. A switch on ChatImportModel.state.
//

import SwiftData
import SwiftUI

struct NearImportView: View {
    let importer: ChatImportModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ImportHero(done: { if case .finished = importer.state { true } else { false } }())
                    .padding(.top, 24)
                Text(ChatImportText.title(for: importer.state))
                    .font(.largeTitle.bold())
                    .padding(.top, 28)
                Text(bodyText)
                    .padding(.top, 12)
                middle
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            // Opaque: at the largest text sizes the content scrolls under the button.
            // Safari's import: the button 30 pt in from each side, its bottom on the safe area's (pinned by
            // ImportBottomButtonLayoutUITests); do not pad below it.
            bottom
                .padding(.horizontal, 30)
                .padding(.top, 12)
                .frame(maxWidth: 580)
                .frame(maxWidth: .infinity)
                .background(.background)
        }
        .toolbar {
            if !isFinished, !importer.isBusy, !isNothingNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatImportText.cancel, action: close).accessibilityIdentifier("import.cancel")
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Kept while no button shows (reading, importing), or the hero jumps up by the bar's height.
        .toolbar(.visible, for: .navigationBar)
        #endif
        .interactiveDismissDisabled(importer.isBusy)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importer.dismissResult()
            importer.check(url: url, container: modelContext.container)
        }
        .onChange(of: importer.state) { _, state in
            if case .finished = state { Haptics.play() }
        }
        .chatImportFailureAlert(importer)
    }

    private func close() {
        importer.dismissResult()
        dismiss()
    }

    private func leave(showingChats: Bool) {
        importer.leave(showingChats: showingChats)
        dismiss()
    }

    private var isFinished: Bool {
        if case .finished = importer.state { true } else { false }
    }

    private var isNothingNew: Bool {
        if case .confirm(let s) = importer.state { ChatImportText.isNothingNew(s) } else { false }
    }

    private var bodyText: String {
        switch importer.state {
        case .confirm(let s) where ChatImportText.isNothingNew(s):
            s.chatsAlreadyHere > 0 ? ChatImportText.nothingNewBody : ChatImportText.emptyBody
        case .importing: ChatImportText.importingBody
        case .finished(let s): ChatImportText.finishedBody(s)
        default: ChatImportText.intro
        }
    }

    @ViewBuilder private var middle: some View {
        switch importer.state {
        case .idle, .failed:
            Text(ChatImportText.exportPath)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Button { picking = true } label: {
                Text(ChatImportText.chooseFile)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(ImportHero.tile, in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.top, 32)
            .accessibilityIdentifier("import.chooseFile")
        case .checking:
            ImportFileCard(file: importer.file, counts: nil, note: nil, reading: true)
                .padding(.top, 28)
        case .confirm(let preview):
            ImportFileCard(file: importer.file, counts: ChatImportText.cardCounts(preview),
                           note: ChatImportText.cardNote(preview))
                .padding(.top, 28)
            Button(ChatImportText.chooseAnother) { picking = true }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .padding(.top, 14)
                .accessibilityIdentifier("import.chooseAnother")
        case .importing:
            EmptyView()
        case .finished(let summary):
            ForEach(ChatImportText.finishedNotes(summary), id: \.self) {
                Text($0).font(.subheadline).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        switch importer.state {
        case .importing(let read, let total):
            VStack(spacing: 10) {
                ProgressView(value: ChatImportModel.fraction(read: read, total: total))
                Text(ChatImportText.progress(read: read, total: total))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("import.progress")
            .frame(minHeight: ImportBottomButton.height)   // centred where the button stood
        case .finished:
            ImportBottomButton(title: ChatImportText.done, enabled: true) { leave(showingChats: false) }
                .accessibilityIdentifier("import.done")
        case .confirm(let preview) where ChatImportText.isNothingNew(preview):
            ImportBottomButton(title: ChatImportText.done, enabled: true, action: close)
                .accessibilityIdentifier("import.done")
        case .confirm(let preview):
            ImportBottomButton(title: ChatImportText.importButton, enabled: preview.chatsImported > 0) {
                importer.confirm(container: modelContext.container, mainContext: modelContext)
            }
            .accessibilityIdentifier("import.confirm")
        default:
            ImportBottomButton(title: ChatImportText.importButton, enabled: false) {}
                .accessibilityIdentifier("import.confirm")
        }
    }
}

/// The cluster of tiles above the title, a glyph and an accent outline on each; done fills the centre tile with the check.
private struct ImportHero: View {
    let done: Bool

    // System grouped colours, not fixed values: a sheet's dark background is #1C1C1E, the tile colour on black.
    #if os(macOS)
    static let tile = Color(nsColor: .controlBackgroundColor)
    static let inner = Color(nsColor: .underPageBackgroundColor)
    #else
    static let tile = Color(uiColor: .secondarySystemBackground)
    static let inner = Color(uiColor: .tertiarySystemBackground)
    #endif
    static let outline: CGFloat = 1.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            side("lock", size: 44, radius: 12, x: 0, y: 52)
            side("photo", size: 54, radius: 14, x: 52, y: 8)
            centre.offset(x: 96, y: 40)
            side("moon", size: 50, radius: 14, x: 178, y: 4)
            side("doc", size: 44, radius: 12, x: 190, y: 66)
        }
        .frame(width: 250, height: 120, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var centre: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(done ? AnyShapeStyle(.tint) : AnyShapeStyle(Self.tile))
            .frame(width: 72, height: 72)
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: Self.outline) }
            .overlay {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 32, weight: .bold))
                        .foregroundStyle(PlatformColors.background)
                } else {
                    Image(systemName: "bubble.left").font(.system(size: 32, weight: .medium)).foregroundStyle(.tint)
                }
            }
    }

    private func side(_ symbol: String, size: CGFloat, radius: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Self.tile)
            .frame(width: size, height: size)
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.tint, lineWidth: Self.outline) }
            .overlay {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.tint)
            }
            .offset(x: x, y: y)
    }
}

/// The chosen file: name, what it holds, its date and size, and what won't come in.
private struct ImportFileCard: View {
    let file: ChatImportModel.FileFacts?
    let counts: String?
    let note: String?
    /// The dry run is reading the file: a spinner stands where the counts go.
    var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(ImportHero.inner, in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let file {
                        Text(file.name).font(.callout.weight(.semibold)).lineLimitGrowing(1).truncationMode(.middle)
                    }
                    if reading {
                        ProgressView().controlSize(.small)
                    } else if let counts {
                        Text(counts).font(.subheadline)
                    }
                    if let file, let facts = ChatImportText.fileFacts(file) {
                        Text(facts).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note {
                Divider()
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(ImportHero.tile, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import.file")
    }
}

/// The one capsule at the bottom: accent when it can be tapped, grey until then.
private struct ImportBottomButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    static let height: CGFloat = 54

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: Self.height)
                .foregroundStyle(enabled ? AnyShapeStyle(PlatformColors.background) : AnyShapeStyle(.secondary))
                .background(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(ImportHero.tile), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
