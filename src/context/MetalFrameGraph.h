#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
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
    // Used as fallback when metalVertexBuffer is null (headless / no VBO).
    const void* vertexData = nullptr;
    std::size_t vertexDataByteCount = 0;
    std::size_t vertexStride = 0;

    // Direct Metal buffer binding (OPT-5).  When non-null the pre-uploaded
    // VBO Metal buffer is bound directly, bypassing the ring-buffer memcpy.
    void* metalVertexBuffer = nullptr;
    std::size_t metalVertexBufferOffset = 0;

    // Per-attribute layout within the interleaved vertex buffer.  Each entry
    // describes one enabled vertex attribute's location and its byte offset
    // within a single stride.  When non-empty, all attributes map to Metal
    // buffer index 0 with these offsets; when empty, the legacy single-
    // attribute (position-only, offset 0) behaviour is used.
    //
    // Phase 8X Group 4d follow-up¹⁴ — the GL VAO record fields
    // (`glType/glComponentCount/glNormalized/glIsInteger`) are the
    // *source of truth* for the MTLVertexFormat of each attribute, not
    // the shader-reflected scalar type. Before follow-up¹⁴ the vertex
    // descriptor derived attribute formats from `ShaderReflection::
    // vertexInputs[i].type` (always `Float4`/`Float3`/etc.), which
    // produced a structural `MTLVertexFormatFloat4` entry for any
    // `in vec4 color` input even when the VBO layout stored 4×UBYTE
    // normalized colors. The GPU then reinterpreted 4 bytes of
    // UBYTE4 + 12 bytes of the next vertex as `float4`, producing the
    // NaN-smeared glyph text BAR diagnosed in followup¹³-verification
    // §Smoking-Gun. The fix is to carry the VAO's `glVertexAttribPointer`
    // parameters end-to-end and derive the Metal format from
    // `vaoTypeToMTLFormat(glType, glComponentCount, glNormalized,
    // glIsInteger)` at encode time.
    struct VertexAttributeLayout {
        GLuint location = 0;
        std::size_t offset = 0;
        // VAO-derived format hints (follow-up¹⁴). Defaults match the
        // pre-follow-up¹⁴ shader-reflected `Float4` assumption so that
        // call sites which have not yet been updated keep working.
        GLenum glType = GL_FLOAT;
        GLint glComponentCount = 4;
        GLboolean glNormalized = GL_FALSE;
        bool glIsInteger = false;
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
        // Direct Metal buffer binding (OPT-5).
        void* metalBuffer = nullptr;
        std::size_t metalBufferOffset = 0;
    };
    std::vector<ExtraVertexBuffer> extraVertexBuffers;

    // Instanced draws.
    GLsizei instanceCount = 1;
    GLuint baseInstance = 0;

    // Indexed draws (nullptr for glDrawArrays).
    const void* indices = nullptr;
    GLsizei indexCount = 0;
    GLenum indexType = 0;

    // Direct Metal index buffer binding (OPT-5).
    void* metalIndexBuffer = nullptr;
    std::size_t metalIndexBufferOffset = 0;

    // Per-stage uniform data laid out to match the SPIRV-Cross-generated
    // push-constant struct.  Each stage gets its own buffer because the
    // vertex and fragment stages may declare different subsets of the
    // program's bare uniforms, producing different struct layouts.
    // Non-owning: the caller keeps the backing storage alive until
    // encodeTranslatedDraw returns (typically thread-local scratch buffers).
    const std::uint8_t* vertexUniformData = nullptr;
    std::size_t vertexUniformSize = 0;
    const std::uint8_t* fragmentUniformData = nullptr;
    std::size_t fragmentUniformSize = 0;

    // Phase 8X Group 4d follow-up⁷ — per-draw texture/sampler binding
    // plumbing. Prior to this round, `encodeTranslatedDraw` bound zero
    // MTLTexture / MTLSamplerState objects to the render encoder: the
    // shader translator correctly emitted `[[texture(N)]]` /
    // `[[sampler(N)]]` arguments on the fragment stage and the reflection
    // carried the binding indices, but nothing ever wired the GL
    // texture-unit state through to the Metal encoder calls. The
    // fragment shader's `texture.sample(sampler, uv)` therefore read
    // from an unbound slot (undefined on Apple Silicon, typically zero
    // on Mac2-family) — this is the structural root cause of the
    // "smeared / double-exposed" glyph artifact BAR captured in
    // followup⁶ verification §Visual.
    //
    // Both vectors are non-owning; `metalTexture` / `metalSamplerState`
    // must outlive the encode call. GLContext::drawArrays (and its
    // instanced / indexed siblings) populate these vectors right after
    // the uniform buffer push by walking the program's fragment (and
    // vertex) sampler uniforms, resolving each one to its bound texture
    // object via the GL texture-unit state, and snapping pointers to
    // the cached MTLTexture / MTLSamplerState on the texture object
    // (lazily rebuilt via `rebuildTextureSamplerState`).
    //
    // `metalSlot` is the SPIRV-Cross `[[texture(N)]]` / `[[sampler(N)]]`
    // slot from `ShaderReflection::sampledTextures[i].metalBinding`,
    // which is `BindingMap::textureBase + glBinding = glBinding` under
    // the default BindingMap. The encoder uses the same slot for both
    // the texture and the sampler state, matching SPIRV-Cross's MSL
    // output pattern where sampled images are decomposed into parallel
    // `[[texture(N)]]` / `[[sampler(N)]]` arguments.
    struct TextureBinding {
        std::uint32_t metalSlot = 0;
        void* metalTexture = nullptr;       // id<MTLTexture>
        void* metalSamplerState = nullptr;  // id<MTLSamplerState>
    };
    std::vector<TextureBinding> fragmentTextures;
    std::vector<TextureBinding> vertexTextures;

    // Phase 8X Group 4d follow-up⁸ — diagnostic-only GL program name,
    // populated by GLContext::drawArrays / drawArraysInstanced /
    // drawElements alongside the other tdi fields. Used exclusively by
    // the first-draw-per-program NSLog in `encodeTranslatedDraw` so
    // BAR-side grep can correlate binding output back to the program
    // identity they already see in their `drawArrays` instrumentation.
    // Not used for any correctness decision — leaving it at 0 is safe
    // (the log will read "program=0" for that draw). Non-owning.
    GLuint program = 0;

    // Pipeline state toggles.
    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;

    // Phase 8X Group 4d follow-up¹⁴ — blend state plumbing.
    //
    // Before follow-up¹⁴ the pipeline descriptor's
    // `colorAttachments[0]` was left at Metal's defaults
    // (`blendingEnabled=NO, src=One, dst=Zero, op=Add, writeMask=All`),
    // which made *every* draw opaque on the GPU side regardless of
    // what the GL state tracker had recorded via `glEnable(GL_BLEND)` +
    // `glBlendFunc(...)`. BAR diagnosed this in followup¹³-verification
    // §Candidate-1 as the cause of the smeared-text overlay for
    // programs that relied on premultiplied-alpha over-compositing.
    //
    // `GLContext::drawArrays` (and the other draw entry points) now
    // reads `state->blendState()` + `state->isEnabled(GL_BLEND)` into
    // this substruct, and `encodeTranslatedDraw` applies it to the
    // pipeline color attachment descriptor before
    // `newRenderPipelineStateWithDescriptor`. The pipeline cache key
    // is also extended to include these fields so a program that
    // toggles blend mid-frame rebuilds its pipeline correctly instead
    // of reusing a stale one.
    //
    // Defaults match `MTLRenderPipelineColorAttachmentDescriptor`'s
    // documented defaults so that a zero-initialised TranslatedDrawInfo
    // still produces a valid opaque pipeline.
    struct BlendState {
        bool enabled = false;
        GLenum srcRGB = GL_ONE;
        GLenum dstRGB = GL_ZERO;
        GLenum srcAlpha = GL_ONE;
        GLenum dstAlpha = GL_ZERO;
        GLenum equationRGB = GL_FUNC_ADD;
        GLenum equationAlpha = GL_FUNC_ADD;
        bool colorMaskR = true;
        bool colorMaskG = true;
        bool colorMaskB = true;
        bool colorMaskA = true;
    };
    BlendState blend;

    // Translated MSL + reflection (borrowed from GLProgramObject).
    const std::string* vertexMSL = nullptr;
    const std::string* fragmentMSL = nullptr;
    const ShaderReflection* vertexReflection = nullptr;
    const ShaderReflection* fragmentReflection = nullptr;

    // Pipeline state cache (stored on GLProgramObject, updated by MetalFrameGraph).
    void** pipelineStateOut = nullptr;
    std::uint32_t* pipelineColorFormatOut = nullptr;

    // Phase 8X Group 4d follow-up¹⁴ — map-based pipeline cache.
    // Non-owning pointer to the `GLProgramObject::metalPipelineStateCache`
    // unordered_map. When non-null, `encodeTranslatedDraw` hashes
    // (colorFormat, blend tuple, per-attribute format tuple) into a
    // 64-bit key and looks it up here first. On hit the mapped
    // `id<MTLRenderPipelineState>` is used. On miss the new pipeline
    // is built and inserted, with the old `pipelineStateOut` scalar
    // slot also updated so the first-draw-per-program diagnostic
    // bookkeeping keeps working.
    std::unordered_map<std::uint64_t, void*>* pipelineStateCacheOut = nullptr;

    // Phase 8X Group 4d follow-up⁴ — pipeline-build failure surfacing.
    //
    // Non-owning. When non-null, encodeTranslatedDraw populates this string
    // on each of the five Metal-side failure paths (newLibraryWithSource for
    // vertex/fragment, newFunctionWithName for vertex/fragment, and
    // newRenderPipelineStateWithDescriptor) before returning false. The
    // first token in the populated string identifies the failing stage so
    // BAR-side tooling can grep-aggregate by stage name even though the
    // record stores the full text. On a successful build path the string
    // is left untouched. On the early-return paths above the build branch
    // (device==nil / bad vertex data / empty MSL) the string is also left
    // untouched, since none of those produce an NSError to surface — the
    // existing translatedFallbackGatesReported bitmask is already enough
    // signal to name them. Only the encode-failed gate (which runs the
    // actual Metal calls) populates this field.
    //
    // The caller (GLContext::drawArrays / drawArraysInstanced /
    // drawElements) inspects the string after the false return and pushes
    // it to Runtime::recordShaderTranslation as a `pipeline-build`
    // ShaderTranslationRecord, gated by the existing first-time-per-program
    // EncodeFailed bit so the record fires once per program rather than
    // once per draw.
    std::string* pipelineBuildErrorOut = nullptr;
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

    // Pipeline cache metrics for benchmarking.
    //
    // `hits` and `misses` retain their original meanings: a hit is a draw
    // where the cached MTLRenderPipelineState on the program object was
    // reused; a miss is a draw where the build branch ran AND succeeded
    // (so the new state is now cached). `misses` is therefore equivalent
    // to "successful first-time builds", which is what most miss-counter
    // consumers expect.
    //
    // Phase 8X Group 4d follow-up⁴ adds two attempt/failure counters so
    // BAR-side tooling can distinguish "never tried to build" (attempts==0)
    // from "tried every time and failed every time" (attempts>0,
    // failures==attempts, misses==0). Pre-this-round the {hits=0, misses=0}
    // metric was ambiguous between those two states, which sent the
    // previous diagnosis round chasing a non-issue.
    //
    // Invariant after every draw: `attempts == misses + failures`.
    struct PipelineCacheMetrics {
        std::uint64_t hits = 0;
        std::uint64_t misses = 0;             // successful first-time builds
        std::uint64_t buildAttempts = 0;      // every entry into the build branch
        std::uint64_t buildFailures = 0;      // builds that returned false
        double cumulativeBuildMillis = 0.0;
    };
    PipelineCacheMetrics pipelineCacheMetrics() const;
    void resetPipelineCacheMetrics();

    // Metal device allocated memory (bytes).  Returns 0 if device unavailable.
    std::uint64_t metalAllocatedBytes() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
