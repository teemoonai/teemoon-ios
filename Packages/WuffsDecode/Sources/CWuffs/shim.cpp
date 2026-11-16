// The Wuffs build: only the decoders teemoon accepts for untrusted bytes, behind tw_decode.
// Keep this file small: it is the only non-Wuffs native code on the untrusted path.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__AUX__BASE
#define WUFFS_CONFIG__MODULE__AUX__IMAGE
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__LZW

#include "wuffs-v0.4.c"

#include <cstdlib>
#include <cstring>
#include <new>

#include "include/teemoon_wuffs.h"

namespace {

// The work buffer (JPEG and PNG scratch space) is capped; a decoder that needs more fails.
constexpr uint64_t kMaxWorkbuf = 64ull * 1024 * 1024;

uint32_t fourcc_for(tw_format format) {
  switch (format) {
    case TW_FORMAT_JPEG: return WUFFS_BASE__FOURCC__JPEG;
    case TW_FORMAT_PNG: return WUFFS_BASE__FOURCC__PNG;
    case TW_FORMAT_GIF: return WUFFS_BASE__FOURCC__GIF;
  }
  return 0;
}

struct Callbacks : public wuffs_aux::DecodeImageCallbacks {
  uint32_t expected_fourcc = 0;
  uint64_t max_pixels = 0;
  bool too_large = false;

  wuffs_base__image_decoder::unique_ptr SelectDecoder(uint32_t fourcc, wuffs_base__slice_u8 prefix_data,
                                                      bool prefix_closed) override {
    // The bytes must sniff as the declared format: a PNG named JPEG is refused, not decoded as PNG.
    if (fourcc != expected_fourcc) {
      return wuffs_base__image_decoder::unique_ptr(nullptr);
    }
    return wuffs_aux::DecodeImageCallbacks::SelectDecoder(fourcc, prefix_data, prefix_closed);
  }

  wuffs_base__pixel_format SelectPixfmt(const wuffs_base__image_config &) override {
    return wuffs_base__make_pixel_format(WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL);
  }

  AllocPixbufResult AllocPixbuf(const wuffs_base__image_config &image_config,
                                bool allow_uninitialized_memory) override {
    const uint64_t w = image_config.pixcfg.width();
    const uint64_t h = image_config.pixcfg.height();
    if (w == 0 || h == 0 || w > max_pixels || h > max_pixels || w * h > max_pixels) {
      too_large = true;
      return AllocPixbufResult("teemoon: too many pixels");
    }
    return wuffs_aux::DecodeImageCallbacks::AllocPixbuf(image_config, allow_uninitialized_memory);
  }

  AllocWorkbufResult AllocWorkbuf(wuffs_base__range_ii_u64 len_range, bool allow_uninitialized_memory) override {
    if (len_range.min_incl > kMaxWorkbuf) {
      return AllocWorkbufResult("teemoon: work buffer too large");
    }
    if (len_range.max_incl > kMaxWorkbuf) {
      len_range.max_incl = kMaxWorkbuf;
    }
    return wuffs_aux::DecodeImageCallbacks::AllocWorkbuf(len_range, allow_uninitialized_memory);
  }
};

}  // namespace

extern "C" tw_status tw_decode(const uint8_t *src, size_t src_len, tw_format format,
                               uint32_t max_dimension, uint64_t max_pixels, tw_image *out) {
  if (out == nullptr) return TW_CORRUPT;
  out->pixels = nullptr;
  out->width = 0;
  out->height = 0;
  if (src == nullptr || src_len == 0) return TW_CORRUPT;
  const uint32_t expected = fourcc_for(format);
  if (expected == 0) return TW_UNSUPPORTED;

  try {
    Callbacks callbacks;
    callbacks.expected_fourcc = expected;
    callbacks.max_pixels = max_pixels;
    wuffs_aux::sync_io::MemoryInput input(src, src_len);
    wuffs_aux::DecodeImageResult result = wuffs_aux::DecodeImage(
        callbacks, input, wuffs_aux::DecodeImageArgQuirks::DefaultValue(),
        wuffs_aux::DecodeImageArgFlags::DefaultValue(), wuffs_aux::DecodeImageArgPixelBlend::DefaultValue(),
        wuffs_aux::DecodeImageArgBackgroundColor::DefaultValue(),
        wuffs_aux::DecodeImageArgMaxInclDimension(max_dimension));

    if (!result.error_message.empty()) {
      if (callbacks.too_large || result.error_message == wuffs_aux::DecodeImage_MaxInclDimensionExceeded) {
        return TW_TOO_LARGE;
      }
      if (result.error_message == wuffs_aux::DecodeImage_UnsupportedImageFormat) return TW_UNSUPPORTED;
      if (result.error_message == wuffs_aux::DecodeImage_OutOfMemory) return TW_NO_MEMORY;
      return TW_CORRUPT;  // includes a partial decode of a truncated file
    }
    if (!result.pixbuf.pixcfg.is_valid()) return TW_CORRUPT;

    const uint32_t width = result.pixbuf.pixcfg.width();
    const uint32_t height = result.pixbuf.pixcfg.height();
    const wuffs_base__table_u8 plane = result.pixbuf.plane(0);
    const uint64_t row_bytes = static_cast<uint64_t>(width) * 4;
    if (width == 0 || height == 0 || plane.width < row_bytes || plane.height < height) return TW_CORRUPT;

    const uint64_t total = row_bytes * height;
    uint8_t *pixels = static_cast<uint8_t *>(std::malloc(static_cast<size_t>(total)));
    if (pixels == nullptr) return TW_NO_MEMORY;
    for (uint32_t y = 0; y < height; y++) {
      std::memcpy(pixels + static_cast<size_t>(row_bytes) * y, plane.ptr + plane.stride * y,
                  static_cast<size_t>(row_bytes));
    }
    out->pixels = pixels;
    out->width = width;
    out->height = height;
    return TW_OK;
  } catch (const std::bad_alloc &) {
    return TW_NO_MEMORY;
  } catch (...) {
    return TW_CORRUPT;
  }
}

extern "C" void tw_free(uint8_t *pixels) { std::free(pixels); }
