# vendoring: textual

This directory is a vendored copy of [gonzalezreal/textual](https://github.com/gonzalezreal/textual)
`0.3.1` — the Markdown renderer the chat transcript draws with. MIT, see
[`LICENSE`](LICENSE); its own third-party attributions are in
[`LICENSE-3rdparty.csv`](LICENSE-3rdparty.csv).

It is not a git submodule and not a URL dependency — there is no `.gitmodules`.
The 290 files here are tracked as plain files and wired into the app as a local
Swift package by a `relativePath` entry in
`teemoon.xcodeproj/project.pbxproj` (`Vendor/textual`).

## why it is vendored

SwiftPM permits `.unsafeFlags` **only in local path packages** and rejects it in
remote/versioned dependencies. teemoon needs one such flag on this package (see
below), so the package has to live in-tree. That is the whole reason this
directory exists, and it is stated at the patch site itself
(`Package.swift:35-42`).

The same rule is why `Packages/LiteRTLM` is vendored; that package has four
further reasons of its own, recorded in
[`Packages/LiteRTLM/VENDORING.md`](../../Packages/LiteRTLM/VENDORING.md).

## patch register

**Six deltas from upstream 0.3.1, plus one added file.** One delta is a build
flag; four are the same fix applied at the places upstream defers work past
the first layout pass; one is list-item spacing on that first pass; and the
added file is the small memo they share.

**1. `.unsafeFlags(["-O"], .when(configuration: .debug))`** — `Package.swift:42`,
with the rationale in the comment directly above it. Without it, Markdown
layout glue compiled at `-Onone` is what turned a heavy transcript into a
frozen phone on Debug device builds: unspecialised generics between every
TextKit call. With it, Textual is optimised even in Debug while the app's own
code stays `-Onone` and fully debuggable.

### 2–5. resolve before the first measure

Upstream's rendering path holds its resolved values in `@State` seeded from
`.onChange(of:initial: true)`. That closure runs when a view APPEARS — after
the layout system has already asked how big it is. So the first measurement of
any freshly built row described an EMPTY document, and the real height arrived
a pass later as a resize. In a recycling transcript that is a resize per row
per appearance, which is the "scrolling is janky because of Textual resizing"
report; it is also why the hand-off needed a re-measure (a 3,801pt reply came
back as 83pt).

Each patch computes the value during body evaluation and memoizes it against
the input it came from, so a recycled view can never show the previous row's
content and nothing is derived twice. The memo is one added file —
`Internal/RenderMemo.swift`, which is entirely teemoon's and explains itself —
held by `@State` as a reference so `body` may write through it (the same
"populate a cache while rendering" rule an `NSCache` follows). Measured on the
transcript fixture: a mixed-block reply first measured **0pt** before,
**1,006pt** after, against a settled 1,069pt. Every site carries a
`TEEMOON PATCH` comment.

- **`StructuredText.swift`** — the markdown parse.
- **`Internal/InlineText/WithInlineStyle.swift`** — inline attribute styling.
- **`Internal/TextFragment/TextFragment.swift`** — the `Text` build (this is
  the one that rendered `Text(verbatim: "")` on the first pass).
- **`StructuredText/Style/Overflow.swift`** — a `ScrollView` is greedy in both
  axes, so a code block's or table's height came only from an
  `.onGeometryChange` `@State`. Fixed vertically, it adopts its content's ideal
  height in the same pass.
- **`Internal/StructuredText/BlockVStack.swift`** — list-item spacing is in
  the environment, so it is applied on the first layout pass rather than
  copied from a preference a pass later.

teemoon also passes a memoizing parser (`CachedMarkdownParser`), so a row
scrolling back into view re-parses nothing. That lives in the app, not here.

**List-item spacing (BlockVStack.swift)** — upstream copies the spacing
preference into `@State` and applies it as a layout value a pass later.
List spacing is already in the environment, so the patch uses it on the
first pass. Paragraph/heading spacing still rides the preference (points,
not pages).

**Still deferred, deliberately**: table column widths resolve a pass late
when Overflow's container width is still nil (points, not pages —
`StructuredTextMeasurementTests` tolerates them explicitly). Chat tables
avoid that path via `MinimalChatTableStyle`'s `fixedSize`; remaining table
stutter during a stream is incomplete GFM (a pipe-paragraph until the
delimiter row), which the app holds in `MarkdownStreamSplitter.displayTail`.

## upgrading

1. Clone the target upstream tag into scratch.
2. Replace this directory's contents with the fresh copy, minus its `.git`.
3. Re-apply the patches above. Each site carries a comment naming itself, so a
   lost patch is findable — `grep -rn "TEEMOON PATCH" Vendor/textual` should
   return six source hits (RenderMemo, parse, inline style, Text build,
   Overflow, list spacing), plus the flag in `Package.swift` — but this
   register is the checklist.
4. Verify: build the app, run `teemoonTests`, and scroll a long transcript on a
   Debug **device** build. A build that succeeds proves nothing here; the
   symptom of a lost patch is a frozen phone, not a compile error.

## honest limit

A vendored copy floats free of upstream's history: `git log` on this directory
shows teemoon's history, not upstream's, and nothing warns when upstream ships
a fix. Bumps are manual and deliberate.
