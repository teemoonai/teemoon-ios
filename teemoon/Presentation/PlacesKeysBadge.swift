//
//  PlacesKeysBadge.swift
//  teemoon
//
//  The badge on the "cloud keys" row of places & keys. Counts KEYS, not
//  records: a cloud setup saved without a key is a row that cannot send,
//  and "1" there told a tester she had a key when she had none.
//

import Foundation

enum PlacesKeysBadge {
    /// `keyed` setups have a stored key; `unkeyed` are cloud setups that still need one.
    static func cloud(keyed: Int, unkeyed: Int) -> String {
        let need = unkeyed == 1 ? "1 needs key" : "\(unkeyed) need keys"
        switch (keyed, unkeyed) {
        case (0, 0): return "none"
        case (0, _): return need
        case (_, 0): return "\(keyed)"
        default:     return "\(keyed) · \(need)"
        }
    }
}
