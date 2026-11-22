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
    /// Stops reading once the body passes `limit` bytes and throws `HTTPBodyTooLarge`.
    func data(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse)
}

struct HTTPBodyTooLarge: Error, Equatable {}

extension HTTPClient {
    /// Seams that hand back planted bytes: the limit is checked on what they return.
    func data(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (data, response) = try await data(for: request)
        guard data.count <= limit else { throw HTTPBodyTooLarge() }
        return (data, response)
    }
}

struct URLSessionHTTP: HTTPClient {
    let session: URLSession

    init(session: URLSession = .chat) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    /// Streams the body and cancels the transfer past `limit`: an oversize answer is never downloaded whole.
    func data(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) { bytes.task.cancel(); throw HTTPBodyTooLarge() }
        var data = Data()
        data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), Int64(limit))))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { bytes.task.cancel(); throw HTTPBodyTooLarge() }
        }
        return (data, response)
    }
}
