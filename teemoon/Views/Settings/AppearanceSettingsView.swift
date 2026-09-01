//
//  AppearanceSettingsView.swift
//  teemoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            #if os(iOS)
            Section {
                Picker(selection: $settings.appTintColor) {
                    ForEach(AppTintColor.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { option in
                        Text(String(describing: option).lowercased())
                            .tag(option)
                    }
                } label: {
                    Label("color", systemImage: "paintbrush.pointed")
                }
                .accessibilityIdentifier("appearance.color")
                .pickerStyle(.navigationLink)
            }
            #endif

            Section(header: Text("font")) {
                Picker(selection: $settings.appFontDesign) {
                    ForEach(AppFontDesign.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { option in
                        Text(String(describing: option).lowercased())
                            .tag(option)
                    }
                } label: {
                    Label("design", systemImage: "textformat")
                }

                Picker(selection: $settings.appFontWidth) {
                    ForEach(AppFontWidth.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { option in
                        Text(String(describing: option).lowercased())
                            .tag(option)
                    }
                } label: {
                    Label("width", systemImage: "arrow.left.and.line.vertical.and.arrow.right")
                }
                .disabled(settings.appFontDesign != .standard)

                #if !os(macOS)
                Picker(selection: $settings.appFontSize) {
                    ForEach(AppFontSize.allCases.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { option in
                        Text(String(describing: option).lowercased())
                            .tag(option)
                    }
                } label: {
                    Label("size", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("appearance.size")
                .pickerStyle(.navigationLink)
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("appearance")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    AppearanceSettingsView()
        .environment(AppSettings())
}
