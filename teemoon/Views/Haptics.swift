//
//  Haptics.swift
//  teemoon
//
//  Soft impact feedback, gated by the user's haptics setting. A view-layer
//  effect — model types never touch UIKit feedback generators.
//

import SwiftUI

@MainActor
enum Haptics {
    #if os(iOS)
    private static let generator: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        return gen
    }()
    #endif

    /// Plays a soft impact if the user has haptics enabled.
    static func play() {
        guard UserDefaults.standard.object(forKey: UserDefaultsKey.shouldPlayHaptics) as? Bool ?? true else { return }
        #if os(iOS)
        generator.impactOccurred()
        generator.prepare()
        #endif
    }
}
