//
//  CreditsView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/6/24.
//
//  ATTRIBUTION, not decoration. Everything teemoon actually ships is listed with the
//  licence it ships under — Apache-2.0 requires the notice to travel with the binary,
//  and this screen is where it travels to.
//
//  It had drifted: `fullmoon-ios` was credited though nothing imports it, while the
//  three dependencies that DO ship — LiteRT-LM, dcap-qvl-swift, swift-secp256k1 —
//  were absent. The consequential omission was LiteRT-LM, whose binary framework is
//  redistributed inside the app.
//
//  Checked against `project.pbxproj`'s package references and the imports in the
//  source, not against memory. Verify both when adding or removing a dependency.
//

import SwiftUI

struct CreditsView: View {
    /// One shipped dependency: what it is, why it's here, and the licence its
    /// redistribution rests on.
    private struct Dependency: Identifiable {
        let name: String
        let license: String
        let role: String
        let url: String
        var id: String { name }
    }

    private let dependencies: [Dependency] = [
        .init(name: "LiteRT-LM", license: "Apache-2.0",
              role: "on-device inference",
              url: "https://github.com/google-ai-edge/LiteRT-LM"),
        .init(name: "AnyLanguageModel", license: "Apache-2.0",
              role: "the language-model interface",
              url: "https://github.com/huggingface/AnyLanguageModel"),
        .init(name: "dcap-qvl-swift", license: "MIT",
              role: "intel tdx quote verification",
              url: "https://github.com/Phala-Network/dcap-qvl-swift"),
        .init(name: "swift-secp256k1", license: "MIT",
              role: "signature checks on attested replies",
              url: "https://github.com/21-DOT-DEV/swift-secp256k1"),
        .init(name: "Textual", license: "MIT",
              role: "markdown rendering",
              url: "https://github.com/gonzalezreal/textual"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(dependencies) { dep in
                    if let url = URL(string: dep.url) {
                        Link(destination: url) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dep.name)
                                        .foregroundStyle(Color.primary)
                                    Text("\(dep.role) · \(dep.license)")
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                        .textCase(.lowercase)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("open source").textCase(.lowercase)
            } footer: {
                Text("teemoon redistributes these. their licences travel with the app; the full texts are at the links above.")
                    .textCase(.lowercase)
            }

            // The WEIGHTS are covered by none of the above, and that is the
            // distinction most likely to be missed: a downloaded model arrives from its
            // publisher at runtime under the publisher's own terms, and teemoon ships
            // none of it.
            Section {
                Text("models you download run under their publisher's own licence — gemma under the gemma terms of use, and so on. teemoon ships no model weights.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .textCase(.lowercase)
            } header: {
                Text("models").textCase(.lowercase)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("credits")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack { CreditsView() }
}
