//
//  OnboardingStyle.swift
//  teemoon
//

import SwiftUI

// MARK: - Design Tokens

enum ML {
    static let bg = Color.black
    static let ink = Color(red: 242/255, green: 242/255, blue: 245/255)
    static let muted = Color(red: 242/255, green: 242/255, blue: 245/255).opacity(0.6)
    static let faint = Color(red: 242/255, green: 242/255, blue: 245/255).opacity(0.35)
    static let hair = Color.white.opacity(0.10)
    static let accent = Color(red: 1, green: 122/255, blue: 26/255)
}

// MARK: - Animation Timing

/// Animation-timing constants for onboarding step choreography.
enum Timing {
    // Welcome typewriter sequence
    static let welcomeCursorBlink: Duration = .milliseconds(530)
    static let welcomeTypingStart: Duration = .milliseconds(900)
    static let welcomeNewlinePauseMS = 300
    static let welcomeCharDelayRangeMS = 50...120
    static let welcomeTypingSettle: Duration = .milliseconds(400)
    static let welcomeLockReveal: Duration = .milliseconds(300)
    static let welcomeDescriptionReveal: Duration = .milliseconds(400)
    static let welcomeButtonsReveal: Duration = .milliseconds(200)

    // Connecting success choreography
    static let connectedCheckReveal: Duration = .milliseconds(150)
    static let connectedMoonAdvance: Duration = .milliseconds(100)
    static let connectedTextReveal: Duration = .milliseconds(50)
    static let connectedSubtitleReveal: Duration = .milliseconds(200)
    static let connectedModelReveal: Duration = .milliseconds(200)
    static let connectedCtaReveal: Duration = .milliseconds(250)
    static let connectedBraveAutoAdvance: Duration = .milliseconds(950)

    // Celebration
    static let celebrationMoonReveal: Duration = .milliseconds(100)
    static let celebrationTitleReveal: Duration = .milliseconds(400)
    static let celebrationSubtitleReveal: Duration = .milliseconds(300)
    static let celebrationButtonReveal: Duration = .milliseconds(300)
}
