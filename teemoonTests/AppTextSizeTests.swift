//
//  AppTextSizeTests.swift
//  teemoonTests
//
//  1.1.0 (the maintainer, 2026-10-30): the size setting follows Dynamic Type. Each choice is a step relative to the phone's
//  size; "large" became "system" and keeps its stored name; an install that never chose gets system. Before 1.1.0
//  a fixed size replaced the phone's, so the accessibility sizes never reached the app.
//

import SwiftUI
import Testing
@testable import teemoon

@Suite("Text size follows the phone")
struct AppTextSizeTests {
    @Test func onADefaultPhoneEachChoiceDrawsAsBefore() {
        #expect(AppFontSize.xsmall.dynamicTypeSize(phone: .large) == .xSmall)
        #expect(AppFontSize.small.dynamicTypeSize(phone: .large) == .small)
        #expect(AppFontSize.medium.dynamicTypeSize(phone: .large) == .medium)
        #expect(AppFontSize.system.dynamicTypeSize(phone: .large) == .large)
        #expect(AppFontSize.xlarge.dynamicTypeSize(phone: .large) == .xLarge)
    }

    @Test func systemIsThePhonesSize() {
        for phone in DynamicTypeSize.allCases {
            #expect(AppFontSize.system.dynamicTypeSize(phone: phone) == phone)
        }
    }

    @Test func aChoiceRidesOnTheAccessibilitySizes() {
        #expect(AppFontSize.medium.dynamicTypeSize(phone: .accessibility3) == .accessibility2)
        #expect(AppFontSize.xlarge.dynamicTypeSize(phone: .accessibility3) == .accessibility4)
    }

    @Test func theStepsClampAtBothEnds() {
        #expect(AppFontSize.xsmall.dynamicTypeSize(phone: .small) == .xSmall)
        #expect(AppFontSize.xlarge.dynamicTypeSize(phone: .accessibility5) == .accessibility5)
    }

    @Test func theListReadsInSizeOrder() {
        #expect(AppFontSize.allCases.map { String(describing: $0) } == ["xsmall", "small", "medium", "system", "xlarge"])
    }

    @Test func aStoredLargeIsSystem() {
        #expect(AppFontSize(rawValue: "large") == .system)
        #expect(AppFontSize.system.rawValue == "large")
    }

    @MainActor @Test func anInstallThatNeverChoseGetsSystem() {
        let key = UserDefaultsKey.appFontSize
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppSettings().appFontSize == .system)
        UserDefaults.standard.set("small", forKey: key)
        #expect(AppSettings().appFontSize == .small)
    }
}

@Suite("Fixed design sizes scale like the nearest text style")
struct ScaledTextTests {
    @Test func eachDesignSizeScalesWithTheStyleOfThatSize() {
        #expect(ScaledText.nearestStyle(to: 9) == .caption2)
        #expect(ScaledText.nearestStyle(to: 11) == .caption2)
        #expect(ScaledText.nearestStyle(to: 12) == .caption)
        #expect(ScaledText.nearestStyle(to: 13) == .footnote)
        #expect(ScaledText.nearestStyle(to: 13.5) == .footnote)
        #expect(ScaledText.nearestStyle(to: 14) == .footnote)
        #expect(ScaledText.nearestStyle(to: 15.5) == .subheadline)
        #expect(ScaledText.nearestStyle(to: 16) == .callout)
        #expect(ScaledText.nearestStyle(to: 17) == .body)
        #expect(ScaledText.nearestStyle(to: 20) == .title3)
        #expect(ScaledText.nearestStyle(to: 29) == .title)
        #expect(ScaledText.nearestStyle(to: 32) == .largeTitle)
    }

    @Test func linesHoldAtOrdinarySizesAndWrapAtAccessibilitySizes() {
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            #expect(ScaledText.lineLimit(1, at: size) == 1)
            #expect(ScaledText.lineLimit(2, at: size) == 2)
        }
        for size in DynamicTypeSize.allCases where size.isAccessibilitySize {
            #expect(ScaledText.lineLimit(1, at: size) == 3)
            #expect(ScaledText.lineLimit(2, at: size) == 6)
        }
    }
}
