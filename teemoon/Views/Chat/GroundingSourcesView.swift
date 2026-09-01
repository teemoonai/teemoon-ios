//
//  GroundingSourcesView.swift
//  teemoon

import SwiftUI

// MARK: - FaviconView

private struct FaviconView: View {
    let domain: String
    let size: CGFloat = 16

    private var glyph: String {
        let stripped = domain
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "en.", with: "")
            .replacingOccurrences(of: "m.", with: "")
        return stripped.prefix(1).uppercased()
    }

    private var backgroundColor: Color {
        var hash: UInt = 5381
        for c in domain.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt(c) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.55)
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: size * 0.62, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
    }
}

// MARK: - SourceRowView

private struct SourceRowView: View {
    let source: GroundingSource

    private var pathCrumb: String? {
        guard let url = URL(string: source.url) else { return nil }
        let path = url.path
        guard path.count > 1 else { return nil }
        let trimmed = String(path.prefix(40))
        return trimmed.count < path.count ? trimmed + "…" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FaviconView(domain: source.domain)
                Text(source.domain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                if let path = pathCrumb {
                    Text("›")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(path)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Text(source.title.isEmpty ? source.domain : source.title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !source.displaySnippet.isEmpty {
                Text(source.displaySnippet)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
    }
}

// MARK: - GroundingSourcesView

struct GroundingSourcesView: View {
    let sources: [GroundingSource]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            SourceRowView(source: source)
                        }
                        .buttonStyle(.plain)
                    } else {
                        SourceRowView(source: source)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparatorTint(.gray.opacity(0.3))
            }
            #if os(iOS) || os(visionOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("sources")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS) || os(visionOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
                #elseif os(macOS)
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Text("close")
                    }
                }
                #endif
            }
        }
    }
}

private let previewSources = [
    GroundingSource(
        url: "https://www.reddit.com/r/twitter/comments/example",
        domain: "reddit.com",
        title: "How I bulk-deleted 14,000 tweets without paying for the API",
        snippet: "I wrote a small script that walks the timeline and hits the delete endpoint with a 200ms throttle … no rate-limit issues over 12 hours."
    ),
    GroundingSource(
        url: "https://github.com/teisseire117/DeleteTweets",
        domain: "github.com",
        title: "teisseire117/DeleteTweets",
        snippet: "Python script that reads your Twitter archive and deletes tweets matching a date range or keyword. No API key required."
    ),
    GroundingSource(
        url: "https://redact.dev",
        domain: "redact.dev",
        title: "Redact — mass delete posts and messages",
        snippet: ""
    ),
]

#Preview("Light") {
    GroundingSourcesView(sources: previewSources)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    GroundingSourcesView(sources: previewSources)
        .preferredColorScheme(.dark)
}

// MARK: - SourceStackChipView

struct SourceStackChipView: View {
    let sources: [GroundingSource]
    @State private var showSources = false

    private let peekOffset: CGFloat = 6

    private static let headerHeight: CGFloat = 73
    private static let rowHeight: CGFloat = 100

    #if os(iOS) || os(visionOS)
    private static func detents(for count: Int) -> Set<PresentationDetent> {
        if count <= 2 {
            let contentHeight = headerHeight + rowHeight * CGFloat(count)
            return [.height(contentHeight), .medium, .large]
        } else if count >= 7 {
            return [.large]
        } else {
            return [.medium, .large]
        }
    }
    #endif

    var body: some View {
        Button { showSources = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.caption2)
                Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            // Front chip
            .background(Capsule().fill(.blue.opacity(0.75)))
            // Middle chip peeks to the right
            .background {
                if sources.count >= 2 {
                    Capsule().fill(.blue.opacity(0.45))
                        .offset(x: peekOffset)
                }
            }
            // Back chip peeks further right
            .background {
                if sources.count >= 3 {
                    Capsule().fill(.blue.opacity(0.25))
                        .offset(x: peekOffset * 2)
                }
            }
            .padding(.trailing, sources.count >= 3 ? peekOffset * 2 : sources.count >= 2 ? peekOffset : 0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.sourcesChip")
        .accessibilityLabel("\(sources.count) source\(sources.count == 1 ? "" : "s")")
        .sheet(isPresented: $showSources) {
            GroundingSourcesView(sources: sources)
            #if os(iOS) || os(visionOS)
                .presentationDetents(Self.detents(for: sources.count))
                .presentationDragIndicator(.visible)
            #elseif os(macOS)
                .frame(minWidth: 400, minHeight: 450)
            #endif
        }
    }
}
