//
//  E2EEStreamCodec.swift
//  teemoon
//
//  Per-field E2EE helpers for the generation engine: request-body encryption
//  and response-field decryption around an E2EEPeer.
//

import Foundation

/// Thin wrapper around `E2EEPeer` for the streaming code paths.
///
/// `decryptField` returns nil on failure; the generation engine treats that
/// as fatal and fails the stream — ciphertext is never rendered as content.
struct E2EEStreamCodec {
    let peer: E2EEPeer

    /// HTTP headers announcing the client's E2EE public key.
    var headers: [String: String] { peer.headers }

    /// Decrypts a single field; returns nil when decryption fails so the
    /// caller can fail the stream.
    func decryptField(_ ciphertext: String) -> String? {
        try? peer.decrypt(ciphertext)
    }

    /// Encrypts a request body. Returns nil when encryption left the body
    /// unchanged — guards against `encryptRequestBody` silently returning the
    /// original on parse failure, so callers never send E2EE headers alongside
    /// a plaintext body.
    func encryptedBodyIfChanged(_ body: Data) throws -> Data? {
        let encrypted = try peer.encryptRequestBody(body)
        return encrypted == body ? nil : encrypted
    }
}
