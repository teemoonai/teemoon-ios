//
//  HomeServerProbeStaleTests.swift
//  teemoonTests
//
//  A model deleted from the user's machine came back: a probe already in flight
//  when the delete landed wrote the pre-delete list over `forget`, and the
//  where sheet mirrored it back into the equipped set.
//

import Foundation
import Testing
@testable import teemoon

@MainActor
@Suite("Home server probe — stale results")
struct HomeServerProbeStaleTests {

    actor Calls {
        let gate = AsyncGate()
        private var count = 0
        func next() async -> Int { count += 1; return count }
    }

    private let box = Provider(name: "box", endpoint: "http://box.local:11434/v1/chat/completions", model: "a")

    @Test func aProbeInFlightAcrossADeleteDoesNotBringTheModelBack() async {
        let calls = Calls()
        let probe = HomeServerProbe(probe: { _, _, _ in
            if await calls.next() > 1 { await calls.gate.pass() }
            return HomeServerProbe.Info(kind: .ollama, models: ["a", "b"])
        })
        await probe.refresh([box]) { _ in "" }
        #expect(probe.info(for: box)?.models == ["a", "b"])

        let inFlight = Task { await probe.refresh([box]) { _ in "" } }
        await calls.gate.reached()
        probe.forget(modelID: "b", on: box)
        await calls.gate.open()
        await inFlight.value
        #expect(probe.info(for: box)?.models == ["a"], "the server's list was read before the delete")
    }
}

@MainActor
@Suite("Home capabilities follow the machine")
struct HomeCapabilityRefreshEndpointTests {
    @Test func aSetupPointedAtAnotherMachineIsAskedAgain() async {
        var asked: [URL] = []
        let refresh = HomeCapabilityRefresh(list: { asked.append($0)
            return [KnownModel(id: "llava", displayName: "llava", vendor: "", price: "", capabilities: [.vision])] })
        var home = Provider(name: "box", endpoint: "http://box.local:11434/v1/chat/completions", model: "llava")
        home.equippedModels = ["llava"]
        await refresh.refresh([home], kind: { _ in .ollama }, adopt: { _, _ in })
        home.endpoint = "http://other.local:11434/v1/chat/completions"
        await refresh.refresh([home], kind: { _ in .ollama }, adopt: { _, _ in })
        #expect(asked.count == 2, "the hour belongs to the first machine, not to the setup's id")
    }
}
