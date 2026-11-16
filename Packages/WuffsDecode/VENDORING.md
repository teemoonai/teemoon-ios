# vendoring: Wuffs

Provenance record for the decoder untrusted image bytes go through (docs/IMAGES.md §2). Android
vendors the same file at the same pin.

| field | value |
|---|---|
| project | Wuffs, https://github.com/google/wuffs |
| tag | v0.4.0-alpha.9 |
| commit | 3387e19512ba52957f29fa3a357f11360b415b08 (2024-09-14, "release: wuffs gen -version=0.4.0-alpha.9") |
| file | `release/c/wuffs-v0.4.c` → `Sources/CWuffs/wuffs-v0.4.c`, verbatim |
| size / sha256 | 3,289,964 bytes / `51d2f73b757adfab105386fd3641aebd69dabc3a19126d5e060b6996ede94714` |
| licence | Apache-2.0, `LICENSE` from the same commit (sha256 `f8ac2c75e7f629a87565c80d61ff9fe5aa15cdea0bda997d52a4dc13fdbd19cb`) |
| form | source, compiled into the app; no binary |
| modules compiled in | BASE, AUX__BASE, AUX__IMAGE, PNG, JPEG, GIF and their dependencies ADLER32, CRC32, DEFLATE, ZLIB, LZW (`Sources/CWuffs/shim.cpp`). Nothing else is reachable: WebP, BMP, QOI, TGA, ETC2, NIE, NPBM and the rest are not compiled. |
| allow-list | JPEG, PNG, GIF (first frame). Any other format is a placeholder before Wuffs is called. |

**Memory-safety basis.** Wuffs code is written in the Wuffs language, whose compiler rejects any
program it cannot prove free of out-of-bounds access and arithmetic overflow; the C file is that
compiler's output. The decoders allocate nothing themselves: every buffer is supplied by the caller
(`shim.cpp` caps the pixel buffer from the header's width × height and the work buffer at 64 MiB).
The claim covers Wuffs' decoders, not `shim.cpp` or the `wuffs_aux` C++ helper (hand-written C++ in the
same file), which is why the shim is small and the corpus and fuzz loop exercise it.

**Upstream status.** v0.4 is marked alpha upstream; it is the line with the JPEG decoder (v0.3 has none).

**Updating.** Change the pin on both platforms together; re-run the image corpus (`conformance/import/near/images`)
and the fuzz loop; record the new sha256 here.
