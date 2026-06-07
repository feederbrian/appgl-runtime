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
#ifndef GL_LUMINANCE
#define GL_LUMINANCE 0x1909
#endif
#ifndef GL_LUMINANCE_ALPHA
#define GL_LUMINANCE_ALPHA 0x190A
#endif
#ifndef GL_LUMINANCE8
#define GL_LUMINANCE8 0x8040
#endif
#ifndef GL_LUMINANCE8_ALPHA8
#define GL_LUMINANCE8_ALPHA8 0x8045
#endif
#ifndef GL_INTENSITY
#define GL_INTENSITY 0x8049
#endif
#ifndef GL_INTENSITY8
#define GL_INTENSITY8 0x804B
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
