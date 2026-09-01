//
//  NoActionLogNotice.swift
//  teemoon
//

import SwiftUI

/// Shown when the model enclave carries NO signed action-log pin — an ABSENCE,
/// surfaced (orange) rather than collapsing to a benign flat list. The seam's
/// load-bearing check has nothing to check, and that fact must be visible.
struct NoActionLogNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("recipe not verifiable").font(.footnote).fontWeight(.semibold)
                Text("this enclave exposed no signed action log, so the running engine + proxy recipe can’t be hash-checked on this device — it isn’t pinned by anything you can verify here.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }
}
