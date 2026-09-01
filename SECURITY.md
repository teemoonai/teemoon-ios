# security

## supported versions

Security fixes are made against the `main` branch and the latest build available on
[TestFlight](https://testflight.apple.com/join/WHZ9VPms) / the App Store. Older
TestFlight builds and forks are not supported — update first, then report.

## reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting:

[github.com/teemoonai/teemoon-ios/security/advisories/new](https://github.com/teemoonai/teemoon-ios/security/advisories/new)

This is the only reporting channel — not email. It keeps the report, the fix, and the
disclosure timeline in one place instead of scattered across an inbox.

We'll acknowledge a new report within **72 hours** and follow up with either a fix or a
concrete remediation plan within **30 days**. This is a small team, so those are the
promises we can actually keep, not the fastest ones we could claim.

## scope

The interesting attack surface here is the attestation and verification chain, not the
UI chrome (the full account of what the app verifies, and what it does not prove, is in
[`ATTESTATION.md`](ATTESTATION.md)):

- TDX quote parsing and structural validation (`TDXQuoteVerifier`)
- DCAP cryptographic verification (`DCAPVerifier`, `dcap-qvl`)
- Sigstore/Rekor provenance checks on the enclave image
- NVIDIA Remote Attestation Service (NRAS) handling of GPU evidence
- E2EE: the X25519/XChaCha20-Poly1305 session, the binding of the encryption
  key to the model quote's `report_data`, and the separate binding of the
  response-signing address to the gateway/GPU quote

Also in scope, and treated with the same severity as a code vulnerability: **the UI
claiming more than the code actually verifies.** A trust tier or a checkmark that
overstates what was checked is a security bug in this project, not a copy nit — that's
the audit philosophy the attestation panel exists to uphold, and a false claim there is
worse than an honest "unverified."

Out of scope:

- Attacks that require a jailbroken or otherwise compromised device
- near.ai's provider-side infrastructure — this repo is the client; the enclave and
  the service around it aren't ours to fix or to receive reports for
- Issues in third-party dependencies with no teemoon-specific impact (report upstream)

## what to include

Steps to reproduce, the affected file/function if you've narrowed it down, and what you'd
expect the app to do instead. For attestation or E2EE issues, note which "place" (on-device,
near.ai, home, custom) you were testing against.
