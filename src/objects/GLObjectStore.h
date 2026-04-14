#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "../shader/ShaderTranslator.h"

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
    bool immutable = false;           // GL 4.4 glBufferStorage
    GLbitfield storageFlags = 0;      // GL 4.4 glBufferStorage flags
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
    GLsizei samples = 0;
    bool immutable = false;
    // Buffer-texture (glTexBufferRange) state.
    GLuint sourceBuffer = 0;
    GLintptr bufferOffset = 0;
    GLsizeiptr bufferSize = 0;
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
    // CPU-side shadow for glVertexAttribL{1,2,3,4}d[v] immediate values.
    // Used by glGetVertexAttribLdv for lossless f64 readback.
    GLdouble immediateDouble[4] = {0.0, 0.0, 0.0, 1.0};
    // GL 4.3 separated vertex format state.
    GLuint bindingIndex = 0;         // which binding point this attribute uses (default = attrib index)
    GLuint relativeOffset = 0;       // offset within the vertex for this attribute
    bool useSeparatedFormat = false;  // true when set via glVertexAttrib*Format
};

// GL 4.3 separated vertex format: per-binding-point state.
// Each binding point holds the buffer, offset, stride and divisor independently
// of the attribute format.  Maps directly to Metal's MTLVertexBufferLayoutDescriptor.
struct GLVertexBindingPoint {
    GLuint buffer = 0;
    GLintptr offset = 0;
    GLsizei stride = 0;
    GLuint divisor = 0;
};

struct GLVertexArrayBufferBinding {
    GLuint glBuffer = 0;
    std::uint32_t metalSlot = 0;
    std::uint32_t stride = 0;
};

struct GLVertexArrayObject {
    std::vector<GLVertexAttributeState> attributes;
    std::vector<GLVertexBindingPoint> bindingPoints;  // GL 4.3 separated format binding points
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
    // GL spec: glDeleteShader on a shader still attached to one or more
    // programs flags the object for deletion but does NOT remove it from the
    // object store — the actual erase is deferred until the last detach (or
    // until glDeleteProgram on the final attached program). `attachmentCount`
    // tracks the number of live program attachments, and the entry points in
    // GLContext.mm (attachShader / detachShader / deleteShader / deleteProgram)
    // perform the maybe-erase pass when both deleteRequested is true and the
    // attachment count drops to zero.
    //
    // BAR's standard shader path (rts/Rendering/Shaders/Shader.cpp) follows
    // the `attach → glDeleteShader (RAII deleter at scope exit) → glLinkProgram`
    // ordering — under the eager-erase Phase A behaviour the link-time lookup
    // saw nullptr and bailed with "attached shader is not compiled", masking
    // every real compile result. The deferred-erase semantics restore the
    // spec-mandated behaviour and let the real compileLog reach the diagnostic
    // ring.
    bool deleteRequested = false;
    int attachmentCount = 0;
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
    std::vector<GLdouble> doubles;  // CPU-side shadow for f64→f32 narrowing (lossless glGetUniformdv readback)
};

// GL 4.3 program resource introspection — per-resource entry used by
// glGetProgramInterfaceiv / glGetProgramResourceiv / etc.
struct GLProgramResourceEntry {
    std::string name;
    GLenum type = 0;          // GL_FLOAT, GL_FLOAT_VEC4, etc.
    GLint location = -1;      // location/binding
    GLint arraySize = 1;
    GLint offset = -1;        // byte offset within block (-1 = N/A)
    GLint blockIndex = -1;    // parent block index (-1 = not in a block)
    GLbitfield referencedBy = 0; // bitmask: 1=vertex, 2=fragment, 4=compute, etc.
};

// Cached uniform locations for the synthesized `appgl_*` fixed-function
// matrix uniforms produced by the compat-shader rewriter (see
// src/shader/CompatShaderRewrite.h). Filled in at link time by scanning
// programObject->uniforms by name; the draw-time matrix push reads each
// non-negative slot and writes the corresponding Matrix4 from the
// per-context MatrixStateMirror into programObject->uniformValues. A
// slot stays at -1 when the original (compat) shader source did not
// reference the corresponding gl_* identifier — there's nothing to push
// for that program in that case.
struct GLSynthesizedMatrixSlots {
    GLint modelView = -1;
    GLint projection = -1;
    GLint modelViewProjection = -1;
    GLint modelViewInverse = -1;
    GLint projectionInverse = -1;
    GLint modelViewProjectionInverse = -1;
    GLint normal = -1;
    // Texture matrix is stored in the rewriter as `mat4 appgl_TextureMatrix[8]`.
    // GL's uniform reflection assigns one location to the array's first
    // element and contiguous locations to subsequent elements; this slot
    // holds the location of `[0]`, and the draw-time push iterates
    // texture units via `texture + i`.
    GLint texture = -1;

    bool hasAny() const {
        return modelView >= 0 || projection >= 0 || modelViewProjection >= 0 ||
               modelViewInverse >= 0 || projectionInverse >= 0 ||
               modelViewProjectionInverse >= 0 || normal >= 0 || texture >= 0;
    }
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
    GLSynthesizedMatrixSlots synthesizedMatrixSlots;

    // Translated shader pipeline (populated at link time when the shader
    // compiler is available).  The MSL sources are consumed by MetalFrameGraph
    // to create MTLRenderPipelineState on first draw.
    std::string vertexMSL;
    std::string fragmentMSL;
    ShaderReflection vertexReflection;
    ShaderReflection fragmentReflection;
    bool hasTranslatedPipeline = false;

    // Opaque pipeline state handle, owned by MetalFrameGraph.  Stored here so
    // repeated draws skip pipeline creation.  Type-erased to avoid ObjC in this
    // header — cast to id<MTLRenderPipelineState> in .mm files.
    void* metalPipelineState = nullptr;
    // Track which pixel format the cached pipeline was created for, so we
    // can invalidate if the render target format changes.
    std::uint32_t metalPipelineColorFormat = 0;

    // GL 4.3 program resource introspection tables (populated at link time).
    std::vector<GLProgramResourceEntry> resourceUniforms;
    std::vector<GLProgramResourceEntry> resourceUniformBlocks;
    std::vector<GLProgramResourceEntry> resourceInputs;
    std::vector<GLProgramResourceEntry> resourceOutputs;
    std::vector<GLProgramResourceEntry> resourceStorageBlocks;
    std::vector<GLProgramResourceEntry> resourceAtomicCounterBuffers;
    std::vector<GLProgramResourceEntry> resourceBufferVariables;

    // GL 4.3 SSBO binding remapping (block index → user-specified binding).
    std::unordered_map<GLuint, GLuint> ssboBindingRemap;

    // ── Precomputed uniform layout (OPT-7) ──
    // Maps push-constant struct members to GL uniform locations, eliminating
    // O(N*M) string comparisons from the per-draw uniform packing path.
    // Computed lazily on first draw and reused for all subsequent draws.
    struct UniformLayoutEntry {
        std::size_t memberOffset = 0;   // byte offset in push-constant struct
        std::size_t copyBytes = 0;      // bytes to memcpy (0 = skip)
        GLint location = -1;            // GL uniform location for value lookup
        bool isMat3Padded = false;      // needs col-by-col padding (12->16 bytes/col)
    };
    std::vector<UniformLayoutEntry> vertexUniformLayout;
    std::vector<UniformLayoutEntry> fragmentUniformLayout;
    bool uniformLayoutComputed = false;
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
    bool paused = false;
    GLsizei capturedPrimitives = 0;  // for glDrawTransformFeedback
};

struct GLProgramPipelineObject {
    GLuint vertexProgram = 0;
    GLuint fragmentProgram = 0;
    GLuint geometryProgram = 0;
    GLuint tessControlProgram = 0;
    GLuint tessEvalProgram = 0;
    GLuint computeProgram = 0;
    GLuint activeShaderProgram = 0;
    bool validated = false;
    std::string infoLog;
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
    ObjectTable<GLProgramPipelineObject>& programPipelines();

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
    ObjectTable<GLProgramPipelineObject> programPipelines_;
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
