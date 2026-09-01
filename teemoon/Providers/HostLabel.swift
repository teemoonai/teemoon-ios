//
//  HostLabel.swift
//  teemoon
//
//  How a hostname becomes a place name. Lives with Provider so persistence and
//  the Where rows can name a machine without importing Presentation.
//
//  A tailnet FQDN is mostly suffix: ringzero.tailnet-name.ts.net → "ringzero".
//  An IPv4 literal has no name to take, so it stays whole.
//

import Foundation

enum HostLabel {
    /// First DNS label of a hostname; the address itself for an IPv4 literal.
    static func friendly(_ host: String) -> String {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return host }
        return parts.first.map(String.init) ?? host
    }
}
