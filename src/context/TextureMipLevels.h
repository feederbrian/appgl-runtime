#pragma once

#include "../../include/AppGL/glcorearb.h"

#include <algorithm>
#include <climits>
#include <cstddef>
#include <type_traits>

namespace appgl {

template <typename Count>
inline Count singleMipLevelCount() {
    return static_cast<Count>(1);
}

template <typename Count>
inline Count nonZeroMipLevelCount(Count levels) {
    return std::max<Count>(levels, singleMipLevelCount<Count>());
}

inline std::size_t mipLevelCountForDimensions(std::size_t width,
                                              std::size_t height,
                                              std::size_t depth) {
    std::size_t maxDimension = std::max(width, std::max(height, depth));
    maxDimension = nonZeroMipLevelCount(maxDimension);
    std::size_t levels = 1;
    while (maxDimension > 1) {
        maxDimension >>= 1;
        ++levels;
    }
    return levels;
}

template <typename Dimension, typename Level>
inline Dimension mipDimensionAtLevel(Dimension base, Level level) {
    if constexpr (std::is_signed_v<Level>) {
        if (level <= 0) {
            return nonZeroMipLevelCount(base);
        }
    }
    if (static_cast<std::size_t>(level) >= sizeof(Dimension) * CHAR_BIT) {
        return singleMipLevelCount<Dimension>();
    }
    return std::max<Dimension>(
        static_cast<Dimension>(base >> level),
        singleMipLevelCount<Dimension>());
}

inline GLsizei glMipDimensionAtLevel(GLsizei base, GLint levelOffset) {
    return mipDimensionAtLevel(base, levelOffset);
}

inline GLint mipTailOffsetForDimensions(GLsizei width,
                                        GLsizei height,
                                        GLsizei depth) {
    return static_cast<GLint>(
        mipLevelCountForDimensions(
            static_cast<std::size_t>(std::max<GLsizei>(width, 1)),
            static_cast<std::size_t>(std::max<GLsizei>(height, 1)),
            static_cast<std::size_t>(std::max<GLsizei>(depth, 1))) -
        1u);
}

inline bool metalTargetRequiresSingleMipLevel(GLenum target,
                                              bool use2DFor1D) {
    return ((target == GL_TEXTURE_1D ||
             target == GL_TEXTURE_1D_ARRAY) && !use2DFor1D) ||
           target == GL_TEXTURE_BUFFER;
}

inline std::size_t metalMipLevelCountForTexture(GLenum target,
                                                bool use2DFor1D,
                                                std::size_t requestedLevels,
                                                std::size_t width,
                                                std::size_t height,
                                                std::size_t depth) {
    if (metalTargetRequiresSingleMipLevel(target, use2DFor1D)) {
        return 1u;
    }
    return std::min(requestedLevels,
                    mipLevelCountForDimensions(width, height, depth));
}

inline std::size_t metalNaturalMipLevelCountForTexture(GLenum target,
                                                       bool use2DFor1D,
                                                       std::size_t width,
                                                       std::size_t height,
                                                       std::size_t depth) {
    return metalMipLevelCountForTexture(
        target,
        use2DFor1D,
        mipLevelCountForDimensions(width, height, depth),
        width,
        height,
        depth);
}

}  // namespace appgl
