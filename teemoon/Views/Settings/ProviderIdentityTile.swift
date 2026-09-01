//
//  ProviderIdentityTile.swift
//  teemoon
//
//  The provider's identity mark, shown in the provider-detail view and preset
//  rows. Prefers a real brand logo from the asset catalog when one exists;
//  otherwise falls back to a placeholder — a lowercase monogram tile for cloud
//  providers, a server glyph for self-hosted endpoints (the design's 4f / 4c
//  split). Dropping real logos in later is a pure asset add, no code change.
//

import SwiftUI

// `namedAssetExists` moved to PlatformAssets.swift — AddEditProviderView needed
// the same check and had open-coded a UIKit-only `UIImage(named:)` instead,
// which is what broke the macOS build. One copy now, shared.

struct ProviderIdentityTile: View {
    let name: String
    let isSelfHosted: Bool
    var size: CGFloat = 58

    /// Asset-catalog name for a real logo, if present (e.g. "near.ai" → "provider-logo-near-ai").
    private var logoAssetName: String {
        "provider-logo-" + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private var monogram: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).lowercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(.secondarySystemFill))

            if namedAssetExists(logoAssetName) {
                Image(logoAssetName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
            } else if isSelfHosted {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("Identity tiles") {
    HStack(spacing: 16) {
        ProviderIdentityTile(name: "near.ai", isSelfHosted: false)
        ProviderIdentityTile(name: "grok", isSelfHosted: false)
        ProviderIdentityTile(name: "local qwen", isSelfHosted: true)
    }
    .padding()
}
