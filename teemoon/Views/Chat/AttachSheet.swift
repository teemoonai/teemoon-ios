//
//  AttachSheet.swift
//  teemoon
//
//  What + opens (docs/IMAGES.md §4d, the maintainer 2026-11-11): two big buttons and the footnote, and on a model that can't
//  see images one line and a way to a model that can. Picks are reported, not run: the composer presents the camera or
//  the picker after this sheet has gone, never on top of it (the S43 camera stall).
//

#if os(iOS)

import SwiftUI

struct AttachSheet: View {
    enum Pick { case camera, photos, imageModel }

    /// The current model's name when it can't see images; nil when it can.
    let cantSeeLine: String?
    /// "up to {n} images per message" when the composer is full; the buttons then say so instead of opening.
    let fullNote: String?
    let cameraAvailable: Bool
    let onPick: (Pick) -> Void

    static let footnote = "photos are resized on this phone and their location is removed before they're sent."
    static let chooseImageModel = "choose an image-capable model"
    static func cantSee(_ model: String) -> String { "\(model) can't see images." }

    @State private var contentHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let cantSeeLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cantSeeLine)
                        .foregroundStyle(.secondary)
                    Button(Self.chooseImageModel) { onPick(.imageModel) }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let fullNote {
                Text(fullNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.attachFull")
            }
            HStack(spacing: 12) {
                if cameraAvailable {
                    bigButton("take photo", systemImage: "camera") { onPick(.camera) }
                }
                bigButton("choose photos", systemImage: "photo.on.rectangle") { onPick(.photos) }
            }
            .disabled(fullNote != nil)
            Text(Self.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .textCase(.lowercase)
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 12)
        // Measured at its own height: filling the sheet fed every pull back into the detent (the maintainer 2026-11-14).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("chat.attachSheet")
    }

    private func bigButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading) {
                Image(systemName: systemImage).font(.system(size: 26, weight: .regular))
                Spacer(minLength: 8)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.tertiarySystemFill)))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#endif
