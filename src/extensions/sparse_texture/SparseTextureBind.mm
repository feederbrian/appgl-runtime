#include "SparseTextureBind.h"

#include "SparseTextureAlloc.h"
#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../caps/GLCapabilities.h"
#include "../../objects/GLObjectStore.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <optional>

namespace appgl::extensions::sparse_texture {

namespace {

struct PageSize {
    GLint x;
    GLint y;
    GLint z;
};

id<MTLDevice> metalDevice(ExtensionContext& ctx) {
    return (__bridge id<MTLDevice>)ctx.metalDevice();
}

bool isStandardSparseTexture2Target(GLenum target) {
    switch (target) {
        case GL_TEXTURE_1D:
        case GL_TEXTURE_1D_ARRAY:
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_RECTANGLE:
        case GL_TEXTURE_BUFFER:
        case GL_RENDERBUFFER:
            return true;
        default:
            return false;
    }
}

std::optional<PageSize> standardSparseTexture2PageSize(GLenum target, GLenum internalformat) {
    if (!ExtensionRegistry::isExtensionActive("GL_ARB_sparse_texture2") ||
        !isStandardSparseTexture2Target(target)) {
        return std::nullopt;
    }

    switch (internalformat) {
        case GL_R8:
        case GL_R8_SNORM:
        case GL_R8I:
        case GL_R8UI:
            return PageSize{256, 256, 1};

        case GL_R16:
        case GL_R16_SNORM:
        case GL_RG8:
        case GL_RG8_SNORM:
        case GL_RGB565:
        case GL_R16F:
        case GL_R16I:
        case GL_R16UI:
        case GL_RG8I:
        case GL_RG8UI:
            return PageSize{256, 128, 1};

        case GL_RG16:
        case GL_RG16_SNORM:
        case GL_RGBA8:
        case GL_RGBA8_SNORM:
        case GL_RGB10_A2:
        case GL_RGB10_A2UI:
        case GL_RG16F:
        case GL_R32F:
        case GL_R11F_G11F_B10F:
        case GL_RGB9_E5:
        case GL_R32I:
        case GL_R32UI:
        case GL_RG16I:
        case GL_RG16UI:
        case GL_RGBA8I:
        case GL_RGBA8UI:
            return PageSize{128, 128, 1};

        case GL_RGBA16:
        case GL_RGBA16_SNORM:
        case GL_RGBA16F:
        case GL_RG32F:
        case GL_RG32I:
        case GL_RG32UI:
        case GL_RGBA16I:
        case GL_RGBA16UI:
            return PageSize{128, 64, 1};

        case GL_RGBA32F:
        case GL_RGBA32I:
        case GL_RGBA32UI:
            return PageSize{64, 64, 1};

        default:
            return std::nullopt;
    }
}

MTLTextureType metalTextureTypeForTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            return MTLTextureType2D;
        case GL_TEXTURE_3D:
            return MTLTextureType3D;
        case GL_TEXTURE_2D_ARRAY:
            return MTLTextureType2DArray;
        case GL_TEXTURE_CUBE_MAP:
            return MTLTextureTypeCube;
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return MTLTextureTypeCubeArray;
        default:
            return MTLTextureType2D;
    }
}

MTLSize sparsePageSizeForFormat(ExtensionContext& ctx, GLenum target, GLenum internalformat) {
    id<MTLDevice> device = metalDevice(ctx);
    if (device == nil || !isAllocationTarget(target)) {
        return MTLSizeMake(0, 0, 0);
    }
    const auto capability = ctx.capabilities().format(internalformat);
    if (!capability.has_value()) {
        return MTLSizeMake(0, 0, 0);
    }
    const MTLPixelFormat pixelFormat =
        static_cast<MTLPixelFormat>(capability->metalPixelFormat);
    if (pixelFormat == MTLPixelFormatInvalid) {
        return MTLSizeMake(0, 0, 0);
    }
    MTLSize tile = [device sparseTileSizeWithTextureType:metalTextureTypeForTarget(target)
                                             pixelFormat:pixelFormat
                                             sampleCount:1];
    if (tile.width == 0 || tile.height == 0) {
        return MTLSizeMake(0, 0, 0);
    }
    return MTLSizeMake(tile.width, tile.height, std::max<NSUInteger>(tile.depth, 1));
}

}  // namespace

bool isTextureParameterPname(GLenum pname) {
    return pname == GL_TEXTURE_SPARSE_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB ||
           pname == GL_NUM_SPARSE_LEVELS_ARB;
}

bool isInternalFormatQueryPname(GLenum pname) {
    return pname == GL_NUM_VIRTUAL_PAGE_SIZES_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_X_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_Y_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_Z_ARB;
}

bool handleTextureParameter(ExtensionContext& ctx,
                            GLenum target,
                            GLenum pname,
                            const GLint* params,
                            bool& handled) {
    handled = false;
    if (pname != GL_TEXTURE_SPARSE_ARB && pname != GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) {
        return true;
    }
    handled = true;
    if (params == nullptr) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_TEXTURE_SPARSE_ARB) {
        if (params[0] != GL_FALSE && params[0] != GL_TRUE) {
            ctx.pushError(GL_INVALID_ENUM);
            return false;
        }
        if (params[0] == GL_TRUE && !isAllocationTarget(target)) {
            ctx.pushError(GL_INVALID_VALUE);
            return false;
        }
    } else if (params[0] < 0) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }

    GLTextureObject* texture = ctx.currentTexture(target);
    if (texture == nullptr) {
        return true;
    }
    if (!texture->instantiated) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (texture->desc.immutable) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (pname == GL_TEXTURE_SPARSE_ARB) {
        setTextureSparse(ctx, *texture, params[0]);
    } else {
        setVirtualPageSizeIndex(ctx, *texture, params[0]);
    }
    texture->samplerDirty = true;
    return true;
}

bool handleTextureParameterQuery(ExtensionContext& ctx,
                                 GLenum target,
                                 GLenum pname,
                                 GLint* params,
                                 bool& handled) {
    handled = false;
    if (!isTextureParameterPname(pname)) {
        return true;
    }
    handled = true;
    if (pname != GL_NUM_SPARSE_LEVELS_ARB && params == nullptr) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTextureObject* texture = ctx.currentTexture(target);
    if (texture == nullptr) {
        if (params != nullptr) {
            params[0] = 0;
        }
        return true;
    }
    if (pname == GL_TEXTURE_SPARSE_ARB) {
        params[0] = textureSparse(ctx, texture);
    } else if (pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) {
        params[0] = virtualPageSizeIndex(ctx, texture);
    } else if (params != nullptr) {
        params[0] = sparseLevels(ctx, texture);
    }
    return true;
}

bool handleInternalFormatQuery(ExtensionContext& ctx,
                               GLenum target,
                               GLenum internalformat,
                               GLenum pname,
                               GLsizei count,
                               GLint* params,
                               bool& handled) {
    handled = false;
    if (!isInternalFormatQueryPname(pname)) {
        return true;
    }
    handled = true;
    if (count <= 0) {
        return true;
    }
    const std::optional<PageSize> standardPage =
        standardSparseTexture2PageSize(target, internalformat);
    switch (pname) {
        case GL_NUM_VIRTUAL_PAGE_SIZES_ARB: {
            if (standardPage.has_value()) {
                params[0] = 1;
                return true;
            }
            const auto capability = ctx.capabilities().format(internalformat);
            const MTLSize tile = sparsePageSizeForFormat(ctx, target, internalformat);
            params[0] = (tile.width > 0 && capability.has_value()) ? 1 : 0;
            return true;
        }
        case GL_VIRTUAL_PAGE_SIZE_X_ARB:
        case GL_VIRTUAL_PAGE_SIZE_Y_ARB:
        case GL_VIRTUAL_PAGE_SIZE_Z_ARB: {
            for (GLsizei i = 0; i < count; ++i) {
                params[i] = 0;
            }
            if (standardPage.has_value()) {
                params[0] =
                    (pname == GL_VIRTUAL_PAGE_SIZE_X_ARB) ? standardPage->x :
                    (pname == GL_VIRTUAL_PAGE_SIZE_Y_ARB) ? standardPage->y :
                                                            standardPage->z;
                return true;
            }
            const auto capability = ctx.capabilities().format(internalformat);
            if (!capability.has_value()) {
                return true;
            }
            const MTLSize tile = sparsePageSizeForFormat(ctx, target, internalformat);
            if (tile.width == 0) {
                return true;
            }
            const NSUInteger value =
                (pname == GL_VIRTUAL_PAGE_SIZE_X_ARB) ? tile.width :
                (pname == GL_VIRTUAL_PAGE_SIZE_Y_ARB) ? tile.height :
                                                        tile.depth;
            params[0] = static_cast<GLint>(value);
            return true;
        }
        default:
            handled = false;
            return true;
    }
}

}  // namespace appgl::extensions::sparse_texture
