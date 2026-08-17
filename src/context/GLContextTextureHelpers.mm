#include "GLContextTextureHelpers.h"
#include "../runtime/AppGLProfile.h"

namespace appgl {

bool isDepthFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32:
        case GL_DEPTH_COMPONENT32F:
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return true;
        default:
            return false;
    }
}

bool isStencilFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_STENCIL_INDEX:
        case GL_STENCIL_INDEX1:
        case GL_STENCIL_INDEX4:
        case GL_STENCIL_INDEX8:
        case GL_STENCIL_INDEX16:
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return true;
        default:
            return false;
    }
}

CompressedBlockInfo compressedBlockInfoForInternalFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RED_RGTC1:
        case GL_COMPRESSED_SIGNED_RED_RGTC1:
            return {4, 4, 1, 8};
        case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
        case GL_COMPRESSED_RG_RGTC2:
        case GL_COMPRESSED_SIGNED_RG_RGTC2:
        case GL_COMPRESSED_RGBA_BPTC_UNORM:
        case GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
        case GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT:
        case GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
            return {4, 4, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_4x4_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR:
            return {4, 4, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_5x4_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR:
            return {5, 4, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_5x5_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR:
            return {5, 5, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_6x5_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR:
            return {6, 5, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_6x6_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR:
            return {6, 6, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_8x5_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR:
            return {8, 5, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_8x6_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR:
            return {8, 6, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_8x8_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR:
            return {8, 8, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_10x5_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR:
            return {10, 5, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_10x6_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR:
            return {10, 6, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_10x8_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR:
            return {10, 8, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_10x10_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR:
            return {10, 10, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_12x10_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR:
            return {12, 10, 1, 16};
        case GL_COMPRESSED_RGBA_ASTC_12x12_KHR:
        case GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR:
            return {12, 12, 1, 16};
        case GL_COMPRESSED_RGB8_ETC2:
        case GL_COMPRESSED_SRGB8_ETC2:
        case GL_COMPRESSED_RGB8_PUNCHTHROUGH_ALPHA1_ETC2:
        case GL_COMPRESSED_SRGB8_PUNCHTHROUGH_ALPHA1_ETC2:
        case GL_COMPRESSED_R11_EAC:
        case GL_COMPRESSED_SIGNED_R11_EAC:
            return {4, 4, 1, 8};
        case GL_COMPRESSED_RGBA8_ETC2_EAC:
        case GL_COMPRESSED_SRGB8_ALPHA8_ETC2_EAC:
        case GL_COMPRESSED_RG11_EAC:
        case GL_COMPRESSED_SIGNED_RG11_EAC:
            return {4, 4, 1, 16};
        default:
            return {};
    }
}

bool isSRGBTextureFormat(GLenum internalFormat) {
    return internalFormat == GL_SRGB8 ||
           internalFormat == GL_SRGB8_ALPHA8 ||
           internalFormat == GL_SRGB ||
           internalFormat == GL_SRGB_ALPHA ||
           internalFormat == GL_COMPRESSED_SRGB ||
           internalFormat == GL_COMPRESSED_SRGB_ALPHA ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR ||
           internalFormat == GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR;
}

TextureViewClass textureViewClassForInternalFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_RGBA32F:
        case GL_RGBA32UI:
        case GL_RGBA32I:
            return TextureViewClass::Bits128;
        case GL_RGB32F:
        case GL_RGB32UI:
        case GL_RGB32I:
            return TextureViewClass::Bits96;
        case GL_RGBA16F:
        case GL_RG32F:
        case GL_RGBA16UI:
        case GL_RG32UI:
        case GL_RGBA16I:
        case GL_RG32I:
        case GL_RGBA16:
        case GL_RGBA16_SNORM:
            return TextureViewClass::Bits64;
        case GL_RGB16:
        case GL_RGB16_SNORM:
        case GL_RGB16F:
        case GL_RGB16UI:
        case GL_RGB16I:
            return TextureViewClass::Bits48;
        case GL_RG16F:
        case GL_R11F_G11F_B10F:
        case GL_R32F:
        case GL_RGB10_A2UI:
        case GL_RGBA8UI:
        case GL_RG16UI:
        case GL_R32UI:
        case GL_RGBA8I:
        case GL_RG16I:
        case GL_R32I:
        case GL_RGB10_A2:
        case GL_RGBA8:
        case GL_RG16:
        case GL_RGBA8_SNORM:
        case GL_RG16_SNORM:
        case GL_SRGB8_ALPHA8:
        case GL_RGB9_E5:
            return TextureViewClass::Bits32;
        case GL_RGB8:
        case GL_RGB8_SNORM:
        case GL_SRGB8:
        case GL_RGB8UI:
        case GL_RGB8I:
            return TextureViewClass::Bits24;
        case GL_R16F:
        case GL_RG8UI:
        case GL_R16UI:
        case GL_RG8I:
        case GL_R16I:
        case GL_RG8:
        case GL_R16:
        case GL_RG8_SNORM:
        case GL_R16_SNORM:
            return TextureViewClass::Bits16;
        case GL_R8UI:
        case GL_R8I:
        case GL_R8:
        case GL_R8_SNORM:
            return TextureViewClass::Bits8;
        case GL_COMPRESSED_RED_RGTC1:
        case GL_COMPRESSED_SIGNED_RED_RGTC1:
            return TextureViewClass::Rgtc1Red;
        case GL_COMPRESSED_RG_RGTC2:
        case GL_COMPRESSED_SIGNED_RG_RGTC2:
            return TextureViewClass::Rgtc2Rg;
        case GL_COMPRESSED_RGBA_BPTC_UNORM:
        case GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
            return TextureViewClass::BptcUnorm;
        case GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT:
        case GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
            return TextureViewClass::BptcFloat;
        default:
            return TextureViewClass::Undefined;
    }
}

std::size_t componentCountForFormat(GLenum format) {
    switch (format) {
        case GL_RED:
        case GL_RED_INTEGER:
        case GL_GREEN:
        case GL_GREEN_INTEGER:
        case GL_BLUE:
        case GL_BLUE_INTEGER:
        case GL_DEPTH_COMPONENT:
        case GL_STENCIL_INDEX:
            return 1;
        case GL_RG:
        case GL_RG_INTEGER:
        case GL_DEPTH_STENCIL:
            return 2;
        case GL_RGB:
        case GL_RGB_INTEGER:
        case GL_BGR:
        case GL_BGR_INTEGER:
            return 3;
        case GL_RGBA:
        case GL_RGBA_INTEGER:
        case GL_BGRA:
        case GL_BGRA_INTEGER:
            return 4;
        case GL_ABGR_EXT:
            return appglCompatProfileEnabled() ? 4 : 0;
        // Compat-profile upload formats.
        case GL_ALPHA:
        case GL_LUMINANCE:
        case GL_INTENSITY:
        // R1.0-c item #10 — EXT_texture_integer external formats carry the
        // same component counts as their non-integer spellings. Without
        // these, componentCountForFormat returned 0 for an ALPHA_INTEGER
        // upload and bytesPerPixel collapsed to 0 with it.
        case GL_ALPHA_INTEGER_EXT:
        case GL_LUMINANCE_INTEGER_EXT:
            return 1;
        case GL_LUMINANCE_ALPHA:
        case GL_LUMINANCE_ALPHA_INTEGER_EXT:
            return 2;
        default:
            return 0;
    }
}

// Returns bytes per component for a given GL pixel type.
// For packed types, returns the total packed pixel size.
std::size_t bytesPerComponent(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE:
        case GL_BYTE:
            return 1;
        case GL_UNSIGNED_SHORT:
        case GL_SHORT:
        case GL_HALF_FLOAT:
            return 2;
        case GL_UNSIGNED_INT:
        case GL_INT:
        case GL_FLOAT:
            return 4;
        default:
            return 0;  // packed types handled separately
    }
}

// Returns true if the type is a packed pixel type (single value per pixel).
bool isPackedPixelType(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE_3_3_2:
        case GL_UNSIGNED_BYTE_2_3_3_REV:
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_5_6_5_REV:
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        case GL_UNSIGNED_INT_8_8_8_8:
        case GL_UNSIGNED_INT_8_8_8_8_REV:
        case GL_UNSIGNED_INT_10_10_10_2:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_24_8:
        case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
        case GL_UNSIGNED_INT_5_9_9_9_REV:
            return true;
        default:
            return false;
    }
}

// Bytes per pixel for a given format + type combination.
std::size_t bytesPerPixel(GLenum format, GLenum type) {
    if (isPackedPixelType(type)) {
        switch (type) {
            case GL_UNSIGNED_BYTE_3_3_2:
            case GL_UNSIGNED_BYTE_2_3_3_REV:
                return 1;
            case GL_UNSIGNED_SHORT_5_6_5:
            case GL_UNSIGNED_SHORT_5_6_5_REV:
            case GL_UNSIGNED_SHORT_4_4_4_4:
            case GL_UNSIGNED_SHORT_4_4_4_4_REV:
            case GL_UNSIGNED_SHORT_5_5_5_1:
            case GL_UNSIGNED_SHORT_1_5_5_5_REV:
                return 2;
            case GL_UNSIGNED_INT_8_8_8_8:
            case GL_UNSIGNED_INT_8_8_8_8_REV:
            case GL_UNSIGNED_INT_10_10_10_2:
            case GL_UNSIGNED_INT_2_10_10_10_REV:
            case GL_UNSIGNED_INT_24_8:
            case GL_UNSIGNED_INT_10F_11F_11F_REV:
            case GL_UNSIGNED_INT_5_9_9_9_REV:
                return 4;
            case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
                return 8;
            default:
                return 4;
        }
    }
    return componentCountForFormat(format) * bytesPerComponent(type);
}

}  // namespace appgl
