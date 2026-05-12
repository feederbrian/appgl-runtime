#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "../shader/ShaderTranslator.h"

namespace appgl::interp {
// Forward-declared; full definition in ../shader/ShaderInterpreter.h.
// Used by GLProgramObject's tess-emul SpirvModule cache (phase 3f-11).
// Carrying the field as `unique_ptr<SpirvModule>` instead of an
// `optional<SpirvModule>` or raw instance lets us keep ShaderInterpreter.h
// out of GLObjectStore.h's wide dependency fan-in — the destructor must
// be instantiated in a TU that does see the full type, which
// GLObjectStore.cpp handles via an explicit dtor.
struct SpirvModule;
}  // namespace appgl::interp

namespace appgl {

template <typename T>
class ObjectTable {
public:
    GLuint create();
    GLuint reserveName();
    // Insert at a specific ID — used by the GL 4.6 §7.1 shared
    // shader/program name pool (GLObjectStore::reserveSharedShaderProgramName).
    // Returns the inserted (or already-existing) object pointer.
    T* insertAt(GLuint id);
    bool erase(GLuint id);
    bool contains(GLuint id) const;
    T* get(GLuint id);
    const T* get(GLuint id) const;
    std::size_t size() const { return objects_.size(); }

    // Skip IDs up through (and including) `id` so the next
    // reserveName call returns at least `id + 1`. Used by the
    // shared shader/program allocator to keep each per-table
    // nextId_ ahead of the shared pool's high-water mark.
    void bumpNextIdBeyond(GLuint id) {
        if (nextId_ <= id) nextId_ = id + 1;
    }

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

    struct Fp64TransportSidecar {
        std::size_t layoutHash = 0;
        std::uint32_t sourceGeneration = 0;
        GLintptr sourceOffset = 0;
        GLsizeiptr sourceSize = 0;
        void* metalBuffer = nullptr;
        std::vector<std::uint8_t> bytes;
    };
    std::vector<Fp64TransportSidecar> fp64TransportSidecars;

    // ADV-10: cached uint8→uint16 index expansion.  Populated on the first
    // drawElements call with GL_UNSIGNED_BYTE; invalidated when buffer data
    // changes (glBufferData / glBufferSubData).  Avoids per-draw heap
    // allocation and byte-widening loop for 8-bit index buffers.
    std::vector<std::uint8_t> cachedExpandedIndices;
    uint32_t indexExpansionGeneration = 0;   // bumped on data change
    uint32_t cachedExpansionGeneration = 0;  // generation when cache was built
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
    // Native-format pixel data for non-RGBA8 Metal textures (e.g. R16F,
    // RGBA32F, R8_SNORM …). Built alongside rgba8 by buildNativeUpload()
    // and used by replaceMetalTexture() when the Metal pixel format
    // differs from RGBA8Unorm. Empty when the internal format maps to
    // RGBA8Unorm or is unsupported — replaceMetalTexture falls back to
    // the rgba8 shadow in that case.
    std::vector<std::uint8_t> nativeData;
    std::size_t nativeBpp = 0; // bytes-per-pixel for nativeData (0 = not available)
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
    GLint depthStencilTextureMode = GL_DEPTH_COMPONENT;
    // GL 4.6 §8.10 / GL_ARB_texture_filter_anisotropic defaults. Stored
    // on the object so glGetSamplerParameter / glGetTextureParameter can
    // round-trip the value — the Metal sampler builder currently ignores
    // both knobs but CTS samplers_defaults / textures_defaults still
    // query them for a full default round-trip.
    GLfloat lodBias = 0.0f;
    GLfloat maxAnisotropy = 1.0f;
};

struct GLTextureObject {
    void* metalTexture = nullptr;
    GLenum target = 0;
    GLTextureDesc desc;
    GLTextureParameters params;
    std::unordered_map<GLint, GLTextureImageLevel> levels;
    bool instantiated = false;

    // Phase 8X Group 4d follow-up⁷ — lazy MTLSamplerState cached on the
    // texture object itself, rebuilt from `params` on demand. GL's
    // glTexParameter path sets filter/wrap/lod/compare state *on the
    // texture object* (this is the legacy "texture has sampler state"
    // API); GL 3.3+ glSamplerParameter lets applications instead attach
    // a separate GLSamplerObject that overrides the texture-owned state
    // at draw time, and GLSamplerObject already carries its own
    // `metalSampler` + dirty flag. Prior to this round we only built
    // MTLSamplerState for the stand-alone GLSamplerObject path, which
    // meant textures without an attached sampler object — the common
    // case for BAR's glyph atlases, the splash texture, and everything
    // uploaded through the legacy glTexImage / glTexParameter path —
    // had no Metal-side sampler to bind, and the fragment shader's
    // `texture.sample(sampler, uv)` call would read from an unbound
    // sampler slot (Apple Silicon returns undefined filtering). This
    // is the structural gap behind the "smeared / double-exposed"
    // glyphs BAR captured in followup⁶ verification §Visual.
    //
    // Lifecycle:
    //  - `samplerDirty` is flipped to true whenever any of the filter /
    //    wrap / lod / compare / border / swizzle fields on `params`
    //    change (texParameterInteger / texParameterFloat).
    //  - `rebuildTextureSamplerState` in GLContext.mm consumes
    //    the dirty flag and builds an MTLSamplerState from the
    //    current params, matching the shape of `rebuildSamplerState`
    //    for GLSamplerObject. Lazy: rebuilt on-demand from the draw
    //    path the first time the texture is sampled after a
    //    parameter change.
    //  - `releaseTextureStorage` releases the retained Metal handle
    //    alongside `metalTexture`. Deleting the GL texture object
    //    therefore releases both the storage and the cached sampler.
    void* metalSampler = nullptr;
    bool samplerDirty = true;

    // GL_TEXTURE_SWIZZLE — lazy MTLTexture view with swizzle channels.
    // Created on demand when non-default swizzle is detected at draw time
    // via `newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:`.
    // The view shares the same storage as `metalTexture` (no data copy).
    // `swizzleDirty` is set whenever any GL_TEXTURE_SWIZZLE_* parameter
    // changes, so the view is rebuilt on the next draw.
    void* metalSwizzledView = nullptr;
    bool swizzleDirty = true;

    // Cube-map completeness tracking. For GL_TEXTURE_CUBE_MAP targets,
    // each bit 0..5 corresponds to a face in the enum order
    //   POSITIVE_X, NEGATIVE_X, POSITIVE_Y, NEGATIVE_Y, POSITIVE_Z, NEGATIVE_Z
    // (GL 4.6 §8.18). A cube map is "cube complete" only when all six
    // faces have been defined at level 0 with matching size and format.
    // Used by glGenerateMipmap / glGenerateTextureMipmap to emit
    // GL_INVALID_OPERATION on incomplete cube maps, as required by the
    // spec and verified by the
    // KHR-GL46.direct_state_access.textures_generate_mipmap_errors test.
    // Non-cube targets ignore this field.
    std::uint8_t cubeFacesDefined = 0;
    // Sprint 16 Day 17 (CKPT226) [Y-flip Option B + viewport routing
    // dual-fix] / Sprint 17 Day 1 (CKPT236) [A.2 narrow gate]: this
    // texture has been the sink of a draw whose Metal write path
    // applied the viewport Y-flip (`originY = rtH - glY - glH`).
    // Metal stores row 0 at the top; OpenGL `glGetTexImage` returns
    // row 0 at the bottom; the render's viewport flip writes
    // Metal-storage-row (rtH-1-glY) for what GL calls row 0. Reading
    // that back without the inverse flip hands the caller upside-down
    // data — observable on `viewport_array.dynamic_viewport_index`,
    // `geometry_shader.layered_rendering.layered_rendering`, and
    // their siblings.
    //
    // Pure upload-then-readback round-trips (CTS `copy_image.*`,
    // `direct_state_access.textures_storage_multisample_*`,
    // `texture_barrier.*`) keep the Metal convention end-to-end
    // because their writes don't go through the GL Y-up viewport
    // flip path — DSA storage allocation, clearColorAttachment direct
    // path, copy_image, and texture_barrier render-to-self all
    // potentially bind the texture as a colour attachment but do NOT
    // engage the viewport-flipped multi-viewport routing path on
    // their writes. Unconditionally Y-flipping the readback regresses
    // those clusters (CKPT221 Day 12 + Sprint 17 Day 1 CKPT236
    // empirical refutations).
    //
    // Set in the draw-encoding path (`encodeEmulatedGsDraw` and
    // sister encoders) ONLY when `routeViewportIndex == true` for
    // the in-flight draw and the bound draw-FBO has colour
    // attachments — the flag is per-texture and remains true for
    // the texture's lifetime. Renderbuffers don't carry this flag
    // because they aren't readable via `glGetTexImage`.
    //
    // Sprint 17 Day 1 narrowing (CKPT236): the binding-time set
    // (originally in `framebufferTexture`) was over-broad and
    // produced 58 false-positive Y-flips (DSA multisample storage
    // + texture_barrier). Moved to draw-time set gated on
    // routeViewportIndex active.
    bool wasViewportRenderedTo = false;
    // Sister to wasViewportRenderedTo, but scoped to framebuffer readback.
    // Set when this texture is rendered or cleared as a framebuffer color
    // attachment under LOWER_LEFT clip origin. Consumed by
    // readColorAttachmentPixels/readFBOColorNative so glReadPixels and
    // blit-source reads undo the FBO producer's Y orientation. NOT consumed
    // by glGetTexImage: DSA storage_multisample, texture_barrier, and
    // copy_image keep texture-image readback on the narrower
    // wasViewportRenderedTo contract above.
    bool wasFramebufferRenderedTo = false;
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
    // CKPT117 (Sprint 11 Phase 1 1a — RB.nativeData refactor): mirror of
    // GLTextureImageLevel::{nativeData,nativeBpp}. Allows RBs to carry a
    // native-precision shadow for non-RGBA8 internal formats (RGB10_A2,
    // RGBA32UI, RGB32F, etc.) so copyImageSubData / glReadPixels round-
    // trips don't truncate to the 8-bit RGBA8 fallback. nativeBpp = 0
    // means "no native shadow" (default for RGBA8-mapped formats).
    std::vector<std::uint8_t> nativeData;
    std::size_t nativeBpp = 0;
    std::vector<GLfloat> depth32;
    std::vector<std::uint8_t> stencil8;
    bool instantiated = false;
    bool storageDefined = false;
    // Sprint 17 Day 9+ Bank-Group-A-1 narrow-gate (regression-debt #1+#2):
    // True when a Metal render pass with this RB as depth attachment
    // wrote the texture; false when only CPU-shadow paths
    // (glClearBufferfv, glRenderbufferStorage init) were the source of
    // depth data. `readDepthAttachmentPixels` gates Metal-texture
    // readback (Bank-Group-A-1 commit `6ba6aad`) on this flag so RBs
    // that were ONLY cleared (no render pass) fall through to the CPU
    // shadow — matches CTS `direct_state_access.framebuffers_blit` +
    // `renderbuffers_storage` pre-fix behavior while preserving
    // `clip_control.depth_mode_one_to_one` post-fix behavior.
    bool wasMetalDepthRendered = false;
    // Stencil companion to wasMetalDepthRendered. Renderbuffer stencil
    // writes happen inside Metal render passes, so CPU shadow reads are
    // stale after stencilOp updates unless this routes readback through
    // the Metal stencil plane.
    bool wasMetalStencilRendered = false;
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
    bool multiview = false;
    GLint baseViewIndex = 0;
    GLsizei numViews = 1;
};

struct GLFramebufferObject {
    std::unordered_map<GLenum, GLFramebufferAttachment> attachments;
    std::array<GLenum, 8> drawBuffers = {GL_COLOR_ATTACHMENT0, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE, GL_NONE};
    GLenum readBuffer = GL_COLOR_ATTACHMENT0;
    bool instantiated = false;
    // GL 4.3 §9.2.1 — attachment-less (no-attachment) framebuffer
    // defaults. These are set via glFramebufferParameteri and form
    // the effective viewport/layer/sample state when the FBO has no
    // attachments. CTS geometry_shader.layered_rendering_fbo_no_
    // attachment exercises the round-trip.
    GLint defaultWidth = 0;
    GLint defaultHeight = 0;
    GLint defaultLayers = 0;
    GLint defaultSamples = 0;
    GLboolean defaultFixedSampleLocations = GL_FALSE;
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
    // True if the GLSL source declared this with array syntax —
    // `in float a[1]` (isArray=true, arraySize=1) vs `in float a`
    // (isArray=false, arraySize=1). Needed because GL 4.6 §7.3.1
    // says array variables report their resource name with a "[0]"
    // suffix even when they have a single element. `arraySize`
    // alone can't distinguish the two cases because the
    // GL_ARRAY_SIZE query returns 1 for both.
    bool isArray = false;
    GLint explicitLocation = -1;
    // `layout(index=N)` on a fragment output — dual-source-blend
    // color index per GL 4.6 §15.2. -1 = unspecified.
    GLint explicitIndex = -1;
    // RC-D08: explicit `layout(binding=N)` qualifier from the GLSL source.
    // -1 means no explicit binding was specified.  The GLSL scanner
    // (`extractLayoutQualifiers`) populates this when it finds a
    // `binding = N` token inside a `layout(...)` block.  Propagated through
    // `appendDeclarationsAsUniforms` into `GLProgramUniformInfo` and from
    // there into the GL 4.3 program-resource introspection table.
    GLint explicitBinding = -1;
    // Byte offset from `layout(offset = N)` on an `atomic_uint`
    // uniform. Required for GL_ATOMIC_COUNTER_BUFFER introspection
    // (BUFFER_DATA_SIZE covers the full offset range of active
    // counters in a binding). -1 = unspecified (GLSL treats that
    // as "append", we default to 0 when first counter of a binding).
    GLint explicitOffset = -1;
    // Image format qualifier from `layout(rgba32f)`, `layout(rg32f)`,
    // `layout(rgba8)`, etc. on an image load/store uniform. Stored
    // as the internal-format GLenum (GL_RGBA32F, GL_RG32F, GL_RGBA8,
    // ...). 0 = unspecified. Cross-stage link validation compares
    // this alongside the uniform type so a program that declares
    // the same image with different format qualifiers in different
    // stages fails link correctly (GL 4.6 §7.4.1 + §4.4.8.2).
    GLenum imageFormat = 0;
    // Phase 8X Group 4d follow-up¹⁵ — GLSL 4.20 / ARB_shading_language_420pack
    // lets uniform declarations carry a default-value initializer, e.g.
    //   uniform vec4 ucolor   = vec4(1.0);
    //   uniform vec4 alphaCtrl = vec4(0.0, 0.0, 0.0, 1.0);
    // Spring's BAR fragment shader template `RenderBuffers.inl` relies on
    // these defaults — the engine never calls glUniform for ucolor/alphaCtrl,
    // so a zero-seeded shadow makes `outColor *= ucolor` evaluate to (0,0,0,0)
    // and the AlphaDiscard branch discards every pixel (black screen).
    // The scanner populates whichever of these three vectors matches the base
    // scalar type of `type`; all three are empty when no initializer is present,
    // in which case linkProgram falls back to zero-seeding.
    std::vector<GLfloat> defaultFloats;
    std::vector<GLint>   defaultInts;
    std::vector<GLuint>  defaultUints;
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
    // GL_ARB_gl_spirv / GL 4.6 §7.2 — true after a successful
    // `glShaderBinary(GL_SHADER_BINARY_FORMAT_SPIR_V, …)` on this
    // shader, cleared by any subsequent `glShaderSource`. Queryable
    // via `glGetShaderiv(GL_SPIR_V_BINARY_ARB)`. Distinguishes
    // shader objects whose `spirv` field came from a pre-compiled
    // binary (user of `glSpecializeShader`) vs objects whose spirv
    // came from our in-tree glslang path.
    bool isSpirvBinary = false;
    std::vector<GLShaderDeclaration> declaredUniforms;
    std::vector<GLShaderDeclaration> declaredInputs;
    std::vector<GLShaderDeclaration> declaredOutputs;
    std::uint32_t advancedBlendSupportMask = 0;
    bool advancedBlendSupportAll = false;
};

struct GLProgramUniformInfo {
    std::string name;
    GLenum type = 0;
    GLint arraySize = 1;
    // True iff the GLSL source used array syntax (see
    // GLShaderDeclaration::isArray). Propagated so
    // resource-interface queries can append the "[0]" suffix even
    // for 1-element arrays.
    bool isArray = false;
    GLint location = -1;
    // RC-D06: explicit location from GLSL `layout(location=N)`.  -1 means
    // the author did not specify one and linkProgram assigns a dense
    // sequential location.  When >= 0 the link-time location assignment
    // honours this value so `glGetUniformLocation` returns the
    // author-specified number, matching CTS expectations.
    GLint explicitLocation = -1;
    // RC-D08: explicit binding from GLSL `layout(binding=N)`.  -1 means
    // unspecified.  Propagated into the GL 4.3 resource introspection table.
    GLint explicitBinding = -1;
    // Byte offset from `layout(offset=N)` on an `atomic_uint`
    // uniform (parallel to GLShaderDeclaration::explicitOffset).
    GLint explicitOffset = -1;
    // Phase 8X Group 4d follow-up¹⁵ — parallel to GLShaderDeclaration.
    // linkProgram (appendDeclarationsAsUniforms) forwards these from the
    // shader-stage declarations into the program-level uniform table so
    // the uniformValues seeding switch can read them without walking the
    // per-stage declaration lists a second time.
    std::vector<GLfloat> defaultFloats;
    std::vector<GLint>   defaultInts;
    std::vector<GLuint>  defaultUints;
};

struct GLProgramAttributeInfo {
    std::string name;
    GLenum type = 0;
    GLint location = -1;
    // Array dimension from the GLSL declaration. `in float c[2]`
    // sets arraySize=2, plain `in float c` sets arraySize=1.
    // Carried through so `glGetProgramResourceName(GL_PROGRAM_INPUT,
    // …)` can append the "[0]" suffix that GL 4.6 §7.3.1 mandates
    // for array inputs (CTS `program_interface_query.input-types`).
    GLint arraySize = 1;
    // True iff the GLSL source used array syntax (`in float c[1]`).
    // GL 4.6 §7.3.1 says every array variable reports its name
    // with "[0]" suffix, even when arraySize==1, so we can't
    // derive this from arraySize alone.
    bool isArray = false;
};

struct GLProgramUniformValue {
    GLenum type = 0;
    GLint arraySize = 1;
    std::vector<GLfloat> floats;
    std::vector<GLint> ints;
    std::vector<GLuint> uints;
    std::vector<GLdouble> doubles;  // CPU-side shadow for f64→f32 narrowing (lossless glGetUniformdv readback)
    std::vector<std::uint32_t> df64TransportWords;  // hi/lo float-bit pairs for AppGL df64 uint2 transport
};

// GL 4.3 program resource introspection — per-resource entry used by
// glGetProgramInterfaceiv / glGetProgramResourceiv / etc.
struct GLProgramResourceEntry {
    std::string name;
    GLenum type = 0;          // GL_FLOAT, GL_FLOAT_VEC4, etc.
    GLint location = -1;      // uniform location (glGetUniformLocation)
    GLint binding = -1;       // RC-D08: explicit layout(binding=N), -1 = unspecified
    GLint arraySize = 1;
    // GL 4.6 §7.3.1 distinguishes "scalar/vector uniform with
    // arraySize=1" (reports GL_ARRAY_SIZE=1) from "unbounded array
    // uniform with arraySize=0" (reports GL_ARRAY_SIZE=0). Both end
    // up with arraySize=0 in SPIRV-Cross's raw reflection, so we
    // need an explicit flag. Also drives the "compute array stride
    // only for array members" branch in glGetActiveUniformsiv.
    bool isArray = false;
    GLint offset = -1;        // byte offset within block (-1 = N/A)
    GLint blockIndex = -1;    // parent block index (-1 = not in a block)
    GLbitfield referencedBy = 0; // bitmask: 1=vertex, 2=fragment, 4=compute, etc.
    bool isRowMajor = false;  // GL_UNIFORM_IS_ROW_MAJOR for matrix block members
    GLint arrayStride = -1;   // byte stride between array elements, -1 for non-block
    GLint matrixStride = -1;  // byte stride between matrix columns/rows, -1 for non-block
    // Dual-source blending index (0 or 1) for fragment outputs.
    // Set by glBindFragDataLocationIndexed per GL 4.6 §15.2.
    // Non-output resources keep the default 0.
    GLint locationIndex = 0;
    // Only populated for block entries (UNIFORM_BLOCK,
    // SHADER_STORAGE_BLOCK, ATOMIC_COUNTER_BUFFER,
    // TRANSFORM_FEEDBACK_BUFFER). Indices of the block's
    // members into the corresponding member-level resource
    // table (resourceUniforms for UBOs, resourceBufferVariables
    // for SSBOs). Drives GL_NUM_ACTIVE_VARIABLES /
    // GL_ACTIVE_VARIABLES queries.
    std::vector<GLint> activeVariables;
    // GL 4.6 §7.3.1 `GL_ATOMIC_COUNTER_BUFFER_INDEX`: for a uniform
    // whose type is `atomic_uint`, index of the owning
    // ATOMIC_COUNTER_BUFFER in the program's
    // resourceAtomicCounterBuffers table; -1 for any non-atomic
    // uniform. Populated at link time after the ATOMIC_COUNTER_BUFFER
    // entries are built.
    GLint atomicCounterBufferIndex = -1;
    // GL 4.6 §7.6.3 the byte offset of an atomic_uint counter inside
    // its ATOMIC_COUNTER_BUFFER binding (from
    // `layout(offset=N)`). -1 for non-atomic uniforms.
    GLint atomicCounterOffset = -1;
    // GL 4.6 §7.3.1 `GL_TOP_LEVEL_ARRAY_SIZE` for a buffer variable
    // (SSBO member): the number of active array elements of the
    // top-level block member that contains this variable. 1 for
    // scalar top-level members, N for `TopType a[N]`, 0 for
    // unbounded. Only meaningful on GL_BUFFER_VARIABLE entries.
    GLint topLevelArraySize = 1;
    // GL 4.6 §7.3.1 `GL_TOP_LEVEL_ARRAY_STRIDE` byte stride between
    // consecutive top-level array elements. 0 for non-array
    // top-level members.
    GLint topLevelArrayStride = 0;
    // GL 4.6 §7.3.1 `GL_IS_PER_PATCH`: true when a TCS output or
    // TES input was declared with the `patch` storage qualifier.
    bool isPerPatch = false;
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
    // Phase 3f-11: explicit special members declared here + defined
    // in GLObjectStore.cpp, where appgl::interp::SpirvModule is a
    // complete type. Necessary so `std::unique_ptr<SpirvModule>`
    // cache fields (below) can be destroyed cleanly without
    // dragging ShaderInterpreter.h into this widely-included header.
    GLProgramObject();
    ~GLProgramObject();
    GLProgramObject(const GLProgramObject&) = delete;
    GLProgramObject& operator=(const GLProgramObject&) = delete;
    GLProgramObject(GLProgramObject&&) noexcept;
    GLProgramObject& operator=(GLProgramObject&&) noexcept;

    std::vector<GLuint> attachedShaders;
    std::string linkLog;
    std::string validateLog;
    bool linked = false;
    bool validated = false;
    // GL 4.1 (ARB_separate_shader_objects) — GL_PROGRAM_SEPARABLE
    // flag set via `glProgramParameteri`. When true, glLinkProgram
    // accepts incomplete stage combinations (e.g. a GS-only or a
    // GS+FS program) because the pipeline object supplies the
    // missing stages at draw time. `glGetProgramiv(GL_PROGRAM_
    // SEPARABLE)` reads this back.
    bool separable = false;
    // GL 4.6 §7.3 — getProgramiv(GL_PROGRAM_SEPARABLE) returns the
    // link-time snapshot, NOT the requested parameter. `separable`
    // above is the request (set by glProgramParameteri); this field
    // is the snapshot, updated on successful linkProgram. Before
    // any link, the query returns GL_FALSE regardless of request.
    // CTS `sepshaderobjs.PipelineApi` asserts this exact behavior.
    bool separableLinked = false;
    bool deleteRequested = false;
    std::vector<GLProgramUniformInfo> uniforms;
    std::vector<GLProgramAttributeInfo> attributes;
    std::unordered_map<GLint, GLProgramUniformValue> uniformValues;
    std::unordered_map<std::string, GLuint> requestedAttribLocations;
    // Pre-link mapping set by `glBindFragDataLocation(program, color,
    // name)`. GL 4.6 §15.2 — these bindings take effect on the next
    // link. The linker consults this map to assign
    // GL_PROGRAM_OUTPUT locations, overriding any GLSL
    // `layout(location=N)` qualifier. Array outputs consume
    // `arraySize` consecutive locations starting at the bound color.
    std::unordered_map<std::string, GLuint> requestedFragDataLocations;
    // Parallel map for the dual-source-blend index (0 or 1) set
    // by `glBindFragDataLocationIndexed`. Default 0 for any
    // output bound via plain `glBindFragDataLocation` or
    // `layout(location=N)`; only named outputs bound with
    // `glBindFragDataLocationIndexed(program, color, 1, name)`
    // get the index-1 slot for dual-source blending.
    std::unordered_map<std::string, GLuint> requestedFragDataLocationIndices;
    GLSynthesizedMatrixSlots synthesizedMatrixSlots;

    // Tessellation program properties (extracted from SPIR-V at link time).
    GLint tessControlOutputVertices = 0;
    GLenum tessGenMode = GL_TRIANGLES;     // GL_TRIANGLES, GL_QUADS, GL_ISOLINES
    GLenum tessGenSpacing = GL_EQUAL;      // GL_EQUAL, GL_FRACTIONAL_EVEN, GL_FRACTIONAL_ODD
    GLenum tessGenVertexOrder = GL_CCW;    // GL_CCW, GL_CW
    GLboolean tessGenPointMode = GL_FALSE;
    bool hasTessellation = false;

    // Translated shader pipeline (populated at link time when the shader
    // compiler is available).  The MSL sources are consumed by MetalFrameGraph
    // to create MTLRenderPipelineState on first draw.
    std::string vertexMSL;
    std::string fragmentMSL;
    // Metal-native tessellation pipeline MSL (Phase 1 of the metal-tess
    // project). Populated at link time for tess programs with SPIRV-Cross's
    // tess options forced on, so TCS is emittable as a compute kernel and
    // TES as a `vertex` function post-tessellator. Consumed by
    // MetalFrameGraph to build the tess compute + render pipeline states.
    // Empty for non-tess programs.
    std::string tessControlMSL;
    std::string tessEvalMSL;
    // Sprint 5 Phase 1 — Phase 3 gate widening signal: this program had
    // no real TCS at link time; the tessControlMSL above came from a
    // synthesized passthrough TCS (GL spec §11.2.4 — TES-only programs
    // use VS outputs directly + glPatchParameterfv defaults for tess
    // levels). Encoder uses this signal to host-populate factorBufFull
    // from `state->tessellationState().defaultOuter/InnerLevel` after
    // TCS-compute runs (synth TCS writes 1.0 defaults to factorBufFull
    // via Path L extension's TCS dual-write; host overwrite injects the
    // user-set glPatchParameterfv values).
    bool tessControlSynthesized = false;
    // Phase 3 of metal-tess: VS emitted as a Metal compute kernel with
    // `capture_output_to_buffer=true`. When a tess program has VS
    // outputs the TCS reads, this kernel runs per-vertex and writes
    // them into a buffer that the TCS compute dispatch consumes via
    // its stage-input descriptor. Empty when no VS outputs exist or
    // for non-tess programs. `vertexMSL` above keeps the traditional
    // `vertex` shader form for non-tess paths (still used by
    // encodeTranslatedDraw when this program is bound to a non-tess
    // draw, which shouldn't happen — but the MSL is cheap to keep).
    std::string tessVertexAsComputeMSL;
    // Phase 3B [metal-tess-TF] groundwork: TES emitted as a Metal
    // compute kernel for the TF-capture draw path. Empty under
    // Phase 3 groundwork (the SPIRV-Cross fork patch that actually
    // changes emission lands in Phase 3B.2); the field + its
    // retained pipeline state are in place so the link path + probe
    // + draw gate can be extended without touching GLProgramObject
    // again.
    std::string tessEvalAsComputeMSL;
    // Phase 3B.5 [metal-tess-TF]: reflected TES output struct layout
    // (per-member name + byte offset + byte size). Used by the
    // TF-capture encoder to locate each GL-declared TF varying by
    // name in the emitted `main0_out` struct and copy the per-vertex
    // bytes into the bound TF buffer at GL's interleaved/separate
    // layout. Empty for non-tess / non-Phase-3B programs.
    appgl::StageOutputLayout tessEvalOutputLayout;
    // Reflections for the tess compute stages. Used to build the
    // per-dispatch default-uniform bytes so TCS / VS-compute / TES-
    // compute can read glUniform* values (CTS tess_invariance + the
    // getAmountOfVerticesGeneratedByTessellator counter program use
    // uniform-fed tess factors and were stuck in the CPU fallback
    // until these were plumbed).
    ShaderReflection tessControlReflection;
    ShaderReflection tessVertexAsComputeReflection;
    ShaderReflection tessEvalAsComputeReflection;
    ShaderReflection vertexReflection;
    ShaderReflection fragmentReflection;
    // Reflection for the geometry stage, harvested from SPIRV-Cross
    // even though the GS is CPU-emulated and the MSL output isn't
    // used for a Metal pipeline. The reflection is usage-based —
    // it lists only the UBOs, SSBOs, and default-uniform-block
    // members the GS actually accesses (via OpAccessChain). Used
    // by `GL_REFERENCED_BY_GEOMETRY_SHADER` queries on
    // glGetProgramResourceiv so CTS
    // `program_resource.program_resource` gets correct per-resource
    // answers.
    ShaderReflection geometryReflection;
    bool hasTranslatedPipeline = false;
    std::uint32_t advancedBlendSupportMask = 0;
    bool advancedBlendSupportAll = false;

    // CPU GS emulation. Set at link time by
    // `detectGeometryEmulatable` when the program has a GS stage
    // whose SPIR-V the interpreter can handle. `geometrySpirv` is
    // copied from the GS shader object so it survives even if the
    // shader is detached + deleted before draw time. drawArrays
    // branches on `geometryEmulated` before the normal translated-
    // pipeline path. See docs/geometry-shader-emulation.md.
    bool geometryEmulated = false;
    std::vector<std::uint32_t> geometrySpirv;
    // Tessellation-emulation flag. Set by
    // `appgl::detectTessellationEmulatable` at link time when the
    // program has a TES stage whose SPIR-V the CPU tessellation
    // emulator can handle (§11.2.2 / §11.2.3). Scaffolding only
    // through iter 162 — flag stays false and drawArrays falls
    // through to the existing path. Full tess CPU emulation lands
    // in iters 163+. See src/shader/TessellationEmulator.{h,cpp}.
    bool tessellationEmulated = false;
    // Phase-3f-2: set when the TES body can be run through the GSE
    // Interpreter (runTesForVertex) per generated vertex rather than
    // reduced to an affine mapping. Orthogonal to `tessellationEmulated`
    // — a program gets the interpreter path when the passthrough
    // matcher REJECTS but the classifier says the body is safe to
    // walk. Gated by the same `APPGL_ENABLE_TESS_EMUL=1` opt-in.
    bool tessellationInterpreted = false;
    // Phase-3f-4: set when the TCS body is interpretable (reads only
    // gl_PrimitiveID / gl_InvocationID / gl_PatchVerticesIn, writes
    // gl_TessLevel* + SSBOs). Orthogonal to `tessellationInterpreted`
    // in principle (a program can have an interpretable TCS + a
    // passthrough-matched TES) but both draw through the same
    // interpreter + domain generator. Gated by APPGL_ENABLE_TESS_EMUL=1.
    bool tessControlInterpreted = false;
    // Phase-3c/3d: when tessellationEmulated is set via the
    // passthrough matcher, these record how to derive each of the 4
    // gl_Position components from a (u,v,w) domain coord at draw time.
    //   tessPositionMapping[i] >= 0 →
    //     gl_Position.i = tessCoord[mapping] * scale[i] + offset[i]
    //   tessPositionMapping[i] == -1 → gl_Position.i = constant[i]
    // Initialized to the phase-2a identity mapping (x,y,z,1.0) so the
    // non-emulated path keeps a safe default.
    std::int8_t tessPositionMapping[4] = {0, 1, 2, -1};
    float tessPositionScale[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    float tessPositionOffset[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float tessPositionConstant[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    // Phase-3e-2: per-user-varying mappings captured from the TES body.
    // Each entry is { name, location, numComponents, mapping[4],
    // scale[4], offset[4], constant[4] } using the same encoding as
    // the position mapping above. The draw path iterates this vector
    // to fill the EmulatedDraw's varying slots per generated vertex.
    // Flat layout: the same type that TessellationEmulator.h defines
    // as `TessVaryingMapping`, but declared here as a lightweight POD
    // so the objects header doesn't need to pull in the tess-emul
    // header. Kept as a plain vector-of-structs because the per-
    // varying count is small (CTS rarely exceeds 4).
    struct TessVaryingSlot {
        std::string name;
        GLuint location = 0;
        GLuint numComponents = 1;
        std::uint8_t baseType = 0;   // 0=float, 1=int, 2=uint
        std::uint8_t interp = 0;     // 0=smooth, 1=flat, 2=noperspective, 3=centroid
        std::int8_t mapping[4] = {-1, -1, -1, -1};
        float scale[4] = {1.0f, 1.0f, 1.0f, 1.0f};
        float offset[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        float constant[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    };
    std::vector<TessVaryingSlot> tessVaryings;
    // TES SPIR-V copy mirrors geometrySpirv's pattern so draw time
    // can emulate without re-reaching the shader object (which may
    // have been detached + deleted).
    std::vector<std::uint32_t> tessEvalSpirv;
    // TCS SPIR-V — optional (§11.2.3). Empty when the program has a
    // TES but no TCS; the emulator then sources tess levels from
    // `glPatchParameterfv(GL_PATCH_DEFAULT_{INNER,OUTER}_LEVEL)`.
    std::vector<std::uint32_t> tessControlSpirv;
    // Phase 3f-11: cached parsed SpirvModule instances so the tess
    // emulator's per-invocation runners don't re-parse the module on
    // every (patch, invocation) pair. Filled lazily by runTes/Tcs
    // ForVertex; reset when tess*Spirv is re-assigned (re-link). The
    // mutable qualifier keeps the cache fill writable from functions
    // that take `const GLProgramObject&`.
    mutable std::unique_ptr<appgl::interp::SpirvModule> tessEvalParsedModule;
    mutable std::unique_ptr<appgl::interp::SpirvModule> tessControlParsedModule;
    // The VS SPIR-V is stashed alongside `geometrySpirv` so the CPU
    // GS emulator can run a VS pre-pass on each drawArrays call —
    // producing real gl_in[] data (VS outputs) to feed into the GS
    // interpreter. Copied from the vertex shader object at link time
    // so detach/delete of the shader doesn't pull the blob out from
    // under a subsequent draw.
    std::vector<std::uint32_t> vertexSpirv;
    // GS input / output topology from the SPIR-V execution modes —
    // OutputPoints / OutputLineStrip / OutputTriangleStrip, and
    // InputPoints / InputLines / InputTrianglesAdjacency etc.
    // GS metadata, populated at link time (independent of whether
    // the CPU emulator can handle the shader). Used by
    // glGetProgramiv(GL_GEOMETRY_*) queries and other GS-aware APIs.
    // `gsPresent` is set iff the linked program contains a GS stage;
    // queries against non-GS programs return GL_INVALID_OPERATION.
    bool gsPresent = false;
    GLenum gsInputTopology = 0;
    GLenum gsOutputTopology = 0;
    std::uint32_t gsMaxVertices = 0;
    std::uint32_t gsInvocations = 1;

    // Sprint 17 Day 7+ Bank-Group-H Phase 6-2-r Path B Component A1.
    // Set true at link time when:
    //   • VS writes gl_CullDistance (per `scanClipCullWrites` SPIR-V walk)
    //   • !gsPresent (no geometry stage in the pipeline)
    //   • !hasTessellation (no TCS/TES stage)
    // Drives:
    //   1) Translator: `disableCullDistanceClipRouting` option suppresses
    //      the gl_CullDistance → [[clip_distance]] HW routing in
    //      ShaderTranslator.cpp:1562-1700 (Phase 2 confirmed Option β
    //      refutation — residual per-fragment clip over-clips 0th vertex
    //      pixel on non-tested cull channels per CTS test design).
    //   2) Draw path: dispatches `emulateVsCullPrepass` to evaluate
    //      GL §14.6.3 per-primitive cull on CPU before issuing the
    //      Metal draw with a filtered index buffer.
    bool needsCullDistancePrepass = false;

    // Cached synthesised pass-through VS for the GS-emulation draw
    // path. Built lazily on the first emulated draw (the layout is
    // fixed at link time by the GS output SPIR-V, which doesn't
    // change between draws). Cleared at program re-link via the
    // same reset path as the rest of the translated-pipeline cache.
    // `gsPassThroughVertexMSLLayered` is set to true when the cached
    // MSL was built with gl_Layer routing to
    // `[[render_target_array_index]]`. When the next emulated draw
    // uses an FBO of different layered-ness, the cache is
    // invalidated and re-synthesised — the MSL declarations differ
    // (layered vs. non-layered) and Metal won't accept swapping.
    std::string gsPassThroughVertexMSL;
    bool gsPassThroughVertexMSLLayered = false;
    // Sprint 15 Day 10 [metal-viewport-array]: sister to
    // gsPassThroughVertexMSLLayered. True when the cached MSL emits
    // `[[viewport_array_index]]` (env-gated via
    // APPGL_ENABLE_METAL_VIEWPORT_INDEX). Cache invalidates when env
    // toggles or viewport-array binding diverges.
    bool gsPassThroughVertexMSLViewportArray = false;
    ShaderReflection gsPassThroughReflection;
    // Rewritten FS MSL for GS-emulated draws that require routing a
    // GS-supplied gl_PrimitiveID override through a flat user varying
    // instead of Metal's rasteriser-provided `[[primitive_id]]`.
    // Populated by `rewriteFragmentMSLForPrimitiveID` on the first
    // such draw; points back to the original `fragmentMSL` via the
    // `gsPassThroughFragmentMSLActive` flag when no rewrite is
    // needed. `gsPassThroughFragmentMSLPrimIdLoc` is kept so a
    // draw that flips to a different primitive-id location (e.g.
    // when varyingLocations change between pipelines — shouldn't
    // happen for a linked program but guard anyway) can rebuild.
    std::string gsPassThroughFragmentMSL;
    bool gsPassThroughFragmentMSLActive = false;
    std::uint32_t gsPassThroughFragmentMSLPrimIdLoc = 0;
    // Parallel pipeline-state cache so the emulated draw doesn't
    // pollute the regular hasTranslatedPipeline cache. Same owner-
    // ship semantics as metalPipelineState* below.
    void* gsPassThroughPipelineState = nullptr;
    std::uint32_t gsPassThroughPipelineColorFormat = 0;
    std::unordered_map<std::uint64_t, void*> gsPassThroughPipelineStateCache;
    // Retained MTLFunction pair for the GS-emulation pass-through render path.
    // Argument-buffer binding needs these functions on pipeline-cache hits to
    // create per-stage MTLArgumentEncoders, just like the regular translated
    // draw path's metalVertexFunction / metalFragmentFunction pair.
    void* gsPassThroughVertexFunction = nullptr;
    void* gsPassThroughFragmentFunction = nullptr;

    // Compute shader pipeline state. The MSL and reflection are populated
    // at link time for ProgramKind::Compute; the MTLComputePipelineState
    // is built immediately and cached here because compute pipelines
    // have no per-dispatch state variation (unlike render pipelines,
    // which depend on color format / blend mode).
    std::string computeMSL;
    ShaderReflection computeReflection;
    // KHR-GL46.shader_storage_buffer_object.basic-stdLayout-case3 uses
    // SSBO double/dvec fields only for raw copies. Metal does not support
    // double-typed buffer members, so link marks this exact copy shape for
    // a CPU byte-copy fallback in draw/dispatch.
    bool ssboStdLayoutDoubleCopyFallback = false;
    std::uint32_t computeLocalSizeX = 1;
    std::uint32_t computeLocalSizeY = 1;
    std::uint32_t computeLocalSizeZ = 1;
    // Retained id<MTLComputePipelineState> (CFBridgingRetain'd; released
    // at linkProgram reset and at program delete via releaseProgram).
    void* metalComputePipelineState = nullptr;
    // Metal tess Phase 1: retained id<MTLComputePipelineState> for the
    // TCS-as-compute stage of a tessellation program. Built at link time
    // by MetalFrameGraph::probeTessellationPipeline alongside the render
    // pipeline probe. Phase 2 will consume this at draw time for the
    // compute-encode TCS step; Phase 1 only validates the build.
    // Released at linkProgram reset and at program delete.
    void* metalTessControlPipelineState = nullptr;
    // Metal tess Phase 3: retained id<MTLComputePipelineState> for
    // the VS-as-compute stage. Non-null only when the tess program has
    // a non-trivial VS whose outputs the TCS consumes (SPIRV-Cross
    // `vertex_for_tessellation + capture_output_to_buffer`). Built at
    // link time via the same probe path as the TCS compute PSO.
    void* metalTessVertexPipelineState = nullptr;
    // T4I [metal-tess-TF]: when true, the VS-as-compute MSL declares
    // `[[stage_in]]` and the PSO must be built at draw time with a
    // MTLStageInputOutputDescriptor derived from the bound VAO. The
    // program is otherwise Phase-3-eligible (TCS, TES, FS all built);
    // only the VS-compute PSO is deferred. The encoder consults this
    // and the per-program PSO cache (keyed on VAO descriptor hash)
    // before dispatch.
    bool metalTessVertexNeedsDescriptor = false;
    // T4I [metal-tess-TF]: cache of per-VAO-descriptor VS-compute
    // PSOs keyed on the descriptor hash. Lookup-or-build at draw
    // time so VAO swaps don't pay the PSO build cost twice. Released
    // alongside the rest of the metal tess state at program delete /
    // relink. Each entry is a CFBridgingRetain'd
    // id<MTLComputePipelineState>.
    std::unordered_map<std::string, void*> metalTessVertexPSOCache;
    // Phase 3B [metal-tess-TF] groundwork: retained
    // id<MTLComputePipelineState> for the TES-as-compute stage.
    // Populated only once the SPIRV-Cross fork patch (Phase 3B.2)
    // emits a kernel form of the TES; until then
    // `tessEvalAsComputeMSL` is either empty or the same MSL as the
    // existing render path, and the probe skips this PSO.
    void* metalTessEvalComputePipelineState = nullptr;

    // Sprint 15 Q3-Option-B Phase 1 groundwork [metal-tf-vs]: VS-as-
    // compute path for VS+FS+TF programs (no GS, no tess). Sister of
    // the metal-tess-TF VS-compute path: SPIRV-Cross emits the VS
    // with `vertex_for_tessellation + capture_output_to_buffer` so
    // per-vertex outputs land in a Metal buffer that the TF-capture
    // encoder consumes. Replaces the CPU-side `emulateVsOnlyDrawForTf`
    // SPIR-V interpreter on the draw-time path once Phase 3 wires
    // the encoder routing in.
    //
    // Phase 1 (this checkpoint) lays the link-time groundwork only:
    //   • re-translate VS with `forceVertexForTessellation=true` to
    //     produce the kernel form
    //   • build the MTLComputePipelineState directly when the VS has
    //     no `[[stage_in]]` (gl_VertexID-only), or set
    //     `metalVsTfNeedsDescriptor=true` and defer to draw time when
    //     a MTLStageInputOutputDescriptor (built from the bound VAO)
    //     is required
    //   • stash MSL + reflection + PSO + tier on the program object
    //
    // No draw-time behaviour change at Phase 1 — encodeTranslatedDraw
    // still routes TF-active VS+FS programs through the CPU helper.
    // Phase 2 (next checkpoint) adds TF buffer binding plumbing;
    // Phase 3 swaps the draw-time routing.
    //
    // Master gate: APPGL_ENABLE_METAL_TF_VS=1 (off by default; mirrors
    // the conservative posture of APPGL_ENABLE_METAL_TESS_TF). The
    // gate is read once at link time so a relink under different env
    // settings re-evaluates cleanly.
    std::string vsTfAsComputeMSL;
    ShaderReflection vsTfAsComputeReflection;
    void* metalVsTfComputePipelineState = nullptr;
    bool metalVsTfNeedsDescriptor = false;
    // VAO-descriptor-hash-keyed PSO cache for the deferred-build path
    // (mirrors `metalTessVertexPSOCache`). Phase 1 leaves the map empty
    // — Phase 3's draw-time path lookup-or-builds entries here when
    // `metalVsTfNeedsDescriptor==true`. Each entry is a
    // CFBridgingRetain'd id<MTLComputePipelineState>; released
    // alongside the rest of the metal-tf-vs state at relink/delete.
    std::unordered_map<std::string, void*> metalVsTfComputePSOCache;
    // Routing tier for the VS+FS+TF compute chain. None=fall through
    // to CPU `emulateVsOnlyDrawForTf` (current behaviour), VsAsCompute
    // =Phase 3 routing eligible.  Set by the link-time gate when the
    // master env is on AND the program has TF varyings AND VS-compute
    // build (or deferred-descriptor flag) succeeded.
    enum class MetalVsTfTier : std::uint8_t {
        None = 0,
        VsAsCompute = 1,
    };
    MetalVsTfTier metalVsTfTier = MetalVsTfTier::None;

    // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]: VS-as-compute output
    // struct layout (member name + byte offset + GL-packed byte size).
    // Sister of `tessEvalOutputLayout` — reflected at link time under
    // `forceVertexForTessellation=true` so the bytes match the kernel-
    // emitted output buffer's per-vertex stride. Phase 3's draw-time
    // path uses this layout to copy per-vertex bytes into the bound
    // GL_TRANSFORM_FEEDBACK_BUFFER at GL's interleaved/separate stride.
    // Empty for non-VS-TF programs / when the link-time gate skipped.
    appgl::StageOutputLayout vsTfOutputLayout;
    // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]: pre-resolved per-TF-
    // varying source (struct-offset + byte-size) inside the VS-compute
    // output struct, computed once at link time so the draw-time TF
    // writer doesn't repeat the name lookup. One entry per declared TF
    // varying (matches `transformFeedbackVaryingNames` order). Source
    // with `bytes==0` indicates an unresolved varying name (Phase 3
    // will emit GL_INVALID_OPERATION at draw time per GL 4.6 §13.2.1
    // when this happens). `gl_Position` is special-cased to match the
    // builtin's BuiltInPosition decoration.
    struct VsTfTfSource {
        std::size_t offset = 0;  // byte offset inside the MSL struct
        std::size_t bytes = 0;   // GL-packed byte size for this varying
    };
    std::vector<VsTfTfSource> vsTfResolvedSources;

    // Which Metal tess draw path the link probe has cleared this
    // program for. Set at link time after the Phase-2-handleability
    // substring scan + Phase-3 VS-compute PSO availability check.
    // Drives the draw-path gate:
    //   None        — fall through to CPU tessellation interpreter
    //   Phase2      — encode via `encodeMetalTessellationDraw`
    //                 (TCS compute → drawPatches, factor + indirect
    //                  buffers only).
    //   Phase3      — encode via `encodeMetalTessellationDrawPhase3`
    //                 (VS-compute → TCS-compute → drawPatches;
    //                  per-CP, per-patch, VS-output buffers plumbed).
    enum class MetalTessTier : std::uint8_t {
        None = 0,
        Phase2 = 1,
        Phase3 = 2,
    };
    MetalTessTier metalTessTier = MetalTessTier::None;

    // Sprint 3 [metal-mesh-GS]: which GS execution path the link
    // probe has cleared this program for. Set at link time after
    // (a) GS shader presence check, (b) device mesh-shader cap
    // (`GLCapabilities::meshShaderSupported()`), and (c) GS shape
    // compatibility with the SPIRV-Cross GS-as-mesh patch's MVP
    // coverage (excludes adjacency, streams, max_vertices > 3).
    //   None             — non-GS programs (no-op, falls through).
    //   CPUInterpreter   — existing CPU GS interpreter path
    //                      (`encodeEmulatedGsDraw`).
    //   MeshShader       — Metal mesh shader path (this sprint's
    //                      target). Encoded via the new
    //                      `encodeMetalGSDraw` once it lands.
    enum class MetalGSTier : std::uint8_t {
        None = 0,
        CPUInterpreter = 1,
        MeshShader = 2,
    };
    MetalGSTier metalGSTier = MetalGSTier::None;
    // Sprint 3 [metal-mesh-GS]: cached MSL emitted with
    // `geometry_shader_as_mesh = true`. Populated when
    // metalGSTier == MeshShader. Used for render-PSO build at link
    // time + rebuild on FBO format changes.
    std::string geometryShaderAsMeshMSL;
    // Sprint 3 [metal-mesh-GS]: retained id<MTLRenderPipelineState>
    // for the mesh render pipeline — built from
    // MTLMeshRenderPipelineDescriptor at link time when
    // `metalGSTier == MeshShader`. Color-format-keyed cache landed
    // at draw time when Metal's render-PSO requirements demand
    // per-FBO rebuild.
    void* metalGSMeshPipelineState = nullptr;
    // Sprint 3 Phase 2 [metal-mesh-GS]: VS-as-compute pre-pass for the
    // mesh-GS path. SPIRV-Cross-emitted MSL with
    // `vertex_for_tessellation + capture_output_to_buffer` writes per-
    // vertex VS outputs into a buffer the mesh function reads at
    // `[[buffer(22)]]` (matches Path A's `spvVsOutputs`). The PSO is
    // built once at link time (no MTLStageInputOutputDescriptor — the
    // 6 MVP conversion targets are all simple gl_VertexID-only VSes;
    // descriptor-needing programs fall back to CPUInterpreter via the
    // PSO-build-failure gate). Released on relink / program-delete.
    std::string metalGSVsComputeMSL;
    void* metalGSVsComputePipelineState = nullptr;
    // Sprint 3 Phase 2: cached id<MTLFunction> for the mesh function.
    // Built from `geometryShaderAsMeshMSL` at link time so the per-
    // FBO-format render-PSO build at draw time only pays the
    // newRenderPipelineStateWithMeshDescriptor cost, not the
    // newLibraryWithSource compile cost.
    void* metalGSMeshFunction = nullptr;
    // Sprint 3 Phase 2: cached id<MTLFunction> for the fragment shader
    // when tier=MeshShader. Compiled from `fragmentMSL` at link time
    // alongside the mesh function. Distinct from `metalFragmentFunction`
    // (argbuf path) so the two caches don't collide.
    void* metalGSFragmentFunction = nullptr;
    // Step 7-3 compute follow-up: retained id<MTLFunction> for the
    // compute entry point, populated alongside the PSO when
    // APPGL_ENABLE_ARGUMENT_BUFFERS is set. `encodeComputeDispatch`
    // reads this to call `newArgumentEncoderWithBufferIndex:` without
    // rebuilding the MTLFunction on every dispatch. Released at the
    // same lifetime as metalComputePipelineState.
    void* metalComputeFunction = nullptr;
    // Step 7-4: retained id<MTLFunction> for vertex + fragment
    // entry points, populated on the first graphics pipeline build
    // when APPGL_ENABLE_ARGUMENT_BUFFERS is set. Without this cache
    // `encodeTranslatedDraw` was forced to miss the pipeline cache
    // on every argbuf draw (the MTLFunction had to stay in scope
    // after `newFunctionWithName:` so we could call
    // `newArgumentEncoderWithBufferIndex:` on it). With the cache,
    // pipeline cache hits restore their O(0) cost and the encoder
    // creation reads from this program-scoped retain. Released on
    // relink / program-delete alongside the PSO.
    void* metalVertexFunction = nullptr;
    void* metalFragmentFunction = nullptr;

    // Phase 8X Group 4d follow-up⁴ — per-stage source hashes captured at
    // link time. Used by the pipeline-build failure path in the translated
    // draw entry points to stamp the failing program's source hashes onto
    // the diagnostic-ring `pipeline-build` record, so BAR-side tooling can
    // correlate the Metal NSError back to the original GLSL source via the
    // same hash that the link-stage records carry. Empty for stages that
    // don't exist (compute-only programs leave both empty).
    std::string vertexSourceHash;
    std::string fragmentSourceHash;

    // Opaque pipeline state handle, owned by MetalFrameGraph.  Stored here so
    // repeated draws skip pipeline creation.  Type-erased to avoid ObjC in this
    // header — cast to id<MTLRenderPipelineState> in .mm files.
    void* metalPipelineState = nullptr;
    // Track which pixel format the cached pipeline was created for, so we
    // can invalidate if the render target format changes.
    std::uint32_t metalPipelineColorFormat = 0;

    // Phase 8X Group 4d follow-up¹⁴ — map-based pipeline cache. The old
    // single-slot {metalPipelineState + metalPipelineColorFormat} cache
    // could only hold one pipeline per program at a time, which
    // thrashed when spring toggled `GL_BLEND` 15× per frame
    // (followup¹³-verification §Candidate-1). The new cache keys on a
    // 64-bit hash of (colorFormat, blend tuple, per-attribute format
    // tuple) so a program that draws both an opaque first pass and an
    // alpha-blended second pass keeps both pipelines hot.
    //
    // Values are `id<MTLRenderPipelineState>` type-erased to `void*`
    // and retained via CFBridgingRetain at insert time. The map is
    // cleared (and entries CFRelease'd) at link time by the existing
    // pipeline-state reset in `linkProgram`. Entries are leaked on
    // program delete, matching the prior single-slot cache's behavior
    // — program deletion is rare, and the static table for this
    // process lifetime is tens of entries at most.
    std::unordered_map<std::uint64_t, void*> metalPipelineStateCache;

    // Phase 8X Group 4d follow-up³ — diagnostic instrumentation for the
    // translated-draw fall-through path. Each bit corresponds to a
    // TranslatedFallbackGate enumerator (defined in GLContext.mm). The
    // reportTranslatedFallbackOnce helper checks the matching bit, sets it
    // if clear, and emits a single NSLog line per (program, gate) pair so
    // BAR-side log analysis can name the gate that's silently routing draws
    // through encodeSolidColorDraw instead of encodeTranslatedDraw without
    // drowning in per-draw spam.
    std::uint32_t translatedFallbackGatesReported = 0;

    // Transform feedback varyings (set by glTransformFeedbackVaryings, used at link time).
    std::vector<std::string> transformFeedbackVaryingNames;
    GLenum transformFeedbackBufferMode = GL_INTERLEAVED_ATTRIBS;

    // GL 4.3 program resource introspection tables (populated at link time).
    std::vector<GLProgramResourceEntry> resourceUniforms;
    std::vector<GLProgramResourceEntry> resourceUniformBlocks;
    std::vector<GLProgramResourceEntry> resourceInputs;
    std::vector<GLProgramResourceEntry> resourceOutputs;
    std::vector<GLProgramResourceEntry> resourceStorageBlocks;
    std::vector<GLProgramResourceEntry> resourceAtomicCounterBuffers;
    std::vector<GLProgramResourceEntry> resourceBufferVariables;
    std::vector<GLProgramResourceEntry> resourceTransformFeedbackVaryings;
    std::vector<GLProgramResourceEntry> resourceTransformFeedbackBuffers;
    // GL 4.0 subroutine interfaces — per-stage lists of subroutine
    // implementations and subroutine-uniform bindings. Indexed by
    // stage (VS=0, TCS=1, TES=2, GS=3, FS=4, CS=5). Populated by
    // the link-time subroutine scanner (see GLContext.mm). Each
    // subroutine uniform's `activeVariables` holds the indices of
    // its compatible subroutines (into resourceSubroutines[stage]),
    // driving GL_NUM_COMPATIBLE_SUBROUTINES / GL_COMPATIBLE_SUBROUTINES.
    std::vector<GLProgramResourceEntry> resourceSubroutines[6];
    std::vector<GLProgramResourceEntry> resourceSubroutineUniforms[6];
    // Sprint 17 Day 3 (CKPT238) [Track 3A — shape-agnostic
    // foundational]: GL 4.0 subroutine selection state.
    //
    // Per GL 4.6 §7.9, glUniformSubroutinesuiv operates on the
    // currently-bound program (no `program` argument); each call
    // sets ALL subroutine-uniform selections for one shader stage at
    // once — `indices[location]` maps the subroutine-uniform AT
    // LOCATION to the subroutine AT INDEX value. State lives on the
    // program object (relink blows it).
    //
    // Indexed by stage (VS=0..CS=5); inner array indexed by uniform
    // location, mirroring the GL setter API contract (NOT by uniform
    // index in `resourceSubroutineUniforms[stage]`). The location is
    // the value returned by glGetSubroutineUniformLocation.
    //
    // Default-init at link time per spec ("any compatible
    // implementation"); we choose compatible-subroutine index 0 for
    // each uniform location.
    //
    // `subroutineSelectionsDirty` is set on glUniformSubroutinesuiv
    // and consumed by the draw-encode path (Sub-task 3A.4 per
    // SPIRV-TW shape decision: table-lookup uniform-buffer pack OR
    // spec-constant pipeline rebuild). Cleared post-consumption.
    std::vector<GLuint> currentSubroutineSelections[6];
    bool subroutineSelectionsDirty = false;

    // Sprint 17 Day 7+ (Bank-Group-C re-engagement): synthetic
    // dispatch-uniform location side-channel. The compat rewriter
    // `rewriteSubroutinesForSpirv` emits one `uniform uint
    // __appgl_sub_<UNI>;` per v1-eligible subroutine uniform (void
    // return, no params) plus a `void __appgl_dispatch_<UNI>()`
    // helper that branches on the synthetic uniform's value to the
    // selected impl. This map is populated at link time by walking
    // every stage's `_DefaultUniforms` reflection for `__appgl_sub_*`
    // members and noting their auto-assigned default-block locations.
    // Keyed by subroutine-uniform NAME (the original user identifier,
    // e.g. "routine"), value is the GL location of the corresponding
    // synthetic dispatch uniform. `glUniformSubroutinesuiv` consumes
    // this map to push the selected subroutine index into the dispatch
    // uniform's storage so the helper's if-else chain selects the
    // requested impl at runtime. (CTS `viewport_index_subroutine`.)
    std::unordered_map<std::string, GLint> subroutineDispatchUniformLocations;

    // GL 4.3 SSBO binding remapping (block index → user-specified binding).
    std::unordered_map<GLuint, GLuint> ssboBindingRemap;

    // GL 4.2 `layout(binding = N)` sampler default unit (§7.6). Maps
    // sampler uniform name → explicit binding. Populated at link time
    // via a GLSL source regex scan across every attached shader; used
    // by the draw-time sampler resolver to substitute N as the texture
    // unit when the application never called `glUniform1i(loc, ...)`.
    // Restricts fallback to user-declared bindings — glslang's auto-
    // assigned DecorationBinding values would otherwise shadow the
    // spec-intended "0 when unset" behaviour (the bd73acc / 9c496f4
    // regression that broke pixelstoragemodes). A GLSL source parse
    // is the unambiguous source of truth since it runs before glslang.
    std::unordered_map<std::string, GLuint> samplerExplicitBindings;

    // ── Precomputed uniform layout (OPT-7) ──
    // Maps push-constant struct members to GL uniform locations, eliminating
    // O(N*M) string comparisons from the per-draw uniform packing path.
    // Computed lazily on first draw and reused for all subsequent draws.
    struct UniformLayoutEntry {
        std::size_t memberOffset = 0;   // byte offset in push-constant struct
        std::size_t copyBytes = 0;      // total bytes to memcpy (0 = skip)
        GLint location = -1;            // GL uniform location for value lookup
        GLenum memberType = 0;
        bool containsFp64 = false;
        // Matrix column-padding fields. When `matPaddedCols` > 0 the
        // member is a matrix type whose GL column width (matPaddedRows
        // floats) is less than the 4-float (16-byte) MSL/std140 column
        // stride — the packer loops column-by-column. Covers mat2/mat3
        // and the non-square shapes mat2x3 / mat3x2 / mat4x3 / mat4x2
        // (for which column stride is vec4 = 16 bytes regardless of
        // the column's actual component count). mat4, mat2x4, mat3x4
        // have column width = 16 bytes so no padding is needed and
        // `matPaddedCols` stays 0.
        int matPaddedCols = 0;
        int matPaddedRows = 0;
        std::size_t matPaddedStrideBytes = 16;
        std::size_t matPaddedScalarBytes = sizeof(float);
        // Array-member unpadding fields. Non-zero arrayCount means the
        // member is an array with `arrayCount` elements where each GPU-
        // side element occupies `arrayStride` bytes (std140 rounds up to
        // at least 16), while each GL-side element is `glElementBytes`
        // tight-packed. Caller loops elementwise instead of a single
        // memcpy.
        std::uint32_t arrayCount = 0;
        std::size_t arrayStride = 0;
        std::size_t glElementBytes = 0;
    };
    std::vector<UniformLayoutEntry> vertexUniformLayout;
    std::vector<UniformLayoutEntry> fragmentUniformLayout;
    std::vector<UniformLayoutEntry> computeUniformLayout;
    std::vector<UniformLayoutEntry> tessControlUniformLayout;
    std::vector<UniformLayoutEntry> tessVertexAsComputeUniformLayout;
    std::vector<UniformLayoutEntry> tessEvalAsComputeUniformLayout;
    // Sprint 15 Day 27 (CKPT200): Phase 3b Component A — uniform-block
    // layout cache for VS-as-compute (TF-VS path). Sister to
    // `tessVertexAsComputeUniformLayout`; computed lazily on first
    // dispatch via `computeStageUniformLayout(layout, reflection,
    // uniforms)` and reused across draws (link-time stable).
    // `buildStageUniformBuffer(scratch, reflection, uniformValues,
    // layout)` packs current uniform values into the byte buffer fed
    // to the VS-as-compute encoder at slot 16.
    std::vector<UniformLayoutEntry> vsTfAsComputeUniformLayout;
    bool uniformLayoutComputed = false;
};

struct GLQueryObject {
    GLenum target = 0;
    GLenum boundTarget = 0;   // First target used with this query; 0 = unbound
    // Stream index for indexed-query targets (GL 4.0+
    // TRANSFORM_FEEDBACK_STREAM_OVERFLOW and TRANSFORM_FEEDBACK_-
    // PRIMITIVES_WRITTEN). The non-indexed BeginQuery path leaves
    // this at 0. CTS `transform_feedback_overflow_query_ARB.
    // context-state-update` expects GetQueryIndexediv to return
    // the active query only at the specific index it was started
    // on, and 0 on every other index.
    GLuint index = 0;
    bool active = false;
    GLuint64 result = 0;
    // GL 4.6 §4.2: `glGenQueries` reserves names without creating
    // objects — `glIsQuery` returns FALSE until the query is first
    // bound via `glBeginQuery`. `glCreateQueries` (GL 4.5 DSA)
    // creates the object fully. Track the distinction here.
    bool instantiated = false;
    // GL 4.6 §22.2 — GL_TIME_ELAPSED / GL_TIMESTAMP record CPU clock
    // nanoseconds between BeginQuery and EndQuery. CTS
    // `direct_state_access.queries_functional` expects EndQuery on a
    // TIME_ELAPSED query to report a non-zero result (`less(0, v)`
    // comparison). Metal doesn't expose a GPU timestamp that maps
    // cleanly to GL's monotonic nanoseconds, so we fall back to
    // CPU-measured elapsed time — far coarser than HW counters but
    // sufficient for the non-zero-duration comparison.
    std::uint64_t startTimeNs = 0;
};

struct GLSyncObject {
    void* sharedEvent = nullptr;
    GLuint64 signalValue = 0;
};

struct GLTransformFeedbackObject {
    bool active = false;
    bool paused = false;
    // GL 4.6 §13.2: glGenTransformFeedbacks reserves a name; the
    // object isn't really created until first bound via
    // glBindTransformFeedback. glCreateTransformFeedbacks (DSA)
    // creates fully-instantiated objects. CTS
    // `direct_state_access.xfb_creation` asserts the reserve-only
    // behaviour by `glGenTransformFeedbacks` + `glIsTransformFeedback`
    // → expect FALSE.
    bool instantiated = false;
    bool hasCompleted = false;  // set to true when EndTransformFeedback is called
    GLenum capturedPrimitiveMode = GL_POINTS;  // mode from beginTransformFeedback
    GLsizei capturedPrimitives = 0;  // for glDrawTransformFeedback
    static constexpr std::size_t kMaxTransformFeedbackStreams = 4;
    // Sprint 8 #9-C (CKPT68): vertex count captured during the active
    // Begin/EndTransformFeedback session. Equals primsWritten ×
    // verts-per-prim of the captured mode. Reset at Begin and
    // accumulated by writeGsXfbAndCheckDiscard / VS-only-TF helper
    // TF-write paths.
    //
    // Sprint 18 Bank D-2/G: DrawTransformFeedback* must read the most
    // recently completed capture, even while the same object is active
    // again for feedback-loop capture. Keep that completed draw count
    // separate from this in-progress accumulator.
    // lastCompletedVertexCount is copied from capturedVertexCount at
    // EndTransformFeedback and is the source for DrawTransformFeedback*
    // counts.
    std::array<GLsizei, kMaxTransformFeedbackStreams> lastCompletedVertexCount{};
    // Active-session per-stream accumulator below. Reset to 0 on each
    // glBeginTransformFeedback; accumulated by writeGsXfbAndCheckDiscard /
    // VS-only-TF helper TF-write paths, then snapshotted at End.
    //
    // Sprint 8 #9-C remainder (CKPT94): per-stream tracking. GL 4.0+
    // multi-stream geometry shaders (`EmitStreamVertex(N)` /
    // `layout(stream=N) out`) emit vertices to up to 4 distinct streams
    // per the spec floor (gl_MaxTransformFeedbackStreams ≥ 4). Each
    // stream has its own captured vertex count; `glDrawTransformFeedback-
    // StreamInstanced(stream=K)` reads the K-th stream's count.
    // Single-stream paths (VS-only TF, non-stream GS, tess) write to
    // stream 0 only — this is the existing pre-#9-C behavior preserved
    // under index 0. Sister to CKPT85's per-TF-object state migration
    // (single-component infrastructure pattern, CONFIRMED at 3-instance);
    // here at higher-cardinality scope (array-of-state).
    //
    // CTS `transform_feedback.draw_xfb_stream_instanced_test` is the
    // immediate consumer — its GS uses `EmitStreamVertex(0)` x4 +
    // `EmitStreamVertex(1)` x4 with `layout(stream=1) out vec4 color`.
    std::array<GLsizei, kMaxTransformFeedbackStreams> capturedVertexCount{};
    // Per-TF-object indexed buffer bindings recorded by the DSA
    // `glTransformFeedbackBufferBase` / `glTransformFeedbackBufferRange`
    // entries. Queried back via `glGetTransformFeedbacki_v` /
    // `glGetTransformFeedbacki64_v` with pname =
    // GL_TRANSFORM_FEEDBACK_BUFFER_{BINDING,START,SIZE}.
    // CTS `direct_state_access.xfb_buffers` asserts the round-trip.
    struct BufferBinding {
        GLuint buffer = 0;
        GLintptr offset = 0;  // 0 for BufferBase
        GLsizeiptr size = 0;  // 0 for BufferBase (means "whole buffer")
    };
    static constexpr std::size_t kMaxTfBuffers = 4;  // MAX_TF_BUFFERS
    std::array<BufferBinding, kMaxTfBuffers> bufferBindings{};
};

struct GLProgramPipelineObject {
    GLProgramPipelineObject();
    ~GLProgramPipelineObject();
    GLProgramPipelineObject(const GLProgramPipelineObject&) = delete;
    GLProgramPipelineObject& operator=(const GLProgramPipelineObject&) = delete;
    GLProgramPipelineObject(GLProgramPipelineObject&&) noexcept;
    GLProgramPipelineObject& operator=(GLProgramPipelineObject&&) noexcept;

    GLuint vertexProgram = 0;
    GLuint fragmentProgram = 0;
    GLuint geometryProgram = 0;
    GLuint tessControlProgram = 0;
    GLuint tessEvalProgram = 0;
    GLuint computeProgram = 0;
    GLuint activeShaderProgram = 0;
    bool validated = false;
    // GL 4.6 §7.4: glGenProgramPipelines reserves names; the pipeline
    // isn't real until bound via glBindProgramPipeline. DSA
    // glCreateProgramPipelines fully instantiates. Track the
    // distinction for glIsProgramPipeline.
    bool instantiated = false;
    std::string infoLog;

    // β [metal-tess-TF] — synthesised combined-stage program for
    // pipeline-bound Metal tessellation. The link-time tess probe in
    // GLContext::linkProgram requires TCS + TES + FS MSL to all live
    // on a single GLProgramObject; for separable programs (one stage
    // per program object) that gate fails and the Metal tess PSOs
    // never build. The pipeline-time orchestrator (Impl::ensure
    // PipelineTessSynthesizedProgram) gathers SPIR-V from the
    // pipeline's separable VS+TCS+TES+FS programs, re-translates with
    // cross-stage info (siblingTesInputSpirv on TCS, force
    // VertexForTessellation on VS, force TessEvalAsCompute +
    // tesePatchVertices on TES), runs the same probeTessellation
    // Pipeline call linkProgram does, and stashes the assembled
    // GLProgramObject here. Cached against the stage-program-name
    // snapshot below so a useProgramStages swap invalidates cleanly.
    std::unique_ptr<GLProgramObject> syntheticTessProgram;
    GLuint syntheticTessVsSnapshot = 0;
    GLuint syntheticTessTcsSnapshot = 0;
    GLuint syntheticTessTesSnapshot = 0;
    GLuint syntheticTessFsSnapshot = 0;
    // Set once the orchestrator has attempted a probe for the current
    // (vs, tcs, tes, fs) snapshot, regardless of success. Avoids
    // re-running the (expensive) translation + probe on every draw.
    // Cleared when the snapshot changes.
    bool syntheticTessProbeAttempted = false;
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

    // GL 4.6 §7.1 — shader and program names share a single allocation
    // pool. `glCreateShader` and `glCreateProgram` should never return
    // numerically-equal names even though the two objects live in
    // separate tables. Scan both tables and return the lowest unused
    // ID across them.
    GLuint reserveSharedShaderProgramName();

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
T* ObjectTable<T>::insertAt(GLuint id) {
    if (id == 0) return nullptr;
    auto [it, inserted] = objects_.try_emplace(id, T{});
    if (nextId_ <= id) nextId_ = id + 1;
    return &it->second;
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
