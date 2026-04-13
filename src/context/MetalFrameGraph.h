#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "../shader/ShaderTranslator.h"

#ifdef __OBJC__
@class CAMetalLayer;
@protocol MTLDevice;
@protocol MTLCommandQueue;
@protocol MTLTexture;
#endif

namespace appgl {

class GLObjectStore;
class GLStateTracker;

// Describes a single draw call. Phase A Group 7 delivers a minimal draw path:
// one vertex attribute (vec3 position at attribute 0) and one fragment uniform
// (vec4 color). Later groups extend this to cover the full vertex/fragment
// resource table once the real GLSL→MSL translator lands.
struct MetalDrawInfo {
    GLenum mode = 0;
    GLsizei vertexCount = 0;
    GLsizei baseVertex = 0;
    // Raw vertex buffer bytes (already at the attribute start offset).
    const void* positions = nullptr;
    std::size_t positionByteCount = 0;
    std::size_t positionStride = 0;
    GLint positionComponents = 3;
    // Indexed draws: nullptr for glDrawArrays.
    const void* indices = nullptr;
    GLsizei indexCount = 0;
    GLenum indexType = 0;
    // Uniforms.
    GLfloat uniformColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    // Pipeline state toggles.
    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;
    // Diagnostic string that identifies the caller for error messages.
    std::string debugLabel;
};

// Describes a draw call using a translated (GLSL→MSL) shader pipeline.
struct TranslatedDrawInfo {
    GLenum mode = 0;
    GLsizei vertexCount = 0;
    GLsizei baseVertex = 0;

    // Raw vertex buffer bytes at the attribute start offset.
    const void* vertexData = nullptr;
    std::size_t vertexDataByteCount = 0;
    std::size_t vertexStride = 0;

    // Per-attribute layout within the interleaved vertex buffer.  Each entry
    // describes one enabled vertex attribute's location and its byte offset
    // within a single stride.  When non-empty, all attributes map to Metal
    // buffer index 0 with these offsets; when empty, the legacy single-
    // attribute (position-only, offset 0) behaviour is used.
    struct VertexAttributeLayout {
        GLuint location = 0;
        std::size_t offset = 0;
    };
    std::vector<VertexAttributeLayout> vertexAttributeLayouts;

    // Additional vertex buffer bindings for multi-VBO setups (e.g. per-instance
    // attribute buffers with glVertexAttribDivisor).  Buffer index 0 is the
    // primary vertexData above; these start at Metal buffer index 1.
    struct ExtraVertexBuffer {
        const void* data = nullptr;
        std::size_t byteCount = 0;
        std::size_t stride = 0;
        GLuint divisor = 0;  // 0=per-vertex, 1+=per-instance
        std::vector<VertexAttributeLayout> attributes;
    };
    std::vector<ExtraVertexBuffer> extraVertexBuffers;

    // Instanced draws.
    GLsizei instanceCount = 1;
    GLuint baseInstance = 0;

    // Indexed draws (nullptr for glDrawArrays).
    const void* indices = nullptr;
    GLsizei indexCount = 0;
    GLenum indexType = 0;

    // Per-stage uniform data laid out to match the SPIRV-Cross-generated
    // push-constant struct.  Each stage gets its own buffer because the
    // vertex and fragment stages may declare different subsets of the
    // program's bare uniforms, producing different struct layouts.
    std::vector<std::uint8_t> vertexUniformBuffer;
    std::vector<std::uint8_t> fragmentUniformBuffer;

    // Pipeline state toggles.
    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;

    // Translated MSL + reflection (borrowed from GLProgramObject).
    const std::string* vertexMSL = nullptr;
    const std::string* fragmentMSL = nullptr;
    const ShaderReflection* vertexReflection = nullptr;
    const ShaderReflection* fragmentReflection = nullptr;

    // Pipeline state cache (stored on GLProgramObject, updated by MetalFrameGraph).
    void** pipelineStateOut = nullptr;
    std::uint32_t* pipelineColorFormatOut = nullptr;
};

class MetalFrameGraph {
public:
    MetalFrameGraph(void* layer, void* device, void* commandQueue);
    ~MetalFrameGraph();

    MetalFrameGraph(const MetalFrameGraph&) = delete;
    MetalFrameGraph& operator=(const MetalFrameGraph&) = delete;

    void resizeDrawable(GLsizei width, GLsizei height);
    void enableOffscreenDrawable(GLsizei width, GLsizei height);
    void encodeDefaultFramebufferClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    );
    void beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects);
    void* currentRenderEncoder() const;
    void endRenderPass();
    // Encodes a single draw call against the current default framebuffer using
    // the prebaked "solid color" pipeline state. Phase A Group 7 MVP. Returns
    // true on success. If the provided layout cannot be handled the caller is
    // expected to fall back to a no-op and record a debug message.
    bool encodeSolidColorDraw(const MetalDrawInfo& info);
    // Encodes a draw call using a translated GLSL→MSL pipeline. The pipeline
    // state is lazily created on first use and cached on the program object.
    bool encodeTranslatedDraw(TranslatedDrawInfo& info);
    void endFrame(GLObjectStore& objects);
    void present();
    bool copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels);
    bool hasValidAttachments() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
