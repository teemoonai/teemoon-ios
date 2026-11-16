// The only entry point into Wuffs. Plain C, so Swift needs no C++ interop.
#ifndef TEEMOON_WUFFS_H
#define TEEMOON_WUFFS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  TW_FORMAT_JPEG = 1,
  TW_FORMAT_PNG = 2,
  TW_FORMAT_GIF = 3,
} tw_format;

typedef enum {
  TW_OK = 0,
  /// The bytes are not the declared format, or the format is not compiled in.
  TW_UNSUPPORTED = 1,
  /// Over max_dimension or max_pixels (checked from the header, before the pixel buffer exists).
  TW_TOO_LARGE = 2,
  /// Truncated or malformed, including a partial decode.
  TW_CORRUPT = 3,
  TW_NO_MEMORY = 4,
} tw_status;

/// Tightly packed RGBA, premultiplied, 8 bits per channel; row stride is width * 4.
typedef struct {
  uint8_t *pixels;
  uint32_t width;
  uint32_t height;
} tw_image;

/// Decodes the first frame of `src` as `format`. On TW_OK the caller owns out->pixels and frees it
/// with tw_free. On any other status out->pixels is NULL. Never aborts on bad input.
tw_status tw_decode(const uint8_t *src, size_t src_len, tw_format format,
                    uint32_t max_dimension, uint64_t max_pixels, tw_image *out);

void tw_free(uint8_t *pixels);

#ifdef __cplusplus
}
#endif

#endif
