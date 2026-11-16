//
//  WhereReasoningBar.swift
//  teemoon
//
//  Developer mode's "reasoning … <level> ›" bar pinned to the where sheet's bottom, and the levels it pushes to
//  (docs/COMPOSER_PANEL.md §Developer mode, docs/REASONING_LEVEL.md). Sheet chrome, not a list row. The rules are
//  `ReasoningLevel.Row`'s.
//

import SwiftUI

struct WhereReasoningBar: View {
    let row: ReasoningLevel.Row
    let setup: Provider
    let open: () -> Void

    @State private var picks = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stored: String? {
        _ = picks
        return ReasoningLevel.stored(for: setup)
    }

    var body: some View {
        Button(action: open) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
            HStack(spacing: 8) {
                layout {
                    Text("reasoning").foregroundStyle(.primary)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(row.barValue(stored: stored)).foregroundStyle(.secondary)
                }
                if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .textCase(.lowercase)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        // Chrome, not a list row: a band one step off the sheet's ground, a hairline on top, no card.
        .background(PlatformColors.sheetBand)
        .overlay(alignment: .top) { Divider() }
        .onReceive(UserDefaults.standard.publisher(for: \.reasoningLevels).dropFirst()) { _ in picks += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("where.reasoningBar")
    }
}

/// The levels, pushed inside the where sheet. A pick applies at once.
struct ReasoningLevelsPage: View {
    let row: ReasoningLevel.Row
    let setup: Provider
    let modelName: String

    @State private var picks = 0

    private var stored: String? {
        _ = picks
        return ReasoningLevel.stored(for: setup)
    }

    var body: some View {
        List {
            Section {
                ForEach(row.levels, id: \.self) { level in
                    Button {
                        ReasoningLevel.set(level == row.defaultLevel ? nil : level, for: setup)
                        picks += 1
                    } label: {
                        HStack {
                            Text(row.label(level)).foregroundStyle(.primary)
                            Spacer()
                            if row.value(stored: stored) == level, !row.refused {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(row.refused)
                    .accessibilityAddTraits(row.value(stored: stored) == level ? .isSelected : [])
                    .accessibilityIdentifier("reasoning.level.\(level)")
                }
            } header: {
                Text(modelName)
            } footer: {
                Text(row.pageFooter(stored: stored))
            }
            .textCase(.lowercase)
        }
        .groupedListStyle()
        .navigationTitle("reasoning")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
