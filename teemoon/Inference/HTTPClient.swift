//
//  HTTPClient.swift
//  teemoon
//
//  One-method GET/POST seam so attestation, key check, and search validation
//  can run against planted bytes. Production uses URLSession; tests do not
//  touch the network. Same shape as NRASHTTPClient / CollateralHTTPClient.
//

import Foundation

protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTP: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
