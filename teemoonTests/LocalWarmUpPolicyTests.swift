//
//  LocalWarmUpPolicyTests.swift
//  teemoonTests
//

import Foundation
import Testing
@testable import teemoon

@Suite("Local warm-up policy")
struct LocalWarmUpPolicyTests {
    private static let ref = LocalModelRef(
        id: "google/gemma-4-e2b", directory: URL(fileURLWithPath: "/tmp/m"),
        sizeMB: 2400, bundleFile: URL(fileURLWithPath: "/tmp/m/model.litertlm"))

    @Test func anInstalledOnDeviceModelIsWarmed() {
        var provider = Provider.nearAI
        provider.localModelID = Self.ref.id
        let target = LocalWarmUpPolicy.target(for: provider) { id in id == Self.ref.id ? Self.ref : nil }
        #expect(target == Self.ref)
    }

    @Test func aModelNotOnDiskIsNot() {
        var provider = Provider.nearAI
        provider.localModelID = Self.ref.id
        #expect(LocalWarmUpPolicy.target(for: provider) { _ in nil } == nil)
    }

    @Test func cloudAndNothingAreNot() {
        #expect(LocalWarmUpPolicy.target(for: Provider.nearAI) { _ in Self.ref } == nil)
        #expect(LocalWarmUpPolicy.target(for: nil) { _ in Self.ref } == nil)
    }
}
