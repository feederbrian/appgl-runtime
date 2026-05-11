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

bool validateStorageRequest(ExtensionContext& ctx,
                            const GLTextureObject& texture,
                            GLenum target,
                            GLenum internalformat,
                            GLsizei levels,
                            GLsizei width,
                            GLsizei height,
                            GLsizei depth,
                            GLsizei samples = 1);
GLsizei levelCountForStorage(ExtensionContext& ctx,
                             GLenum target,
                             GLsizei levels,
                             GLsizei width,
                             GLsizei height,
                             GLsizei depth,
                             GLenum internalformat,
                             GLsizei samples = 1);
bool allocateStorage(ExtensionContext& ctx, GLTextureObject& texture);

void* sparseHeap(ExtensionContext& ctx, const GLTextureObject& texture);
void replaceSparseHeap(ExtensionContext& ctx, GLTextureObject& texture, void* retainedHeap);

std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, GLTextureObject& texture);
const std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, const GLTextureObject& texture);
void clearCommittedRegions(ExtensionContext& ctx, GLTextureObject& texture);

bool uploadCommittedRegions(ExtensionContext& ctx,
                            GLTextureObject& texture,
                            GLuint textureName,
                            bool& handled);
bool pageCommitment(ExtensionContext& ctx,
                    GLTextureObject& texture,
                    GLuint textureName,
                    GLint level,
                    GLint xoffset,
                    GLint yoffset,
                    GLint zoffset,
                    GLsizei width,
                    GLsizei height,
                    GLsizei depth,
                    GLboolean commit);

void resetStorage(ExtensionContext& ctx, GLTextureObject& texture);
void destroyTexture(ExtensionContext& ctx, GLTextureObject& texture);
void destroyContext(ExtensionContext& ctx);

}  // namespace appgl::extensions::sparse_texture
