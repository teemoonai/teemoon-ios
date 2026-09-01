//
//  FakeSSEProbe.swift
//  teemoonUITests
//
//  Asks the already-running fake SSE server what it is actually serving,
//  with one non-streaming completion request, BEFORE a test encodes any
//  expectation about the content.
//
//  Exists because of a real incident (2026-08-06): a fixture-mode server from
//  an earlier session still held the port, `/v1/models` answered identically,
//  and every content assertion in LongThreadStreamingUITests failed against
//  content the tests never streamed. `TEST FAILED` said "product bug"; the
//  truth was "wrong server". A suite that needs paragraph replies must skip —
//  loudly, naming the mismatch — when the server is serving markdown, and
//  vice versa.
//

import XCTest

enum FakeSSEProbe {

    /// One non-streaming completion, returned as plain text. The server is
    /// deterministic, so this is exactly the text every streaming request in
    /// the test will also produce.
    static func servedText(endpoint: String) throws -> String {
        guard let url = URL(string: endpoint + "/chat/completions") else {
            throw XCTSkip("TEEMOON_FAKE_SSE is not a URL: \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "fake-model",
            "stream": false,
            "messages": [["role": "user", "content": "probe"]],
        ])

        var served: String?
        let done = XCTestExpectation(description: "probe reply")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                served = message["content"] as? String
            }
            done.fulfill()
        }.resume()
        _ = XCTWaiter.wait(for: [done], timeout: 10)

        guard let served else {
            throw XCTSkip("the fake SSE server at \(endpoint) did not answer the content probe")
        }
        return served
    }

    /// Skips the calling test unless the served text contains `sentinel` —
    /// i.e. unless the server is up in the mode this test was written for.
    /// The skip message names both sides so a harness mistake reads as a
    /// harness mistake.
    static func requireServedContent(
        endpoint: String, toContain sentinel: String, mode: String
    ) throws {
        let text = try servedText(endpoint: endpoint)
        if !text.contains(sentinel) {
            throw XCTSkip(
                "server at \(endpoint) is not serving \(mode) content "
                + "(no \"\(sentinel)\" in its reply) — restart the fake SSE server "
                + "in the mode this test needs; see the file header")
        }
    }
}
