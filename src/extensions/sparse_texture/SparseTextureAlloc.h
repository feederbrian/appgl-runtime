#pragma once

#include <vector>

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
struct GLTextureObject;
}

namespace appgl::extensions::sparse_texture {

struct CommittedRegion {
    GLint level = 0;
    GLint xoffset = 0;
    GLint yoffset = 0;
    GLint zoffset = 0;
    GLsizei width = 0;
    GLsizei height = 0;
    GLsizei depth = 0;
};

bool isAllocationTarget(GLenum target);
bool targetUsesSlices(GLenum target);
GLsizei storedDepthForTarget(GLenum target, GLsizei depth);

GLint textureSparse(ExtensionContext& ctx, const GLTextureObject* texture);
void setTextureSparse(ExtensionContext& ctx, GLTextureObject& texture, GLint value);

GLint virtualPageSizeIndex(ExtensionContext& ctx, const GLTextureObject* texture);
void setVirtualPageSizeIndex(ExtensionContext& ctx, GLTextureObject& texture, GLint value);

GLsizei sparseLevels(ExtensionContext& ctx, const GLTextureObject* texture);
void setSparseLevels(ExtensionContext& ctx, GLTextureObject& texture, GLsizei levels);

void* sparseHeap(ExtensionContext& ctx, const GLTextureObject& texture);
void replaceSparseHeap(ExtensionContext& ctx, GLTextureObject& texture, void* retainedHeap);

std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, GLTextureObject& texture);
const std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, const GLTextureObject& texture);
void clearCommittedRegions(ExtensionContext& ctx, GLTextureObject& texture);

void resetStorage(ExtensionContext& ctx, GLTextureObject& texture);
void destroyTexture(ExtensionContext& ctx, GLTextureObject& texture);
void destroyContext(ExtensionContext& ctx);

}  // namespace appgl::extensions::sparse_texture
