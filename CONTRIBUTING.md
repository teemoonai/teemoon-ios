# contributing

## building and testing

See [`README.md`](README.md#building) and [`README.md`](README.md#testing) — build
requirements, the LFS step, and the exact `xcodebuild` invocation for the offline unit
suite all live there rather than being repeated here.

## the CLA

teemoon is AGPL-3.0 and is also distributed through the App Store by the copyright
holder, ringzero ventures llc. Apple's terms and the AGPL can only coexist for a
distribution ringzero itself controls the copyright of — a pull request that added
someone else's copyrighted code without an agreement in place would break that. The
CLA is what lets outside contributions in without giving that up: it assigns or
licenses your contribution so ringzero can keep distributing the whole work, App Store
included, under both.

You don't have to sign anything up front. Open your first pull request and
cla-assistant will comment with the agreement and a link to sign it electronically —
takes a minute, and it's remembered for every PR after that.

## opening a pull request

- **Bug fixes need a regression test.** This is a house rule, not a suggestion — a fix
  without a test that would have caught the bug will get sent back for one.
- **Keep claims accurate.** A comment, doc, or UI string that says the code verifies or
  checks more than it actually does is treated as a bug here, same severity as a
  functional one — this matters most on the attestation and E2EE paths, but it applies
  everywhere.
- Keep the unit suite offline (no keys, no network) — see `README.md#testing` for what
  that means in practice.
- Large or speculative changes: open an issue first. It's a faster path than a PR that
  has to be re-architected in review.

## reporting a security issue

Don't file it as an issue or a PR. See [`SECURITY.md`](SECURITY.md) for the private
reporting channel and what's in scope.
