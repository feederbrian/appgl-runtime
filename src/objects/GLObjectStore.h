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
    std::vector<GLShaderDeclaration> declaredUniforms;
    std::vector<GLShaderDeclaration> declaredInputs;
    std::vector<GLShaderDeclaration> declaredOutputs;
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
};

// GL 4.3 program resource introspection — per-resource entry used by
// glGetProgramInterfaceiv / glGetProgramResourceiv / etc.
struct GLProgramResourceEntry {
    std::string name;
    GLenum type = 0;          // GL_FLOAT, GL_FLOAT_VEC4, etc.
    GLint location = -1;      // uniform location (glGetUniformLocation)
    GLint binding = -1;       // RC-D08: explicit layout(binding=N), -1 = unspecified
    GLint arraySize = 1;
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
    // GL 4.1 (ARB_separate_shader_objects) — GL_PROGRAM_SEPARABLE
    // flag set via `glProgramParameteri`. When true, glLinkProgram
    // accepts incomplete stage combinations (e.g. a GS-only or a
    // GS+FS program) because the pipeline object supplies the
    // missing stages at draw time. `glGetProgramiv(GL_PROGRAM_
    // SEPARABLE)` reads this back.
    bool separable = false;
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

    // CPU GS emulation. Set at link time by
    // `detectGeometryEmulatable` when the program has a GS stage
    // whose SPIR-V the interpreter can handle. `geometrySpirv` is
    // copied from the GS shader object so it survives even if the
    // shader is detached + deleted before draw time. drawArrays
    // branches on `geometryEmulated` before the normal translated-
    // pipeline path. See docs/geometry-shader-emulation.md.
    bool geometryEmulated = false;
    std::vector<std::uint32_t> geometrySpirv;
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

    // Compute shader pipeline state. The MSL and reflection are populated
    // at link time for ProgramKind::Compute; the MTLComputePipelineState
    // is built immediately and cached here because compute pipelines
    // have no per-dispatch state variation (unlike render pipelines,
    // which depend on color format / blend mode).
    std::string computeMSL;
    ShaderReflection computeReflection;
    std::uint32_t computeLocalSizeX = 1;
    std::uint32_t computeLocalSizeY = 1;
    std::uint32_t computeLocalSizeZ = 1;
    // Retained id<MTLComputePipelineState> (CFBridgingRetain'd; released
    // at linkProgram reset and at program delete via releaseProgram).
    void* metalComputePipelineState = nullptr;

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
        bool isMat3Padded = false;      // needs col-by-col padding (12->16 bytes/col)
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
    bool uniformLayoutComputed = false;
};

struct GLQueryObject {
    GLenum target = 0;
    GLenum boundTarget = 0;   // First target used with this query; 0 = unbound
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
    bool hasCompleted = false;  // set to true when EndTransformFeedback is called
    GLenum capturedPrimitiveMode = GL_POINTS;  // mode from beginTransformFeedback
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
