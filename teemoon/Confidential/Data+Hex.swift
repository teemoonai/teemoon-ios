//
//  Data+Hex.swift
//  teemoon
//
//  Hex encoding/decoding used by the E2EE wire format and attestation parsing.
//

import Foundation

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexString hex: String) throws {
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next != i, let byte = UInt8(hex[i..<next], radix: 16) else {
                throw E2EEError.invalidHex
            }
            data.append(byte)
            i = next
        }
        self = data
    }
}
