#include "SparseTextureAlloc.h"

#include "../ExtensionContext.h"
#include "../../context/GLContext.h"
#include "../../objects/GLObjectStore.h"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <mutex>
#include <unordered_map>

namespace appgl::extensions::sparse_texture {

namespace {

struct TextureState {
    GLint sparse = GL_FALSE;
    GLint virtualPageSizeIndex = 0;
    GLsizei sparseLevels = 0;
    void* sparseHeap = nullptr;
    std::vector<CommittedRegion> committedRegions;
};

struct ContextState {
    std::unordered_map<const GLTextureObject*, TextureState> textures;
};

std::mutex& stateMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<const GLContext*, ContextState>& contextStates() {
    static std::unordered_map<const GLContext*, ContextState> states;
    return states;
}

void releaseRetainedMetalObject(void* object) {
    if (object != nullptr) {
        CFRelease(object);
    }
}

TextureState& stateForLocked(ExtensionContext& ctx, const GLTextureObject& texture) {
    return contextStates()[&ctx.context()].textures[&texture];
}

TextureState* findStateLocked(ExtensionContext& ctx, const GLTextureObject* texture) {
    if (texture == nullptr) {
        return nullptr;
    }
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return nullptr;
    }
    auto textureIt = contextIt->second.textures.find(texture);
    if (textureIt == contextIt->second.textures.end()) {
        return nullptr;
    }
    return &textureIt->second;
}

void releaseTextureStorage(TextureState& state) {
    releaseRetainedMetalObject(state.sparseHeap);
    state.sparseHeap = nullptr;
    state.committedRegions.clear();
    state.sparseLevels = 0;
}

}  // namespace

bool isAllocationTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_RECTANGLE:
            return true;
        default:
            return false;
    }
}

bool targetUsesSlices(GLenum target) {
    return target == GL_TEXTURE_2D_ARRAY ||
           target == GL_TEXTURE_CUBE_MAP ||
           target == GL_TEXTURE_CUBE_MAP_ARRAY;
}

GLsizei storedDepthForTarget(GLenum target, GLsizei depth) {
    switch (target) {
        case GL_TEXTURE_3D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return std::max<GLsizei>(depth, 1);
        case GL_TEXTURE_CUBE_MAP:
            return 6;
        default:
            return 1;
    }
}

GLint textureSparse(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->sparse : GL_FALSE;
}

void setTextureSparse(ExtensionContext& ctx, GLTextureObject& texture, GLint value) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).sparse = value;
}

GLint virtualPageSizeIndex(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->virtualPageSizeIndex : 0;
}

void setVirtualPageSizeIndex(ExtensionContext& ctx, GLTextureObject& texture, GLint value) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).virtualPageSizeIndex = value;
}

GLsizei sparseLevels(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->sparseLevels : 0;
}

void setSparseLevels(ExtensionContext& ctx, GLTextureObject& texture, GLsizei levels) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).sparseLevels = levels;
}

void* sparseHeap(ExtensionContext& ctx, const GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    return state != nullptr ? state->sparseHeap : nullptr;
}

void replaceSparseHeap(ExtensionContext& ctx, GLTextureObject& texture, void* retainedHeap) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState& state = stateForLocked(ctx, texture);
    releaseRetainedMetalObject(state.sparseHeap);
    state.sparseHeap = retainedHeap;
}

std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    return stateForLocked(ctx, texture).committedRegions;
}

const std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx,
                                                     const GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    static const std::vector<CommittedRegion> empty;
    return state != nullptr ? state->committedRegions : empty;
}

void clearCommittedRegions(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    if (state != nullptr) {
        state->committedRegions.clear();
    }
}

void resetStorage(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    if (state != nullptr) {
        releaseTextureStorage(*state);
    }
}

void destroyTexture(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    auto textureIt = contextIt->second.textures.find(&texture);
    if (textureIt == contextIt->second.textures.end()) {
        return;
    }
    releaseTextureStorage(textureIt->second);
    contextIt->second.textures.erase(textureIt);
}

void destroyContext(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    for (auto& [texture, state] : contextIt->second.textures) {
        (void)texture;
        releaseTextureStorage(state);
    }
    contextStates().erase(contextIt);
}

}  // namespace appgl::extensions::sparse_texture
