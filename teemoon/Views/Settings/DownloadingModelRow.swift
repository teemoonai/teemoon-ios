//
//  DownloadingModelRow.swift
//  teemoon
//
//  A model that's being pulled to the server, shown as a disabled row in the
//  provider's model list — grayed, non-selectable, with inline progress — right
//  where it'll live once installed (App Store / Xcode pattern). This replaces the
//  global pinned banner (which blocked the nav bar). Only active/reconnecting
//  pulls appear here; a finished pull re-probes into a normal installed row, and
//  a failed pull is handled in the download sheet.
//

import SwiftUI

struct DownloadingModelRow: View {
    let download: OllamaDownloadCenter.Download
    /// Explicit cancel (stops the pull). Shown as an X on the row.
    var onCancel: (() -> Void)? = nil

    private var name: String {
        download.id.split(separator: "/").last.map(String.init) ?? download.id
    }
    private var statusText: String {
        download.phase == .reconnecting ? "reconnecting…" : "downloading"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(name).textCase(.lowercase).lineLimit(1)
                if let f = download.fraction, download.phase == .active {
                    ProgressView(value: f).tint(Color.accentColor)   // app tint = working
                } else {
                    ProgressView().progressViewStyle(.linear)        // indeterminate (reconnecting / no total yet)
                        .tint(download.phase == .reconnecting ? .orange : Color.accentColor)   // orange = degraded
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText).font(.caption2).textCase(.lowercase)
                if let b = download.bytes {
                    Text(b).font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.tertiary)
            .fixedSize()

            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("cancel download")
            }
        }
        .foregroundStyle(.secondary)   // grayed / de-emphasized vs installed models
    }
}

/// The ambient "warm" indicator: a small green dot that gently breathes (~2.6s cycle)
/// for a model loaded in server memory. A dot, not a badge — warm is a transient
/// runtime fact, so it reads like an activity light and vanishes cleanly when cold.
struct WarmDot: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

#if DEBUG
/// Replicates the installed model row from AddEditProviderView.modelPicker (name +
/// ctx·quant subtitle + warm chip + checkmark) so a preview mirrors the shipped UI.
@ViewBuilder
private func previewInstalledRow(_ name: String, _ sub: String, warm: Bool = false, selected: Bool = false) -> some View {
    HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).tint(.primary).textCase(.lowercase)
            Text(sub).font(.caption2).foregroundStyle(.secondary).textCase(.lowercase)
        }
        if warm {
            HStack(spacing: 4) {
                WarmDot()
                Text("warm").font(.caption2).foregroundStyle(.secondary)
            }
        }
        Spacer()
        if selected {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
        }
    }
}

/// The full model section as SHIPPED — for syncing Claude Design to the code.
#Preview("model section — shipped") {
    Form {
        Section("model") {
            DownloadingModelRow(download: .init(
                id: "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF",
                baseURL: URL(string: "https://ringzero.tailnet-name.ts.net/v1")!,
                status: "downloading…", fraction: 0.42, bytes: "2.0 / 4.7 gb", phase: .active),
                onCancel: {})
            previewInstalledRow("qwen3.5:4b", "256k · q4_k_m", warm: true, selected: true)
            previewInstalledRow("gemma4:e2b-it-qat", "128k · q4_0")
            previewInstalledRow("gemma3n:e4b", "32k · q4_0")
            Button { } label: { Label("refresh models", systemImage: "arrow.triangle.2.circlepath").textCase(.lowercase) }
            Button { } label: { Label("download a model", systemImage: "arrow.down.circle").textCase(.lowercase) }
        }
    }
}

#Preview("downloading — determinate") {
    Form {
        Section("model") {
            DownloadingModelRow(download: .init(   // in-flight pull at the TOP
                id: "hf.co/bartowski/Qwen2.5-7B-Instruct-GGUF",
                baseURL: URL(string: "https://ringzero.tailnet-name.ts.net/v1")!,
                status: "downloading…", fraction: 0.42, bytes: "2.0 / 4.7 gb", phase: .active),
                onCancel: {})
            Text("qwen3.5:4b").textCase(.lowercase)          // installed rows below
            Text("gemma4:e2b-it-qat").textCase(.lowercase)
        }
    }
}

#Preview("downloading — reconnecting") {
    Form {
        Section("model") {
            DownloadingModelRow(download: .init(
                id: "hf.co/igorls/gemma-4-e4b-it-heretic-gguf",
                baseURL: URL(string: "https://ringzero.tailnet-name.ts.net/v1")!,
                status: "reconnecting…", fraction: nil, bytes: "3.1 / 5.3 gb", phase: .reconnecting),
                onCancel: {})
        }
    }
}
#endif
