//
//  IntelRootCA.swift
//  TDXQuoteVerifier
//
//  Intel SGX/TDX Root CA certificate (self-signed).
//  Source: https://certificates.trustedservices.intel.com/IntelSGXRootCA.der
//
//  Subject: CN=Intel SGX Root CA, O=Intel Corporation, L=Santa Clara, ST=CA, C=US
//  Validity: 2018-05-21 to 2049-12-31
//  Key: ECDSA P-256
//  Fingerprint (SHA256): see intelRootCAFingerprint below
//

import Foundation

/// PEM-encoded Intel SGX Root CA certificate.
///
/// This is the trust anchor for all Intel SGX and TDX attestation.
/// The quote's PCK certificate chain must chain back to this root.
///
/// To update: download from Intel's PCS and replace.
/// Verify the SHA-256 fingerprint matches Intel's published value.
let intelSGXRootCAPEM = """
-----BEGIN CERTIFICATE-----
MIICjzCCAjSgAwIBAgIUImUM1lqdNInzg7SVUr9QGzknBqwwCgYIKoZIzj0EAwIw
aDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENv
cnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJ
BgNVBAYTAlVTMB4XDTE4MDUyMTEwNDExMVoXDTQ5MTIzMTIzNTk1OVowaDEaMBgG
A1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0
aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYT
AlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEC6nEwMDIYZOj/iPWsCzaEKi7
1OiOSLRFhWGjbnBVJfVnkY4u3IjkDYYL0MxO4mqsyYjlBalTVYxFP2sJBK5zlKOB
uzCBuDAfBgNVHSMEGDAWgBQiZQzWWp00ifODtJVSv1AbOScGrDBSBgNVHR8ESzBJ
MEegRaBDhkFodHRwczovL2NlcnRpZmljYXRlcy50cnVzdGVkc2VydmljZXMuaW50
ZWwuY29tL0ludGVsU0dYUm9vdENBLmRlcjAdBgNVHQ4EFgQUImUM1lqdNInzg7SV
Ur9QGzknBqwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQEwCgYI
KoZIzj0EAwIDSQAwRgIhAOW/5QkR+S9CiSDcNoowLuPRLsWGf/Yi7GSX94BgwTwg
AiEA4fQ+jnO5kDrAhLUo0uX2cp1L7wQUNBJdBAe4zJpuHgg=
-----END CERTIFICATE-----
"""

/// SHA-256 fingerprint of the Intel SGX Root CA certificate (DER-encoded).
/// Use this to verify you have the correct root CA.
let intelRootCAFingerprint = "06a4d221e1d57d35df8feb50ea0c0e0005a58f4b27a1f441d01e74eade10cd8c"
