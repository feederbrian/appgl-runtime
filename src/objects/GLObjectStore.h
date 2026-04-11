#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

template <typename T>
class ObjectTable {
public:
    GLuint create();
    GLuint reserveName();
    bool erase(GLuint id);
    bool contains(GLuint id) const;
    T* get(GLuint id);
    const T* get(GLuint id) const;
    std::size_t size() const { return objects_.size(); }

    template <typename Visitor>
    void forEach(Visitor&& visitor);

private:
    GLuint nextId_ = 1;
    std::unordered_map<GLuint, T> objects_;
};

struct GLBufferObject {
    void* metalBuffer = nullptr;
    GLsizeiptr size = 0;
    GLenum usage = GL_STATIC_DRAW;
    bool mapped = false;
    bool instantiated = false;
    GLenum mapAccess = GL_READ_WRITE;
    GLbitfield mapAccessFlags = 0;
    GLintptr mapOffset = 0;
    GLsizeiptr mapLength = 0;
    void* mapPointer = nullptr;
    std::vector<std::uint8_t> shadowBytes;
};

struct GLTextureDesc {
    GLenum target = 0;
    GLenum internalFormat = 0;
    GLenum sourceFormat = GL_RGBA;
    GLenum sourceType = GL_UNSIGNED_BYTE;
    GLsizei width = 0;
    GLsizei height = 1;
    GLsizei depth = 1;
    GLsizei levels = 1;
    GLsizei layers = 1;
    bool immutable = false;
};

struct GLTextureImageLevel {
    GLTextureDesc desc;
    std::vector<std::uint8_t> rgba8;
    bool defined = false;
};

struct GLTextureParameters {
    GLint minFilter = GL_NEAREST_MIPMAP_LINEAR;
    GLint magFilter = GL_LINEAR;
    GLint wrapS = GL_REPEAT;
    GLint wrapT = GL_REPEAT;
    GLint wrapR = GL_REPEAT;
    GLfloat minLod = -1000.0f;
    GLfloat maxLod = 1000.0f;
    GLint baseLevel = 0;
    GLint maxLevel = 1000;
    GLint compareMode = GL_NONE;
    GLint compareFunc = GL_LEQUAL;
    std::array<GLfloat, 4> borderColor = {0.0f, 0.0f, 0.0f, 0.0f};
    std::array<GLint, 4> swizzle = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
};

struct GLTextureObject {
    void* metalTexture = nullptr;
    GLenum target = 0;
    GLTextureDesc desc;
    GLTextureParameters params;
    std::unordered_map<GLint, GLTextureImageLevel> levels;
    bool instantiated = false;
};

struct GLSamplerObject {
    void* metalSampler = nullptr;
    GLTextureParameters params;
    bool instantiated = false;
    bool dirty = true;
};

struct GLRenderbufferObject {
    void* metalTexture = nullptr;
    GLenum internalFormat = 0;
    GLsizei width = 0;
    GLsizei height = 0;
    GLsizei samples = 0;
    std::vector<std::uint8_t> rgba8;
    std::vector<GLfloat> depth32;
    std::vector<std::uint8_t> stencil8;
    bool instantiated = false;
    bool storageDefined = false;
};

struct GLFramebufferAttachment {
    enum class Kind {
        None,
        Texture,
        Renderbuffer,
    };

    Kind kind = Kind::None;
    GLuint object = 0;
    GLint level = 0;
    GLint layer = 0;
    GLenum textureTarget = 0;
    bool layered = false;
};

struct GLFramebufferObject {
    std::unordered_map<GLenum, GLFramebufferAttachment> attachments;
    std::array<GLenum, 8> drawBuffers = {GL_COLOR_ATTACHMENT0, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE};
    GLenum readBuffer = GL_COLOR_ATTACHMENT0;
    bool instantiated = false;
};

struct GLVertexAttributeState {
    bool enabled = false;
    GLint size = 4;
    GLenum type = GL_FLOAT;
    GLboolean normalized = GL_FALSE;
    GLsizei stride = 0;
    std::uintptr_t pointer = 0;
    GLuint buffer = 0;
    GLuint divisor = 0;
    bool integer = false;
    bool longData = false;
};

struct GLVertexArrayBufferBinding {
    GLuint glBuffer = 0;
    std::uint32_t metalSlot = 0;
    std::uint32_t stride = 0;
};

struct GLVertexArrayObject {
    std::vector<GLVertexAttributeState> attributes;
    void* metalVertexDescriptor = nullptr;
    std::string vertexDescriptorHash;
    std::string vertexDescriptorError;
    std::vector<GLVertexArrayBufferBinding> vertexBufferBindings;
    GLuint elementArrayBuffer = 0;
    bool instantiated = false;
    bool vertexDescriptorDirty = true;
};

struct GLShaderDeclaration {
    std::string name;
    GLenum type = 0;
    GLint arraySize = 1;
    GLint explicitLocation = -1;
};

struct GLShaderObject {
    GLenum stage = 0;
    std::string source;
    std::vector<std::uint32_t> spirv;
    std::string compileLog;
    bool compiled = false;
    bool deleteRequested = false;
    std::vector<GLShaderDeclaration> declaredUniforms;
    std::vector<GLShaderDeclaration> declaredInputs;
    std::vector<GLShaderDeclaration> declaredOutputs;
};

struct GLProgramUniformInfo {
    std::string name;
    GLenum type = 0;
    GLint arraySize = 1;
    GLint location = -1;
};

struct GLProgramAttributeInfo {
    std::string name;
    GLenum type = 0;
    GLint location = -1;
};

struct GLProgramUniformValue {
    GLenum type = 0;
    GLint arraySize = 1;
    std::vector<GLfloat> floats;
    std::vector<GLint> ints;
    std::vector<GLuint> uints;
};

struct GLProgramObject {
    std::vector<GLuint> attachedShaders;
    std::string linkLog;
    std::string validateLog;
    bool linked = false;
    bool validated = false;
    bool deleteRequested = false;
    std::vector<GLProgramUniformInfo> uniforms;
    std::vector<GLProgramAttributeInfo> attributes;
    std::unordered_map<GLint, GLProgramUniformValue> uniformValues;
    std::unordered_map<std::string, GLuint> requestedAttribLocations;
};

struct GLQueryObject {
    GLenum target = 0;
    bool active = false;
    GLuint64 result = 0;
};

struct GLSyncObject {
    void* sharedEvent = nullptr;
    GLuint64 signalValue = 0;
};

struct GLTransformFeedbackObject {
    bool active = false;
};

class GLObjectStore {
public:
    explicit GLObjectStore(GLsizei maxVertexAttribs = 16);

    ObjectTable<GLBufferObject>& buffers();
    ObjectTable<GLTextureObject>& textures();
    ObjectTable<GLSamplerObject>& samplers();
    ObjectTable<GLRenderbufferObject>& renderbuffers();
    ObjectTable<GLFramebufferObject>& framebuffers();
    ObjectTable<GLVertexArrayObject>& vertexArrays();
    ObjectTable<GLShaderObject>& shaders();
    ObjectTable<GLProgramObject>& programs();
    ObjectTable<GLQueryObject>& queries();
    ObjectTable<GLSyncObject>& syncs();
    ObjectTable<GLTransformFeedbackObject>& transformFeedbacks();

    GLsizei maxVertexAttribs() const;
    void initializeVertexArray(GLVertexArrayObject& vertexArray) const;

    void deferDelete(std::string label);
    void drainDeferredDeletes();

private:
    GLsizei maxVertexAttribs_ = 16;
    ObjectTable<GLBufferObject> buffers_;
    ObjectTable<GLTextureObject> textures_;
    ObjectTable<GLSamplerObject> samplers_;
    ObjectTable<GLRenderbufferObject> renderbuffers_;
    ObjectTable<GLFramebufferObject> framebuffers_;
    ObjectTable<GLVertexArrayObject> vertexArrays_;
    ObjectTable<GLShaderObject> shaders_;
    ObjectTable<GLProgramObject> programs_;
    ObjectTable<GLQueryObject> queries_;
    ObjectTable<GLSyncObject> syncs_;
    ObjectTable<GLTransformFeedbackObject> transformFeedbacks_;
    std::vector<std::string> deferredDeletes_;
};

template <typename T>
GLuint ObjectTable<T>::create() {
    const GLuint id = reserveName();
    objects_[id] = T{};
    return id;
}

template <typename T>
GLuint ObjectTable<T>::reserveName() {
    while (objects_.contains(nextId_) || nextId_ == 0) {
        ++nextId_;
    }
    const GLuint id = nextId_++;
    objects_.try_emplace(id, T{});
    return id;
}

template <typename T>
bool ObjectTable<T>::erase(GLuint id) {
    if (id == 0) {
        return false;
    }
    return objects_.erase(id) > 0;
}

template <typename T>
bool ObjectTable<T>::contains(GLuint id) const {
    return id != 0 && objects_.contains(id);
}

template <typename T>
T* ObjectTable<T>::get(GLuint id) {
    const auto found = objects_.find(id);
    if (found == objects_.end()) {
        return nullptr;
    }
    return &found->second;
}

template <typename T>
const T* ObjectTable<T>::get(GLuint id) const {
    const auto found = objects_.find(id);
    if (found == objects_.end()) {
        return nullptr;
    }
    return &found->second;
}

template <typename T>
template <typename Visitor>
void ObjectTable<T>::forEach(Visitor&& visitor) {
    for (auto& [id, object] : objects_) {
        visitor(id, object);
    }
}

}  // namespace appgl
