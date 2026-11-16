//
//  WhereShowOnlyRow.swift
//  teemoon
//
//  The where sheet's count + "show only" row (docs/IMAGES.md §4e). WhereFilterPolicy decides every word.
//

import SwiftUI

struct WhereShowOnlyRow: View {
    let count: String
    @Binding var filters: ModelBrowserQuery.Filter

    private var policy: WhereFilterPolicy { WhereFilterPolicy(filters: filters) }

    var body: some View {
        HStack {
            Text(count)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("where.showOnly.count")
            Spacer(minLength: 12)
            Menu {
                Section(WhereFilterPolicy.heading) {
                    ForEach(WhereFilterPolicy.offered, id: \.rawValue) { option in
                        Toggle(option.label, isOn: Binding(
                            get: { filters.contains(option) },
                            set: { on in
                                if on { filters.insert(option) } else { filters.remove(option) }
                            }))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(policy.controlLabel)
                        .fontWeight(policy.isFiltering ? .semibold : .regular)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(policy.isFiltering ? Color.accentColor : .secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("where.showOnly")
        }
        .font(.subheadline)
        .textCase(.lowercase)
    }
}
