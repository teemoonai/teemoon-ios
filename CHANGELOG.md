# Changelog

Changes to the teemoon iPhone app, one section per public release, newest first. The date is that of the release commit on public `main`. Older sections state only what their GitHub release notes and audit pages say.

## 1.1.0 (62) — 2026-11-17

### Added
- Images: attach from Photos, take one in teemoon, paste, or share one from any app; Wuffs decodes JPEG, PNG and GIF, and every image is re-encoded with no location or camera metadata.
- Gemma on the phone reads images when the phone has the memory free.
- near.ai Private Chat import: settings → chats → "import from near.ai", images stored in the export included.

### Changed
- The composer is one panel; text size follows Dynamic Type; a stopped or cut-short reply says so after the chat is reopened.

### Fixed
- Your chats stay where 1.0.6 kept them, and streaming code and thinking blocks render without flicker.

### Security
- Fixed the 1.0.6 MEDIUM: under unpublished-only provenance the send gate allowed a recipe-hash mismatch; it now blocks.
- A sealed request never asks for a plaintext reply field, near.ai image parts are sealed with the text, and a turn that started attestable never leaves unsealed.

### Known issues
- MEDIUM, found after release (audit addendum 2026-11-19, mechanism present at 1.0.6): the app verifies only the first listed near.ai model enclave, but every enclave near.ai's key service admits under the app id holds the same key, so a sealed message can be opened by enclaves the app did not verify.
- Two LOWs accepted for 1.1.0, fix planned in 1.1.1: near.ai's model list can move a sealed model to plain TLS with no ask, and a model key with no quote behind it gets the "send anyway" ask.
- `conformance/` and `docs/` are not in the public tree, so tests that load them fail from a public clone and public CI is red.

[`v1.1.0`](https://github.com/teemoonai/teemoon-ios/tree/v1.1.0) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.1.0) · [audit v1.1.0-6c5f7a2](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.1.0-6c5f7a2.md) · [full 1.1.0 detail](docs/releases/1.1.0.md)

## 1.0.6 (60) — 2026-10-23

### Changed
- Reasoning defaults to low: up to 11× faster first token (near.ai GLM 5.3 Flash 14.6 s → 1.3 s, Fireworks 5×); long-press a reply and tap think harder for hard problems.

### Fixed
- Caching: Fireworks GLM 5.3 Flash reused ~0% of earlier input, now up to 90% per message (it varies).
- Deleted chats stay deleted.

### Security
- near.ai reply signatures are checked against the attested model's key.
- NVIDIA GPU tokens and TLS quotes are verified.

### Known issues
- MEDIUM (audit addendum 2026-11-06): under unpublished-only provenance the send gate allowed a recipe-hash mismatch. Fixed in 1.1.0.
- Two LOWs (audit addendum): the chip could read "verified" while checks were in flight, and a previous record's provenance verdict could carry over. Fixed in 1.1.0.
- MEDIUM (audit addendum 2026-11-19): the app verifies only the first listed near.ai model enclave, and the listed enclaves share one key. Open in 1.1.0.
- Two LOWs first recorded by the 1.1.0 audit are present here: near.ai's model list can move a sealed model to plain TLS with no ask, and a model key with no quote behind it gets the 'send anyway' ask.

[`v1.0.6`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.6) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.6) · [audit v1.0.6-ab64f15](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.6-ab64f15.md) · [build audit tf-1.0.6-60-06cd6f6](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/tf-1.0.6-60-06cd6f6.md)

## 1.0.5 (43) — 2026-10-15

### Added
- An on-device answer cut short when you leave the app is asked again when you come back.
- Developer mode shows on-device speed: how fast the model reads your message and how fast it writes.

### Changed
- Fireworks uses Kimi K3: new setups start on it, and a saved Kimi K2.6 setup moves to it and shows the new price.

### Fixed
- "turn off & retry" retries without web search.
- Sending scrolls in one motion.
- An address that only looks local is no longer treated as your machine.

### Security
- A relayed near.ai model no longer shows as end-to-end encrypted while the model list loads.

[`v1.0.5`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.5) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.5) · [audit v1.0.5-304d6bd](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.5-304d6bd.md) · [build audit tf-1.0.5-43-705764b](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/tf-1.0.5-43-705764b.md)

## 1.0.4 (38) — 2026-09-19

### Added
- New providers: OpenRouter (hundreds of models, one key) and NVIDIA (free hosted tier).
- First run walks through setup and lands you in the composer.

### Changed
- Model lists come from each provider, live, with prices, in one browser across all of them.
- Gemma on the phone streams about twice as fast and loads in the background.
- near.ai's enclave hosts come from near.ai's live directory.

### Fixed
- Retired near.ai models heal to GLM-5.3 Flash.
- The web-search offer no longer leaves gaps, and rejected keys say so.

### Security
- A near.ai model with no published enclave host asks before sending instead of sending in the clear.

[`v1.0.4`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.4) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.4) · [audit v1.0.4-3abe3e2](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.4-3abe3e2.md)

## 1.0.3 (35) — 2026-09-11

### Security
- Authenticated requests no longer land in the shared URL cache, where a provider key could be read back from the app's Cache.db (MEDIUM, present since 1.0, found by the 1.0.2 audit's runtime pass).
- The shared cache is replaced with a zero-capacity one before any session exists, and the cache earlier builds wrote is emptied on first launch.

This build is the 1.0.2 code plus the fix above.

[`v1.0.3`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.3) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.3) · [audit v1.0.3-7edcb55](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.3-7edcb55.md)

## 1.0.2 (33) — 2026-09-09

### Added
- Models download in the background, survive the app being closed, and resume where they stopped.
- A download paused off wi-fi waits for wi-fi and says so; mobile data is used only when you choose it.

### Changed
- Adding a cloud key is two steps: pick the provider, then its key.
- A setup without its key can't be sent to, and the row says what it needs; the picker names the recommended model.

### Fixed
- The transcript no longer shifts or opens a blank band as a reply lands.
- On-device replies stop cleanly, and a reply cut off by leaving the app resumes when you return.
- A download whose link expired starts over on its own.
- One failed verification leg no longer discards another leg's success.

### Known issues
- MEDIUM: a provider key could be read back from the shared URL cache on disk (present since 1.0). Fixed in 1.0.3.

[`v1.0.2`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.2) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.2) · [audit v1.0.2-21d534e](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.2-21d534e.md)

## 1.0.1 (26) — 2026-09-01

### Changed
- The whole client is open source.
- Long chats stream and scroll smoothly.
- The everyday proof shows what each audit found, not just that one exists.
- Web search sends the model facts, not raw page markup.

### Fixed
- Alert buttons match teemoon orange.

### Known issues
- MEDIUM: a provider key could be read back from the shared URL cache on disk. Fixed in 1.0.3.

[`v1.0.1`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.1) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.1) · [audit v1.0.1-0dfad8b](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.1-0dfad8b.md)

## 1.0 — 2026-08-31

The first public release of the source, under AGPL-3.0. This commit was cut from the tree that became 1.0.1 (26); the reviewed App Store 1.0 (25) build was not published separately.

### Added
- On-device Gemma 4 via LiteRT-LM, with weights SHA-256 verified before they can run; your own llama.cpp, ollama or LM Studio machine; bring-your-own-key cloud providers.
- End-to-end encryption into near.ai's attested enclaves, verified on the phone: Intel TDX quote with DCAP, NVIDIA GPU evidence, key bound to the enclave's quote, TLS attestation.
- Enclave images are traced to published near.ai source where near.ai publishes a signed build record, with per-model audits, an everyday proof view and an expert view.
- As the 1.0 release notes said: a failed check blocks sending rather than warning, and each reply's signature is checked. Later audits found limits; see Security and Known issues under 1.0.4, 1.0.6 and 1.1.0.
- Web search through Brave with inline citations, and search over your own chat history.
- No account, no analytics; keys in the iOS Keychain; chats stay on the device with versioned schema migrations.

### Known issues
- Anthropic keys are not supported directly; end-to-end encryption applies only to near.ai; iPhone only, iOS 18.6 or later.
- MEDIUM: a provider key could be read back from the shared URL cache on disk. Fixed in 1.0.3.

[`v1.0.0`](https://github.com/teemoonai/teemoon-ios/tree/v1.0.0) · [GitHub release](https://github.com/teemoonai/teemoon-ios/releases/tag/v1.0.0) · [audit v1.0.0-2d9e206](https://github.com/teemoonai/audits/blob/main/client/teemoon-ios/v1.0.0-2d9e206.md)
