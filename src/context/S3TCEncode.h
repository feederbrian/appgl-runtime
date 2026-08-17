#pragma once

// R1.0 residue — CPU S3TC/DXT block encoder.
//
// Why a CPU encoder exists at all: this device DOES support BC texture
// formats for SAMPLING (MTLDevice.supportsBCTextureCompression == YES on
// Apple M1 Max / macOS 26.5, and BC1/BC2/BC3/BC7 MTLTextures allocate), and
// GLCapabilities.mm:656-659 already maps the four S3TC enums onto
// MTLPixelFormatBC{1,2,3}_RGBA. What no Apple framework provides is an
// ENCODER:
//   * Metal has no compress entry point. MTLTextureCompressionType is
//     lossless/lossy framebuffer compression, unrelated to BC.
//   * MetalPerformanceShaders and Accelerate/vImage contain no BC symbol.
//   * ImageIO advertises kCGImagePropertyBCEncoder / kCGImagePropertyBCFormat
//     (CGImageDestination.h:198-204) but its DDS destination writes a
//     zero-byte file even with no BC key at all, and its KTX destination
//     ignores the key and emits glInternalFormat 0x881A (GL_RGBA16F).
// So glTexImage2D with a compressed internalformat has to compress here.
//
// This is the exact inverse of the decoder that already lives at
// GLContextTexture.inc.mm:2266 (decodeS3TCLevelToRGBA8); the colour-table,
// explicit-alpha and interpolated-alpha conventions below are written to
// round-trip against it.
//
// Algorithm is the classic one: per 4x4 block, take the RGB bounding box as
// the two endpoints, quantise to RGB565, build the 4-colour ramp, and pick
// each texel's index by nearest ramp entry in squared RGB distance. Flat
// blocks — which is what the piglit patterns are almost entirely made of —
// come out exact, and piglit probes with a tolerance, so the endpoint
// refinement a shipping encoder would add is not what these rows turn on.

#include "../../include/AppGL/glcorearb.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace appgl {
namespace s3tc {

// The four S3TC internal formats this encoder handles. Anything else returns
// false from encodeImage and the caller keeps its existing behaviour.
inline bool isEncodableFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
            return true;
        default:
            return false;
    }
}

inline std::size_t blockBytesForFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
            return 8u;
        case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
            return 16u;
        default:
            return 0u;
    }
}

namespace detail {

inline std::uint16_t pack565(int r, int g, int b) {
    const int r5 = (std::clamp(r, 0, 255) * 31 + 127) / 255;
    const int g6 = (std::clamp(g, 0, 255) * 63 + 127) / 255;
    const int b5 = (std::clamp(b, 0, 255) * 31 + 127) / 255;
    return static_cast<std::uint16_t>((r5 << 11) | (g6 << 5) | b5);
}

// Must match decodeS3TCLevelToRGBA8's expand565 bit-for-bit, otherwise a
// value we encode does not survive its own round trip.
inline void expand565(std::uint16_t packed, int rgb[3]) {
    rgb[0] = static_cast<int>(((packed >> 11) & 0x1fu) * 255u / 31u);
    rgb[1] = static_cast<int>(((packed >> 5) & 0x3fu) * 255u / 63u);
    rgb[2] = static_cast<int>((packed & 0x1fu) * 255u / 31u);
}

inline void writeLE16(std::uint8_t* dst, std::uint16_t v) {
    dst[0] = static_cast<std::uint8_t>(v & 0xffu);
    dst[1] = static_cast<std::uint8_t>((v >> 8) & 0xffu);
}

// Encode the 8-byte DXT1 colour block for one 4x4 tile.
//
// `punchThrough` selects the 3-colour mode (c0 <= c1, index 3 == transparent
// black) required by GL_COMPRESSED_RGBA_S3TC_DXT1_EXT when the tile contains
// any texel with alpha < 128. GL_COMPRESSED_RGB_S3TC_DXT1_EXT never uses it:
// its alpha is defined to be 1.0, so the 4-colour mode is always available
// and always the better choice.
inline void encodeColorBlock(const std::uint8_t texels[16][4],
                             bool punchThrough,
                             std::uint8_t out[8]) {
    // Bounding box over the texels that actually contribute colour. In
    // punch-through mode the transparent texels take index 3 regardless, so
    // letting them drag the endpoints around only costs quality.
    int lo[3] = {255, 255, 255};
    int hi[3] = {0, 0, 0};
    bool anyOpaque = false;
    for (std::size_t i = 0; i < 16u; ++i) {
        if (punchThrough && texels[i][3] < 128u) continue;
        anyOpaque = true;
        for (std::size_t c = 0; c < 3u; ++c) {
            lo[c] = std::min(lo[c], static_cast<int>(texels[i][c]));
            hi[c] = std::max(hi[c], static_cast<int>(texels[i][c]));
        }
    }
    if (!anyOpaque) {
        // Every texel is transparent. Emit the canonical fully-transparent
        // block: c0 == c1 == 0 puts us in 3-colour mode, and index 3 is
        // transparent black there.
        writeLE16(out, 0u);
        writeLE16(out + 2, 0u);
        out[4] = out[5] = out[6] = out[7] = 0xffu;  // every texel -> index 3
        return;
    }

    std::uint16_t c0 = pack565(hi[0], hi[1], hi[2]);
    std::uint16_t c1 = pack565(lo[0], lo[1], lo[2]);

    // Mode selection is carried entirely by the c0/c1 ordering, which is why
    // it has to be forced rather than merely hoped for.
    if (punchThrough) {
        if (c0 > c1) std::swap(c0, c1);   // need c0 <= c1 for 3-colour mode
    } else {
        if (c0 < c1) std::swap(c0, c1);   // need c0 >  c1 for 4-colour mode
    }

    int ramp[4][3];
    expand565(c0, ramp[0]);
    expand565(c1, ramp[1]);
    const int rampCount = punchThrough ? 3 : 4;
    if (punchThrough) {
        for (std::size_t c = 0; c < 3u; ++c) {
            ramp[2][c] = (ramp[0][c] + ramp[1][c]) / 2;
        }
        ramp[3][0] = ramp[3][1] = ramp[3][2] = 0;
    } else {
        for (std::size_t c = 0; c < 3u; ++c) {
            ramp[2][c] = (2 * ramp[0][c] + ramp[1][c]) / 3;
            ramp[3][c] = (ramp[0][c] + 2 * ramp[1][c]) / 3;
        }
    }

    writeLE16(out, c0);
    writeLE16(out + 2, c1);

    std::uint32_t indices = 0;
    for (std::size_t i = 0; i < 16u; ++i) {
        std::uint32_t best = 0;
        if (punchThrough && texels[i][3] < 128u) {
            best = 3u;  // the transparent slot
        } else {
            int bestErr = -1;
            for (int k = 0; k < rampCount; ++k) {
                const int dr = static_cast<int>(texels[i][0]) - ramp[k][0];
                const int dg = static_cast<int>(texels[i][1]) - ramp[k][1];
                const int db = static_cast<int>(texels[i][2]) - ramp[k][2];
                const int err = dr * dr + dg * dg + db * db;
                if (bestErr < 0 || err < bestErr) {
                    bestErr = err;
                    best = static_cast<std::uint32_t>(k);
                }
            }
        }
        indices |= best << (2u * i);
    }
    out[4] = static_cast<std::uint8_t>(indices & 0xffu);
    out[5] = static_cast<std::uint8_t>((indices >> 8) & 0xffu);
    out[6] = static_cast<std::uint8_t>((indices >> 16) & 0xffu);
    out[7] = static_cast<std::uint8_t>((indices >> 24) & 0xffu);
}

// DXT3: 8 bytes of explicit 4-bit alpha, two texels per byte, low nibble
// first. Inverse of decodeExplicitAlphaDXT3, which expands nibble * 17.
inline void encodeExplicitAlpha(const std::uint8_t texels[16][4],
                                std::uint8_t out[8]) {
    for (std::size_t i = 0; i < 8u; ++i) {
        const unsigned a0 = (texels[2u * i][3] * 15u + 127u) / 255u;
        const unsigned a1 = (texels[2u * i + 1u][3] * 15u + 127u) / 255u;
        out[i] = static_cast<std::uint8_t>((a1 << 4) | a0);
    }
}

// DXT5: two alpha endpoints plus 3-bit indices. We always emit the
// a0 > a1 (8-value interpolated) variant, so the 6-value variant's
// hard 0/255 slots are unused; endpoints already cover them.
inline void encodeInterpolatedAlpha(const std::uint8_t texels[16][4],
                                    std::uint8_t out[8]) {
    int lo = 255, hi = 0;
    for (std::size_t i = 0; i < 16u; ++i) {
        lo = std::min(lo, static_cast<int>(texels[i][3]));
        hi = std::max(hi, static_cast<int>(texels[i][3]));
    }
    if (lo == hi) {
        // Constant alpha. a0 > a1 is impossible when they are equal, and the
        // 6-value mode's index 6/7 are 0/255, so pin a1 one step away and
        // send every texel to index 0.
        out[0] = static_cast<std::uint8_t>(hi);
        out[1] = static_cast<std::uint8_t>(hi > 0 ? hi - 1 : 1);
        if (hi == 0) {
            // a0 == 0 < a1 == 1 would select the 6-value mode where index 6
            // is exactly 0, which is what we want anyway.
            for (std::size_t i = 2; i < 8u; ++i) out[i] = 0xdbu;  // 6 repeated
            return;
        }
        for (std::size_t i = 2; i < 8u; ++i) out[i] = 0u;
        return;
    }

    out[0] = static_cast<std::uint8_t>(hi);   // a0 > a1 -> 8-value mode
    out[1] = static_cast<std::uint8_t>(lo);
    int table[8];
    table[0] = hi;
    table[1] = lo;
    for (int k = 0; k < 6; ++k) {
        table[2 + k] = ((6 - k) * hi + (1 + k) * lo) / 7;
    }

    std::uint64_t bits = 0;
    for (std::size_t i = 0; i < 16u; ++i) {
        const int a = static_cast<int>(texels[i][3]);
        int best = 0;
        int bestErr = -1;
        for (int k = 0; k < 8; ++k) {
            const int err = (a - table[k]) * (a - table[k]);
            if (bestErr < 0 || err < bestErr) {
                bestErr = err;
                best = k;
            }
        }
        bits |= static_cast<std::uint64_t>(best) << (3u * i);
    }
    for (std::size_t b = 0; b < 6u; ++b) {
        out[2u + b] = static_cast<std::uint8_t>((bits >> (8u * b)) & 0xffu);
    }
}

}  // namespace detail

// Compress a tightly-packed RGBA8 image (as produced by
// Impl::buildRGBA8Upload) into S3TC blocks.
//
// Slices are emitted back to back, matching the layout
// decodeS3TCLevelToRGBA8 reads and the layout compressedTexImage uploads
// per array slice. Partial edge blocks replicate the last real texel, which
// is what every S3TC encoder does and what keeps a non-multiple-of-4 level
// from sampling garbage past the edge.
inline bool encodeImage(GLenum internalFormat,
                        const std::uint8_t* rgba8,
                        std::size_t width,
                        std::size_t height,
                        std::size_t depth,
                        std::vector<std::uint8_t>& out) {
    if (rgba8 == nullptr || !isEncodableFormat(internalFormat)) return false;
    if (width == 0u || height == 0u || depth == 0u) return false;
    const std::size_t blockBytes = blockBytesForFormat(internalFormat);
    if (blockBytes == 0u) return false;

    const bool dxt1 = blockBytes == 8u;
    const bool dxt3 = internalFormat == GL_COMPRESSED_RGBA_S3TC_DXT3_EXT;
    const bool dxt5 = internalFormat == GL_COMPRESSED_RGBA_S3TC_DXT5_EXT;
    const bool alphaCapableDXT1 =
        internalFormat == GL_COMPRESSED_RGBA_S3TC_DXT1_EXT;

    const std::size_t blocksX = (width + 3u) / 4u;
    const std::size_t blocksY = (height + 3u) / 4u;
    out.assign(blocksX * blocksY * depth * blockBytes, 0u);

    for (std::size_t z = 0; z < depth; ++z) {
        const std::uint8_t* slice = rgba8 + z * width * height * 4u;
        std::uint8_t* dstSlice = out.data() + z * blocksX * blocksY * blockBytes;
        for (std::size_t by = 0; by < blocksY; ++by) {
            for (std::size_t bx = 0; bx < blocksX; ++bx) {
                std::uint8_t texels[16][4];
                for (std::size_t ty = 0; ty < 4u; ++ty) {
                    // Clamp instead of wrapping: an edge block on a 6-wide
                    // level must not fold texel 0 back in as texel 6.
                    const std::size_t sy =
                        std::min(by * 4u + ty, height - 1u);
                    for (std::size_t tx = 0; tx < 4u; ++tx) {
                        const std::size_t sx =
                            std::min(bx * 4u + tx, width - 1u);
                        const std::uint8_t* src =
                            slice + (sy * width + sx) * 4u;
                        std::uint8_t* dst = texels[ty * 4u + tx];
                        dst[0] = src[0];
                        dst[1] = src[1];
                        dst[2] = src[2];
                        dst[3] = src[3];
                    }
                }

                std::uint8_t* dst =
                    dstSlice + (by * blocksX + bx) * blockBytes;
                if (dxt1) {
                    bool punchThrough = false;
                    if (alphaCapableDXT1) {
                        for (std::size_t i = 0; i < 16u; ++i) {
                            if (texels[i][3] < 128u) { punchThrough = true; break; }
                        }
                    }
                    detail::encodeColorBlock(texels, punchThrough, dst);
                } else {
                    if (dxt3) {
                        detail::encodeExplicitAlpha(texels, dst);
                    } else if (dxt5) {
                        detail::encodeInterpolatedAlpha(texels, dst);
                    }
                    // DXT3/DXT5 colour is always the 4-colour mode: their
                    // alpha lives in the first 8 bytes, so the c0 <= c1
                    // encoding has no transparent meaning here.
                    detail::encodeColorBlock(texels, /*punchThrough=*/false,
                                             dst + 8);
                }
            }
        }
    }
    return true;
}

}  // namespace s3tc
}  // namespace appgl
