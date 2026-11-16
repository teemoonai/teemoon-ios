//
//  TrustScopeLineView.swift
//  teemoon
//

import SwiftUI

/// One trust-scope line: green when proven, orange when not checked, red when broken.
struct TrustScopeLineView: View {
    let line: TrustScopeLine

    private var tint: Color {
        switch line.tone {
        case .proven: teeVerified
        case .caution: .orange
        case .broken: .red
        case .quiet: .secondary
        }
    }

    private var icon: String {
        switch line.tone {
        case .proven: "checkmark.seal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .broken: "xmark.octagon.fill"
        case .quiet: "minus.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(line.text).font(.caption2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint)
            if let detail = line.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// (c): what the action log names as running, one row per service, its file's check on the right.
struct RunningNowSection: View {
    let rows: [TrustScope.RunningRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TrustScopeText.runningHeader)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let text = TrustScopeText.runningRow(row)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title).font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption = text.caption {
                        Text(caption).font(.caption2).foregroundStyle(.tertiary)
                    }
                    TrustScopeLineView(line: text.state)
                    if let liveness = text.liveness { TrustScopeLineView(line: liveness) }
                }
            }
            Text(TrustScopeText.runningFooter).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
