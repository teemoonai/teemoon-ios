//
//  AttestationState.swift
//  teemoon
//
//  The four-way session state the chip and sheet share. Interpretation
//  lives on ConfidentialSession; everyday sentences live on TrustVerdict.
//

import Foundation

/// Combined security state for the nav bar lock indicator and the
/// attestation sheet.
enum AttestationState: Equatable {
    /// TEE attested and E2EE encryption active.
    case ok
    /// TEE attested but E2EE failed or unavailable (plaintext inside enclave).
    case degraded
    /// Attestation is being fetched — not yet verified.
    case verifying
    /// Provider doesn't support TEE — no indicator shown.
    case none

    /// Plain caption used when the chip is not in a special mode.
    var caption: String {
        switch self {
        case .verifying: return "verifying\u{2026}"
        case .ok:        return "end-to-end encrypted"
        case .degraded:  return "not end-to-end encrypted"
        case .none:      return ""
        }
    }
}
