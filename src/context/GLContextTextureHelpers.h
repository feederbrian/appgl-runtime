#pragma once

#include "../../include/AppGL/glcorearb.h"

#import <Foundation/NSObjCRuntime.h>

#include <cstddef>

// Compat-profile upload-format enums removed from the core glcorearb.h
// surface in GL 3.2. AppGL still accepts them as upload aliases via
// componentCountForFormat + buildRGBA8Upload; defining them here with
// #ifndef guards keeps the compat-profile texture path self-contained
// without polluting the public header surface or the codegen tables.
// See GLCapabilities.mm for the matching format-table registrations
// and the upload channel-fill rules in buildRGBA8Upload.
#ifndef GL_ALPHA8
#define GL_ALPHA8 0x803C
#endif
#ifndef GL_ALPHA4
#define GL_ALPHA4 0x803B
#endif
#ifndef GL_ALPHA12
#define GL_ALPHA12 0x803D
#endif
#ifndef GL_ALPHA16
#define GL_ALPHA16 0x803E
#endif
#ifndef GL_LUMINANCE
#define GL_LUMINANCE 0x1909
#endif
#ifndef GL_LUMINANCE_ALPHA
#define GL_LUMINANCE_ALPHA 0x190A
#endif
#ifndef GL_LUMINANCE4
#define GL_LUMINANCE4 0x803F
#endif
#ifndef GL_LUMINANCE8
#define GL_LUMINANCE8 0x8040
#endif
#ifndef GL_LUMINANCE12
#define GL_LUMINANCE12 0x8041
#endif
#ifndef GL_LUMINANCE16
#define GL_LUMINANCE16 0x8042
#endif
#ifndef GL_LUMINANCE4_ALPHA4
#define GL_LUMINANCE4_ALPHA4 0x8043
#endif
#ifndef GL_LUMINANCE6_ALPHA2
#define GL_LUMINANCE6_ALPHA2 0x8044
#endif
#ifndef GL_LUMINANCE8_ALPHA8
#define GL_LUMINANCE8_ALPHA8 0x8045
#endif
#ifndef GL_LUMINANCE12_ALPHA4
#define GL_LUMINANCE12_ALPHA4 0x8046
#endif
#ifndef GL_LUMINANCE12_ALPHA12
#define GL_LUMINANCE12_ALPHA12 0x8047
#endif
#ifndef GL_LUMINANCE16_ALPHA16
#define GL_LUMINANCE16_ALPHA16 0x8048
#endif
#ifndef GL_INTENSITY
#define GL_INTENSITY 0x8049
#endif
#ifndef GL_INTENSITY4
#define GL_INTENSITY4 0x804A
#endif
#ifndef GL_INTENSITY8
#define GL_INTENSITY8 0x804B
#endif
#ifndef GL_INTENSITY12
#define GL_INTENSITY12 0x804C
#endif
#ifndef GL_INTENSITY16
#define GL_INTENSITY16 0x804D
#endif
#ifndef GL_TEXTURE_LUMINANCE_SIZE
#define GL_TEXTURE_LUMINANCE_SIZE 0x8060
#endif
#ifndef GL_TEXTURE_INTENSITY_SIZE
#define GL_TEXTURE_INTENSITY_SIZE 0x8061
#endif
#ifndef GL_ABGR_EXT
#define GL_ABGR_EXT 0x8000
#endif
#ifndef GL_SLUMINANCE8
#define GL_SLUMINANCE8 0x8C47
#endif
#ifndef GL_SLUMINANCE8_ALPHA8
#define GL_SLUMINANCE8_ALPHA8 0x8C45
#endif

namespace appgl {

struct CompressedBlockInfo {
    NSUInteger width = 0;
    NSUInteger height = 0;
    NSUInteger depth = 0;
    NSUInteger bytes = 0;
};

enum class TextureViewClass {
    Undefined,
    Bits128,
    Bits96,
    Bits64,
    Bits48,
    Bits32,
    Bits24,
    Bits16,
    Bits8,
    Rgtc1Red,
    Rgtc2Rg,
    BptcUnorm,
    BptcFloat,
};

bool isDepthFormat(GLenum internalFormat);
bool isStencilFormat(GLenum internalFormat);
CompressedBlockInfo compressedBlockInfoForInternalFormat(GLenum internalFormat);
bool isSRGBTextureFormat(GLenum internalFormat);
TextureViewClass textureViewClassForInternalFormat(GLenum internalFormat);
std::size_t componentCountForFormat(GLenum format);
std::size_t bytesPerComponent(GLenum type);
bool isPackedPixelType(GLenum type);
std::size_t bytesPerPixel(GLenum format, GLenum type);

}  // namespace appgl
