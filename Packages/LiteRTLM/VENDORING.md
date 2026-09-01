# vendoring: LiteRTLM

This package is a vendored copy of Google's [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
Swift wrapper — `v0.14.0`, commit `80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6`,
Apache-2.0 (see `LICENSE`; sources carry Google's copyright headers). It is not
a git submodule and not a URL dependency — it is tracked as plain files and
wired into the app via a `relativePath` entry in `teemoon.xcodeproj/project.pbxproj`.

Why: upstream's own `v0.14.0` manifest checksums do not match its published
release assets (SPM refuses to resolve, and pinning to `0.13.1` doesn't help
because SPM keeps resolving `0.14.0` regardless). SPM's `.unsafeFlags` is also
only legal in local path packages. On top of that, the macOS binary slice
needs reshaping (below) and the Swift source carries one functional patch.
This document is the LiteRTLM-specific rebuild/audit record.

## patch register

Four deltas from upstream. Re-apply all of them on any version bump — the
build will not catch a lost patch.

1. **`Tool.getSchema()` promoted from protocol extension to protocol
   requirement** — `Sources/LiteRTLM/Tool.swift:240` (comment above the
   declaration). Without this, `ToolManager` iterates `[Tool]` existentials,
   so a method declared only in a protocol extension dispatches statically
   and a conformer's override is dead code — the default (which reflects
   over `@ToolParam` properties) found none in teemoon's untyped shim and
   omitted `parameters`. The model was told a tool took no arguments and
   complied, silently: it ran with `"arguments":{}`, searched for nothing,
   then correctly said it had no real-time information. Indistinguishable
   from the model just declining to search. Symptom is silent, not a build
   failure — verify by exercising on-device tool calling and confirming the
   emitted `arguments` are non-empty for a schema'd tool.

2. **`-all_load` dropped** from the `LiteRTLM` target's linker settings —
   see the comment on that target in `Package.swift`. Without this, every
   SwiftUI Preview in the app dies with `duplicate definition of symbol
   '___absvdi2'` in `libclang_rt.iossim.a` — `-all_load` force-loads every
   object from every static archive on the command line, including the
   compiler runtime, and the preview JIT linker chokes on it. Safe to drop
   because `-all_load` only affects *static* archives, and
   `CLiteRTLM.framework`'s binary is a dylib — there are no archive members
   to force-load, so the flag did nothing for this artifact. If a future
   upstream release ships a static slice, the targeted fix is
   `-force_load <that archive>`, never `-all_load`.

3. **Recomputed binary-target checksums** for `CLiteRTLM` (the iOS
   xcframework, fetched by URL). Upstream's manifest checksum doesn't match
   its own published asset. The value in `Package.swift` was obtained by
   downloading the artifact fresh and running `swift package
   compute-checksum` — not copied from an SPM error message.

4. **`swift-tools-version: 5.9`, kept deliberately** (top of `Package.swift`).
   Under 6.x tooling the target defaults to the Swift 6 language mode and
   upstream's `ExperimentalFlags` fails to compile — a dozen "nonisolated
   global shared mutable state" errors. This is vendored third-party code;
   it should build the way its authors build it, not be patched to satisfy
   a stricter mode.

## the macOS slice: repackaged, not just re-checksummed

Upstream ships the iOS xcframework as a *framework*-shaped slice (headers
inside the bundle) but the macOS slice as a *library*-type slice — loose
`Headers/` next to a `.dylib`. Xcode copies a library-type slice's headers
into the shared `$BUILT_PRODUCTS_DIR/include/`, and any second library-type
dependency doing the same thing (in this app's case, Phala's dcap-qvl)
collides on `include/module.modulemap` — a build-*planning* failure, before
a single file compiles, that takes down the whole macOS destination.

The fix is a shape correction, not a workaround: rebuild the macOS slice as
a framework, matching Google's own iOS shape. `CLiteRTLM_mac` in
`Package.swift` is a `.binaryTarget(path:)` pointing at
`artifacts/CLiteRTLM_mac.xcframework`, committed via **Git LFS** (only the
Mach-O is LFS-tracked, by exact path — a glob would also catch the bundle's
five symlinks and LFS would rewrite them into pointer files, quietly
breaking the framework). Because `binaryTarget(path:)` is validated when the
manifest loads, on every platform, a missing artifact doesn't just break
macOS — it stops the package resolving at all, and the iOS build goes down
with it. That's why the artifact has to actually be present in a fresh
clone, LFS included.

### repackage procedure

The original tooling lived at `scripts/repackage-litertlm-mac.sh` (not
present in this distribution). To reproduce or regenerate the artifact:

1. **Download** the pinned upstream asset:
   `https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM_mac.xcframework.zip`
2. **Verify its SHA-256 before unpacking anything.** The pinned value is
   `450615483509aaa6d34b321fdc6862e41a224b674468ab10aff64ebe113d21b7`.
   Refuse to proceed on a mismatch — do not "fix" this by pasting the actual
   hash back into the pin. Upstream has re-uploaded release assets under an
   existing tag before (see checksum caveat above); a mismatch here means
   investigate, not update-and-continue.
3. **Unpack** and locate `macos-arm64_x86_64/CLiteRTLM_mac.xcframework/`
   inside it. Ignore the `__MACOSX/` sidecar (AppleDouble resource forks
   that mirror the real tree but aren't it). Confirm the slice still has
   loose `Headers/` next to `libCLiteRTLM_mac.dylib` — if upstream ever
   ships this slice as a framework already, this whole procedure is
   obsolete; point `Package.swift` straight at the upstream artifact
   instead.
4. **Assemble a versioned macOS framework bundle**,
   `CLiteRTLM.framework/Versions/A/{CLiteRTLM,Headers,Modules,Resources}`,
   with `Current -> A` and the four standard top-level symlinks
   (`CLiteRTLM`, `Headers`, `Modules`, `Resources`) into `Versions/Current`:
   - Copy the dylib in as `Versions/A/CLiteRTLM` (both archs, arm64 +
     x86_64, preserved — Intel Macs stay supported).
   - Copy Google's headers verbatim into `Versions/A/Headers/` — they are
     byte-identical to the iOS framework's and only touch stdbool/stddef/
     stdint, so nothing needs include-path rewriting.
   - Generate (don't copy) an umbrella header
     `#import <CLiteRTLM/engine.h>` + `#import <CLiteRTLM/capabilities_c.h>`,
     and a framework modulemap declaring `framework module CLiteRTLM`
     mirroring the iOS slice's. The module name stays `CLiteRTLM` —
     upstream's own macOS modulemap already declares that name — so
     `import CLiteRTLM` needs no platform `#if`.
   - Write a minimal `Info.plist` (`CFBundlePackageType: FMWK`,
     `CFBundleExecutable/CFBundleName: CLiteRTLM`).
5. **Retarget the install name**: was `@rpath/libCLiteRTLM_mac.dylib`;
   inside a versioned bundle the loader needs the full path,
   `@rpath/CLiteRTLM.framework/Versions/A/CLiteRTLM`
   (`install_name_tool -id`).
6. **Re-sign ad hoc** (`codesign --force --sign - --timestamp=none`). The
   install-name rewrite invalidates Google's original signature; this costs
   nothing in practice because Xcode re-signs every embedded framework with
   the app's own identity at build time anyway.
7. **Wrap as an xcframework**: `xcodebuild -create-xcframework -framework
   <bundle> -output CLiteRTLM_mac.xcframework`. Verify the result: the
   output must be framework-shaped (no loose `Headers/` at the slice root,
   which would mean the collision this exists to fix would persist), the
   modulemap must be present, and the archs must match what went in.
8. **Zip it reproducibly** for checking against what's committed: `zip -y
   -X` (store symlinks as symlinks — a macOS framework is a bundle held
   together by them, and following them instead inflates the zip to four
   copies of a ~130 MB binary and breaks the bundle; drop extra
   uid/gid/Finder attributes that differ per machine), file list sorted for
   a fixed order, and every file's mtime normalized to a fixed epoch first
   (`touch -h -t 200001010000`) — without that, the checksum changes run to
   run even though the underlying Mach-O is byte-identical. Same upstream
   zip in, same output bytes out, on any machine.

Regenerate this only when bumping the upstream version, and re-pin the new
zip's SHA-256 into both `Package.swift` (the `CLiteRTLM_mac` binary target
comment references it) and step 2 above — by downloading and checking the
new artifact yourself, never by copying a value out of an SPM/script error
message.

### no dSYM for CLiteRTLM (iOS)

Checked rather than assumed (2026-07-30, v0.14.0): the device slice ships
stripped (`dwarfdump --debug-info` prints empty `.debug_info`), and
upstream's release has no dSYM asset to fetch. A crash inside LiteRT's
native code will show raw addresses for its frames in Organizer/App Store
Connect; `atos -o` against the exact pinned binary can still resolve
*exported* symbols, which is why keeping the version pin exact matters even
though there's no dSYM.

## checksum-verification caveat

Every checksum in this package — the recomputed `CLiteRTLM` (iOS) binary
target checksum and the pinned `CLiteRTLM_mac` zip SHA-256 — proves
**self-consistency, not authenticity**. It shows the manifest matches what
was downloaded on one machine on one day, not that Google published exactly
those bytes. Authenticity here rests on HTTPS from Google's official GitHub
releases and on the zip containing a well-formed xcframework (checked by
hand: `ios-arm64` + `ios-arm64-simulator` slices for iOS, both archs
present for macOS). That's a real limit, not a formality — keep it in mind
before treating either checksum as a substitute for provenance.

## upgrading

1. Clone the target upstream tag into scratch, with
   `GIT_LFS_SKIP_SMUDGE=1` — a plain clone trips a Git LFS smudge error
   (the `prebuilt/` dylibs are Bazel artifacts; SPM takes its binaries from
   GitHub Releases, so nothing is lost by skipping them).
2. Replace this directory's contents with the fresh copy, minus `.git`.
3. Re-apply every entry in the patch register above.
4. Re-download each binary artifact, re-run `swift package
   compute-checksum` for the iOS target, and redo the macOS repackage
   procedure for the mac slice. Keep `swift-tools-version: 5.9`.
5. Verify: build the app, run `teemoonTests`, render a SwiftUI preview (a
   dead preview with `___absvdi2` means `-all_load` came back), and
   exercise on-device tool calling to confirm non-empty `arguments`.
