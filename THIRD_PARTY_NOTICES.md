# Third-Party Notices

teemoon incorporates and builds upon third-party software. The notices below are
preserved to satisfy the license terms of that software. The project as a whole is
licensed under the GNU AGPL-3.0 (see [`LICENSE`](LICENSE)); the notices here cover
portions that originate from, or remain governed by, the licenses of their upstream
authors. MIT and Apache-2.0 are one-way compatible with AGPL-3.0, so those components
may be distributed as part of this AGPL-3.0 work while their original notices ride
along.

---

## fullmoon (original project base)

teemoon began as a fork of **fullmoon** (an iOS app for running local language
models), originally published under the MIT License. Substantial user-facing design
and portions of the original codebase are derived from fullmoon, so its copyright and
permission notice are preserved below as MIT requires. teemoon has since been
substantially rewritten and relicensed to AGPL-3.0 for the parts authored by ringzero
ventures llc.

- Upstream: fullmoon by Mainframe Computer, Inc. (https://github.com/mainframecomputer/fullmoon-ios)

```
MIT License

Copyright (c) 2024 Mainframe Computer, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Bundled dependencies

teemoon depends on additional open-source packages (via Swift Package Manager and
vendored sources) under MIT and Apache-2.0 licenses — all one-way compatible with
AGPL-3.0. Each dependency retains its own license within its source or package
metadata; see the resolved package manifests, `Vendor/*/LICENSE`, and
`Packages/*/LICENSE` for the per-dependency terms.
