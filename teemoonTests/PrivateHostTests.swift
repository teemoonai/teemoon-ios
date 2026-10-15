//
//  PrivateHostTests.swift
//  teemoonTests
//
//  `Provider.isPrivateHost` decides whether an endpoint is the user's own
//  machine. That answer is not cosmetic: it makes the api key optional, drops
//  the cleartext-http warning, files the provider under `home` in the Where
//  sheet, and — the one that matters most — makes `TrustVerdict` return
//  `.selfHosted` from `chipMode`, so the trust sheet tells the user their plaintext is staying
//  on a machine they own.
//
//  So a host that is NOT the user's machine must never classify as private.
//  It used to: `compactMap { UInt8($0) }` DROPPED every label that wasn't a
//  number in 0...255 instead of rejecting the host, so `10.0.0.1.attacker.com`
//  kept four octets, passed the count guard, and read as 10.0.0.0/8.
//  Reported 2026-09-20 from the Android port, whose Kotlin had the label-count
//  check the Swift was missing.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Private host classification")
struct PrivateHostTests {

    /// Each of these is a PUBLIC host an attacker can register and serve. The
    /// numeric prefix is the whole trick — it survives the octet parse and the
    /// real registrable domain is thrown away.
    @Test(arguments: [
        "10.0.0.1.attacker.com",
        "192.168.1.1.evil.com",
        "127.0.0.1.evil.com",
        "172.16.0.1.evil.com",
        "169.254.0.1.evil.com",
        "100.64.0.1.evil.com",       // the Tailscale CGNAT range
        "10.999.0.0.1.evil.com",     // out-of-range labels were dropped too
        "10.0.0.1.attacker.com.",    // trailing root dot
    ])
    func publicHostWearingAPrivatePrefixIsNotPrivate(_ host: String) {
        #expect(Provider.isPrivateHost(host) == false,
                "\(host) is a public host — classifying it private makes its key optional, silences the cleartext warning, and tells the user it is their own machine")
    }

    /// The real thing must keep working — this is the range list the comment on
    /// `isPrivateHost` promises.
    ///
    /// BOTH ENDS OF EVERY RANGE. One value per range proves only that the range
    /// STARTS, not that it spans: narrowing 127/8 to 127.0/16, or 192.168/16 to
    /// 192.168.1/24, leaves any low-end value passing. Mutation-checked — each
    /// of those narrowings is caught here by exactly one high-end address and
    /// nothing else, so none of these is decorative. (The 172 and CGNAT bounds
    /// are ranges rather than equalities; their ends are pinned the same way,
    /// and `addressesOutsideThePrivateRangesArePublic` covers widening.)
    @Test(arguments: [
        "127.0.0.1", "127.255.255.254",           // 127.0.0.0/8
        "10.0.0.1", "10.255.255.254",             // 10.0.0.0/8
        "192.168.0.1", "192.168.255.254",         // 192.168.0.0/16
        "172.16.0.1", "172.31.255.254",           // 172.16.0.0/12
        "169.254.0.1", "169.254.255.254",         // 169.254.0.0/16
        "100.64.0.1", "100.127.255.254",          // 100.64.0.0/10 CGNAT
    ])
    func privateIPv4LiteralsStayPrivate(_ host: String) {
        #expect(Provider.isPrivateHost(host), "\(host) is an RFC1918/CGNAT/loopback literal")
    }

    @Test(arguments: ["localhost", "::1", "mac.local", "ringzero.tailnet-name.ts.net"])
    func privateNameSuffixesStayPrivate(_ host: String) {
        #expect(Provider.isPrivateHost(host))
    }

    /// Public hosts with no numeric games, including the ones teemoon ships as
    /// presets — a regression here would make every cloud provider keyless.
    @Test(arguments: [
        "example.com", "api.openai.com", "api.near.ai",
        "api.fireworks.ai", "openrouter.ai", "8.8.8.8", "1.1.1.1",
    ])
    func publicHostsAreNotPrivate(_ host: String) {
        #expect(Provider.isPrivateHost(host) == false)
    }

    /// The addresses either side of each range. The in-range values above prove
    /// the ranges work; only these prove they STOP where they claim to — widen
    /// `172.16.0.0/12` to `16...32` or CGNAT to `64...128` and nothing else here
    /// fails. (Android's suite carried `172.32.0.1`; this one did not, which is
    /// the same untested-boundary gap in the other direction.)
    @Test(arguments: [
        "172.15.255.254",   // just below 172.16.0.0/12
        "172.32.0.1",       // just above 172.31.255.255
        "100.63.255.254",   // just below the Tailscale CGNAT range
        "100.128.0.1",      // just above it
        "192.167.1.1",      // 192.168.0.0/16 is one /16, not a /8
        "192.169.1.1",
        "169.253.0.1",      // link-local is 169.254 only
        "169.255.0.1",
        "126.0.0.1",        // loopback is 127/8, and 11/8 is not 10/8
        "128.0.0.1",
        "11.0.0.1",
    ])
    func addressesOutsideThePrivateRangesArePublic(_ host: String) {
        #expect(Provider.isPrivateHost(host) == false,
                "\(host) is outside every private range — a widened bound makes a public address self-hosted")
    }

    /// The classification is what `isSelfHosted` is built on, and `isSelfHosted`
    /// is what the trust sheet reads. Pin the whole chain, not just the leaf.
    @Test func anAttackerHostIsNeitherSelfHostedNorTrustedAsSuch() {
        let provider = Provider(name: "totally my laptop",
                                endpoint: "http://10.0.0.1.attacker.com/v1",
                                model: "some-model",
                                requiresAPIKey: false)
        #expect(provider.isSelfHosted == false)

        let mode = TrustVerdict.chipMode(
            .init(attestationState: .none, isLocal: false, isSelfHosted: provider.isSelfHosted))
        #expect(mode != .selfHosted,
                "the trust sheet would say 'on your own machine' about an attacker's server")
    }
}
