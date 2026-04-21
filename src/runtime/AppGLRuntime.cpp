#include "AppGLRuntime.h"

#include <algorithm>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <execinfo.h>
#include <functional>
#include <sstream>
#include <unistd.h>
#include <unordered_set>

#include "../../include/AppGL/AppGL.h"
#include "../caps/GLCapabilities.h"
#include "../loader/DispatchInstall.h"
#include "../objects/GLObjectStore.h"
#include "../shared/JsonUtil.h"
#include "../state/GLStateTracker.h"

// Phase 8X Group 4d follow-up⁶ — compat-profile upload aliases. These
// enums were removed from the core profile in GL 3.2, so glcorearb.h does
// not expose them. AppGL still accepts them at the driver edge because
// font caches (FreeType, stb_truetype, BAR's glyph atlases) allocate
// GL_ALPHA8 / GL_LUMINANCE8 / GL_LUMINANCE8_ALPHA8 textures through
// glTexImage2D and upload single-channel glyph coverage bytes. The same
// #ifndef guards are used by GLCapabilities.mm to keep both sides of the
// upload path in sync without polluting the public glcorearb.h surface.
#ifndef GL_ALPHA8
#define GL_ALPHA8 0x803C
#endif
#ifndef GL_LUMINANCE
#define GL_LUMINANCE 0x1909
#endif
#ifndef GL_LUMINANCE_ALPHA
#define GL_LUMINANCE_ALPHA 0x190A
#endif
#ifndef GL_LUMINANCE8
#define GL_LUMINANCE8 0x8040
#endif
#ifndef GL_LUMINANCE8_ALPHA8
#define GL_LUMINANCE8_ALPHA8 0x8045
#endif
#ifndef GL_INTENSITY
#define GL_INTENSITY 0x8049
#endif
#ifndef GL_INTENSITY8
#define GL_INTENSITY8 0x804B
#endif

namespace appgl {

namespace {
thread_local GLContext* gCurrentContext = nullptr;
constexpr const char* kBootstrapTestId = "bootstrap.clear-loop";
constexpr const char* kPhaseAStateTestId = "phase-a.state";
constexpr const char* kPhaseADebugTestId = "phase-a.debug";
constexpr const char* kPhaseABufferTestId = "phase-a.buffers";
constexpr const char* kPhaseAVertexInputTestId = "phase-a.vertex-input";
constexpr const char* kPhaseATextureTestId = "phase-a.textures";
constexpr const char* kPhaseAFramebufferTestId = "phase-a.framebuffers";
constexpr const char* kPhaseAShaderTestId = "phase-a.shaders";
constexpr const char* kPhaseAProgramTestId = "phase-a.programs";
constexpr const char* kPhaseADrawTestId = "phase-a.draw";
constexpr GLuint kPhaseAMaxDrawBuffers = 8;
// Per-target maximum indexed buffer bindings. Must match the
// values advertised via GL_MAX_* queries in GLCapabilities — a
// lower dispatch-layer cap rejects spec-legal binding indices as
// INVALID_VALUE (CTS `shader_atomic_counter_ops_tests.*` binds
// ATOMIC_COUNTER_BUFFER at index 1, our cap says 8).
GLuint maxIndexedBindings(GLenum target) {
    switch (target) {
        case GL_TRANSFORM_FEEDBACK_BUFFER: return 4;   // GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS
        case GL_UNIFORM_BUFFER:            return 84;  // GL_MAX_UNIFORM_BUFFER_BINDINGS
        case GL_ATOMIC_COUNTER_BUFFER:     return 8;   // GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS
        case GL_SHADER_STORAGE_BUFFER:     return 8;   // GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS
        default: return 0;
    }
}
// Must match the cap reported via GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS in
// GLCapabilities (currently 80). CTS state reset iterates the reported cap
// via glActiveTexture(GL_TEXTURE0 + ndx) — a lower validator cap makes the
// loop blow up with GL_INVALID_ENUM and skips subsequent state reset steps.
constexpr GLuint kPhaseAMaxTextureUnits = 80;

GLContext* requireCurrentContext(std::string_view functionName) {
    auto* context = Runtime::shared().currentContext();
    if (context == nullptr) {
        Runtime::shared().recordBootstrapTrace(
            std::string(functionName) + ": no current context"
        );
    }
    return context;
}

std::string formatFloat(GLfloat value) {
    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(3);
    stream << value;
    return stream.str();
}

// Phase 8X Group 4d follow-up¹¹ — §Tertiary upload-rejection warning
// helper. `glTexImage2D` / `glTexSubImage2D` silently push
// GL_INVALID_ENUM when the caller hands them a `format` or `type`
// outside `isValidTextureUploadFormat` / `isValidTextureUploadType`
// (see AppGLRuntime.cpp:587+). On the GL error queue this shows up
// as a validation error but does not appear in the stderr capture
// BAR is grepping — so if Recoil uses `GL_UNSIGNED_INT_8_8_8_8_REV`
// or `GL_BGRA` for its glyph atlases the rejection is invisible in
// the log stream and the glyph bytes vanish without a trace.
//
// This emits one `[GL] WARNING:` stderr line the first time each
// distinct `(functionName, format, type, internalFormat)` tuple
// is rejected, so BAR can see which uploads are being dropped at
// the validator edge. Downstream of this function, execution still
// returns normally after `recordValidationError`.
void warnUploadRejectionOnce(const char* functionName,
                             GLenum format,
                             GLenum type,
                             GLenum internalFormat) {
    static std::unordered_set<std::uint64_t> warned;
    const std::uint64_t key =
        (static_cast<std::uint64_t>(std::hash<std::string>{}(functionName)) << 48)
        ^ (static_cast<std::uint64_t>(internalFormat) << 32)
        ^ (static_cast<std::uint64_t>(format) << 16)
        ^ static_cast<std::uint64_t>(type);
    if (warned.insert(key).second) {
        std::fprintf(stderr,
                     "[GL] WARNING: upload-rejection %s"
                     " internalFormat=0x%04X format=0x%04X type=0x%04X — "
                     "combination is outside the Phase A RGBA8 validator;"
                     " byte payload dropped at the entry point."
                     " Phase 8X Group 4d follow-up¹¹.\n",
                     functionName,
                     static_cast<unsigned>(internalFormat),
                     static_cast<unsigned>(format),
                     static_cast<unsigned>(type));
        std::fflush(stderr);
    }
}

void recordValidationError(GLContext* context, std::string_view functionName, GLenum error, std::string_view message) {
    if (context == nullptr) {
        return;
    }
    // Landing C 3g: pushError now forwards into Runtime::recordError so
    // the single call reaches both the per-context GL error queue and the
    // runtime diagnostics ring buffer. No more double-pushing.
    context->pushError(error, functionName, message);
    context->emitDebugMessage(
        GL_DEBUG_SOURCE_APPLICATION,
        GL_DEBUG_TYPE_ERROR,
        2,
        GL_DEBUG_SEVERITY_HIGH,
        std::string(functionName) + ": " + std::string(message)
    );
    Runtime::shared().recordBootstrapTrace(
        std::string(functionName) + " -> error " + std::to_string(error) + ": " + std::string(message)
    );
}

void markStateFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseAStateTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

// Phase A state mirror allowlist — every cap that glEnable/glDisable/glIsEnabled
// accepts without raising GL_INVALID_ENUM. Keeping this list explicit means BAR's
// audit can cross-reference which caps are supported against their InitGLState
// call sites. New caps land here as soon as a real engine call site needs them.
//
// Supported groups:
//   Raster/blending   : GL_BLEND, GL_CULL_FACE, GL_DEPTH_TEST, GL_STENCIL_TEST,
//                       GL_SCISSOR_TEST, GL_DITHER, GL_FRAMEBUFFER_SRGB
//   Polygon offsets   : GL_POLYGON_OFFSET_{FILL,LINE,POINT}
//   Primitive restart : GL_PRIMITIVE_RESTART, GL_PRIMITIVE_RESTART_FIXED_INDEX
//   Point/line/smooth : GL_PROGRAM_POINT_SIZE, GL_LINE_SMOOTH, GL_POLYGON_SMOOTH
//   MSAA              : GL_MULTISAMPLE, GL_SAMPLE_{ALPHA_TO_COVERAGE,
//                       ALPHA_TO_ONE,COVERAGE,MASK}
//   Transform fb      : GL_RASTERIZER_DISCARD
//   Cube map seamless : GL_TEXTURE_CUBE_MAP_SEAMLESS
//   Debug output      : GL_DEBUG_OUTPUT, GL_DEBUG_OUTPUT_SYNCHRONOUS
//   Clip distances    : GL_CLIP_DISTANCE0..GL_CLIP_DISTANCE7
//
// Anything outside this list pushes GL_INVALID_ENUM. That is the spec-correct
// behaviour for unknown caps — but the message also reports the raw enum in hex
// so the caller (or their diagnostic log) knows exactly which cap failed.
bool isValidEnableCap(GLenum cap) {
    if (cap >= GL_CLIP_DISTANCE0 && cap <= GL_CLIP_DISTANCE7) {
        return true;
    }
    switch (cap) {
        case GL_BLEND:
        case GL_CULL_FACE:
        case GL_DEBUG_OUTPUT:
        case GL_DEBUG_OUTPUT_SYNCHRONOUS:
        case GL_DEPTH_TEST:
        case GL_DITHER:
        case GL_LINE_SMOOTH:
        case GL_MULTISAMPLE:
        case GL_POLYGON_OFFSET_FILL:
        case GL_POLYGON_OFFSET_LINE:
        case GL_POLYGON_OFFSET_POINT:
        case GL_POLYGON_SMOOTH:
        case GL_PRIMITIVE_RESTART:
        case GL_PRIMITIVE_RESTART_FIXED_INDEX:
        case GL_PROGRAM_POINT_SIZE:
        case GL_RASTERIZER_DISCARD:
        case GL_SAMPLE_ALPHA_TO_COVERAGE:
        case GL_SAMPLE_ALPHA_TO_ONE:
        case GL_SAMPLE_COVERAGE:
        case GL_SAMPLE_MASK:
        case GL_SCISSOR_TEST:
        case GL_STENCIL_TEST:
        case GL_TEXTURE_CUBE_MAP_SEAMLESS:
        case GL_FRAMEBUFFER_SRGB:
        // GL 4.0 sample-rate shading. BAR's deferred-shading path probes
        // GL_SAMPLE_SHADING during its multisample-quality init step. The
        // toggle is a real core enum (added in GL_ARB_sample_shading) so
        // it belongs in the spec-valid list rather than the compat no-op
        // list. AppGL has no MSAA backend yet, so the enable simply
        // updates the state mirror without affecting the Metal pass.
        case GL_SAMPLE_SHADING:
        case GL_DEPTH_CLAMP:
            return true;
        default:
            return false;
    }
}

// Compat-profile glEnable/glDisable caps that AppGL accepts as silent
// no-ops. These are GL 1.x-era state toggles whose backing pipeline
// state was removed from core (3.2+), and which AppGL has no Metal-side
// equivalent for. Compat-profile engines call glEnable/glDisable with
// these caps during initialization without checking whether they're
// supported — silently accepting them keeps boot from tripping
// GL_INVALID_ENUM on every legacy state probe.
//
// "Silent" means: no error pushed, no state mirror update, but a trace
// is still recorded so diagnostics can show that the legacy cap was
// touched. glIsEnabled returns GL_FALSE for every cap in this set
// (matches the spec semantics of a disabled compat feature).
//
// Add a cap here only when a real engine call site needs it — keeping
// the list small means future debugging still has signal from
// "unhandled cap" errors for genuinely new probes.
//
// Currently:
//   GL_ALPHA_TEST     (0x0BC0) — alpha-test stage from compat fragment pipeline.
//   GL_LIGHTING       (0x0B50) — fixed-function lighting (compat-only since 3.1).
//   GL_TEXTURE_2D     (0x0DE1) — fixed-function texture-target enable; in core
//                                profile texture binding alone is sufficient,
//                                but compat engines still toggle it during
//                                init (e.g. BAR's CompoundDraw / TextureUtils).
//   GL_NORMALIZE      (0x0BA1) — fixed-function per-vertex normal rescaling.
//                                AppGL has no fixed-function lighting pipeline,
//                                so the normal-rescale state has no semantic.
//   GL_LIGHT0         (0x4000) — fixed-function light 0 enable. Phase 8X
//   GL_LIGHT1         (0x4001) — fixed-function light 1 enable. Group 4d
//                                follow-up¹⁸: BAR's `LuaOpenGL::ResetGLState`
//                                at `rts/Lua/LuaOpenGL.cpp:975,1046,1047`
//                                literally calls `glDisable(GL_LIGHT0)` and
//                                `glDisable(GL_LIGHT1)` on every frame-setup
//                                pass. These enums are spec-correct per
//                                `glad.h:1170-1171` — follow-up¹⁶ traced the
//                                `0x4001` trap to this `GL_LIGHT1` call site
//                                (not `GL_PARITY`, which was a bad guess in
//                                an earlier draft). AppGL has no fixed-
//                                function lighting pipeline, so silently
//                                accepting both lights is the right answer.
//   GL_LINE_STIPPLE   (0x0B24) — compat-profile line stippling. BAR's
//                                `LuaOpenGL::ResetGLState` disables it during
//                                state reset (`LuaOpenGL.cpp:517`). Metal
//                                has no line-stipple equivalent and AppGL
//                                never enables it, so disable is a no-op.
//   GL_COLOR_LOGIC_OP (0x0BF2) — compat-profile fragment logical-op stage.
//                                BAR's `LuaOpenGL::ResetGLState` disables it
//                                at `LuaOpenGL.cpp:533`. Metal supports a
//                                pipeline-level logic op but AppGL doesn't
//                                wire the compat toggle through to the
//                                Metal render-pipeline descriptor; silently
//                                accepting the disable is the correct
//                                semantic (the default is "off" anyway).
//   GL_TEXTURE_GEN_S  (0x0C60) — fixed-function per-coordinate automatic
//   GL_TEXTURE_GEN_T  (0x0C61)   texture-coordinate generation. Phase 8X
//   GL_TEXTURE_GEN_R  (0x0C62)   Group 4d follow-up¹⁹ — the legacy GLSL
//   GL_TEXTURE_GEN_Q  (0x0C63)   shader rewriter unlocks `#version 120/130`
//                                desktop shaders that Spring pairs with
//                                `glDisable(GL_TEXTURE_GEN_*)` in
//                                `LuaOpenGL::ResetGLState`. The fixed-
//                                function texgen stage was dropped in
//                                core 3.2 — translated shaders compute
//                                their own texture coordinates in the
//                                vertex stage — so silent accept is the
//                                correct no-op semantic.
//   GL_POINT_SPRITE   (0x8861) — compat-profile point-sprite mode. Phase
//                                8X Group 4d follow-up²⁰ — the fw¹⁹
//                                verification memo §5.1 pinned this as
//                                the loudest remaining uncovered cap
//                                enum, with ~5,030+ errorLog hits at
//                                the pre-crash sample. Spring's particle
//                                and billboard code enabled point-sprite
//                                mode in the GL 2.x / compat era; in
//                                core 3.2+ point sprites are the default
//                                (there's no toggle — `gl_PointCoord` is
//                                always available in the fragment stage),
//                                so silent accept is correct.
#ifndef GL_ALPHA_TEST
#define GL_ALPHA_TEST 0x0BC0
#endif
#ifndef GL_LIGHTING
#define GL_LIGHTING 0x0B50
#endif
#ifndef GL_TEXTURE_2D
#define GL_TEXTURE_2D 0x0DE1
#endif
#ifndef GL_NORMALIZE
#define GL_NORMALIZE 0x0BA1
#endif
#ifndef GL_LIGHT0
#define GL_LIGHT0 0x4000
#endif
#ifndef GL_LIGHT1
#define GL_LIGHT1 0x4001
#endif
#ifndef GL_LINE_STIPPLE
#define GL_LINE_STIPPLE 0x0B24
#endif
#ifndef GL_COLOR_LOGIC_OP
#define GL_COLOR_LOGIC_OP 0x0BF2
#endif
#ifndef GL_TEXTURE_GEN_S
#define GL_TEXTURE_GEN_S 0x0C60
#endif
#ifndef GL_TEXTURE_GEN_T
#define GL_TEXTURE_GEN_T 0x0C61
#endif
#ifndef GL_TEXTURE_GEN_R
#define GL_TEXTURE_GEN_R 0x0C62
#endif
#ifndef GL_TEXTURE_GEN_Q
#define GL_TEXTURE_GEN_Q 0x0C63
#endif
#ifndef GL_POINT_SPRITE
#define GL_POINT_SPRITE 0x8861
#endif
bool isCompatNoOpEnableCap(GLenum cap) {
    switch (cap) {
        case GL_ALPHA_TEST:
        case GL_LIGHTING:
        case GL_TEXTURE_2D:
        case GL_NORMALIZE:
        case GL_LIGHT0:
        case GL_LIGHT1:
        case GL_LINE_STIPPLE:
        case GL_COLOR_LOGIC_OP:
        case GL_TEXTURE_GEN_S:
        case GL_TEXTURE_GEN_T:
        case GL_TEXTURE_GEN_R:
        case GL_TEXTURE_GEN_Q:
        case GL_POINT_SPRITE:
            return true;
        default:
            return false;
    }
}

// Known enums that real GL applications probe to detect attached debug tools
// even though they are not spec-valid cap arguments. These MUST still return
// GL_FALSE from glIsEnabled AND push GL_INVALID_ENUM (because that is how the
// probing app detects "no debug tool attached" — see e.g. Recoil's RenderDoc
// check at rts/Rendering/GlobalRendering.cpp:929). The tracked list exists
// purely so the diagnostic error message can flag the probe as *expected*
// rather than *unhandled cap in the state mirror*.
bool isKnownDebugToolProbeEnum(GLenum cap) {
    switch (cap) {
        // GL_DEBUG_TOOL_EXT — RenderDoc probe, spec at renderdoc.org/debug_tool.txt
        case 0x6789:
            return true;
        default:
            return false;
    }
}

// Build an error message that names the raw cap enum so diagnostic logs point
// at the exact value the caller passed. Hex is the native GL convention; the
// helper also flags known probe enums so they're recognizable in the ring.
std::string buildUnknownCapMessage(GLenum cap) {
    std::ostringstream hex;
    hex << "0x" << std::hex << std::uppercase << cap;
    if (isKnownDebugToolProbeEnum(cap)) {
        std::ostringstream out;
        out << "known debug-tool probe enum " << hex.str()
            << " (e.g. RenderDoc GL_DEBUG_TOOL_EXT; GL_INVALID_ENUM is spec-correct)";
        return out.str();
    }
    std::ostringstream out;
    out << "unknown cap enum " << hex.str()
        << " (not in Phase A state mirror allowlist)";
    return out.str();
}

bool isValidBlendFactor(GLenum factor) {
    switch (factor) {
        case GL_ZERO:
        case GL_ONE:
        case GL_SRC_COLOR:
        case GL_ONE_MINUS_SRC_COLOR:
        case GL_DST_COLOR:
        case GL_ONE_MINUS_DST_COLOR:
        case GL_SRC_ALPHA:
        case GL_ONE_MINUS_SRC_ALPHA:
        case GL_DST_ALPHA:
        case GL_ONE_MINUS_DST_ALPHA:
        case GL_CONSTANT_COLOR:
        case GL_ONE_MINUS_CONSTANT_COLOR:
        case GL_CONSTANT_ALPHA:
        case GL_ONE_MINUS_CONSTANT_ALPHA:
        case GL_SRC_ALPHA_SATURATE:
        case GL_SRC1_COLOR:
        case GL_ONE_MINUS_SRC1_COLOR:
        case GL_SRC1_ALPHA:
        case GL_ONE_MINUS_SRC1_ALPHA:
            return true;
        default:
            return false;
    }
}

bool isValidBlendEquation(GLenum equation) {
    switch (equation) {
        case GL_FUNC_ADD:
        case GL_FUNC_SUBTRACT:
        case GL_FUNC_REVERSE_SUBTRACT:
        case GL_MIN:
        case GL_MAX:
            return true;
        default:
            return false;
    }
}

bool isValidCompareFunc(GLenum func) {
    switch (func) {
        case GL_NEVER:
        case GL_LESS:
        case GL_EQUAL:
        case GL_LEQUAL:
        case GL_GREATER:
        case GL_NOTEQUAL:
        case GL_GEQUAL:
        case GL_ALWAYS:
            return true;
        default:
            return false;
    }
}

bool isValidStencilOp(GLenum op) {
    switch (op) {
        case GL_KEEP:
        case GL_ZERO:
        case GL_REPLACE:
        case GL_INCR:
        case GL_INCR_WRAP:
        case GL_DECR:
        case GL_DECR_WRAP:
        case GL_INVERT:
            return true;
        default:
            return false;
    }
}

bool isValidStencilFace(GLenum face) {
    return face == GL_FRONT || face == GL_BACK || face == GL_FRONT_AND_BACK;
}

bool isValidCullFaceMode(GLenum mode) {
    return mode == GL_FRONT || mode == GL_BACK || mode == GL_FRONT_AND_BACK;
}

bool isValidFrontFace(GLenum mode) {
    return mode == GL_CW || mode == GL_CCW;
}

bool isValidHintTarget(GLenum target) {
    switch (target) {
        case GL_FRAGMENT_SHADER_DERIVATIVE_HINT:
        case GL_LINE_SMOOTH_HINT:
        case GL_POLYGON_SMOOTH_HINT:
        case GL_TEXTURE_COMPRESSION_HINT:
            return true;
        default:
            return false;
    }
}

bool isValidHintMode(GLenum mode) {
    return mode == GL_FASTEST || mode == GL_NICEST || mode == GL_DONT_CARE;
}

bool isValidBufferTarget(GLenum target) {
    switch (target) {
        case GL_ARRAY_BUFFER:
        case GL_ELEMENT_ARRAY_BUFFER:
        case GL_COPY_READ_BUFFER:
        case GL_COPY_WRITE_BUFFER:
        case GL_PIXEL_PACK_BUFFER:
        case GL_PIXEL_UNPACK_BUFFER:
        case GL_TRANSFORM_FEEDBACK_BUFFER:
        case GL_UNIFORM_BUFFER:
        case GL_TEXTURE_BUFFER:
        case GL_DRAW_INDIRECT_BUFFER:
        case GL_ATOMIC_COUNTER_BUFFER:
        case GL_DISPATCH_INDIRECT_BUFFER:
        case GL_SHADER_STORAGE_BUFFER:
        case GL_QUERY_BUFFER:
        case GL_PARAMETER_BUFFER:
            return true;
        default:
            return false;
    }
}

bool isValidIndexedBufferTarget(GLenum target) {
    switch (target) {
        case GL_TRANSFORM_FEEDBACK_BUFFER:
        case GL_UNIFORM_BUFFER:
        case GL_ATOMIC_COUNTER_BUFFER:
        case GL_SHADER_STORAGE_BUFFER:
            return true;
        default:
            return false;
    }
}

bool isValidBufferUsage(GLenum usage) {
    switch (usage) {
        case GL_STREAM_DRAW:
        case GL_STREAM_READ:
        case GL_STREAM_COPY:
        case GL_STATIC_DRAW:
        case GL_STATIC_READ:
        case GL_STATIC_COPY:
        case GL_DYNAMIC_DRAW:
        case GL_DYNAMIC_READ:
        case GL_DYNAMIC_COPY:
            return true;
        default:
            return false;
    }
}

bool isValidMapBufferAccess(GLenum access) {
    return access == GL_READ_ONLY || access == GL_WRITE_ONLY || access == GL_READ_WRITE;
}

bool isValidMapBufferRangeAccess(GLbitfield access) {
    constexpr GLbitfield kSupportedAccessBits = GL_MAP_READ_BIT
        | GL_MAP_WRITE_BIT
        | GL_MAP_INVALIDATE_RANGE_BIT
        | GL_MAP_INVALIDATE_BUFFER_BIT
        | GL_MAP_FLUSH_EXPLICIT_BIT
        | GL_MAP_UNSYNCHRONIZED_BIT
        | GL_MAP_PERSISTENT_BIT
        | GL_MAP_COHERENT_BIT;
    if ((access & ~kSupportedAccessBits) != 0) {
        return false;
    }

    const bool readable = (access & GL_MAP_READ_BIT) != 0;
    const bool writable = (access & GL_MAP_WRITE_BIT) != 0;
    if (!readable && !writable) {
        return false;
    }
    if (readable && (access & (GL_MAP_INVALIDATE_RANGE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT | GL_MAP_UNSYNCHRONIZED_BIT)) != 0) {
        return false;
    }
    if ((access & GL_MAP_FLUSH_EXPLICIT_BIT) != 0 && !writable) {
        return false;
    }
    return true;
}

bool isValidBufferParameterPname(GLenum pname) {
    switch (pname) {
        case GL_BUFFER_SIZE:
        case GL_BUFFER_USAGE:
        case GL_BUFFER_ACCESS:
        case GL_BUFFER_ACCESS_FLAGS:
        case GL_BUFFER_MAPPED:
        case GL_BUFFER_MAP_OFFSET:
        case GL_BUFFER_MAP_LENGTH:
        case GL_BUFFER_IMMUTABLE_STORAGE:
        case GL_BUFFER_STORAGE_FLAGS:
            return true;
        default:
            return false;
    }
}

void markBufferFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseABufferTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

void markShaderFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseAShaderTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

void markProgramFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseAProgramTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

void markDrawFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseADrawTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

bool isValidVertexAttribPointerType(GLenum type) {
    switch (type) {
        case GL_BYTE:
        case GL_UNSIGNED_BYTE:
        case GL_SHORT:
        case GL_UNSIGNED_SHORT:
        case GL_INT:
        case GL_UNSIGNED_INT:
        case GL_HALF_FLOAT:
        case GL_FLOAT:
        case GL_DOUBLE:
        case GL_FIXED:
        case GL_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:  // GL 4.4 §10.3.8 packed float
            return true;
        default:
            return false;
    }
}

bool isValidVertexAttribIPointerType(GLenum type) {
    switch (type) {
        case GL_BYTE:
        case GL_UNSIGNED_BYTE:
        case GL_SHORT:
        case GL_UNSIGNED_SHORT:
        case GL_INT:
        case GL_UNSIGNED_INT:
            return true;
        default:
            return false;
    }
}

bool isValidVertexAttribPname(GLenum pname) {
    switch (pname) {
        case GL_VERTEX_ATTRIB_ARRAY_ENABLED:
        case GL_VERTEX_ATTRIB_ARRAY_SIZE:
        case GL_VERTEX_ATTRIB_ARRAY_STRIDE:
        case GL_VERTEX_ATTRIB_ARRAY_TYPE:
        case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED:
        case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING:
        case GL_VERTEX_ATTRIB_ARRAY_INTEGER:
        case GL_VERTEX_ATTRIB_ARRAY_DIVISOR:
        case GL_VERTEX_ATTRIB_ARRAY_LONG:
        case GL_CURRENT_VERTEX_ATTRIB:
        // GL 4.3+ separated vertex format (ARB_vertex_attrib_binding).
        // `GL_VERTEX_ATTRIB_BINDING` returns the binding index the
        // attribute is linked to (default = attribute index), and
        // `GL_VERTEX_ATTRIB_RELATIVE_OFFSET` returns the member
        // offset within the vertex stride. CTS
        // `vertex_attrib_binding.basic-state*` queries both.
        case GL_VERTEX_ATTRIB_BINDING:
        case GL_VERTEX_ATTRIB_RELATIVE_OFFSET:
            return true;
        default:
            return false;
    }
}

void markVertexInputFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseAVertexInputTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

bool isValidTextureTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_1D:
        case GL_TEXTURE_2D:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_1D_ARRAY:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_RECTANGLE:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_BUFFER:
        case GL_TEXTURE_2D_MULTISAMPLE:
        case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
            return true;
        default:
            return false;
    }
}

bool isValidLegacyUploadInternalFormat(GLenum internalFormat) {
    // Accept all sized internal formats that GL 4.6 allows for glTexImage*.
    // The legacy validator previously restricted this to 8-bit unorm only;
    // widened now so CTS format/type coverage tests can reach the upload path.
    switch (internalFormat) {
        // Unsized (base) formats
        case GL_RED:
        case GL_RG:
        case GL_RGB:
        case GL_RGBA:
        // 8-bit unorm
        case GL_R8:
        case GL_RG8:
        case GL_RGB8:
        case GL_RGBA8:
        // 8-bit snorm
        case GL_R8_SNORM:
        case GL_RG8_SNORM:
        case GL_RGB8_SNORM:
        case GL_RGBA8_SNORM:
        // 16-bit unorm / snorm
        case GL_R16:
        case GL_RG16:
        case GL_RGB16:
        case GL_RGBA16:
        case GL_R16_SNORM:
        case GL_RG16_SNORM:
        case GL_RGB16_SNORM:
        case GL_RGBA16_SNORM:
        // Float formats
        case GL_R16F:
        case GL_RG16F:
        case GL_RGB16F:
        case GL_RGBA16F:
        case GL_R32F:
        case GL_RG32F:
        case GL_RGB32F:
        case GL_RGBA32F:
        // Integer formats (signed)
        case GL_R8I:
        case GL_RG8I:
        case GL_RGB8I:
        case GL_RGBA8I:
        case GL_R16I:
        case GL_RG16I:
        case GL_RGB16I:
        case GL_RGBA16I:
        case GL_R32I:
        case GL_RG32I:
        case GL_RGB32I:
        case GL_RGBA32I:
        // Integer formats (unsigned)
        case GL_R8UI:
        case GL_RG8UI:
        case GL_RGB8UI:
        case GL_RGBA8UI:
        case GL_R16UI:
        case GL_RG16UI:
        case GL_RGB16UI:
        case GL_RGBA16UI:
        case GL_R32UI:
        case GL_RG32UI:
        case GL_RGB32UI:
        case GL_RGBA32UI:
        // Packed / special formats
        case GL_R11F_G11F_B10F:
        case GL_RGB9_E5:
        case GL_RGB10_A2:
        case GL_RGB10_A2UI:
        case GL_RGB565:
        // sRGB
        case GL_SRGB8:
        case GL_SRGB8_ALPHA8:
        // Depth / stencil
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32F:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
        case GL_STENCIL_INDEX8:
        // Legacy low-precision / packed sized formats (upcast to RGBA8 /
        // nearest Metal format in buildRGBA8Upload). CTS copy_image and a
        // handful of format/type tests still exercise these.
        case GL_R3_G3_B2:
        case GL_RGBA2:
        case GL_RGB4:
        case GL_RGB5:
        case GL_RGBA4:
        case GL_RGB5_A1:
        case GL_RGB10:
        case GL_RGB12:
        case GL_RGBA12:
        // Compat-profile aliases (upcast to RGBA8 in buildRGBA8Upload)
        case GL_ALPHA:
        case GL_ALPHA8:
        case GL_LUMINANCE:
        case GL_LUMINANCE8:
        case GL_LUMINANCE_ALPHA:
        case GL_LUMINANCE8_ALPHA8:
        case GL_INTENSITY:
        case GL_INTENSITY8:
        // Generic "compressed" internal formats — GL 4.6 §8.5.3 allows
        // the driver to keep uncompressed, so treat them as aliases to
        // the uncompressed base format. `metalRenderbufferFormat` maps
        // each to the corresponding Metal uncompressed pixel format.
        case GL_COMPRESSED_RED:
        case GL_COMPRESSED_RG:
        case GL_COMPRESSED_RGB:
        case GL_COMPRESSED_RGBA:
        case GL_COMPRESSED_SRGB:
        case GL_COMPRESSED_SRGB_ALPHA:
            return true;
        default:
            return false;
    }
}

bool isValidStorageInternalFormat(GLContext* context, GLenum internalFormat) {
    // Permissive validator used by glTexStorage* / glTexBufferRange — the
    // internal-format set here is anything the capabilities format table
    // registers (Phase 8X Landing C 3b: float / packed / integer /
    // compressed / sRGB / depth formats), plus the unsized named color
    // aliases that GL 4.6 still accepts on allocation entry points.
    switch (internalFormat) {
        case GL_RED:
        case GL_RG:
        case GL_RGB:
        case GL_RGBA:
            return true;
        default:
            break;
    }
    if (context == nullptr) {
        return false;
    }
    return context->capabilities().isSupportedInternalFormat(internalFormat);
}

bool isValidTextureUploadFormat(GLenum format) {
    // GL 4.6 base formats accepted by glTexImage* / glTexSubImage* for the
    // format parameter. Widened from the original RED/RG/RGB/RGBA-only set
    // to include integer variants, depth/stencil, and BGR ordering.
    switch (format) {
        case GL_RED:
        case GL_RG:
        case GL_RGB:
        case GL_RGBA:
        case GL_BGR:
        case GL_BGRA:
        case GL_RED_INTEGER:
        case GL_RG_INTEGER:
        case GL_RGB_INTEGER:
        case GL_RGBA_INTEGER:
        case GL_BGR_INTEGER:
        case GL_BGRA_INTEGER:
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_STENCIL:
        case GL_STENCIL_INDEX:
        // Compat-profile aliases
        case GL_ALPHA:
        case GL_LUMINANCE:
        case GL_LUMINANCE_ALPHA:
        case GL_INTENSITY:
            return true;
        default:
            return false;
    }
}

bool isValidTextureUploadType(GLenum type) {
    // GL 4.6 pixel data types accepted by glTexImage* / glTexSubImage* /
    // glReadPixels. Widened from GL_UNSIGNED_BYTE-only to include all
    // standard types and packed integer variants.
    switch (type) {
        case GL_UNSIGNED_BYTE:
        case GL_BYTE:
        case GL_UNSIGNED_SHORT:
        case GL_SHORT:
        case GL_UNSIGNED_INT:
        case GL_INT:
        case GL_HALF_FLOAT:
        case GL_FLOAT:
        case GL_UNSIGNED_BYTE_3_3_2:
        case GL_UNSIGNED_BYTE_2_3_3_REV:
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_5_6_5_REV:
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        case GL_UNSIGNED_INT_8_8_8_8:
        case GL_UNSIGNED_INT_8_8_8_8_REV:
        case GL_UNSIGNED_INT_10_10_10_2:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_24_8:
        case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
        case GL_UNSIGNED_INT_5_9_9_9_REV:
            return true;
        default:
            return false;
    }
}

// Check if the upload format (e.g., GL_RED, GL_RED_INTEGER, GL_DEPTH_COMPONENT)
// is compatible with the internal format (e.g., GL_R8, GL_R8I, GL_DEPTH_COMPONENT16).
// Returns false for mismatches like uploading depth data to a color texture.
bool isFormatCompatibleWithInternalFormat(GLenum format, GLenum internalFormat) {
    // Classify the upload format
    const bool isDepthFormat = (format == GL_DEPTH_COMPONENT);
    const bool isDepthStencilFormat = (format == GL_DEPTH_STENCIL);
    const bool isStencilFormat = (format == GL_STENCIL_INDEX);
    const bool isIntegerFormat = (format == GL_RED_INTEGER || format == GL_RG_INTEGER
        || format == GL_RGB_INTEGER || format == GL_RGBA_INTEGER
        || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER);
    const bool isColorFormat = !isDepthFormat && !isDepthStencilFormat
        && !isStencilFormat && !isIntegerFormat;

    // Classify the internal format
    switch (internalFormat) {
        // Depth internal formats
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32F:
            return isDepthFormat;
        // Depth-stencil internal formats
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return isDepthStencilFormat;
        // Stencil internal format
        case GL_STENCIL_INDEX:
        case GL_STENCIL_INDEX8:
            return isStencilFormat;
        // Integer internal formats — require _INTEGER upload format
        case GL_R8I: case GL_R8UI: case GL_R16I: case GL_R16UI: case GL_R32I: case GL_R32UI:
        case GL_RG8I: case GL_RG8UI: case GL_RG16I: case GL_RG16UI: case GL_RG32I: case GL_RG32UI:
        case GL_RGB8I: case GL_RGB8UI: case GL_RGB16I: case GL_RGB16UI: case GL_RGB32I: case GL_RGB32UI:
        case GL_RGBA8I: case GL_RGBA8UI: case GL_RGBA16I: case GL_RGBA16UI: case GL_RGBA32I: case GL_RGBA32UI:
        case GL_RGB10_A2UI:
            return isIntegerFormat;
        // Everything else is a color (non-integer) internal format
        default:
            return isColorFormat;
    }
}

// Format-type compatibility per GL 4.6 §8.4.4.2 Table 8.7 (texture
// upload) and §18.3.2 Table 18.2 (readback). Plain integer/float types
// are compatible with any base format; packed types are constrained
// to specific format families. Used by glTexImage* / glTexSubImage* /
// glReadPixels paths to reject invalid combos that the pre-this-fix
// code accepted silently — matches CTS packed_pixels expectations.
bool isFormatTypeCompatible(GLenum format, GLenum type) {
    // Classify the base format.
    const bool isDepthFormat = (format == GL_DEPTH_COMPONENT);
    const bool isDepthStencilFormat = (format == GL_DEPTH_STENCIL);
    const bool isStencilFormat = (format == GL_STENCIL_INDEX);
    const bool isIntegerFormat = (format == GL_RED_INTEGER || format == GL_RG_INTEGER
        || format == GL_RGB_INTEGER || format == GL_RGBA_INTEGER
        || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER
        || format == GL_GREEN_INTEGER || format == GL_BLUE_INTEGER);
    const bool isRGB = (format == GL_RGB || format == GL_RGB_INTEGER);
    const bool isBGR = (format == GL_BGR || format == GL_BGR_INTEGER);
    const bool isRGBA_family = (format == GL_RGBA || format == GL_RGBA_INTEGER
        || format == GL_BGRA || format == GL_BGRA_INTEGER);

    switch (type) {
        // Plain integer/float types accept any base color format, plus
        // depth/stencil under narrow rules that CTS enforces via
        // isFormatCompatibleWithInternalFormat rather than here.
        case GL_UNSIGNED_BYTE:
        case GL_BYTE:
        case GL_UNSIGNED_SHORT:
        case GL_SHORT:
        case GL_UNSIGNED_INT:
        case GL_INT:
        case GL_HALF_FLOAT:
        case GL_FLOAT:
            // Float type with integer format is invalid (Table 8.7 "F"
            // column rejects *_INTEGER formats).
            if (type == GL_FLOAT || type == GL_HALF_FLOAT) {
                return !isIntegerFormat;
            }
            return true;
        // RGB-packed types: format must be one of GL_RGB / GL_RGB_INTEGER.
        case GL_UNSIGNED_BYTE_3_3_2:
        case GL_UNSIGNED_BYTE_2_3_3_REV:
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_5_6_5_REV:
            return isRGB;
        // RGBA-packed types: format must be GL_RGBA / GL_BGRA (or their
        // _INTEGER variants).
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        case GL_UNSIGNED_INT_8_8_8_8:
        case GL_UNSIGNED_INT_8_8_8_8_REV:
        case GL_UNSIGNED_INT_10_10_10_2:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
            return isRGBA_family;
        // Depth-stencil packed types.
        case GL_UNSIGNED_INT_24_8:
        case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
            return isDepthStencilFormat;
        // Float-packed RGB types (§8.4.4.2): RGB only, non-integer.
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
        case GL_UNSIGNED_INT_5_9_9_9_REV:
            return format == GL_RGB;
        default:
            // Unknown type — don't reject here; the type-validity check
            // catches truly invalid enums.
            return true;
    }
    (void)isBGR; (void)isDepthFormat; (void)isStencilFormat;
}

}  // end file-local anonymous namespace scope for isFormatTypeCompatible

// Re-expose at namespace appgl {} scope so GLContext.mm's readPixels
// path can link against it. The anonymous-namespace copy above is
// the definition; this pass-through provides external linkage.
bool isFormatTypeCompatible_extern(GLenum format, GLenum type);
bool isFormatTypeCompatible_extern(GLenum format, GLenum type) {
    return isFormatTypeCompatible(format, type);
}

namespace {

bool isValidTextureFilter(GLint filter, bool minFilter) {
    if (filter == GL_NEAREST || filter == GL_LINEAR) {
        return true;
    }
    return minFilter
        && (filter == GL_NEAREST_MIPMAP_NEAREST
            || filter == GL_LINEAR_MIPMAP_NEAREST
            || filter == GL_NEAREST_MIPMAP_LINEAR
            || filter == GL_LINEAR_MIPMAP_LINEAR);
}

bool isValidTextureWrap(GLint wrap) {
    return wrap == GL_REPEAT || wrap == GL_MIRRORED_REPEAT || wrap == GL_CLAMP_TO_EDGE || wrap == GL_CLAMP_TO_BORDER;
}

bool isValidTextureCompareMode(GLint mode) {
    return mode == GL_NONE || mode == GL_COMPARE_REF_TO_TEXTURE;
}

bool isValidTextureSwizzle(GLint value) {
    return value == GL_RED || value == GL_GREEN || value == GL_BLUE || value == GL_ALPHA || value == GL_ZERO || value == GL_ONE;
}

bool isValidTextureParameterPname(GLenum pname) {
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
        case GL_TEXTURE_MAG_FILTER:
        case GL_TEXTURE_WRAP_S:
        case GL_TEXTURE_WRAP_T:
        case GL_TEXTURE_WRAP_R:
        case GL_TEXTURE_MIN_LOD:
        case GL_TEXTURE_MAX_LOD:
        case GL_TEXTURE_BASE_LEVEL:
        case GL_TEXTURE_MAX_LEVEL:
        case GL_TEXTURE_COMPARE_MODE:
        case GL_TEXTURE_COMPARE_FUNC:
        case GL_TEXTURE_BORDER_COLOR:
        case GL_TEXTURE_SWIZZLE_R:
        case GL_TEXTURE_SWIZZLE_G:
        case GL_TEXTURE_SWIZZLE_B:
        case GL_TEXTURE_SWIZZLE_A:
        case GL_TEXTURE_SWIZZLE_RGBA:
        case GL_TEXTURE_LOD_BIAS:
        case GL_TEXTURE_MAX_ANISOTROPY:
        case GL_DEPTH_STENCIL_TEXTURE_MODE:
        // GL 4.6 §8.11 storage-state pnames — valid for GetTexParameter*
        // only. The SetTextureParameter path rejects them via the
        // inner switch in `setTextureParameterInteger` (they don't
        // map to a settable field), so widening this validator just
        // moves the rejection from the dispatch layer to the context
        // layer without changing behaviour on the set path.
        // CTS `texture_border_clamp.gettexparameteri_errors` plants
        // IMMUTABLE_FORMAT on CUBE_MAP and asserts NO_ERROR.
        case GL_TEXTURE_IMMUTABLE_FORMAT:
        case GL_TEXTURE_IMMUTABLE_LEVELS:
        case GL_TEXTURE_VIEW_MIN_LEVEL:
        case GL_TEXTURE_VIEW_MIN_LAYER:
        case GL_TEXTURE_VIEW_NUM_LEVELS:
        case GL_TEXTURE_VIEW_NUM_LAYERS:
        case GL_TEXTURE_TARGET:
            return true;
        default:
            return false;
    }
}

bool isValidSamplerParameterPname(GLenum pname) {
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
        case GL_TEXTURE_MAG_FILTER:
        case GL_TEXTURE_WRAP_S:
        case GL_TEXTURE_WRAP_T:
        case GL_TEXTURE_WRAP_R:
        case GL_TEXTURE_MIN_LOD:
        case GL_TEXTURE_MAX_LOD:
        case GL_TEXTURE_LOD_BIAS:
        case GL_TEXTURE_COMPARE_MODE:
        case GL_TEXTURE_COMPARE_FUNC:
        case GL_TEXTURE_BORDER_COLOR:
        case GL_TEXTURE_MAX_ANISOTROPY:
            return true;
        default:
            return false;
    }
}

bool validateTextureParameterValues(GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return false;
    }
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
            return isValidTextureFilter(params[0], true);
        case GL_TEXTURE_MAG_FILTER:
            return isValidTextureFilter(params[0], false);
        case GL_TEXTURE_WRAP_S:
        case GL_TEXTURE_WRAP_T:
        case GL_TEXTURE_WRAP_R:
            return isValidTextureWrap(params[0]);
        case GL_TEXTURE_BASE_LEVEL:
        case GL_TEXTURE_MAX_LEVEL:
            return params[0] >= 0;
        case GL_TEXTURE_COMPARE_MODE:
            return isValidTextureCompareMode(params[0]);
        case GL_TEXTURE_COMPARE_FUNC:
            return isValidCompareFunc(static_cast<GLenum>(params[0]));
        case GL_TEXTURE_SWIZZLE_R:
        case GL_TEXTURE_SWIZZLE_G:
        case GL_TEXTURE_SWIZZLE_B:
        case GL_TEXTURE_SWIZZLE_A:
            return isValidTextureSwizzle(params[0]);
        case GL_TEXTURE_SWIZZLE_RGBA:
            return isValidTextureSwizzle(params[0])
                && isValidTextureSwizzle(params[1])
                && isValidTextureSwizzle(params[2])
                && isValidTextureSwizzle(params[3]);
        case GL_TEXTURE_MIN_LOD:
        case GL_TEXTURE_MAX_LOD:
        case GL_TEXTURE_BORDER_COLOR:
        case GL_TEXTURE_LOD_BIAS:
        case GL_TEXTURE_MAX_ANISOTROPY:
            return true;
        case GL_DEPTH_STENCIL_TEXTURE_MODE:
            return params[0] == GL_DEPTH_COMPONENT || params[0] == GL_STENCIL_INDEX;
        default:
            return false;
    }
}

bool validateTextureParameterValues(GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return false;
    }
    switch (pname) {
        case GL_TEXTURE_MIN_LOD:
        case GL_TEXTURE_MAX_LOD:
        case GL_TEXTURE_LOD_BIAS:
        case GL_TEXTURE_MAX_ANISOTROPY:
            return std::isfinite(params[0]);
        case GL_TEXTURE_BORDER_COLOR:
            return std::isfinite(params[0]) && std::isfinite(params[1])
                && std::isfinite(params[2]) && std::isfinite(params[3]);
        default: {
            GLint integerParams[4] = {static_cast<GLint>(params[0]), 0, 0, 0};
            if (pname == GL_TEXTURE_SWIZZLE_RGBA) {
                integerParams[1] = static_cast<GLint>(params[1]);
                integerParams[2] = static_cast<GLint>(params[2]);
                integerParams[3] = static_cast<GLint>(params[3]);
            }
            return validateTextureParameterValues(pname, integerParams);
        }
    }
}

bool isValidPixelStorePname(GLenum pname) {
    switch (pname) {
        case GL_PACK_SWAP_BYTES:
        case GL_PACK_LSB_FIRST:
        case GL_PACK_ROW_LENGTH:
        case GL_PACK_SKIP_ROWS:
        case GL_PACK_SKIP_PIXELS:
        case GL_PACK_ALIGNMENT:
        case GL_PACK_IMAGE_HEIGHT:
        case GL_PACK_SKIP_IMAGES:
        case GL_UNPACK_SWAP_BYTES:
        case GL_UNPACK_LSB_FIRST:
        case GL_UNPACK_ROW_LENGTH:
        case GL_UNPACK_SKIP_ROWS:
        case GL_UNPACK_SKIP_PIXELS:
        case GL_UNPACK_ALIGNMENT:
        case GL_UNPACK_IMAGE_HEIGHT:
        case GL_UNPACK_SKIP_IMAGES:
            return true;
        default:
            return false;
    }
}

bool isValidPixelStoreValue(GLenum pname, GLint value) {
    switch (pname) {
        case GL_PACK_ALIGNMENT:
        case GL_UNPACK_ALIGNMENT:
            return value == 1 || value == 2 || value == 4 || value == 8;
        case GL_PACK_SWAP_BYTES:
        case GL_PACK_LSB_FIRST:
        case GL_UNPACK_SWAP_BYTES:
        case GL_UNPACK_LSB_FIRST:
            return value == GL_FALSE || value == GL_TRUE;
        default:
            return value >= 0;
    }
}

bool isValidFramebufferTarget(GLenum target) {
    return target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER;
}

bool isValidRenderbufferTarget(GLenum target) {
    return target == GL_RENDERBUFFER;
}

bool isValidRenderbufferFormat(GLenum internalFormat) {
    switch (internalFormat) {
        // Unsized color
        case GL_RGB:
        case GL_RGBA:
        // Sized color (8-bit)
        case GL_RGB8:
        case GL_RGBA8:
        case GL_R8:
        case GL_R8_SNORM:
        case GL_R8I:
        case GL_R8UI:
        case GL_RG8:
        case GL_RG8_SNORM:
        case GL_RG8I:
        case GL_RG8UI:
        case GL_RGBA8_SNORM:
        case GL_RGBA8I:
        case GL_RGBA8UI:
        case GL_SRGB8_ALPHA8:
        // Sized color (16-bit)
        case GL_R16:
        case GL_R16_SNORM:
        case GL_R16F:
        case GL_R16I:
        case GL_R16UI:
        case GL_RG16:
        case GL_RG16_SNORM:
        case GL_RG16F:
        case GL_RG16I:
        case GL_RG16UI:
        case GL_RGBA16:
        case GL_RGBA16_SNORM:
        case GL_RGBA16F:
        case GL_RGBA16I:
        case GL_RGBA16UI:
        // Sized color (32-bit)
        case GL_R32F:
        case GL_R32I:
        case GL_R32UI:
        case GL_RG32F:
        case GL_RG32I:
        case GL_RG32UI:
        case GL_RGBA32F:
        case GL_RGBA32I:
        case GL_RGBA32UI:
        // Packed color
        case GL_RGB10_A2:
        case GL_RGB10_A2UI:
        case GL_R11F_G11F_B10F:
        case GL_RGB9_E5:
        case GL_RGB565:
        // sRGB
        case GL_SRGB8:
        // RGB-only sized (no explicit alpha). Not strictly color-renderable
        // in GL 4.6 core, but CTS copy_image exercises these against
        // glRenderbufferStorage and expects no API-level error. Backing
        // store falls back to the nearest Metal renderable format.
        case GL_RGB8_SNORM:
        case GL_RGB16:
        case GL_RGB16_SNORM:
        case GL_RGB16F:
        case GL_RGB16I:
        case GL_RGB16UI:
        case GL_RGB32F:
        case GL_RGB32I:
        case GL_RGB32UI:
        case GL_RGB8I:
        case GL_RGB8UI:
        // Legacy low-precision / packed sized color formats. Same rationale
        // as the RGB-only block above.
        case GL_R3_G3_B2:
        case GL_RGB4:
        case GL_RGB5:
        case GL_RGB10:
        case GL_RGB12:
        case GL_RGBA2:
        case GL_RGBA4:
        case GL_RGB5_A1:
        case GL_RGBA12:
        // Depth
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32:
        case GL_DEPTH_COMPONENT32F:
        // Stencil
        case GL_STENCIL_INDEX:
        case GL_STENCIL_INDEX8:
        // Depth-stencil
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return true;
        default:
            return false;
    }
}

bool isValidRenderbufferParameterPname(GLenum pname) {
    switch (pname) {
        case GL_RENDERBUFFER_WIDTH:
        case GL_RENDERBUFFER_HEIGHT:
        case GL_RENDERBUFFER_INTERNAL_FORMAT:
        case GL_RENDERBUFFER_RED_SIZE:
        case GL_RENDERBUFFER_GREEN_SIZE:
        case GL_RENDERBUFFER_BLUE_SIZE:
        case GL_RENDERBUFFER_ALPHA_SIZE:
        case GL_RENDERBUFFER_DEPTH_SIZE:
        case GL_RENDERBUFFER_STENCIL_SIZE:
        case GL_RENDERBUFFER_SAMPLES:
            return true;
        default:
            return false;
    }
}

bool isValidFramebufferAttachment(GLenum attachment) {
    // GL 4.6 §9.2.8 distinguishes two classes of enum:
    //  • Recognised attachment name (color-attachment-shaped in the
    //    0..31 range, or depth/stencil variants) — this function
    //    returns true so the dispatch layer hands control off to
    //    `framebufferTexture` which can then distinguish
    //    "out-of-MAX-range" (INVALID_OPERATION) from "truly
    //    unrecognised enum" (INVALID_ENUM).
    //  • Unrecognised shape — return false so dispatch emits
    //    INVALID_ENUM directly.
    //
    // CTS `geometry_shader.layered_fbo.fb_texture_invalid_attachment`
    // uses `COLOR_ATTACHMENT0 + MAX_COLOR_ATTACHMENTS` which is a
    // valid shape but exceeds MAX — it expects INVALID_OPERATION
    // from the entry point, which requires the dispatch-level gate
    // to accept the enum and defer to the context-level check.
    return (attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT0 + 31)
        || attachment == GL_DEPTH_ATTACHMENT
        || attachment == GL_STENCIL_ATTACHMENT
        || attachment == GL_DEPTH_STENCIL_ATTACHMENT
        || attachment == GL_FRONT_LEFT
        || attachment == GL_FRONT_RIGHT
        || attachment == GL_BACK_LEFT
        || attachment == GL_BACK_RIGHT
        || attachment == GL_DEPTH
        || attachment == GL_STENCIL;
}

bool isValidFramebufferAttachmentPname(GLenum pname) {
    switch (pname) {
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE:
        case GL_FRAMEBUFFER_ATTACHMENT_LAYERED:
        case GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE:
        case GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE:
        case GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING:
            return true;
        default:
            return false;
    }
}

void markFramebufferFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseAFramebufferTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

void markTextureFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseATextureTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}

bool isValidDebugSource(GLenum source, bool allowDontCare) {
    if (allowDontCare && source == GL_DONT_CARE) {
        return true;
    }
    switch (source) {
        case GL_DEBUG_SOURCE_API:
        case GL_DEBUG_SOURCE_WINDOW_SYSTEM:
        case GL_DEBUG_SOURCE_SHADER_COMPILER:
        case GL_DEBUG_SOURCE_THIRD_PARTY:
        case GL_DEBUG_SOURCE_APPLICATION:
        case GL_DEBUG_SOURCE_OTHER:
            return true;
        default:
            return false;
    }
}

bool isValidDebugInsertSource(GLenum source) {
    return source == GL_DEBUG_SOURCE_APPLICATION || source == GL_DEBUG_SOURCE_THIRD_PARTY;
}

bool isValidDebugType(GLenum type, bool allowDontCare) {
    if (allowDontCare && type == GL_DONT_CARE) {
        return true;
    }
    switch (type) {
        case GL_DEBUG_TYPE_ERROR:
        case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR:
        case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR:
        case GL_DEBUG_TYPE_PORTABILITY:
        case GL_DEBUG_TYPE_PERFORMANCE:
        case GL_DEBUG_TYPE_OTHER:
        case GL_DEBUG_TYPE_MARKER:
        case GL_DEBUG_TYPE_PUSH_GROUP:
        case GL_DEBUG_TYPE_POP_GROUP:
            return true;
        default:
            return false;
    }
}

bool isValidDebugSeverity(GLenum severity, bool allowDontCare) {
    if (allowDontCare && severity == GL_DONT_CARE) {
        return true;
    }
    switch (severity) {
        case GL_DEBUG_SEVERITY_HIGH:
        case GL_DEBUG_SEVERITY_MEDIUM:
        case GL_DEBUG_SEVERITY_LOW:
        case GL_DEBUG_SEVERITY_NOTIFICATION:
            return true;
        default:
            return false;
    }
}

bool isValidDebugObjectIdentifier(GLenum identifier) {
    switch (identifier) {
        case GL_BUFFER:
        case GL_SHADER:
        case GL_PROGRAM:
        case GL_VERTEX_ARRAY:
        case GL_QUERY:
        case GL_PROGRAM_PIPELINE:
        case GL_TRANSFORM_FEEDBACK:
        case GL_SAMPLER:
        case GL_TEXTURE:
        case GL_RENDERBUFFER:
        case GL_FRAMEBUFFER:
            return true;
        default:
            return false;
    }
}

std::string stringFromGLText(GLsizei length, const GLchar* text) {
    if (text == nullptr) {
        return {};
    }
    if (length < 0) {
        return std::string(text);
    }
    return std::string(text, text + length);
}

void markDebugFunction(FunctionId id, std::string_view note) {
    Runtime::shared().coverageStore().markSmokeTested(id, kPhaseADebugTestId, note);
    Runtime::shared().refreshCurrentContextClaimedVersion();
}
}  // namespace

Runtime& Runtime::shared() {
    static Runtime runtime;
    return runtime;
}

Runtime::Runtime() {
    initializeDispatch();
    // Install crash handlers that print a backtrace on SIGBUS/SIGSEGV so we
    // can diagnose deterministic late-sweep crashes (e.g. the 12648-test
    // SIGBUS on program_interface_query.subroutines-vertex).
    auto crashHandler = +[](int sig) {
        const char* name = sig == SIGBUS ? "SIGBUS" :
                           sig == SIGSEGV ? "SIGSEGV" :
                           sig == SIGABRT ? "SIGABRT" : "signal";
        fprintf(stderr, "\n[CRASH] caught %s, backtrace:\n", name);
        void* frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, STDERR_FILENO);
        fflush(stderr);
        // Re-raise to preserve exit code.
        signal(sig, SIG_DFL);
        raise(sig);
    };
    signal(SIGBUS, crashHandler);
    signal(SIGSEGV, crashHandler);
}

void Runtime::initializeDispatch() {
    installBootstrapDispatch(dispatch_, coverageStore_);
}

GLDispatchTable& Runtime::dispatch() {
    return dispatch_;
}

const GLDispatchTable& Runtime::dispatch() const {
    return dispatch_;
}

void Runtime::recordFunctionInvocation(FunctionId id, std::string_view functionName) {
    coverageStore_.recordCall(id);
    traceLog_.append(std::string(functionName));
}

void Runtime::recordBootstrapTrace(std::string message) {
    traceLog_.append(std::move(message));
}

void Runtime::recordUnimplemented(FunctionId id, std::string_view functionName) {
    coverageStore_.markStubbed(id, "Entry point exported, but backend work is not implemented yet.");
    coverageStore_.recordUnimplementedHit(id);
    traceLog_.append(std::string(functionName) + " -> stubbed");
    if (gCurrentContext != nullptr) {
        // Landing C 3g: pushError forwards into Runtime::recordError, so a
        // single cross-wired call reaches both the glGetError queue and the
        // runtime ring buffer with the correct function tag. No more
        // separate recordError fan-out — the previous implementation
        // double-counted unimplemented hits because the context-level
        // pushError would emit an "<internal>" record alongside the
        // explicit named record.
        const std::string stubMessage =
            std::string(functionName) + " is not implemented in AppGL yet.";
        gCurrentContext->pushError(GL_INVALID_OPERATION, functionName, stubMessage);
        gCurrentContext->emitDebugMessage(
            GL_DEBUG_SOURCE_APPLICATION,
            GL_DEBUG_TYPE_ERROR,
            1,
            GL_DEBUG_SEVERITY_HIGH,
            stubMessage
        );
    } else {
        // No current context — fall back to direct ring buffer recording
        // so the unimplemented hit is still visible in the diagnostics
        // dump even when the failing call happened outside a live context.
        ErrorRecord record;
        record.function = std::string(functionName);
        record.errorEnum = GL_INVALID_OPERATION;
        record.message = std::string(functionName) + " is not implemented in AppGL yet.";
        recordError(std::move(record));
    }
}

// Names that should silently no-op rather than push a fixed-function-stub
// ring entry. These are compat-profile entry points BAR (and other engines)
// expect to work as no-ops under a core-profile-translated context — keeping
// them in the diagnostic ring is pure noise. Matches the spirit of
// `isCompatNoOpEnableCap` for cap enums.
//
// The bootstrap trace line still fires so coverage tooling can prove the
// stub was called; only the error-log push is skipped.
//
// To add a name: append it here, document why in a one-line comment, and the
// next BAR-side run will see one fewer steady-state errorLog entry.
static bool isSilentlyAcceptedFixedFunctionStub(std::string_view functionName) {
    // glPushAttrib / glPopAttrib: BAR's Lua bindings wrap every widget draw
    // in a save/restore-state pair, ~14 hits per frame in the select-menu
    // smoke. The underlying state mirror already absorbs the relevant
    // toggles, so the push/pop pair is a true no-op for the translated path.
    if (functionName == "glPushAttrib") return true;
    if (functionName == "glPopAttrib") return true;
    // glColor3f: rare hit from a single Lua widget code path (~1 per run).
    // The fixed-function colour register has no Metal analogue and BAR
    // never reads it back through GL — it ends up driving an immediate-mode
    // vertex stream that the translated pipeline doesn't sample.
    if (functionName == "glColor3f") return true;
    // Phase 8X Group 4d follow-up⁴ §6d — three more legacy compat entry
    // points BAR's verification round flagged as steady-state noise:
    //
    //   glColor4f    — same rationale as glColor3f, just the alpha-bearing
    //                  variant. The fixed-function colour register has no
    //                  Metal analogue and translated draws never sample it.
    //   glShadeModel — flat vs smooth shading is a vertex-output decoration
    //                  the translator handles via vertex-stage attribute
    //                  qualifiers, not a runtime toggle. The compat call is
    //                  a true no-op for translated programs.
    //   glRectf      — emits an immediate-mode quad. The translated path
    //                  never reaches the immediate-mode vertex stream the
    //                  compat profile would push, so there's no draw to
    //                  drop on the floor — the call is silently absorbed
    //                  the same way glBegin/glEnd are.
    if (functionName == "glColor4f") return true;
    if (functionName == "glShadeModel") return true;
    if (functionName == "glRectf") return true;
    // Phase 8X Group 4d follow-up¹⁸ — four more compat-profile fixed-function
    // entry points BAR's verification round pinned as steady-state noise, all
    // originating from `rts/Lua/LuaOpenGL::ResetGLState` at `LuaOpenGL.cpp`
    // lines 500-578 which runs on every widget-draw boundary:
    //
    //   glMaterialfv — fixed-function material-colour uploads for the legacy
    //                  lighting pipeline. AppGL has no fixed-function lighting
    //                  (see `isCompatNoOpEnableCap`'s GL_LIGHTING/GL_LIGHT0/
    //                  GL_LIGHT1 entries), so the material register is never
    //                  sampled. BAR's reset path calls it ~4 times per pass
    //                  with the ambient/diffuse/specular/emission slots.
    //   glMaterialf  — scalar variant for the shininess exponent. Same
    //                  rationale — the fixed-function lighting pipeline is
    //                  absent, so the exponent upload has no semantic.
    //   glAlphaFunc  — configures the compat-profile alpha-test comparison.
    //                  The associated GL_ALPHA_TEST cap is already on the
    //                  silent-accept cap allowlist; this adds the matching
    //                  configuration setter so the pair is symmetric and
    //                  the reset path stays noise-free.
    //   glTexEnvi    — fixed-function texture-environment combiner setup.
    //                  AppGL's translated path runs everything through
    //                  GLSL core-profile shaders, so the compat combiner
    //                  register has no effect on any draw.
    if (functionName == "glMaterialfv") return true;
    if (functionName == "glMaterialf") return true;
    if (functionName == "glAlphaFunc") return true;
    if (functionName == "glTexEnvi") return true;
    return false;
}

void Runtime::recordFixedFunctionStub(std::string_view functionName) {
    // Fixed-function compat-profile entry points intentionally no-op.
    // We publish a diagnostic ring entry (errorEnum = 0 so it doesn't
    // masquerade as a real GL error and doesn't reach the engine-facing
    // glGetError queue) that tooling can surface to show which legacy
    // symbols a client is touching. The ErrorRecord dedupe collapses
    // per-frame spam so a 120 Hz caller hitting glMatrixMode still
    // only produces a single ring entry with a bumped count.
    //
    // Names on the silent-accept allowlist skip the ring push entirely —
    // the bootstrap trace line still fires so the call is observable to
    // coverage tooling, but the steady-state error log stays clean.
    if (!isSilentlyAcceptedFixedFunctionStub(functionName)) {
        ErrorRecord record;
        record.function = std::string(functionName);
        record.errorEnum = 0;
        record.message = std::string(functionName) +
                         " is a fixed-function compat-profile entry point and is stubbed in AppGL.";
        recordError(std::move(record));
    }
    traceLog_.append(std::string(functionName) + " -> fixed-function stub");
}

void Runtime::makeCurrent(GLContext* context) {
    gCurrentContext = context;
    if (context != nullptr) {
        noteRenderer(context->rendererString());
        refreshCurrentContextClaimedVersion();
    }
}

GLContext* Runtime::currentContext() {
    return gCurrentContext;
}

void Runtime::registerContext(GLContext* context) {
    if (context == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(contextMutex_);
    liveContexts_.insert(context);
}

void Runtime::unregisterContext(GLContext* context) {
    if (context == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(contextMutex_);
    // Capture a final inventory BEFORE the context leaves the live set so a
    // post-mortem diagnostic dump (like the BAR engine's DestroyWindowAndContext
    // hook) can report non-zero counts even though the context is gone by the
    // time the writer runs. Runs under contextMutex_ so we know `context` is
    // still a live pointer; we cannot simply re-query after erase.
    snapshotContextInventoryLocked(context);
    liveContexts_.erase(context);
    // Clear the current-context slot on THIS thread if it still points at the
    // context being destroyed. Other threads cannot be reached through thread_local
    // storage, but isContextLiveLocked() protects diagnostic readers on those
    // threads from dereferencing a freed pointer.
    if (gCurrentContext == context) {
        gCurrentContext = nullptr;
    }
}

void Runtime::snapshotContextInventoryLocked(GLContext* context) {
    if (context == nullptr) {
        return;
    }
    auto& store = context->objects();
    InventorySnapshot snap;
    snap.valid = true;
    snap.buffers = store.buffers().size();
    snap.textures = store.textures().size();
    snap.samplers = store.samplers().size();
    snap.renderbuffers = store.renderbuffers().size();
    snap.framebuffers = store.framebuffers().size();
    snap.vertexArrays = store.vertexArrays().size();
    snap.shaders = store.shaders().size();
    snap.programs = store.programs().size();
    snap.queries = store.queries().size();
    snap.syncs = store.syncs().size();
    snap.transformFeedbacks = store.transformFeedbacks().size();
    store.buffers().forEach([&snap](GLuint, GLBufferObject& buffer) {
        snap.bufferBytes += static_cast<std::uint64_t>(buffer.size > 0 ? buffer.size : 0);
    });
    store.textures().forEach([&snap](GLuint, GLTextureObject& texture) {
        for (const auto& [level, image] : texture.levels) {
            (void)level;
            snap.textureBytes += static_cast<std::uint64_t>(image.rgba8.size());
        }
    });
    store.renderbuffers().forEach([&snap](GLuint, GLRenderbufferObject& rb) {
        snap.renderbufferBytes += static_cast<std::uint64_t>(rb.rgba8.size())
            + static_cast<std::uint64_t>(rb.depth32.size() * sizeof(GLfloat))
            + static_cast<std::uint64_t>(rb.stencil8.size());
    });
    const auto metrics = context->pipelineCacheMetrics();
    snap.pipelineCacheHits = metrics.hits;
    snap.pipelineCacheMisses = metrics.misses;
    // Phase 8X Group 4d follow-up⁴ — capture the new build attempt/failure
    // counters so the post-mortem snapshot disambiguates "never tried"
    // (attempts==0) from "tried and always failed" (attempts>0,
    // failures==attempts) at teardown time too.
    snap.pipelineBuildAttempts = metrics.buildAttempts;
    snap.pipelineBuildFailures = metrics.buildFailures;
    snap.pipelineCumulativeBuildMillis = metrics.cumulativeBuildMillis;
    lastKnownInventory_ = snap;
}

bool Runtime::isContextLiveLocked(GLContext* context) const {
    if (context == nullptr) {
        return false;
    }
    return liveContexts_.find(context) != liveContexts_.end();
}

std::mutex& Runtime::contextMutex() {
    return contextMutex_;
}

std::string Runtime::claimedVersionString() const {
    // Declarative constant (Phase 8X Landing C). See
    // CoverageStore::claimedVersion for the rationale — this is what
    // glGetString(GL_VERSION) reports, independent of coverage walk.
    return CoverageStore::claimedVersion();
}

void Runtime::refreshCurrentContextClaimedVersion() {
    if (gCurrentContext != nullptr) {
        gCurrentContext->setClaimedVersionString(claimedVersionString());
    }
}

void Runtime::noteRenderer(std::string renderer) {
    rendererString_ = std::move(renderer);
}

void Runtime::recordShaderTranslation(ShaderTranslationRecord record) {
    std::lock_guard<std::mutex> lock(translationMutex_);
    // Keep last 32 translations to avoid unbounded growth. The lifetime
    // counter below is intentionally independent of the ring size so test
    // harnesses can measure "how many records were pushed in this window"
    // as a simple (after - before) delta even after the ring has wrapped.
    if (shaderTranslations_.size() >= 32) {
        shaderTranslations_.erase(shaderTranslations_.begin());
    }
    shaderTranslations_.push_back(std::move(record));
    ++shaderTranslationsEverPushed_;
}

std::uint64_t Runtime::shaderTranslationCount() {
    std::lock_guard<std::mutex> lock(translationMutex_);
    return shaderTranslationsEverPushed_;
}

std::vector<Runtime::ShaderTranslationRecord> Runtime::shaderTranslationSnapshot() {
    std::lock_guard<std::mutex> lock(translationMutex_);
    return shaderTranslations_;
}

void Runtime::recordError(ErrorRecord record) {
    std::lock_guard<std::mutex> lock(errorLogMutex_);
    // Every observed error event bumps the lifetime counter, including
    // the dedupe-collapse path below. Test harnesses use the counter
    // delta to assert "this call recorded an error" in a way that is
    // robust to ring eviction AND duplicate collapsing — asserting on
    // errorLog_.size() fails in both of those cases even though the
    // error was correctly captured.
    ++errorLogEventsObserved_;
    // Collapse into the previous entry if it's the same function+error enum.
    // Spammy stub paths (e.g. a thousand copies of "glFoo is not implemented"
    // fired every frame) otherwise fill the 64-entry ring immediately and hide
    // everything that came before them.
    if (!errorLog_.empty()) {
        auto& back = errorLog_.back();
        if (back.function == record.function && back.errorEnum == record.errorEnum) {
            ++back.count;
            return;
        }
    }
    if (errorLog_.size() >= 64) {
        errorLog_.erase(errorLog_.begin());
    }
    record.count = 1;
    errorLog_.push_back(std::move(record));
}

std::uint64_t Runtime::errorLogCount() {
    std::lock_guard<std::mutex> lock(errorLogMutex_);
    return errorLogEventsObserved_;
}

std::vector<Runtime::ErrorRecord> Runtime::errorLogSnapshot() {
    std::lock_guard<std::mutex> lock(errorLogMutex_);
    return errorLog_;
}

std::size_t Runtime::writeCoverageSnapshotJSON(char* out, std::size_t cap) {
    const std::string payload = coverageStore_.buildSnapshotJson(rendererString_, traceLog_.snapshot());
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }
    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}

std::size_t Runtime::writeDiagnosticsJSON(char* out, std::size_t cap) {
    // Hold the context mutex for the entire inventory walk so that a concurrent
    // context destruction (from any thread) cannot free the pointer we are
    // dereferencing. If `gCurrentContext` was cleared by unregisterContext on
    // this thread, the liveness check below will cleanly take the null branch.
    std::lock_guard<std::mutex> contextLock(contextMutex_);
    GLContext* const currentContext = gCurrentContext;
    const bool contextIsLive = isContextLiveLocked(currentContext);

    std::ostringstream stream;
    stream << "{";
    stream << "\"renderer\":\"" << jsonEscape(rendererString_) << "\",";
    stream << "\"hasCurrentContext\":" << (contextIsLive ? "true" : "false") << ",";
    // Tells external tooling whether the objectStore/pipelineCache fields
    // reflect the CURRENT live context or the most recently destroyed context's
    // final snapshot. This is how BAR can distinguish an honest post-mortem
    // dump from a cold-boot dump with nothing to report.
    //
    // `metricsSource` mirrors `inventorySource` in the full writer (both the
    // object store and pipeline cache come from the same source). It's emitted
    // so tooling that polls both `appglDiagnosticsJSON` and
    // `appglLiveDiagnosticsJSON` can use a single uniform key.
    const char* const provenance =
        contextIsLive ? "live" : (lastKnownInventory_.valid ? "post-mortem-snapshot" : "empty");
    stream << "\"inventorySource\":\"" << provenance << "\",";
    stream << "\"metricsSource\":\"" << provenance << "\",";

    // ── Object store inventory ──
    // Live path: walk the current context's object store directly.
    // Post-mortem path: replay the snapshot captured at unregisterContext,
    // which reflects the most recently destroyed context's final state.
    // Cold-boot fallthrough: no live context, no snapshot — genuinely empty.
    stream << "\"objectStore\":{";
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    std::uint64_t pipelineBuildAttempts = 0;
    std::uint64_t pipelineBuildFailures = 0;
    double pipelineCumulativeBuildMillis = 0.0;
    if (contextIsLive) {
        auto& store = currentContext->objects();

        // Walk buffers/textures explicitly to compute resident byte totals.
        std::uint64_t bufferBytes = 0;
        store.buffers().forEach([&bufferBytes](GLuint, GLBufferObject& buffer) {
            bufferBytes += static_cast<std::uint64_t>(buffer.size > 0 ? buffer.size : 0);
        });
        std::uint64_t textureBytes = 0;
        store.textures().forEach([&textureBytes](GLuint, GLTextureObject& texture) {
            for (const auto& [level, image] : texture.levels) {
                (void)level;
                textureBytes += static_cast<std::uint64_t>(image.rgba8.size());
            }
        });
        std::uint64_t renderbufferBytes = 0;
        store.renderbuffers().forEach([&renderbufferBytes](GLuint, GLRenderbufferObject& rb) {
            renderbufferBytes += static_cast<std::uint64_t>(rb.rgba8.size())
                + static_cast<std::uint64_t>(rb.depth32.size() * sizeof(GLfloat))
                + static_cast<std::uint64_t>(rb.stencil8.size());
        });

        stream << "\"buffers\":" << store.buffers().size() << ",";
        stream << "\"textures\":" << store.textures().size() << ",";
        stream << "\"samplers\":" << store.samplers().size() << ",";
        stream << "\"renderbuffers\":" << store.renderbuffers().size() << ",";
        stream << "\"framebuffers\":" << store.framebuffers().size() << ",";
        stream << "\"vertexArrays\":" << store.vertexArrays().size() << ",";
        stream << "\"shaders\":" << store.shaders().size() << ",";
        stream << "\"programs\":" << store.programs().size() << ",";
        stream << "\"queries\":" << store.queries().size() << ",";
        stream << "\"syncs\":" << store.syncs().size() << ",";
        stream << "\"transformFeedbacks\":" << store.transformFeedbacks().size() << ",";
        stream << "\"bufferBytes\":" << bufferBytes << ",";
        stream << "\"textureBytes\":" << textureBytes << ",";
        stream << "\"renderbufferBytes\":" << renderbufferBytes;

        const auto metrics = currentContext->pipelineCacheMetrics();
        pipelineCacheHits = metrics.hits;
        pipelineCacheMisses = metrics.misses;
        pipelineBuildAttempts = metrics.buildAttempts;
        pipelineBuildFailures = metrics.buildFailures;
        pipelineCumulativeBuildMillis = metrics.cumulativeBuildMillis;
    } else if (lastKnownInventory_.valid) {
        const auto& snap = lastKnownInventory_;
        stream << "\"buffers\":" << snap.buffers << ",";
        stream << "\"textures\":" << snap.textures << ",";
        stream << "\"samplers\":" << snap.samplers << ",";
        stream << "\"renderbuffers\":" << snap.renderbuffers << ",";
        stream << "\"framebuffers\":" << snap.framebuffers << ",";
        stream << "\"vertexArrays\":" << snap.vertexArrays << ",";
        stream << "\"shaders\":" << snap.shaders << ",";
        stream << "\"programs\":" << snap.programs << ",";
        stream << "\"queries\":" << snap.queries << ",";
        stream << "\"syncs\":" << snap.syncs << ",";
        stream << "\"transformFeedbacks\":" << snap.transformFeedbacks << ",";
        stream << "\"bufferBytes\":" << snap.bufferBytes << ",";
        stream << "\"textureBytes\":" << snap.textureBytes << ",";
        stream << "\"renderbufferBytes\":" << snap.renderbufferBytes;

        pipelineCacheHits = snap.pipelineCacheHits;
        pipelineCacheMisses = snap.pipelineCacheMisses;
        pipelineBuildAttempts = snap.pipelineBuildAttempts;
        pipelineBuildFailures = snap.pipelineBuildFailures;
        pipelineCumulativeBuildMillis = snap.pipelineCumulativeBuildMillis;
    } else {
        stream << "\"buffers\":0,\"textures\":0,\"samplers\":0,\"renderbuffers\":0,"
                  "\"framebuffers\":0,\"vertexArrays\":0,\"shaders\":0,\"programs\":0,"
                  "\"queries\":0,\"syncs\":0,\"transformFeedbacks\":0,"
                  "\"bufferBytes\":0,\"textureBytes\":0,\"renderbufferBytes\":0";
    }
    stream << "},";

    // ── Pipeline cache metrics ──
    // Entries = total misses (every miss constructs a new MTLRenderPipelineState,
    // and the frame graph currently does not evict entries, so this count is
    // monotonic over the context's lifetime).
    //
    // Phase 8X Group 4d follow-up⁴ — `buildAttempts` and `buildFailures` are
    // emitted alongside hits/misses so BAR-side tooling can disambiguate
    // {hits:0,misses:0}: attempts==0 means "translated path never reached
    // the build branch" (one of the four pre-encode gates fired); attempts>0
    // with failures==attempts means "build branch ran every time and Metal
    // rejected the result every time" (the encode-failed gate). Invariant
    // after every draw: buildAttempts == misses + buildFailures.
    const std::uint64_t pipelineEntries = pipelineCacheMisses;
    const double averageBuildMillis = pipelineCacheMisses > 0
        ? pipelineCumulativeBuildMillis / static_cast<double>(pipelineCacheMisses)
        : 0.0;
    stream << "\"pipelineCache\":{"
           << "\"entries\":" << pipelineEntries << ","
           << "\"hits\":" << pipelineCacheHits << ","
           << "\"misses\":" << pipelineCacheMisses << ","
           << "\"buildAttempts\":" << pipelineBuildAttempts << ","
           << "\"buildFailures\":" << pipelineBuildFailures << ","
           << "\"averageBuildMillis\":" << averageBuildMillis
           << "},";

    // ── Shader translation log ──
    {
        std::lock_guard<std::mutex> lock(translationMutex_);
        stream << "\"shaderTranslations\":[";
        for (std::size_t i = 0; i < shaderTranslations_.size(); ++i) {
            if (i != 0) stream << ",";
            const auto& rec = shaderTranslations_[i];
            stream << "{"
                   << "\"id\":\"" << jsonEscape(rec.id) << "\","
                   << "\"stage\":\"" << jsonEscape(rec.stage) << "\","
                   << "\"sourceHash\":\"" << jsonEscape(rec.sourceHash) << "\","
                   << "\"vertexSourceHash\":\"" << jsonEscape(rec.vertexSourceHash) << "\","
                   << "\"fragmentSourceHash\":\"" << jsonEscape(rec.fragmentSourceHash) << "\","
                   << "\"glslangLog\":\"" << jsonEscape(rec.glslangLog) << "\","
                   << "\"mslPreview\":\"" << jsonEscape(rec.mslPreview) << "\","
                   << "\"success\":" << (rec.success ? "true" : "false")
                   << "}";
        }
        stream << "],";
    }

    // ── GL error stream ──
    // Ring buffer of the last 64 distinct (function, error enum) pairs seen by
    // recordValidationError() or recordUnimplemented(). Consecutive duplicates
    // collapse into a single record with a `count` field so a single frame of
    // unimplemented-stub spam cannot wipe older context from the ring.
    {
        std::lock_guard<std::mutex> lock(errorLogMutex_);
        stream << "\"errorLog\":[";
        for (std::size_t i = 0; i < errorLog_.size(); ++i) {
            if (i != 0) stream << ",";
            const auto& rec = errorLog_[i];
            stream << "{"
                   << "\"function\":\"" << jsonEscape(rec.function) << "\","
                   << "\"errorEnum\":" << rec.errorEnum << ","
                   << "\"message\":\"" << jsonEscape(rec.message) << "\","
                   << "\"count\":" << rec.count
                   << "}";
        }
        stream << "]";
    }

    stream << "}";

    const std::string payload = stream.str();
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }
    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}

std::size_t Runtime::writeLiveDiagnosticsJSON(char* out, std::size_t cap) {
    // Lightweight poll-friendly subset of writeDiagnosticsJSON. Skips the
    // object-store inventory walk entirely so the cost is bounded by the size
    // of the ring buffers (32 shader translations + 64 error records) plus
    // a single pipelineCacheMetrics() read.
    //
    // Locks are taken in sequence — not nested — so this entry point is safe
    // to call from any thread concurrently with any other diagnostics path.

    // 1. Pipeline cache metrics (held briefly).
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    std::uint64_t pipelineBuildAttempts = 0;
    std::uint64_t pipelineBuildFailures = 0;
    double pipelineCumulativeBuildMillis = 0.0;
    bool haveMetrics = false;
    bool contextIsLive = false;
    std::string rendererCopy;
    {
        std::lock_guard<std::mutex> contextLock(contextMutex_);
        rendererCopy = rendererString_;
        contextIsLive = isContextLiveLocked(gCurrentContext);
        if (contextIsLive) {
            const auto m = gCurrentContext->pipelineCacheMetrics();
            pipelineCacheHits = m.hits;
            pipelineCacheMisses = m.misses;
            pipelineBuildAttempts = m.buildAttempts;
            pipelineBuildFailures = m.buildFailures;
            pipelineCumulativeBuildMillis = m.cumulativeBuildMillis;
            haveMetrics = true;
        } else if (lastKnownInventory_.valid) {
            pipelineCacheHits = lastKnownInventory_.pipelineCacheHits;
            pipelineCacheMisses = lastKnownInventory_.pipelineCacheMisses;
            pipelineBuildAttempts = lastKnownInventory_.pipelineBuildAttempts;
            pipelineBuildFailures = lastKnownInventory_.pipelineBuildFailures;
            pipelineCumulativeBuildMillis = lastKnownInventory_.pipelineCumulativeBuildMillis;
            haveMetrics = true;
        }
    }

    std::ostringstream stream;
    stream << "{";
    stream << "\"renderer\":\"" << jsonEscape(rendererCopy) << "\",";
    stream << "\"hasCurrentContext\":" << (contextIsLive ? "true" : "false") << ",";
    stream << "\"metricsSource\":\""
           << (contextIsLive ? "live" : (haveMetrics ? "post-mortem-snapshot" : "empty"))
           << "\",";

    // Phase 8X Group 4d follow-up⁴ — see writeDiagnosticsJSON for the full
    // rationale on the buildAttempts/buildFailures emission.
    const std::uint64_t pipelineEntries = pipelineCacheMisses;
    const double averageBuildMillis = pipelineCacheMisses > 0
        ? pipelineCumulativeBuildMillis / static_cast<double>(pipelineCacheMisses)
        : 0.0;
    stream << "\"pipelineCache\":{"
           << "\"entries\":" << pipelineEntries << ","
           << "\"hits\":" << pipelineCacheHits << ","
           << "\"misses\":" << pipelineCacheMisses << ","
           << "\"buildAttempts\":" << pipelineBuildAttempts << ","
           << "\"buildFailures\":" << pipelineBuildFailures << ","
           << "\"averageBuildMillis\":" << averageBuildMillis
           << "},";

    // 2. Shader translations (held briefly, in isolation).
    {
        std::lock_guard<std::mutex> lock(translationMutex_);
        stream << "\"shaderTranslations\":[";
        for (std::size_t i = 0; i < shaderTranslations_.size(); ++i) {
            if (i != 0) stream << ",";
            const auto& rec = shaderTranslations_[i];
            stream << "{"
                   << "\"id\":\"" << jsonEscape(rec.id) << "\","
                   << "\"stage\":\"" << jsonEscape(rec.stage) << "\","
                   << "\"sourceHash\":\"" << jsonEscape(rec.sourceHash) << "\","
                   << "\"vertexSourceHash\":\"" << jsonEscape(rec.vertexSourceHash) << "\","
                   << "\"fragmentSourceHash\":\"" << jsonEscape(rec.fragmentSourceHash) << "\","
                   << "\"glslangLog\":\"" << jsonEscape(rec.glslangLog) << "\","
                   << "\"mslPreview\":\"" << jsonEscape(rec.mslPreview) << "\","
                   << "\"success\":" << (rec.success ? "true" : "false")
                   << "}";
        }
        stream << "],";
    }

    // 3. Error log (held briefly, in isolation).
    {
        std::lock_guard<std::mutex> lock(errorLogMutex_);
        stream << "\"errorLog\":[";
        for (std::size_t i = 0; i < errorLog_.size(); ++i) {
            if (i != 0) stream << ",";
            const auto& rec = errorLog_[i];
            stream << "{"
                   << "\"function\":\"" << jsonEscape(rec.function) << "\","
                   << "\"errorEnum\":" << rec.errorEnum << ","
                   << "\"message\":\"" << jsonEscape(rec.message) << "\","
                   << "\"count\":" << rec.count
                   << "}";
        }
        stream << "]";
    }

    stream << "}";

    const std::string payload = stream.str();
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }
    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}

CoverageStore& Runtime::coverageStore() {
    return coverageStore_;
}

TraceLog& Runtime::traceLog() {
    return traceLog_;
}

namespace impl {

void APIENTRY glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    auto* context = requireCurrentContext("glClearColor");
    if (context == nullptr) {
        return;
    }
    context->setClearColor(red, green, blue, alpha);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearColor,
        kBootstrapTestId,
        "Animated clear loop drives the Metal-backed default framebuffer."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glClearColor(" + formatFloat(red) + ", " + formatFloat(green) + ", " + formatFloat(blue) + ", " + formatFloat(alpha) + ")"
    );
}

void APIENTRY glClear(GLbitfield mask) {
    auto* context = requireCurrentContext("glClear");
    if (context == nullptr) {
        return;
    }
    constexpr GLbitfield validMask = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
    if ((mask & ~validMask) != 0) {
        recordValidationError(context, "glClear", GL_INVALID_VALUE, "mask contains unsupported bits");
        return;
    }
    context->clear(mask);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClear,
        kBootstrapTestId,
        "Bootstrap clear path encodes a Metal render pass and presents it."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClear(mask=" + std::to_string(mask) + ")");
}

void APIENTRY glClearDepth(GLdouble depth) {
    auto* context = requireCurrentContext("glClearDepth");
    if (context == nullptr) {
        return;
    }
    context->setClearDepth(depth);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearDepth,
        "phase-a.read-pixels",
        "Default framebuffer depth clear state is tracked."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClearDepth(" + formatFloat(static_cast<GLfloat>(depth)) + ")");
}

void APIENTRY glClearStencil(GLint stencil) {
    auto* context = requireCurrentContext("glClearStencil");
    if (context == nullptr) {
        return;
    }
    context->setClearStencil(stencil);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearStencil,
        "phase-a.read-pixels",
        "Default framebuffer stencil clear state is tracked."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClearStencil(" + std::to_string(stencil) + ")");
}

void APIENTRY glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glViewport");
    if (context == nullptr) {
        return;
    }
    if (width < 0 || height < 0) {
        recordValidationError(context, "glViewport", GL_INVALID_VALUE, "width and height must be non-negative");
        return;
    }
    context->setViewport(x, y, width, height);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glViewport,
        kBootstrapTestId,
        "Viewport updates drive the CAMetalLayer drawable size."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glViewport(" + std::to_string(x) + ", " + std::to_string(y) + ", "
        + std::to_string(width) + ", " + std::to_string(height) + ")"
    );
}

void APIENTRY glScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glScissor");
    if (context == nullptr) {
        return;
    }
    if (width < 0 || height < 0) {
        recordValidationError(context, "glScissor", GL_INVALID_VALUE, "width and height must be non-negative");
        return;
    }
    context->setScissor(x, y, width, height);
    markStateFunction(FunctionId::glScissor, "Scissor box state is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace(
        "glScissor(" + std::to_string(x) + ", " + std::to_string(y) + ", "
        + std::to_string(width) + ", " + std::to_string(height) + ")"
    );
}

void APIENTRY glDepthRange(GLdouble nearValue, GLdouble farValue) {
    auto* context = requireCurrentContext("glDepthRange");
    if (context == nullptr) {
        return;
    }
    context->setDepthRange(nearValue, farValue);
    markStateFunction(FunctionId::glDepthRange, "Depth range state is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace(
        "glDepthRange(" + formatFloat(static_cast<GLfloat>(nearValue)) + ", "
        + formatFloat(static_cast<GLfloat>(farValue)) + ")"
    );
}

void APIENTRY glDepthRangef(GLfloat nearValue, GLfloat farValue) {
    auto* context = requireCurrentContext("glDepthRangef");
    if (context == nullptr) {
        return;
    }
    context->setDepthRange(nearValue, farValue);
    markStateFunction(FunctionId::glDepthRangef, "Depth range float alias updates the canonical state.");
    Runtime::shared().recordBootstrapTrace(
        "glDepthRangef(" + formatFloat(nearValue) + ", " + formatFloat(farValue) + ")"
    );
}

void APIENTRY glFlush(void) {
    auto* context = requireCurrentContext("glFlush");
    if (context == nullptr) {
        return;
    }
    context->flush();
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glFlush,
        kBootstrapTestId,
        "Bootstrap flush presents the pending CAMetalLayer drawable."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glFlush()");
}

void APIENTRY glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    auto* context = requireCurrentContext("glReadPixels");
    if (context == nullptr) {
        return;
    }
    context->readPixels(x, y, width, height, format, type, pixels);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glReadPixels,
        "phase-a.read-pixels",
        "RGBA/UNSIGNED_BYTE readback drives golden capture."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glReadPixels(" + std::to_string(width) + "x" + std::to_string(height) + ")"
    );
}

void APIENTRY glGetBooleanv(GLenum pname, GLboolean* data) {
    auto* context = requireCurrentContext("glGetBooleanv");
    if (context == nullptr) {
        return;
    }
    (void)context->queryBoolean(pname, data);
    markStateFunction(FunctionId::glGetBooleanv, "Boolean state and capability queries route through the context.");
    Runtime::shared().recordBootstrapTrace("glGetBooleanv(" + std::to_string(pname) + ")");
}

void APIENTRY glGetIntegerv(GLenum pname, GLint* data) {
    auto* context = requireCurrentContext("glGetIntegerv");
    if (context == nullptr) {
        return;
    }
    (void)context->queryInteger(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetIntegerv,
        "phase-a.capabilities",
        "Capability integer queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetIntegerv(" + std::to_string(pname) + ")");
}

void APIENTRY glGetInteger64v(GLenum pname, GLint64* data) {
    auto* context = requireCurrentContext("glGetInteger64v");
    if (context == nullptr) {
        return;
    }
    (void)context->queryInteger64(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetInteger64v,
        "phase-a.capabilities",
        "Capability integer64 queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetInteger64v(" + std::to_string(pname) + ")");
}

void APIENTRY glGetFloatv(GLenum pname, GLfloat* data) {
    auto* context = requireCurrentContext("glGetFloatv");
    if (context == nullptr) {
        return;
    }
    (void)context->queryFloat(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetFloatv,
        "phase-a.capabilities",
        "Capability float queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetFloatv(" + std::to_string(pname) + ")");
}

void APIENTRY glGetDoublev(GLenum pname, GLdouble* data) {
    auto* context = requireCurrentContext("glGetDoublev");
    if (context == nullptr) {
        return;
    }
    (void)context->queryDouble(pname, data);
    markStateFunction(FunctionId::glGetDoublev, "Double state and capability queries route through the context.");
    Runtime::shared().recordBootstrapTrace("glGetDoublev(" + std::to_string(pname) + ")");
}

void APIENTRY glGenBuffers(GLsizei n, GLuint* buffers) {
    auto* context = requireCurrentContext("glGenBuffers");
    if (context == nullptr) {
        return;
    }
    if (context->genBuffers(n, buffers)) {
        markBufferFunction(FunctionId::glGenBuffers, "Buffer names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenBuffers(" + std::to_string(n) + ")");
    }
}

void APIENTRY glDeleteBuffers(GLsizei n, const GLuint* buffers) {
    auto* context = requireCurrentContext("glDeleteBuffers");
    if (context == nullptr) {
        return;
    }
    if (context->deleteBuffers(n, buffers)) {
        markBufferFunction(FunctionId::glDeleteBuffers, "Buffer names are deleted and stale bindings are cleared.");
        Runtime::shared().recordBootstrapTrace("glDeleteBuffers(" + std::to_string(n) + ")");
    }
}

GLboolean APIENTRY glIsBuffer(GLuint buffer) {
    auto* context = requireCurrentContext("glIsBuffer");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markBufferFunction(FunctionId::glIsBuffer, "Buffer object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsBuffer(" + std::to_string(buffer) + ")");
    return context->isBuffer(buffer) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindBuffer(GLenum target, GLuint buffer) {
    auto* context = requireCurrentContext("glBindBuffer");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glBindBuffer", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (context->bindBuffer(target, buffer)) {
        markBufferFunction(FunctionId::glBindBuffer, "Generic buffer binding points are tracked.");
        Runtime::shared().recordBootstrapTrace("glBindBuffer(" + std::to_string(target) + ", " + std::to_string(buffer) + ")");
    }
}

void APIENTRY glBindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    auto* context = requireCurrentContext("glBindBufferBase");
    if (context == nullptr) {
        return;
    }
    if (!isValidIndexedBufferTarget(target)) {
        recordValidationError(context, "glBindBufferBase", GL_INVALID_ENUM, "target is not an indexed buffer binding point");
        return;
    }
    if (index >= maxIndexedBindings(target)) {
        recordValidationError(context, "glBindBufferBase", GL_INVALID_VALUE, "binding index exceeds maximum for target");
        return;
    }
    // GL 4.6 §6.1.1: binding XFB buffers while transform feedback is active is INVALID_OPERATION.
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER && context->isTransformFeedbackActive()) {
        recordValidationError(context, "glBindBufferBase", GL_INVALID_OPERATION, "cannot bind transform feedback buffer while transform feedback is active");
        return;
    }
    if (context->bindBufferBase(target, index, buffer)) {
        markBufferFunction(FunctionId::glBindBufferBase, "Indexed buffer-base bindings are tracked.");
        Runtime::shared().recordBootstrapTrace("glBindBufferBase(" + std::to_string(target) + ", " + std::to_string(index) + ")");
    }
}

void APIENTRY glBindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    auto* context = requireCurrentContext("glBindBufferRange");
    if (context == nullptr) {
        return;
    }
    if (!isValidIndexedBufferTarget(target)) {
        recordValidationError(context, "glBindBufferRange", GL_INVALID_ENUM, "target is not an indexed buffer binding point");
        return;
    }
    if (index >= maxIndexedBindings(target)) {
        recordValidationError(context, "glBindBufferRange", GL_INVALID_VALUE, "binding index exceeds maximum for target");
        return;
    }
    // GL 4.6 §6.1.1: binding XFB buffers while transform feedback is active is INVALID_OPERATION.
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER && context->isTransformFeedbackActive()) {
        recordValidationError(context, "glBindBufferRange", GL_INVALID_OPERATION, "cannot bind transform feedback buffer while transform feedback is active");
        return;
    }
    // GL 4.6 §6.1.1: For TRANSFORM_FEEDBACK_BUFFER, size must be > 0, and
    // both offset and size must be word-aligned (multiple of 4).
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER && buffer != 0) {
        if (size <= 0) {
            recordValidationError(context, "glBindBufferRange", GL_INVALID_VALUE, "size must be > 0 for transform feedback buffer");
            return;
        }
        if (offset % 4 != 0) {
            recordValidationError(context, "glBindBufferRange", GL_INVALID_VALUE, "offset must be word-aligned for transform feedback buffer");
            return;
        }
        if (size % 4 != 0) {
            recordValidationError(context, "glBindBufferRange", GL_INVALID_VALUE, "size must be word-aligned for transform feedback buffer");
            return;
        }
    }
    if (context->bindBufferRange(target, index, buffer, offset, size)) {
        markBufferFunction(FunctionId::glBindBufferRange, "Indexed buffer-range bindings are tracked.");
        Runtime::shared().recordBootstrapTrace("glBindBufferRange(" + std::to_string(target) + ", " + std::to_string(index) + ")");
    }
}

void APIENTRY glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    auto* context = requireCurrentContext("glBufferData");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glBufferData", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (!isValidBufferUsage(usage)) {
        recordValidationError(context, "glBufferData", GL_INVALID_ENUM, "usage is invalid");
        return;
    }
    if (context->bufferData(target, size, data, usage)) {
        markBufferFunction(FunctionId::glBufferData, "Buffer storage is backed by deterministic shadow bytes.");
        Runtime::shared().recordBootstrapTrace("glBufferData(" + std::to_string(target) + ", " + std::to_string(size) + ")");
    }
}

void APIENTRY glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    auto* context = requireCurrentContext("glBufferSubData");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glBufferSubData", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (context->bufferSubData(target, offset, size, data)) {
        markBufferFunction(FunctionId::glBufferSubData, "Buffer subdata writes update deterministic shadow bytes.");
        Runtime::shared().recordBootstrapTrace("glBufferSubData(" + std::to_string(target) + ", " + std::to_string(size) + ")");
    }
}

void APIENTRY glCopyBufferSubData(
    GLenum readTarget,
    GLenum writeTarget,
    GLintptr readOffset,
    GLintptr writeOffset,
    GLsizeiptr size
) {
    auto* context = requireCurrentContext("glCopyBufferSubData");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(readTarget) || !isValidBufferTarget(writeTarget)) {
        recordValidationError(context, "glCopyBufferSubData", GL_INVALID_ENUM, "read or write target is invalid");
        return;
    }
    if (context->copyBufferSubData(readTarget, writeTarget, readOffset, writeOffset, size)) {
        markBufferFunction(FunctionId::glCopyBufferSubData, "Buffer-to-buffer shadow copy is live.");
        Runtime::shared().recordBootstrapTrace("glCopyBufferSubData(" + std::to_string(size) + ")");
    }
}

void APIENTRY glGetBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data) {
    auto* context = requireCurrentContext("glGetBufferSubData");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glGetBufferSubData", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (context->getBufferSubData(target, offset, size, data)) {
        markBufferFunction(FunctionId::glGetBufferSubData, "Buffer readback from shadow storage is live.");
        Runtime::shared().recordBootstrapTrace("glGetBufferSubData(" + std::to_string(target) + ", " + std::to_string(size) + ")");
    }
}

void* APIENTRY glMapBuffer(GLenum target, GLenum access) {
    auto* context = requireCurrentContext("glMapBuffer");
    if (context == nullptr) {
        return nullptr;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glMapBuffer", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return nullptr;
    }
    if (!isValidMapBufferAccess(access)) {
        recordValidationError(context, "glMapBuffer", GL_INVALID_ENUM, "access must be READ_ONLY, WRITE_ONLY, or READ_WRITE");
        return nullptr;
    }
    void* pointer = context->mapBuffer(target, access);
    if (pointer != nullptr) {
        markBufferFunction(FunctionId::glMapBuffer, "Whole-buffer mapping returns a CPU-visible pointer.");
        Runtime::shared().recordBootstrapTrace("glMapBuffer(" + std::to_string(target) + ")");
    }
    return pointer;
}

void* APIENTRY glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    auto* context = requireCurrentContext("glMapBufferRange");
    if (context == nullptr) {
        return nullptr;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glMapBufferRange", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return nullptr;
    }
    // Access-flag validation is deferred to context->mapBufferRange,
    // which runs the full GL 4.4 §6.3.1 spec-ordered checks — including
    // storage-flag compatibility (INVALID_OPERATION when access bits
    // aren't set in the buffer's storage flags). CTS
    // `buffer_storage.errors` asserts the storage-compat check wins
    // over the "access needs READ/WRITE" check, and having a wrapper
    // pre-check that raises INVALID_VALUE on access=PERSISTENT alone
    // shadows the spec-correct INVALID_OPERATION.
    void* pointer = context->mapBufferRange(target, offset, length, access);
    if (pointer != nullptr) {
        markBufferFunction(FunctionId::glMapBufferRange, "Range mapping returns a CPU-visible pointer.");
        Runtime::shared().recordBootstrapTrace("glMapBufferRange(" + std::to_string(target) + ", " + std::to_string(length) + ")");
    }
    return pointer;
}

GLboolean APIENTRY glUnmapBuffer(GLenum target) {
    auto* context = requireCurrentContext("glUnmapBuffer");
    if (context == nullptr) {
        return GL_FALSE;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glUnmapBuffer", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return GL_FALSE;
    }
    const GLboolean unmapped = context->unmapBuffer(target);
    if (unmapped == GL_TRUE) {
        markBufferFunction(FunctionId::glUnmapBuffer, "Mapped buffer pointers are released and shadow bytes are synchronized.");
        Runtime::shared().recordBootstrapTrace("glUnmapBuffer(" + std::to_string(target) + ")");
    }
    return unmapped;
}

void APIENTRY glFlushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {
    auto* context = requireCurrentContext("glFlushMappedBufferRange");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glFlushMappedBufferRange", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (context->flushMappedBufferRange(target, offset, length)) {
        markBufferFunction(FunctionId::glFlushMappedBufferRange, "Explicit mapped-range flush synchronizes the deterministic mirror.");
        Runtime::shared().recordBootstrapTrace("glFlushMappedBufferRange(" + std::to_string(target) + ", " + std::to_string(length) + ")");
    }
}

void APIENTRY glGetBufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetBufferParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glGetBufferParameteriv", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (!isValidBufferParameterPname(pname)) {
        recordValidationError(context, "glGetBufferParameteriv", GL_INVALID_ENUM, "pname is not a supported buffer parameter");
        return;
    }
    if (context->getBufferParameterInteger(target, pname, params)) {
        markBufferFunction(FunctionId::glGetBufferParameteriv, "Buffer integer parameter queries expose size, usage, and map state.");
        Runtime::shared().recordBootstrapTrace("glGetBufferParameteriv(" + std::to_string(target) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetBufferParameteri64v(GLenum target, GLenum pname, GLint64* params) {
    auto* context = requireCurrentContext("glGetBufferParameteri64v");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glGetBufferParameteri64v", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (!isValidBufferParameterPname(pname)) {
        recordValidationError(context, "glGetBufferParameteri64v", GL_INVALID_ENUM, "pname is not a supported buffer parameter");
        return;
    }
    if (context->getBufferParameterInteger64(target, pname, params)) {
        markBufferFunction(FunctionId::glGetBufferParameteri64v, "Buffer integer64 parameter queries expose size and mapped range metadata.");
        Runtime::shared().recordBootstrapTrace("glGetBufferParameteri64v(" + std::to_string(target) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetBufferPointerv(GLenum target, GLenum pname, void** params) {
    auto* context = requireCurrentContext("glGetBufferPointerv");
    if (context == nullptr) {
        return;
    }
    if (!isValidBufferTarget(target)) {
        recordValidationError(context, "glGetBufferPointerv", GL_INVALID_ENUM, "target is not a supported buffer binding point");
        return;
    }
    if (pname != GL_BUFFER_MAP_POINTER) {
        recordValidationError(context, "glGetBufferPointerv", GL_INVALID_ENUM, "pname must be GL_BUFFER_MAP_POINTER");
        return;
    }
    if (context->getBufferPointer(target, pname, params)) {
        markBufferFunction(FunctionId::glGetBufferPointerv, "Mapped buffer pointer queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetBufferPointerv(" + std::to_string(target) + ")");
    }
}

void APIENTRY glGenVertexArrays(GLsizei n, GLuint* arrays) {
    auto* context = requireCurrentContext("glGenVertexArrays");
    if (context == nullptr) {
        return;
    }
    if (context->genVertexArrays(n, arrays)) {
        markVertexInputFunction(FunctionId::glGenVertexArrays, "Vertex-array names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenVertexArrays(" + std::to_string(n) + ")");
    }
}

void APIENTRY glDeleteVertexArrays(GLsizei n, const GLuint* arrays) {
    auto* context = requireCurrentContext("glDeleteVertexArrays");
    if (context == nullptr) {
        return;
    }
    if (context->deleteVertexArrays(n, arrays)) {
        markVertexInputFunction(FunctionId::glDeleteVertexArrays, "Vertex arrays are deleted and stale bindings are cleared.");
        Runtime::shared().recordBootstrapTrace("glDeleteVertexArrays(" + std::to_string(n) + ")");
    }
}

GLboolean APIENTRY glIsVertexArray(GLuint array) {
    auto* context = requireCurrentContext("glIsVertexArray");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markVertexInputFunction(FunctionId::glIsVertexArray, "Vertex-array object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsVertexArray(" + std::to_string(array) + ")");
    return context->isVertexArray(array) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindVertexArray(GLuint array) {
    auto* context = requireCurrentContext("glBindVertexArray");
    if (context == nullptr) {
        return;
    }
    if (context->bindVertexArray(array)) {
        markVertexInputFunction(FunctionId::glBindVertexArray, "Current vertex-array binding is tracked.");
        Runtime::shared().recordBootstrapTrace("glBindVertexArray(" + std::to_string(array) + ")");
    }
}

void APIENTRY glEnableVertexAttribArray(GLuint index) {
    auto* context = requireCurrentContext("glEnableVertexAttribArray");
    if (context == nullptr) {
        return;
    }
    if (context->enableVertexAttribArray(index, true)) {
        markVertexInputFunction(FunctionId::glEnableVertexAttribArray, "Vertex attribute enable state is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glEnableVertexAttribArray(" + std::to_string(index) + ")");
    }
}

void APIENTRY glDisableVertexAttribArray(GLuint index) {
    auto* context = requireCurrentContext("glDisableVertexAttribArray");
    if (context == nullptr) {
        return;
    }
    if (context->enableVertexAttribArray(index, false)) {
        markVertexInputFunction(FunctionId::glDisableVertexAttribArray, "Vertex attribute disable state is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glDisableVertexAttribArray(" + std::to_string(index) + ")");
    }
}

void APIENTRY glVertexAttribPointer(
    GLuint index,
    GLint size,
    GLenum type,
    GLboolean normalized,
    GLsizei stride,
    const void* pointer
) {
    auto* context = requireCurrentContext("glVertexAttribPointer");
    if (context == nullptr) {
        return;
    }
    if (!isValidVertexAttribPointerType(type)) {
        recordValidationError(context, "glVertexAttribPointer", GL_INVALID_ENUM, "type is not supported for floating-point attribute arrays");
        return;
    }
    if (context->vertexAttribPointer(index, size, type, normalized, stride, pointer)) {
        markVertexInputFunction(FunctionId::glVertexAttribPointer, "Floating-point vertex attribute pointer state captures the current array buffer.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribPointer(" + std::to_string(index) + ")");
    }
}

void APIENTRY glVertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    auto* context = requireCurrentContext("glVertexAttribIPointer");
    if (context == nullptr) {
        return;
    }
    if (!isValidVertexAttribIPointerType(type)) {
        recordValidationError(context, "glVertexAttribIPointer", GL_INVALID_ENUM, "type is not supported for integer attribute arrays");
        return;
    }
    if (context->vertexAttribIPointer(index, size, type, stride, pointer)) {
        markVertexInputFunction(FunctionId::glVertexAttribIPointer, "Integer vertex attribute pointer state captures the current array buffer.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribIPointer(" + std::to_string(index) + ")");
    }
}

void APIENTRY glVertexAttribDivisor(GLuint index, GLuint divisor) {
    auto* context = requireCurrentContext("glVertexAttribDivisor");
    if (context == nullptr) {
        return;
    }
    if (context->vertexAttribDivisor(index, divisor)) {
        markVertexInputFunction(FunctionId::glVertexAttribDivisor, "Vertex attribute divisors are tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribDivisor(" + std::to_string(index) + ", " + std::to_string(divisor) + ")");
    }
}

// --- GL 4.3: Separated vertex format (ARB_vertex_attrib_binding) ---

void APIENTRY glBindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    auto* context = requireCurrentContext("glBindVertexBuffer");
    if (context == nullptr) {
        return;
    }
    if (stride < 0) {
        recordValidationError(context, "glBindVertexBuffer", GL_INVALID_VALUE, "stride must be non-negative");
        return;
    }
    if (offset < 0) {
        recordValidationError(context, "glBindVertexBuffer", GL_INVALID_VALUE, "offset must be non-negative");
        return;
    }
    if (context->bindVertexBuffer(bindingindex, buffer, offset, stride)) {
        markVertexInputFunction(FunctionId::glBindVertexBuffer, "Separated vertex format binding point buffer/offset/stride is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glBindVertexBuffer(" + std::to_string(bindingindex) + ", " + std::to_string(buffer) + ")");
    }
}

void APIENTRY glVertexAttribFormat(GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    auto* context = requireCurrentContext("glVertexAttribFormat");
    if (context == nullptr) {
        return;
    }
    // GL 4.4 §10.3.8 allows size ∈ {1, 2, 3, 4, GL_BGRA}. Context-side
    // vertexAttribFormat handles the GL_BGRA constraints
    // (type/normalized restrictions) and raises INVALID_OPERATION on
    // violation — keep this pre-check narrow enough to let GL_BGRA
    // flow through.
    const bool sizeIsBgra = (size == static_cast<GLint>(GL_BGRA));
    if (!sizeIsBgra && (size < 1 || size > 4)) {
        recordValidationError(context, "glVertexAttribFormat", GL_INVALID_VALUE, "size must be 1, 2, 3, 4, or GL_BGRA");
        return;
    }
    if (!isValidVertexAttribPointerType(type)) {
        recordValidationError(context, "glVertexAttribFormat", GL_INVALID_ENUM, "type is not a valid vertex attribute format type");
        return;
    }
    if (context->vertexAttribFormat(attribindex, size, type, normalized, relativeoffset)) {
        markVertexInputFunction(FunctionId::glVertexAttribFormat, "Separated floating-point vertex attribute format is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribFormat(" + std::to_string(attribindex) + ", size=" + std::to_string(size) + ")");
    }
}

void APIENTRY glVertexAttribIFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    auto* context = requireCurrentContext("glVertexAttribIFormat");
    if (context == nullptr) {
        return;
    }
    if (size < 1 || size > 4) {
        recordValidationError(context, "glVertexAttribIFormat", GL_INVALID_VALUE, "size must be 1, 2, 3, or 4");
        return;
    }
    if (!isValidVertexAttribIPointerType(type)) {
        recordValidationError(context, "glVertexAttribIFormat", GL_INVALID_ENUM, "type is not a valid integer vertex attribute format type");
        return;
    }
    if (context->vertexAttribIFormat(attribindex, size, type, relativeoffset)) {
        markVertexInputFunction(FunctionId::glVertexAttribIFormat, "Separated integer vertex attribute format is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribIFormat(" + std::to_string(attribindex) + ", size=" + std::to_string(size) + ")");
    }
}

void APIENTRY glVertexAttribLFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    auto* context = requireCurrentContext("glVertexAttribLFormat");
    if (context == nullptr) {
        return;
    }
    if (size < 1 || size > 4) {
        recordValidationError(context, "glVertexAttribLFormat", GL_INVALID_VALUE, "size must be 1, 2, 3, or 4");
        return;
    }
    if (type != GL_DOUBLE) {
        recordValidationError(context, "glVertexAttribLFormat", GL_INVALID_ENUM, "type must be GL_DOUBLE for long vertex attribute format");
        return;
    }
    if (context->vertexAttribLFormat(attribindex, size, type, relativeoffset)) {
        markVertexInputFunction(FunctionId::glVertexAttribLFormat, "Separated double-precision vertex attribute format is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribLFormat(" + std::to_string(attribindex) + ", size=" + std::to_string(size) + ")");
    }
}

void APIENTRY glVertexAttribBinding(GLuint attribindex, GLuint bindingindex) {
    auto* context = requireCurrentContext("glVertexAttribBinding");
    if (context == nullptr) {
        return;
    }
    if (context->vertexAttribBinding(attribindex, bindingindex)) {
        markVertexInputFunction(FunctionId::glVertexAttribBinding, "Vertex attribute to binding point association is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexAttribBinding(" + std::to_string(attribindex) + ", " + std::to_string(bindingindex) + ")");
    }
}

void APIENTRY glVertexBindingDivisor(GLuint bindingindex, GLuint divisor) {
    auto* context = requireCurrentContext("glVertexBindingDivisor");
    if (context == nullptr) {
        return;
    }
    if (context->vertexBindingDivisor(bindingindex, divisor)) {
        markVertexInputFunction(FunctionId::glVertexBindingDivisor, "Separated vertex format binding point divisor is tracked per VAO.");
        Runtime::shared().recordBootstrapTrace("glVertexBindingDivisor(" + std::to_string(bindingindex) + ", " + std::to_string(divisor) + ")");
    }
}

void APIENTRY glGetVertexAttribiv(GLuint index, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetVertexAttribiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidVertexAttribPname(pname)) {
        recordValidationError(context, "glGetVertexAttribiv", GL_INVALID_ENUM, "pname is not a supported vertex attribute query");
        return;
    }
    if (context->getVertexAttribInteger(index, pname, params)) {
        markVertexInputFunction(FunctionId::glGetVertexAttribiv, "Integer vertex attribute state queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetVertexAttribiv(" + std::to_string(index) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetVertexAttribfv(GLuint index, GLenum pname, GLfloat* params) {
    auto* context = requireCurrentContext("glGetVertexAttribfv");
    if (context == nullptr) {
        return;
    }
    if (!isValidVertexAttribPname(pname)) {
        recordValidationError(context, "glGetVertexAttribfv", GL_INVALID_ENUM, "pname is not a supported vertex attribute query");
        return;
    }
    if (context->getVertexAttribFloat(index, pname, params)) {
        markVertexInputFunction(FunctionId::glGetVertexAttribfv, "Float vertex attribute state queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetVertexAttribfv(" + std::to_string(index) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetVertexAttribPointerv(GLuint index, GLenum pname, void** pointer) {
    auto* context = requireCurrentContext("glGetVertexAttribPointerv");
    if (context == nullptr) {
        return;
    }
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) {
        recordValidationError(context, "glGetVertexAttribPointerv", GL_INVALID_ENUM, "pname must be GL_VERTEX_ATTRIB_ARRAY_POINTER");
        return;
    }
    if (context->getVertexAttribPointer(index, pname, pointer)) {
        markVertexInputFunction(FunctionId::glGetVertexAttribPointerv, "Vertex attribute pointer queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetVertexAttribPointerv(" + std::to_string(index) + ")");
    }
}

void APIENTRY glActiveTexture(GLenum texture) {
    auto* context = requireCurrentContext("glActiveTexture");
    if (context == nullptr) {
        return;
    }
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + kPhaseAMaxTextureUnits) {
        recordValidationError(context, "glActiveTexture", GL_INVALID_ENUM, "texture unit exceeds Phase A limit");
        return;
    }
    if (context->activeTexture(texture)) {
        markTextureFunction(FunctionId::glActiveTexture, "Active texture unit state is tracked.");
        Runtime::shared().recordBootstrapTrace("glActiveTexture(" + std::to_string(texture) + ")");
    }
}

void APIENTRY glGenTextures(GLsizei n, GLuint* textures) {
    auto* context = requireCurrentContext("glGenTextures");
    if (context == nullptr) {
        return;
    }
    if (context->genTextures(n, textures)) {
        markTextureFunction(FunctionId::glGenTextures, "Texture names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenTextures(" + std::to_string(n) + ")");
    }
}

void APIENTRY glDeleteTextures(GLsizei n, const GLuint* textures) {
    auto* context = requireCurrentContext("glDeleteTextures");
    if (context == nullptr) {
        return;
    }
    if (context->deleteTextures(n, textures)) {
        markTextureFunction(FunctionId::glDeleteTextures, "Texture names are deleted and stale bindings are cleared.");
        Runtime::shared().recordBootstrapTrace("glDeleteTextures(" + std::to_string(n) + ")");
    }
}

GLboolean APIENTRY glIsTexture(GLuint texture) {
    auto* context = requireCurrentContext("glIsTexture");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markTextureFunction(FunctionId::glIsTexture, "Texture object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsTexture(" + std::to_string(texture) + ")");
    return context->isTexture(texture) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindTexture(GLenum target, GLuint texture) {
    auto* context = requireCurrentContext("glBindTexture");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target)) {
        recordValidationError(context, "glBindTexture", GL_INVALID_ENUM, "target is not a Phase A texture target");
        return;
    }
    if (context->bindTexture(target, texture)) {
        markTextureFunction(FunctionId::glBindTexture, "Texture target bindings are tracked per active texture unit.");
        Runtime::shared().recordBootstrapTrace("glBindTexture(" + std::to_string(target) + ", " + std::to_string(texture) + ")");
    }
}

void APIENTRY glTexImage1D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLint border, GLenum format, GLenum type, const void* pixels) {
    auto* context = requireCurrentContext("glTexImage1D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_1D) {
        recordValidationError(context, "glTexImage1D", GL_INVALID_ENUM, "target must be GL_TEXTURE_1D");
        return;
    }
    if (!isValidLegacyUploadInternalFormat(static_cast<GLenum>(internalformat)) || !isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexImage1D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexImage1D", format, type, static_cast<GLenum>(internalformat));
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexImage1D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (!isFormatCompatibleWithInternalFormat(format, static_cast<GLenum>(internalformat))) {
        recordValidationError(context, "glTexImage1D", GL_INVALID_OPERATION, "format/internalformat mismatch");
        return;
    }
    if (context->texImage(target, level, internalformat, width, 1, 1, border, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexImage1D, "1D texture storage and RGBA8 shadow upload are live.");
        Runtime::shared().recordBootstrapTrace("glTexImage1D(" + std::to_string(width) + ")");
    }
}

void APIENTRY glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void* pixels) {
    auto* context = requireCurrentContext("glTexImage2D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_2D
        && target != GL_TEXTURE_1D_ARRAY
        && target != GL_TEXTURE_RECTANGLE
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_X
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_X
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_Y
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_Y
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_Z
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_Z) {
        recordValidationError(context, "glTexImage2D", GL_INVALID_ENUM, "target must be GL_TEXTURE_2D");
        return;
    }
    if (!isValidLegacyUploadInternalFormat(static_cast<GLenum>(internalformat)) || !isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexImage2D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexImage2D", format, type, static_cast<GLenum>(internalformat));
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexImage2D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (!isFormatCompatibleWithInternalFormat(format, static_cast<GLenum>(internalformat))) {
        recordValidationError(context, "glTexImage2D", GL_INVALID_OPERATION, "format/internalformat mismatch");
        return;
    }
    if (context->texImage(target, level, internalformat, width, height, 1, border, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexImage2D, "2D texture storage and RGBA8 shadow upload are live.");
        Runtime::shared().recordBootstrapTrace("glTexImage2D(" + std::to_string(width) + "x" + std::to_string(height) + ")");
    }
}

void APIENTRY glTexImage3D(
    GLenum target,
    GLint level,
    GLint internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLint border,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    auto* context = requireCurrentContext("glTexImage3D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_3D
        && target != GL_TEXTURE_2D_ARRAY
        && target != GL_TEXTURE_CUBE_MAP_ARRAY) {
        recordValidationError(context, "glTexImage3D", GL_INVALID_ENUM, "target must be GL_TEXTURE_3D");
        return;
    }
    if (!isValidLegacyUploadInternalFormat(static_cast<GLenum>(internalformat)) || !isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexImage3D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexImage3D", format, type, static_cast<GLenum>(internalformat));
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexImage3D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (!isFormatCompatibleWithInternalFormat(format, static_cast<GLenum>(internalformat))) {
        recordValidationError(context, "glTexImage3D", GL_INVALID_OPERATION, "format/internalformat mismatch");
        return;
    }
    if (context->texImage(target, level, internalformat, width, height, depth, border, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexImage3D, "3D texture storage and RGBA8 shadow upload are live.");
        Runtime::shared().recordBootstrapTrace("glTexImage3D(" + std::to_string(width) + "x" + std::to_string(height) + "x" + std::to_string(depth) + ")");
    }
}

void APIENTRY glTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels) {
    auto* context = requireCurrentContext("glTexSubImage1D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_1D) {
        recordValidationError(context, "glTexSubImage1D", GL_INVALID_ENUM, "target must be GL_TEXTURE_1D");
        return;
    }
    if (!isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexSubImage1D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexSubImage1D", format, type, 0);
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexSubImage1D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (context->texSubImage(target, level, xoffset, 0, 0, width, 1, 1, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexSubImage1D, "1D texture subimage uploads update shadow and Metal storage.");
        Runtime::shared().recordBootstrapTrace("glTexSubImage1D(" + std::to_string(width) + ")");
    }
}

void APIENTRY glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels) {
    auto* context = requireCurrentContext("glTexSubImage2D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_2D
        && target != GL_TEXTURE_1D_ARRAY
        && target != GL_TEXTURE_RECTANGLE
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_X
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_X
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_Y
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_Y
        && target != GL_TEXTURE_CUBE_MAP_POSITIVE_Z
        && target != GL_TEXTURE_CUBE_MAP_NEGATIVE_Z) {
        recordValidationError(context, "glTexSubImage2D", GL_INVALID_ENUM, "target must be GL_TEXTURE_2D");
        return;
    }
    if (!isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexSubImage2D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexSubImage2D", format, type, 0);
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexSubImage2D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (context->texSubImage(target, level, xoffset, yoffset, 0, width, height, 1, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexSubImage2D, "2D texture subimage uploads update shadow and Metal storage.");
        Runtime::shared().recordBootstrapTrace("glTexSubImage2D(" + std::to_string(width) + "x" + std::to_string(height) + ")");
    }
}

void APIENTRY glTexSubImage3D(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint zoffset,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    auto* context = requireCurrentContext("glTexSubImage3D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_3D
        && target != GL_TEXTURE_2D_ARRAY
        && target != GL_TEXTURE_CUBE_MAP_ARRAY) {
        recordValidationError(context, "glTexSubImage3D", GL_INVALID_ENUM, "target must be GL_TEXTURE_3D");
        return;
    }
    if (!isValidTextureUploadFormat(format) || !isValidTextureUploadType(type)) {
        recordValidationError(context, "glTexSubImage3D", GL_INVALID_ENUM, "format/type combination is outside the Phase A RGBA8 upload path");
        warnUploadRejectionOnce("glTexSubImage3D", format, type, 0);
        return;
    }
    if (!isFormatTypeCompatible(format, type)) {
        recordValidationError(context, "glTexSubImage3D", GL_INVALID_OPERATION, "format/type combination is invalid (Table 8.7)");
        return;
    }
    if (context->texSubImage(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)) {
        markTextureFunction(FunctionId::glTexSubImage3D, "3D texture subimage uploads update shadow and Metal storage.");
        Runtime::shared().recordBootstrapTrace("glTexSubImage3D(" + std::to_string(width) + "x" + std::to_string(height) + "x" + std::to_string(depth) + ")");
    }
}

void APIENTRY glTexParameteri(GLenum target, GLenum pname, GLint param) {
    // GL 4.6 §8.10: the scalar glTexParameteri/f entry points reject
    // 4-component pnames (BORDER_COLOR, SWIZZLE_RGBA) with
    // INVALID_ENUM — they require the vector form. CTS
    // `texture_border_clamp.border_color_errors` asserts this.
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        auto* context = requireCurrentContext("glTexParameteri");
        if (context) recordValidationError(context, "glTexParameteri", GL_INVALID_ENUM,
            "pname takes a 4-component vector; use glTexParameteriv");
        return;
    }
    glTexParameteriv(target, pname, &param);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glTexParameteri, kPhaseATextureTestId, "Texture scalar integer parameters route through the canonical parameter store.");
}

void APIENTRY glTexParameteriv(GLenum target, GLenum pname, const GLint* params) {
    auto* context = requireCurrentContext("glTexParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glTexParameteriv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (!validateTextureParameterValues(pname, params)) {
        recordValidationError(context, "glTexParameteriv", params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->texParameterInteger(target, pname, params)) {
        markTextureFunction(FunctionId::glTexParameteriv, "Texture integer-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glTexParameteriv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        auto* context = requireCurrentContext("glTexParameterf");
        if (context) recordValidationError(context, "glTexParameterf", GL_INVALID_ENUM,
            "pname takes a 4-component vector; use glTexParameterfv");
        return;
    }
    glTexParameterfv(target, pname, &param);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glTexParameterf, kPhaseATextureTestId, "Texture scalar float parameters route through the canonical parameter store.");
}

void APIENTRY glTexParameterfv(GLenum target, GLenum pname, const GLfloat* params) {
    auto* context = requireCurrentContext("glTexParameterfv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glTexParameterfv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (!validateTextureParameterValues(pname, params)) {
        recordValidationError(context, "glTexParameterfv", params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->texParameterFloat(target, pname, params)) {
        markTextureFunction(FunctionId::glTexParameterfv, "Texture float-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glTexParameterfv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glTexParameterIiv(GLenum target, GLenum pname, const GLint* params) {
    auto* context = requireCurrentContext("glTexParameterIiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glTexParameterIiv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (!validateTextureParameterValues(pname, params)) {
        recordValidationError(context, "glTexParameterIiv", params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->texParameterInteger(target, pname, params)) {
        markTextureFunction(FunctionId::glTexParameterIiv, "Texture integer-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glTexParameterIiv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glTexParameterIuiv(GLenum target, GLenum pname, const GLuint* params) {
    auto* context = requireCurrentContext("glTexParameterIuiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname) || params == nullptr) {
        recordValidationError(context, "glTexParameterIuiv", params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "target, pname, or params are invalid");
        return;
    }
    GLint converted[4] = {static_cast<GLint>(params[0]), 0, 0, 0};
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        converted[1] = static_cast<GLint>(params[1]);
        converted[2] = static_cast<GLint>(params[2]);
        converted[3] = static_cast<GLint>(params[3]);
    }
    if (!validateTextureParameterValues(pname, converted)) {
        recordValidationError(context, "glTexParameterIuiv", GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->texParameterUnsignedInteger(target, pname, params)) {
        markTextureFunction(FunctionId::glTexParameterIuiv, "Texture unsigned integer-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glTexParameterIuiv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetTexParameteriv(GLenum target, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetTexParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glGetTexParameteriv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (context->getTexParameterInteger(target, pname, params)) {
        markTextureFunction(FunctionId::glGetTexParameteriv, "Texture integer parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetTexParameteriv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetTexParameterfv(GLenum target, GLenum pname, GLfloat* params) {
    auto* context = requireCurrentContext("glGetTexParameterfv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glGetTexParameterfv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (context->getTexParameterFloat(target, pname, params)) {
        markTextureFunction(FunctionId::glGetTexParameterfv, "Texture float parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetTexParameterfv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetTexParameterIiv(GLenum target, GLenum pname, GLint* params) {
    glGetTexParameteriv(target, pname, params);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glGetTexParameterIiv, kPhaseATextureTestId, "Texture integer parameter queries route through the canonical parameter store.");
}

void APIENTRY glGetTexParameterIuiv(GLenum target, GLenum pname, GLuint* params) {
    auto* context = requireCurrentContext("glGetTexParameterIuiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target) || !isValidTextureParameterPname(pname)) {
        recordValidationError(context, "glGetTexParameterIuiv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (context->getTexParameterUnsignedInteger(target, pname, params)) {
        markTextureFunction(FunctionId::glGetTexParameterIuiv, "Texture unsigned parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetTexParameterIuiv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGenerateMipmap(GLenum target) {
    auto* context = requireCurrentContext("glGenerateMipmap");
    if (context == nullptr) {
        return;
    }
    if (!isValidTextureTarget(target)) {
        recordValidationError(context, "glGenerateMipmap", GL_INVALID_ENUM, "target is not a Phase A texture target");
        return;
    }
    if (context->generateMipmap(target)) {
        markTextureFunction(FunctionId::glGenerateMipmap, "Mipmap chains are generated into texture shadow storage and Metal storage.");
        Runtime::shared().recordBootstrapTrace("glGenerateMipmap(" + std::to_string(target) + ")");
    }
}

void APIENTRY glTexStorage1D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width) {
    auto* context = requireCurrentContext("glTexStorage1D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_1D) {
        recordValidationError(context, "glTexStorage1D", GL_INVALID_ENUM, "target must be GL_TEXTURE_1D");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexStorage1D", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texStorage(target, levels, internalformat, width, 1, 1)) {
        markTextureFunction(FunctionId::glTexStorage1D, "1D immutable texture storage is live.");
        Runtime::shared().recordBootstrapTrace("glTexStorage1D(" + std::to_string(width) + ", " + std::to_string(levels) + " levels)");
    }
}

void APIENTRY glTexStorage2D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glTexStorage2D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_2D && target != GL_TEXTURE_CUBE_MAP &&
        target != GL_TEXTURE_1D_ARRAY && target != GL_TEXTURE_RECTANGLE) {
        recordValidationError(context, "glTexStorage2D", GL_INVALID_ENUM,
                              "target must be GL_TEXTURE_2D, GL_TEXTURE_CUBE_MAP, GL_TEXTURE_1D_ARRAY, or GL_TEXTURE_RECTANGLE");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexStorage2D", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texStorage(target, levels, internalformat, width, height, 1)) {
        markTextureFunction(FunctionId::glTexStorage2D, "2D immutable texture storage is live.");
        Runtime::shared().recordBootstrapTrace("glTexStorage2D(" + std::to_string(width) + "x" + std::to_string(height) + ", " + std::to_string(levels) + " levels)");
    }
}

void APIENTRY glTexStorage3D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth) {
    auto* context = requireCurrentContext("glTexStorage3D");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_3D && target != GL_TEXTURE_2D_ARRAY &&
        target != GL_TEXTURE_CUBE_MAP_ARRAY) {
        recordValidationError(context, "glTexStorage3D", GL_INVALID_ENUM,
                              "target must be GL_TEXTURE_3D, GL_TEXTURE_2D_ARRAY, or GL_TEXTURE_CUBE_MAP_ARRAY");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexStorage3D", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texStorage(target, levels, internalformat, width, height, depth)) {
        markTextureFunction(FunctionId::glTexStorage3D, "3D immutable texture storage is live.");
        Runtime::shared().recordBootstrapTrace("glTexStorage3D(" + std::to_string(width) + "x" + std::to_string(height) + "x" + std::to_string(depth) + ", " + std::to_string(levels) + " levels)");
    }
}

void APIENTRY glTexStorage2DMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations) {
    auto* context = requireCurrentContext("glTexStorage2DMultisample");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_2D_MULTISAMPLE) {
        recordValidationError(context, "glTexStorage2DMultisample", GL_INVALID_ENUM, "target must be GL_TEXTURE_2D_MULTISAMPLE");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexStorage2DMultisample", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texStorageMultisample(target, samples, internalformat, width, height, 1, fixedsamplelocations)) {
        markTextureFunction(FunctionId::glTexStorage2DMultisample, "2D multisample immutable texture storage is live.");
        Runtime::shared().recordBootstrapTrace("glTexStorage2DMultisample(" + std::to_string(width) + "x" + std::to_string(height) + ", " + std::to_string(samples) + " samples)");
    }
}

void APIENTRY glTexStorage3DMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations) {
    auto* context = requireCurrentContext("glTexStorage3DMultisample");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_2D_MULTISAMPLE_ARRAY) {
        recordValidationError(context, "glTexStorage3DMultisample", GL_INVALID_ENUM, "target must be GL_TEXTURE_2D_MULTISAMPLE_ARRAY");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexStorage3DMultisample", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texStorageMultisample(target, samples, internalformat, width, height, depth, fixedsamplelocations)) {
        markTextureFunction(FunctionId::glTexStorage3DMultisample, "3D multisample immutable texture storage is live.");
        Runtime::shared().recordBootstrapTrace("glTexStorage3DMultisample(" + std::to_string(width) + "x" + std::to_string(height) + "x" + std::to_string(depth) + ", " + std::to_string(samples) + " samples)");
    }
}

void APIENTRY glTexBufferRange(GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    auto* context = requireCurrentContext("glTexBufferRange");
    if (context == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_BUFFER) {
        recordValidationError(context, "glTexBufferRange", GL_INVALID_ENUM, "target must be GL_TEXTURE_BUFFER");
        return;
    }
    if (!isValidStorageInternalFormat(context, internalformat)) {
        recordValidationError(context, "glTexBufferRange", GL_INVALID_ENUM, "internalformat is not a supported texture format");
        return;
    }
    if (context->texBufferRange(target, internalformat, buffer, offset, size)) {
        markTextureFunction(FunctionId::glTexBufferRange, "Buffer-texture range binding is live.");
        Runtime::shared().recordBootstrapTrace("glTexBufferRange(buffer=" + std::to_string(buffer) + ", offset=" + std::to_string(offset) + ", size=" + std::to_string(size) + ")");
    }
}

void APIENTRY glPixelStorei(GLenum pname, GLint param) {
    auto* context = requireCurrentContext("glPixelStorei");
    if (context == nullptr) {
        return;
    }
    if (!isValidPixelStorePname(pname)) {
        recordValidationError(context, "glPixelStorei", GL_INVALID_ENUM, "pname is not a supported pixel-store field");
        return;
    }
    if (!isValidPixelStoreValue(pname, param)) {
        recordValidationError(context, "glPixelStorei", GL_INVALID_VALUE, "pixel-store value is invalid");
        return;
    }
    if (context->pixelStore(pname, param)) {
        markTextureFunction(FunctionId::glPixelStorei, "Integer pixel-store state is tracked and queryable.");
        Runtime::shared().recordBootstrapTrace("glPixelStorei(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glPixelStoref(GLenum pname, GLfloat param) {
    if (!std::isfinite(param)) {
        auto* context = requireCurrentContext("glPixelStoref");
        recordValidationError(context, "glPixelStoref", GL_INVALID_VALUE, "pixel-store value must be finite");
        return;
    }
    glPixelStorei(pname, static_cast<GLint>(param));
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glPixelStoref, kPhaseATextureTestId, "Float pixel-store values route through the integer pixel-store state.");
}

void APIENTRY glDrawBuffer(GLenum buffer) {
    auto* context = requireCurrentContext("glDrawBuffer");
    if (context == nullptr) {
        return;
    }
    if (context->drawBuffer(buffer)) {
        markFramebufferFunction(FunctionId::glDrawBuffer, "Single draw-buffer state is tracked for default and user framebuffers.");
        Runtime::shared().recordBootstrapTrace("glDrawBuffer(" + std::to_string(buffer) + ")");
    }
}

void APIENTRY glDrawBuffers(GLsizei n, const GLenum* buffers) {
    auto* context = requireCurrentContext("glDrawBuffers");
    if (context == nullptr) {
        return;
    }
    if (n > static_cast<GLsizei>(kPhaseAMaxDrawBuffers)) {
        recordValidationError(context, "glDrawBuffers", GL_INVALID_VALUE, "draw-buffer count exceeds Phase A limit");
        return;
    }
    if (context->drawBuffers(n, buffers)) {
        markFramebufferFunction(FunctionId::glDrawBuffers, "MRT draw-buffer state is tracked up to the Phase A limit.");
        Runtime::shared().recordBootstrapTrace("glDrawBuffers(" + std::to_string(n) + ")");
    }
}

void APIENTRY glReadBuffer(GLenum buffer) {
    auto* context = requireCurrentContext("glReadBuffer");
    if (context == nullptr) {
        return;
    }
    if (context->readBuffer(buffer)) {
        markFramebufferFunction(FunctionId::glReadBuffer, "Read-buffer state is tracked for default and user framebuffers.");
        Runtime::shared().recordBootstrapTrace("glReadBuffer(" + std::to_string(buffer) + ")");
    }
}

void APIENTRY glGenRenderbuffers(GLsizei n, GLuint* renderbuffers) {
    auto* context = requireCurrentContext("glGenRenderbuffers");
    if (context == nullptr) {
        return;
    }
    if (context->genRenderbuffers(n, renderbuffers)) {
        markFramebufferFunction(FunctionId::glGenRenderbuffers, "Renderbuffer names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenRenderbuffers(" + std::to_string(n) + ")");
    }
}

void APIENTRY glDeleteRenderbuffers(GLsizei n, const GLuint* renderbuffers) {
    auto* context = requireCurrentContext("glDeleteRenderbuffers");
    if (context == nullptr) {
        return;
    }
    if (context->deleteRenderbuffers(n, renderbuffers)) {
        markFramebufferFunction(FunctionId::glDeleteRenderbuffers, "Renderbuffer deletion clears stale bindings and framebuffer attachments.");
        Runtime::shared().recordBootstrapTrace("glDeleteRenderbuffers(" + std::to_string(n) + ")");
    }
}

GLboolean APIENTRY glIsRenderbuffer(GLuint renderbuffer) {
    auto* context = requireCurrentContext("glIsRenderbuffer");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markFramebufferFunction(FunctionId::glIsRenderbuffer, "Renderbuffer object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsRenderbuffer(" + std::to_string(renderbuffer) + ")");
    return context->isRenderbuffer(renderbuffer) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindRenderbuffer(GLenum target, GLuint renderbuffer) {
    auto* context = requireCurrentContext("glBindRenderbuffer");
    if (context == nullptr) {
        return;
    }
    if (!isValidRenderbufferTarget(target)) {
        recordValidationError(context, "glBindRenderbuffer", GL_INVALID_ENUM, "target must be GL_RENDERBUFFER");
        return;
    }
    if (context->bindRenderbuffer(target, renderbuffer)) {
        markFramebufferFunction(FunctionId::glBindRenderbuffer, "Renderbuffer binding state is tracked.");
        Runtime::shared().recordBootstrapTrace("glBindRenderbuffer(" + std::to_string(renderbuffer) + ")");
    }
}

void APIENTRY glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glRenderbufferStorage");
    if (context == nullptr) {
        return;
    }
    if (!isValidRenderbufferTarget(target)) {
        recordValidationError(context, "glRenderbufferStorage", GL_INVALID_ENUM, "target must be GL_RENDERBUFFER");
        return;
    }
    if (!isValidRenderbufferFormat(internalformat)) {
        recordValidationError(context, "glRenderbufferStorage", GL_INVALID_ENUM, "internal format is outside the Phase A renderbuffer set");
        return;
    }
    if (context->renderbufferStorage(target, internalformat, width, height, 0)) {
        markFramebufferFunction(FunctionId::glRenderbufferStorage, "Renderbuffer storage is backed by a Metal render-target texture.");
        Runtime::shared().recordBootstrapTrace("glRenderbufferStorage(" + std::to_string(width) + "x" + std::to_string(height) + ")");
    }
}

void APIENTRY glRenderbufferStorageMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glRenderbufferStorageMultisample");
    if (context == nullptr) {
        return;
    }
    if (!isValidRenderbufferTarget(target)) {
        recordValidationError(context, "glRenderbufferStorageMultisample", GL_INVALID_ENUM, "target must be GL_RENDERBUFFER");
        return;
    }
    if (!isValidRenderbufferFormat(internalformat)) {
        recordValidationError(context, "glRenderbufferStorageMultisample", GL_INVALID_ENUM, "internal format is outside the Phase A renderbuffer set");
        return;
    }
    if (context->renderbufferStorage(target, internalformat, width, height, samples)) {
        markFramebufferFunction(FunctionId::glRenderbufferStorageMultisample, "Multisample renderbuffer metadata and Metal storage are tracked.");
        Runtime::shared().recordBootstrapTrace("glRenderbufferStorageMultisample(" + std::to_string(samples) + ")");
    }
}

void APIENTRY glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetRenderbufferParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidRenderbufferTarget(target) || !isValidRenderbufferParameterPname(pname)) {
        recordValidationError(context, "glGetRenderbufferParameteriv", GL_INVALID_ENUM, "target or pname is invalid");
        return;
    }
    if (context->getRenderbufferParameterInteger(target, pname, params)) {
        markFramebufferFunction(FunctionId::glGetRenderbufferParameteriv, "Renderbuffer storage parameters are queryable.");
        Runtime::shared().recordBootstrapTrace("glGetRenderbufferParameteriv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGenFramebuffers(GLsizei n, GLuint* framebuffers) {
    auto* context = requireCurrentContext("glGenFramebuffers");
    if (context == nullptr) {
        return;
    }
    if (context->genFramebuffers(n, framebuffers)) {
        markFramebufferFunction(FunctionId::glGenFramebuffers, "Framebuffer names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenFramebuffers(" + std::to_string(n) + ")");
    }
}

void APIENTRY glDeleteFramebuffers(GLsizei n, const GLuint* framebuffers) {
    auto* context = requireCurrentContext("glDeleteFramebuffers");
    if (context == nullptr) {
        return;
    }
    if (context->deleteFramebuffers(n, framebuffers)) {
        markFramebufferFunction(FunctionId::glDeleteFramebuffers, "Framebuffer deletion clears stale read/draw bindings.");
        Runtime::shared().recordBootstrapTrace("glDeleteFramebuffers(" + std::to_string(n) + ")");
    }
}

GLboolean APIENTRY glIsFramebuffer(GLuint framebuffer) {
    auto* context = requireCurrentContext("glIsFramebuffer");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markFramebufferFunction(FunctionId::glIsFramebuffer, "Framebuffer object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsFramebuffer(" + std::to_string(framebuffer) + ")");
    return context->isFramebuffer(framebuffer) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindFramebuffer(GLenum target, GLuint framebuffer) {
    auto* context = requireCurrentContext("glBindFramebuffer");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferTarget(target)) {
        recordValidationError(context, "glBindFramebuffer", GL_INVALID_ENUM, "target must be GL_FRAMEBUFFER, GL_DRAW_FRAMEBUFFER, or GL_READ_FRAMEBUFFER");
        return;
    }
    if (context->bindFramebuffer(target, framebuffer)) {
        markFramebufferFunction(FunctionId::glBindFramebuffer, "Framebuffer read/draw bindings are tracked.");
        Runtime::shared().recordBootstrapTrace("glBindFramebuffer(" + std::to_string(target) + ", " + std::to_string(framebuffer) + ")");
    }
}

GLenum APIENTRY glCheckFramebufferStatus(GLenum target) {
    auto* context = requireCurrentContext("glCheckFramebufferStatus");
    if (context == nullptr) {
        return 0;
    }
    if (!isValidFramebufferTarget(target)) {
        recordValidationError(context, "glCheckFramebufferStatus", GL_INVALID_ENUM, "target must be a framebuffer binding point");
        return 0;
    }
    const GLenum status = context->checkFramebufferStatus(target);
    if (status != 0) {
        markFramebufferFunction(FunctionId::glCheckFramebufferStatus, "Framebuffer completeness checks are live.");
        Runtime::shared().recordBootstrapTrace("glCheckFramebufferStatus(" + std::to_string(status) + ")");
    }
    return status;
}

void APIENTRY glFramebufferTexture1D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level) {
    auto* context = requireCurrentContext("glFramebufferTexture1D");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment) || textarget != GL_TEXTURE_1D) {
        recordValidationError(context, "glFramebufferTexture1D", GL_INVALID_ENUM, "attachment or texture target is invalid");
        return;
    }
    if (context->framebufferTexture(target, attachment, textarget, texture, level, 0, false)) {
        markFramebufferFunction(FunctionId::glFramebufferTexture1D, "1D texture framebuffer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferTexture1D(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level) {
    auto* context = requireCurrentContext("glFramebufferTexture2D");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment) ||
        (textarget != GL_TEXTURE_2D &&
         textarget != GL_TEXTURE_2D_MULTISAMPLE &&
         textarget != GL_TEXTURE_CUBE_MAP_POSITIVE_X &&
         textarget != GL_TEXTURE_CUBE_MAP_NEGATIVE_X &&
         textarget != GL_TEXTURE_CUBE_MAP_POSITIVE_Y &&
         textarget != GL_TEXTURE_CUBE_MAP_NEGATIVE_Y &&
         textarget != GL_TEXTURE_CUBE_MAP_POSITIVE_Z &&
         textarget != GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)) {
        recordValidationError(context, "glFramebufferTexture2D", GL_INVALID_ENUM, "attachment or texture target is invalid");
        return;
    }
    if (context->framebufferTexture(target, attachment, textarget, texture, level, 0, false)) {
        markFramebufferFunction(FunctionId::glFramebufferTexture2D, "2D texture framebuffer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferTexture2D(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glFramebufferTexture3D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint zoffset) {
    auto* context = requireCurrentContext("glFramebufferTexture3D");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment) || textarget != GL_TEXTURE_3D) {
        recordValidationError(context, "glFramebufferTexture3D", GL_INVALID_ENUM, "attachment or texture target is invalid");
        return;
    }
    if (context->framebufferTexture(target, attachment, textarget, texture, level, zoffset, false)) {
        markFramebufferFunction(FunctionId::glFramebufferTexture3D, "3D texture framebuffer layer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferTexture3D(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level) {
    auto* context = requireCurrentContext("glFramebufferTexture");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment)) {
        recordValidationError(context, "glFramebufferTexture", GL_INVALID_ENUM, "attachment is invalid");
        return;
    }
    if (context->framebufferTexture(target, attachment, 0, texture, level, 0, true)) {
        markFramebufferFunction(FunctionId::glFramebufferTexture, "Whole-texture framebuffer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferTexture(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glFramebufferTextureLayer(GLenum target, GLenum attachment, GLuint texture, GLint level, GLint layer) {
    auto* context = requireCurrentContext("glFramebufferTextureLayer");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment)) {
        recordValidationError(context, "glFramebufferTextureLayer", GL_INVALID_ENUM, "attachment is invalid");
        return;
    }
    if (context->framebufferTexture(target, attachment, 0, texture, level, layer, false)) {
        markFramebufferFunction(FunctionId::glFramebufferTextureLayer, "Layered texture framebuffer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferTextureLayer(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    auto* context = requireCurrentContext("glFramebufferRenderbuffer");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment) || renderbuffertarget != GL_RENDERBUFFER) {
        recordValidationError(context, "glFramebufferRenderbuffer", GL_INVALID_ENUM, "attachment or renderbuffer target is invalid");
        return;
    }
    if (context->framebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer)) {
        markFramebufferFunction(FunctionId::glFramebufferRenderbuffer, "Renderbuffer framebuffer attachments are tracked.");
        Runtime::shared().recordBootstrapTrace("glFramebufferRenderbuffer(" + std::to_string(attachment) + ")");
    }
}

void APIENTRY glBlitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter) {
    auto* context = requireCurrentContext("glBlitFramebuffer");
    if (context == nullptr) {
        return;
    }
    if (context->blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)) {
        markFramebufferFunction(FunctionId::glBlitFramebuffer, "Framebuffer-to-framebuffer blits route through CPU shadow attachments.");
        Runtime::shared().recordBootstrapTrace("glBlitFramebuffer(" + std::to_string(mask) + ")");
    }
}

void APIENTRY glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetFramebufferAttachmentParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidFramebufferAttachment(attachment) || !isValidFramebufferAttachmentPname(pname)) {
        recordValidationError(context, "glGetFramebufferAttachmentParameteriv", GL_INVALID_ENUM, "attachment or pname is invalid");
        return;
    }
    if (context->getFramebufferAttachmentParameterInteger(target, attachment, pname, params)) {
        markFramebufferFunction(FunctionId::glGetFramebufferAttachmentParameteriv, "Framebuffer attachment parameters are queryable.");
        Runtime::shared().recordBootstrapTrace("glGetFramebufferAttachmentParameteriv(" + std::to_string(pname) + ")");
    }
}

void APIENTRY glGenSamplers(GLsizei count, GLuint* samplers) {
    auto* context = requireCurrentContext("glGenSamplers");
    if (context == nullptr) {
        return;
    }
    if (context->genSamplers(count, samplers)) {
        markTextureFunction(FunctionId::glGenSamplers, "Sampler names are generated in the object store.");
        Runtime::shared().recordBootstrapTrace("glGenSamplers(" + std::to_string(count) + ")");
    }
}

void APIENTRY glDeleteSamplers(GLsizei count, const GLuint* samplers) {
    auto* context = requireCurrentContext("glDeleteSamplers");
    if (context == nullptr) {
        return;
    }
    if (context->deleteSamplers(count, samplers)) {
        markTextureFunction(FunctionId::glDeleteSamplers, "Sampler names are deleted and stale bindings are cleared.");
        Runtime::shared().recordBootstrapTrace("glDeleteSamplers(" + std::to_string(count) + ")");
    }
}

GLboolean APIENTRY glIsSampler(GLuint sampler) {
    auto* context = requireCurrentContext("glIsSampler");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markTextureFunction(FunctionId::glIsSampler, "Sampler object existence queries are live.");
    Runtime::shared().recordBootstrapTrace("glIsSampler(" + std::to_string(sampler) + ")");
    return context->isSampler(sampler) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBindSampler(GLuint unit, GLuint sampler) {
    auto* context = requireCurrentContext("glBindSampler");
    if (context == nullptr) {
        return;
    }
    if (unit >= kPhaseAMaxTextureUnits) {
        recordValidationError(context, "glBindSampler", GL_INVALID_VALUE, "sampler unit exceeds Phase A limit");
        return;
    }
    if (context->bindSampler(unit, sampler)) {
        markTextureFunction(FunctionId::glBindSampler, "Sampler bindings are tracked per texture unit.");
        Runtime::shared().recordBootstrapTrace("glBindSampler(" + std::to_string(unit) + ", " + std::to_string(sampler) + ")");
    }
}

void APIENTRY glSamplerParameteri(GLuint sampler, GLenum pname, GLint param) {
    // GL 4.6 §8.10.3 — scalar glSamplerParameteri/f rejects
    // 4-component pnames with INVALID_ENUM. CTS
    // `texture_border_clamp.border_color_errors` asserts this.
    if (pname == GL_TEXTURE_BORDER_COLOR) {
        auto* context = requireCurrentContext("glSamplerParameteri");
        if (context) recordValidationError(context, "glSamplerParameteri", GL_INVALID_ENUM,
            "pname takes a 4-component vector; use glSamplerParameteriv");
        return;
    }
    glSamplerParameteriv(sampler, pname, &param);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glSamplerParameteri, kPhaseATextureTestId, "Sampler scalar integer parameters route through the canonical parameter store.");
}

void APIENTRY glSamplerParameteriv(GLuint sampler, GLenum pname, const GLint* param) {
    auto* context = requireCurrentContext("glSamplerParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname)) {
        recordValidationError(context, "glSamplerParameteriv", GL_INVALID_ENUM, "pname is invalid for sampler objects");
        return;
    }
    if (!validateTextureParameterValues(pname, param)) {
        recordValidationError(context, "glSamplerParameteriv", param == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->samplerParameterInteger(sampler, pname, param)) {
        markTextureFunction(FunctionId::glSamplerParameteriv, "Sampler integer-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glSamplerParameteriv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glSamplerParameterf(GLuint sampler, GLenum pname, GLfloat param) {
    if (pname == GL_TEXTURE_BORDER_COLOR) {
        auto* context = requireCurrentContext("glSamplerParameterf");
        if (context) recordValidationError(context, "glSamplerParameterf", GL_INVALID_ENUM,
            "pname takes a 4-component vector; use glSamplerParameterfv");
        return;
    }
    glSamplerParameterfv(sampler, pname, &param);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glSamplerParameterf, kPhaseATextureTestId, "Sampler scalar float parameters route through the canonical parameter store.");
}

void APIENTRY glSamplerParameterfv(GLuint sampler, GLenum pname, const GLfloat* param) {
    auto* context = requireCurrentContext("glSamplerParameterfv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname)) {
        recordValidationError(context, "glSamplerParameterfv", GL_INVALID_ENUM, "pname is invalid for sampler objects");
        return;
    }
    if (!validateTextureParameterValues(pname, param)) {
        recordValidationError(context, "glSamplerParameterfv", param == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->samplerParameterFloat(sampler, pname, param)) {
        markTextureFunction(FunctionId::glSamplerParameterfv, "Sampler float-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glSamplerParameterfv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glSamplerParameterIiv(GLuint sampler, GLenum pname, const GLint* param) {
    glSamplerParameteriv(sampler, pname, param);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glSamplerParameterIiv, kPhaseATextureTestId, "Sampler integer-vector parameters route through the canonical parameter store.");
}

void APIENTRY glSamplerParameterIuiv(GLuint sampler, GLenum pname, const GLuint* param) {
    auto* context = requireCurrentContext("glSamplerParameterIuiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname) || param == nullptr) {
        recordValidationError(context, "glSamplerParameterIuiv", param == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM, "pname or param is invalid");
        return;
    }
    GLint converted[4] = {static_cast<GLint>(param[0]), 0, 0, 0};
    if (pname == GL_TEXTURE_BORDER_COLOR) {
        converted[1] = static_cast<GLint>(param[1]);
        converted[2] = static_cast<GLint>(param[2]);
        converted[3] = static_cast<GLint>(param[3]);
    }
    if (!validateTextureParameterValues(pname, converted)) {
        recordValidationError(context, "glSamplerParameterIuiv", GL_INVALID_ENUM, "parameter value is invalid");
        return;
    }
    if (context->samplerParameterUnsignedInteger(sampler, pname, param)) {
        markTextureFunction(FunctionId::glSamplerParameterIuiv, "Sampler unsigned integer-vector parameters are tracked.");
        Runtime::shared().recordBootstrapTrace("glSamplerParameterIuiv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetSamplerParameteriv(GLuint sampler, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetSamplerParameteriv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname)) {
        recordValidationError(context, "glGetSamplerParameteriv", GL_INVALID_ENUM, "pname is invalid for sampler objects");
        return;
    }
    if (context->getSamplerParameterInteger(sampler, pname, params)) {
        markTextureFunction(FunctionId::glGetSamplerParameteriv, "Sampler integer parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetSamplerParameteriv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetSamplerParameterfv(GLuint sampler, GLenum pname, GLfloat* params) {
    auto* context = requireCurrentContext("glGetSamplerParameterfv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname)) {
        recordValidationError(context, "glGetSamplerParameterfv", GL_INVALID_ENUM, "pname is invalid for sampler objects");
        return;
    }
    if (context->getSamplerParameterFloat(sampler, pname, params)) {
        markTextureFunction(FunctionId::glGetSamplerParameterfv, "Sampler float parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetSamplerParameterfv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glGetSamplerParameterIiv(GLuint sampler, GLenum pname, GLint* params) {
    glGetSamplerParameteriv(sampler, pname, params);
    Runtime::shared().coverageStore().markSmokeTested(FunctionId::glGetSamplerParameterIiv, kPhaseATextureTestId, "Sampler integer parameter queries route through the canonical parameter store.");
}

void APIENTRY glGetSamplerParameterIuiv(GLuint sampler, GLenum pname, GLuint* params) {
    auto* context = requireCurrentContext("glGetSamplerParameterIuiv");
    if (context == nullptr) {
        return;
    }
    if (!isValidSamplerParameterPname(pname)) {
        recordValidationError(context, "glGetSamplerParameterIuiv", GL_INVALID_ENUM, "pname is invalid for sampler objects");
        return;
    }
    if (context->getSamplerParameterUnsignedInteger(sampler, pname, params)) {
        markTextureFunction(FunctionId::glGetSamplerParameterIuiv, "Sampler unsigned parameter queries are live.");
        Runtime::shared().recordBootstrapTrace("glGetSamplerParameterIuiv(" + std::to_string(sampler) + ", " + std::to_string(pname) + ")");
    }
}

void APIENTRY glEnable(GLenum cap) {
    auto* context = requireCurrentContext("glEnable");
    if (context == nullptr) {
        return;
    }
    if (isCompatNoOpEnableCap(cap)) {
        // Compat-profile no-op: trace the call so diagnostics can show
        // the legacy probe but don't push an error or update state.
        Runtime::shared().recordBootstrapTrace(
            "glEnable(0x" + [](GLenum c) {
                std::ostringstream out;
                out << std::hex << std::uppercase << c;
                return out.str();
            }(cap) + ") -> compat no-op");
        return;
    }
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glEnable", GL_INVALID_ENUM, buildUnknownCapMessage(cap));
        return;
    }
    context->setEnabled(cap, true);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glEnable,
        kPhaseAStateTestId,
        "Enable-state mirror updates canonical GL state."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glEnable(" + std::to_string(cap) + ")");
}

void APIENTRY glDisable(GLenum cap) {
    auto* context = requireCurrentContext("glDisable");
    if (context == nullptr) {
        return;
    }
    if (isCompatNoOpEnableCap(cap)) {
        Runtime::shared().recordBootstrapTrace(
            "glDisable(0x" + [](GLenum c) {
                std::ostringstream out;
                out << std::hex << std::uppercase << c;
                return out.str();
            }(cap) + ") -> compat no-op");
        return;
    }
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glDisable", GL_INVALID_ENUM, buildUnknownCapMessage(cap));
        return;
    }
    context->setEnabled(cap, false);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glDisable,
        kPhaseAStateTestId,
        "Enable-state mirror updates canonical GL state."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glDisable(" + std::to_string(cap) + ")");
}

GLboolean APIENTRY glIsEnabled(GLenum cap) {
    auto* context = requireCurrentContext("glIsEnabled");
    if (context == nullptr) {
        return GL_FALSE;
    }
    if (isCompatNoOpEnableCap(cap)) {
        // Compat no-op caps always read as disabled — they have no
        // backing state because the underlying pipeline stage was
        // removed in core 3.2. No error pushed.
        Runtime::shared().recordBootstrapTrace(
            "glIsEnabled(0x" + [](GLenum c) {
                std::ostringstream out;
                out << std::hex << std::uppercase << c;
                return out.str();
            }(cap) + ") -> compat no-op (false)");
        return GL_FALSE;
    }
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glIsEnabled", GL_INVALID_ENUM, buildUnknownCapMessage(cap));
        return GL_FALSE;
    }
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glIsEnabled,
        kPhaseAStateTestId,
        "Enable-state mirror answers canonical GL state queries."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glIsEnabled(" + std::to_string(cap) + ")");
    return context->isEnabled(cap) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glBlendFunc(GLenum srcFactor, GLenum dstFactor) {
    auto* context = requireCurrentContext("glBlendFunc");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendFactor(srcFactor) || !isValidBlendFactor(dstFactor)) {
        recordValidationError(context, "glBlendFunc", GL_INVALID_ENUM, "blend factor is invalid");
        return;
    }
    context->setBlendFuncSeparate(srcFactor, dstFactor, srcFactor, dstFactor);
    markStateFunction(FunctionId::glBlendFunc, "Blend factor state is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glBlendFunc(" + std::to_string(srcFactor) + ", " + std::to_string(dstFactor) + ")");
}

void APIENTRY glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    auto* context = requireCurrentContext("glBlendFuncSeparate");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendFactor(srcRGB) || !isValidBlendFactor(dstRGB)
        || !isValidBlendFactor(srcAlpha) || !isValidBlendFactor(dstAlpha)) {
        recordValidationError(context, "glBlendFuncSeparate", GL_INVALID_ENUM, "blend factor is invalid");
        return;
    }
    context->setBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha);
    markStateFunction(FunctionId::glBlendFuncSeparate, "Separate RGB/alpha blend factors are tracked.");
    Runtime::shared().recordBootstrapTrace("glBlendFuncSeparate()");
}

void APIENTRY glBlendEquation(GLenum mode) {
    auto* context = requireCurrentContext("glBlendEquation");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendEquation(mode)) {
        recordValidationError(context, "glBlendEquation", GL_INVALID_ENUM, "blend equation is invalid");
        return;
    }
    context->setBlendEquationSeparate(mode, mode);
    markStateFunction(FunctionId::glBlendEquation, "Blend equation state is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glBlendEquation(" + std::to_string(mode) + ")");
}

void APIENTRY glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha) {
    auto* context = requireCurrentContext("glBlendEquationSeparate");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendEquation(modeRGB) || !isValidBlendEquation(modeAlpha)) {
        recordValidationError(context, "glBlendEquationSeparate", GL_INVALID_ENUM, "blend equation is invalid");
        return;
    }
    context->setBlendEquationSeparate(modeRGB, modeAlpha);
    markStateFunction(FunctionId::glBlendEquationSeparate, "Separate RGB/alpha blend equations are tracked.");
    Runtime::shared().recordBootstrapTrace("glBlendEquationSeparate()");
}

void APIENTRY glBlendFunci(GLuint buf, GLenum src, GLenum dst) {
    auto* context = requireCurrentContext("glBlendFunci");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendFactor(src) || !isValidBlendFactor(dst)) {
        recordValidationError(context, "glBlendFunci", GL_INVALID_ENUM, "blend factor is invalid");
        return;
    }
    if (buf >= 8) {
        recordValidationError(context, "glBlendFunci", GL_INVALID_VALUE, "draw buffer index out of range");
        return;
    }
    context->setBlendFuncSeparatei(buf, src, dst, src, dst);
    markStateFunction(FunctionId::glBlendFunci, "Indexed blend func state is tracked per draw buffer.");
}

void APIENTRY glBlendFuncSeparatei(GLuint buf, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    auto* context = requireCurrentContext("glBlendFuncSeparatei");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendFactor(srcRGB) || !isValidBlendFactor(dstRGB)
        || !isValidBlendFactor(srcAlpha) || !isValidBlendFactor(dstAlpha)) {
        recordValidationError(context, "glBlendFuncSeparatei", GL_INVALID_ENUM, "blend factor is invalid");
        return;
    }
    if (buf >= 8) {
        recordValidationError(context, "glBlendFuncSeparatei", GL_INVALID_VALUE, "draw buffer index out of range");
        return;
    }
    context->setBlendFuncSeparatei(buf, srcRGB, dstRGB, srcAlpha, dstAlpha);
    markStateFunction(FunctionId::glBlendFuncSeparatei, "Indexed separate blend func state is tracked per draw buffer.");
}

void APIENTRY glBlendEquationi(GLuint buf, GLenum mode) {
    auto* context = requireCurrentContext("glBlendEquationi");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendEquation(mode)) {
        recordValidationError(context, "glBlendEquationi", GL_INVALID_ENUM, "blend equation is invalid");
        return;
    }
    if (buf >= 8) {
        recordValidationError(context, "glBlendEquationi", GL_INVALID_VALUE, "draw buffer index out of range");
        return;
    }
    context->setBlendEquationSeparatei(buf, mode, mode);
    markStateFunction(FunctionId::glBlendEquationi, "Indexed blend equation state is tracked per draw buffer.");
}

void APIENTRY glBlendEquationSeparatei(GLuint buf, GLenum modeRGB, GLenum modeAlpha) {
    auto* context = requireCurrentContext("glBlendEquationSeparatei");
    if (context == nullptr) {
        return;
    }
    if (!isValidBlendEquation(modeRGB) || !isValidBlendEquation(modeAlpha)) {
        recordValidationError(context, "glBlendEquationSeparatei", GL_INVALID_ENUM, "blend equation is invalid");
        return;
    }
    if (buf >= 8) {
        recordValidationError(context, "glBlendEquationSeparatei", GL_INVALID_VALUE, "draw buffer index out of range");
        return;
    }
    context->setBlendEquationSeparatei(buf, modeRGB, modeAlpha);
    markStateFunction(FunctionId::glBlendEquationSeparatei, "Indexed separate blend equation state is tracked per draw buffer.");
}

void APIENTRY glMinSampleShading(GLfloat value) {
    auto* context = requireCurrentContext("glMinSampleShading");
    if (context == nullptr) {
        return;
    }
    context->setMinSampleShading(value);
    markStateFunction(FunctionId::glMinSampleShading, "Minimum sample shading value is tracked.");
}

void APIENTRY glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    auto* context = requireCurrentContext("glBlendColor");
    if (context == nullptr) {
        return;
    }
    context->setBlendColor(red, green, blue, alpha);
    markStateFunction(FunctionId::glBlendColor, "Constant blend color is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace(
        "glBlendColor(" + formatFloat(red) + ", " + formatFloat(green) + ", "
        + formatFloat(blue) + ", " + formatFloat(alpha) + ")"
    );
}

void APIENTRY glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    auto* context = requireCurrentContext("glColorMask");
    if (context == nullptr) {
        return;
    }
    context->setColorMask(red, green, blue, alpha);
    markStateFunction(FunctionId::glColorMask, "Global color write mask is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glColorMask()");
}

void APIENTRY glColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    auto* context = requireCurrentContext("glColorMaski");
    if (context == nullptr) {
        return;
    }
    if (index >= kPhaseAMaxDrawBuffers) {
        recordValidationError(context, "glColorMaski", GL_INVALID_VALUE, "draw-buffer index exceeds Phase A limit");
        return;
    }
    context->setColorMaski(index, red, green, blue, alpha);
    markStateFunction(FunctionId::glColorMaski, "Indexed color write mask state is tracked.");
    Runtime::shared().recordBootstrapTrace("glColorMaski(" + std::to_string(index) + ")");
}

void APIENTRY glDepthFunc(GLenum func) {
    auto* context = requireCurrentContext("glDepthFunc");
    if (context == nullptr) {
        return;
    }
    if (!isValidCompareFunc(func)) {
        recordValidationError(context, "glDepthFunc", GL_INVALID_ENUM, "depth function is invalid");
        return;
    }
    context->setDepthFunc(func);
    markStateFunction(FunctionId::glDepthFunc, "Depth compare function is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glDepthFunc(" + std::to_string(func) + ")");
}

void APIENTRY glDepthMask(GLboolean flag) {
    auto* context = requireCurrentContext("glDepthMask");
    if (context == nullptr) {
        return;
    }
    context->setDepthMask(flag);
    markStateFunction(FunctionId::glDepthMask, "Depth write mask is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glDepthMask()");
}

void APIENTRY glStencilFunc(GLenum func, GLint ref, GLuint mask) {
    auto* context = requireCurrentContext("glStencilFunc");
    if (context == nullptr) {
        return;
    }
    if (!isValidCompareFunc(func)) {
        recordValidationError(context, "glStencilFunc", GL_INVALID_ENUM, "compare function is invalid");
        return;
    }
    context->setStencilFuncSeparate(GL_FRONT_AND_BACK, func, ref, mask);
    markStateFunction(FunctionId::glStencilFunc, "Front/back stencil compare state is tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilFunc()");
}

void APIENTRY glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    auto* context = requireCurrentContext("glStencilFuncSeparate");
    if (context == nullptr) {
        return;
    }
    if (!isValidStencilFace(face) || !isValidCompareFunc(func)) {
        recordValidationError(context, "glStencilFuncSeparate", GL_INVALID_ENUM, "face or compare function is invalid");
        return;
    }
    context->setStencilFuncSeparate(face, func, ref, mask);
    markStateFunction(FunctionId::glStencilFuncSeparate, "Separate stencil compare state is tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilFuncSeparate()");
}

void APIENTRY glStencilOp(GLenum fail, GLenum depthFail, GLenum depthPass) {
    auto* context = requireCurrentContext("glStencilOp");
    if (context == nullptr) {
        return;
    }
    if (!isValidStencilOp(fail) || !isValidStencilOp(depthFail) || !isValidStencilOp(depthPass)) {
        recordValidationError(context, "glStencilOp", GL_INVALID_ENUM, "stencil operation is invalid");
        return;
    }
    context->setStencilOpSeparate(GL_FRONT_AND_BACK, fail, depthFail, depthPass);
    markStateFunction(FunctionId::glStencilOp, "Front/back stencil operation state is tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilOp()");
}

void APIENTRY glStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass) {
    auto* context = requireCurrentContext("glStencilOpSeparate");
    if (context == nullptr) {
        return;
    }
    if (!isValidStencilFace(face) || !isValidStencilOp(fail)
        || !isValidStencilOp(depthFail) || !isValidStencilOp(depthPass)) {
        recordValidationError(context, "glStencilOpSeparate", GL_INVALID_ENUM, "face or stencil operation is invalid");
        return;
    }
    context->setStencilOpSeparate(face, fail, depthFail, depthPass);
    markStateFunction(FunctionId::glStencilOpSeparate, "Separate stencil operation state is tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilOpSeparate()");
}

void APIENTRY glStencilMask(GLuint mask) {
    auto* context = requireCurrentContext("glStencilMask");
    if (context == nullptr) {
        return;
    }
    context->setStencilMaskSeparate(GL_FRONT_AND_BACK, mask);
    markStateFunction(FunctionId::glStencilMask, "Front/back stencil write mask is tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilMask(" + std::to_string(mask) + ")");
}

void APIENTRY glStencilMaskSeparate(GLenum face, GLuint mask) {
    auto* context = requireCurrentContext("glStencilMaskSeparate");
    if (context == nullptr) {
        return;
    }
    if (!isValidStencilFace(face)) {
        recordValidationError(context, "glStencilMaskSeparate", GL_INVALID_ENUM, "face is invalid");
        return;
    }
    context->setStencilMaskSeparate(face, mask);
    markStateFunction(FunctionId::glStencilMaskSeparate, "Separate stencil write masks are tracked.");
    Runtime::shared().recordBootstrapTrace("glStencilMaskSeparate()");
}

void APIENTRY glCullFace(GLenum mode) {
    auto* context = requireCurrentContext("glCullFace");
    if (context == nullptr) {
        return;
    }
    if (!isValidCullFaceMode(mode)) {
        recordValidationError(context, "glCullFace", GL_INVALID_ENUM, "cull-face mode is invalid");
        return;
    }
    context->setCullFace(mode);
    markStateFunction(FunctionId::glCullFace, "Cull-face mode is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glCullFace(" + std::to_string(mode) + ")");
}

void APIENTRY glFrontFace(GLenum mode) {
    auto* context = requireCurrentContext("glFrontFace");
    if (context == nullptr) {
        return;
    }
    if (!isValidFrontFace(mode)) {
        recordValidationError(context, "glFrontFace", GL_INVALID_ENUM, "front-face winding is invalid");
        return;
    }
    context->setFrontFace(mode);
    markStateFunction(FunctionId::glFrontFace, "Front-face winding is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glFrontFace(" + std::to_string(mode) + ")");
}

void APIENTRY glPolygonOffset(GLfloat factor, GLfloat units) {
    auto* context = requireCurrentContext("glPolygonOffset");
    if (context == nullptr) {
        return;
    }
    context->setPolygonOffset(factor, units);
    markStateFunction(FunctionId::glPolygonOffset, "Polygon offset factor/units are tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glPolygonOffset(" + formatFloat(factor) + ", " + formatFloat(units) + ")");
}

void APIENTRY glLineWidth(GLfloat width) {
    auto* context = requireCurrentContext("glLineWidth");
    if (context == nullptr) {
        return;
    }
    if (!std::isfinite(width) || width <= 0.0f) {
        recordValidationError(context, "glLineWidth", GL_INVALID_VALUE, "width must be positive");
        return;
    }
    context->setLineWidth(width);
    markStateFunction(FunctionId::glLineWidth, "Line width is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glLineWidth(" + formatFloat(width) + ")");
}

void APIENTRY glPointSize(GLfloat size) {
    auto* context = requireCurrentContext("glPointSize");
    if (context == nullptr) {
        return;
    }
    if (!std::isfinite(size) || size <= 0.0f) {
        recordValidationError(context, "glPointSize", GL_INVALID_VALUE, "size must be positive");
        return;
    }
    context->setPointSize(size);
    markStateFunction(FunctionId::glPointSize, "Point size is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glPointSize(" + formatFloat(size) + ")");
}

void APIENTRY glHint(GLenum target, GLenum mode) {
    auto* context = requireCurrentContext("glHint");
    if (context == nullptr) {
        return;
    }
    if (!isValidHintTarget(target) || !isValidHintMode(mode)) {
        recordValidationError(context, "glHint", GL_INVALID_ENUM, "hint target or mode is invalid");
        return;
    }
    context->setHint(target, mode);
    markStateFunction(FunctionId::glHint, "Hint state is tracked and queryable.");
    Runtime::shared().recordBootstrapTrace("glHint(" + std::to_string(target) + ", " + std::to_string(mode) + ")");
}

const GLubyte* APIENTRY glGetString(GLenum name) {
    auto* context = requireCurrentContext("glGetString");
    if (context == nullptr) {
        return nullptr;
    }
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetString,
        kBootstrapTestId,
        "AppGL reports conservative bootstrap identity strings."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    return context->getString(name);
}

GLenum APIENTRY glGetError(void) {
    auto* context = Runtime::shared().currentContext();
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetError,
        kBootstrapTestId,
        "Bootstrap runtime maintains a per-context error FIFO."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    if (context == nullptr) {
        return GL_NO_ERROR;
    }
    return context->popError();
}

void APIENTRY glDebugMessageControl(
    GLenum source,
    GLenum type,
    GLenum severity,
    GLsizei count,
    const GLuint* ids,
    GLboolean enabled
) {
    auto* context = requireCurrentContext("glDebugMessageControl");
    if (context == nullptr) {
        return;
    }
    if (!isValidDebugSource(source, true) || !isValidDebugType(type, true) || !isValidDebugSeverity(severity, true)) {
        recordValidationError(context, "glDebugMessageControl", GL_INVALID_ENUM, "source, type, or severity is invalid");
        return;
    }
    if (count < 0 || (count > 0 && ids == nullptr)) {
        recordValidationError(context, "glDebugMessageControl", GL_INVALID_VALUE, "count/ids are invalid");
        return;
    }
    context->setDebugMessageControl(source, type, severity, count, ids, enabled);
    markDebugFunction(FunctionId::glDebugMessageControl, "Debug message filtering rules are tracked.");
    Runtime::shared().recordBootstrapTrace("glDebugMessageControl()");
}

void APIENTRY glDebugMessageInsert(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar* buf) {
    auto* context = requireCurrentContext("glDebugMessageInsert");
    if (context == nullptr) {
        return;
    }
    if (!isValidDebugInsertSource(source) || !isValidDebugType(type, false) || !isValidDebugSeverity(severity, false)) {
        recordValidationError(context, "glDebugMessageInsert", GL_INVALID_ENUM, "source, type, or severity is invalid");
        return;
    }
    if (length < 0 && buf == nullptr) {
        recordValidationError(context, "glDebugMessageInsert", GL_INVALID_VALUE, "message must be non-null");
        return;
    }
    if (length > 0 && buf == nullptr) {
        recordValidationError(context, "glDebugMessageInsert", GL_INVALID_VALUE, "message must be non-null");
        return;
    }
    context->insertDebugMessage(source, type, id, severity, stringFromGLText(length, buf));
    markDebugFunction(FunctionId::glDebugMessageInsert, "Application debug messages enter the per-context log.");
    Runtime::shared().recordBootstrapTrace("glDebugMessageInsert(" + std::to_string(id) + ")");
}

void APIENTRY glDebugMessageCallback(GLDEBUGPROC callback, const void* userParam) {
    auto* context = requireCurrentContext("glDebugMessageCallback");
    if (context == nullptr) {
        return;
    }
    context->setDebugCallback(callback, userParam);
    markDebugFunction(FunctionId::glDebugMessageCallback, "Debug callback and user pointer are tracked.");
    Runtime::shared().recordBootstrapTrace("glDebugMessageCallback(callback)");
}

GLuint APIENTRY glGetDebugMessageLog(
    GLuint count,
    GLsizei bufSize,
    GLenum* sources,
    GLenum* types,
    GLuint* ids,
    GLenum* severities,
    GLsizei* lengths,
    GLchar* messageLog
) {
    auto* context = requireCurrentContext("glGetDebugMessageLog");
    if (context == nullptr) {
        return 0;
    }
    const GLuint delivered = context->getDebugMessageLog(count, bufSize, sources, types, ids, severities, lengths, messageLog);
    markDebugFunction(FunctionId::glGetDebugMessageLog, "Per-context debug messages can be drained through glGetDebugMessageLog.");
    Runtime::shared().recordBootstrapTrace("glGetDebugMessageLog(" + std::to_string(delivered) + ")");
    return delivered;
}

void APIENTRY glPushDebugGroup(GLenum source, GLuint id, GLsizei length, const GLchar* message) {
    auto* context = requireCurrentContext("glPushDebugGroup");
    if (context == nullptr) {
        return;
    }
    if (!isValidDebugSource(source, false)) {
        recordValidationError(context, "glPushDebugGroup", GL_INVALID_ENUM, "source is invalid");
        return;
    }
    if ((length < 0 || length > 0) && message == nullptr) {
        recordValidationError(context, "glPushDebugGroup", GL_INVALID_VALUE, "message must be non-null");
        return;
    }
    context->pushDebugGroup(source, id, stringFromGLText(length, message));
    markDebugFunction(FunctionId::glPushDebugGroup, "Debug group stack push is tracked and logged.");
    Runtime::shared().recordBootstrapTrace("glPushDebugGroup(" + std::to_string(id) + ")");
}

void APIENTRY glPopDebugGroup(void) {
    auto* context = requireCurrentContext("glPopDebugGroup");
    if (context == nullptr) {
        return;
    }
    (void)context->popDebugGroup();
    markDebugFunction(FunctionId::glPopDebugGroup, "Debug group stack pop is tracked and logged.");
    Runtime::shared().recordBootstrapTrace("glPopDebugGroup()");
}

void APIENTRY glObjectLabel(GLenum identifier, GLuint name, GLsizei length, const GLchar* label) {
    auto* context = requireCurrentContext("glObjectLabel");
    if (context == nullptr) {
        return;
    }
    if (!isValidDebugObjectIdentifier(identifier)) {
        recordValidationError(context, "glObjectLabel", GL_INVALID_ENUM, "object identifier is invalid");
        return;
    }
    if ((length < 0 || length > 0) && label == nullptr) {
        recordValidationError(context, "glObjectLabel", GL_INVALID_VALUE, "label must be non-null");
        return;
    }
    context->setObjectLabel(identifier, name, stringFromGLText(length, label));
    markDebugFunction(FunctionId::glObjectLabel, "Named GL object labels are tracked.");
    Runtime::shared().recordBootstrapTrace("glObjectLabel(" + std::to_string(identifier) + ", " + std::to_string(name) + ")");
}

void APIENTRY glGetObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label) {
    auto* context = requireCurrentContext("glGetObjectLabel");
    if (context == nullptr) {
        return;
    }
    if (!isValidDebugObjectIdentifier(identifier)) {
        recordValidationError(context, "glGetObjectLabel", GL_INVALID_ENUM, "object identifier is invalid");
        return;
    }
    context->getObjectLabel(identifier, name, bufSize, length, label);
    markDebugFunction(FunctionId::glGetObjectLabel, "Named GL object labels are queryable.");
    Runtime::shared().recordBootstrapTrace("glGetObjectLabel(" + std::to_string(identifier) + ", " + std::to_string(name) + ")");
}

void APIENTRY glObjectPtrLabel(const void* ptr, GLsizei length, const GLchar* label) {
    auto* context = requireCurrentContext("glObjectPtrLabel");
    if (context == nullptr) {
        return;
    }
    if ((length < 0 || length > 0) && label == nullptr) {
        recordValidationError(context, "glObjectPtrLabel", GL_INVALID_VALUE, "label must be non-null");
        return;
    }
    context->setObjectPtrLabel(ptr, stringFromGLText(length, label));
    markDebugFunction(FunctionId::glObjectPtrLabel, "Pointer labels are tracked.");
    Runtime::shared().recordBootstrapTrace("glObjectPtrLabel()");
}

void APIENTRY glGetObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label) {
    auto* context = requireCurrentContext("glGetObjectPtrLabel");
    if (context == nullptr) {
        return;
    }
    context->getObjectPtrLabel(ptr, bufSize, length, label);
    markDebugFunction(FunctionId::glGetObjectPtrLabel, "Pointer labels are queryable.");
    Runtime::shared().recordBootstrapTrace("glGetObjectPtrLabel()");
}

void APIENTRY glGetPointerv(GLenum pname, void** params) {
    auto* context = requireCurrentContext("glGetPointerv");
    if (context == nullptr) {
        return;
    }
    (void)context->getPointer(pname, params);
    markDebugFunction(FunctionId::glGetPointerv, "Debug callback pointers are queryable.");
    Runtime::shared().recordBootstrapTrace("glGetPointerv(" + std::to_string(pname) + ")");
}

// ============================================================================
// Group 6 — Shaders and Programs
// ============================================================================

GLuint APIENTRY glCreateShader(GLenum type) {
    auto* context = requireCurrentContext("glCreateShader");
    if (context == nullptr) {
        return 0;
    }
    const GLuint id = context->createShader(type);
    if (id != 0) {
        markShaderFunction(FunctionId::glCreateShader, "Shader objects are created with a stage tag.");
        Runtime::shared().recordBootstrapTrace("glCreateShader(" + std::to_string(type) + ") -> " + std::to_string(id));
    }
    return id;
}

void APIENTRY glDeleteShader(GLuint shader) {
    auto* context = requireCurrentContext("glDeleteShader");
    if (context == nullptr) {
        return;
    }
    if (context->deleteShader(shader)) {
        markShaderFunction(FunctionId::glDeleteShader, "Shader objects are removed from the object store.");
        Runtime::shared().recordBootstrapTrace("glDeleteShader(" + std::to_string(shader) + ")");
    }
}

GLboolean APIENTRY glIsShader(GLuint shader) {
    auto* context = requireCurrentContext("glIsShader");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markShaderFunction(FunctionId::glIsShader, "Shader existence queries are live.");
    return context->isShader(shader) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glShaderSource(GLuint shader, GLsizei count, const GLchar* const* strings, const GLint* length) {
    auto* context = requireCurrentContext("glShaderSource");
    if (context == nullptr) {
        return;
    }
    if (context->shaderSource(shader, count, strings, length)) {
        markShaderFunction(FunctionId::glShaderSource, "Shader source strings are concatenated and stored.");
        Runtime::shared().recordBootstrapTrace("glShaderSource(" + std::to_string(shader) + ", " + std::to_string(count) + ")");
    }
}

void APIENTRY glCompileShader(GLuint shader) {
    auto* context = requireCurrentContext("glCompileShader");
    if (context == nullptr) {
        return;
    }
    const bool ok = context->compileShader(shader);
    markShaderFunction(FunctionId::glCompileShader, "Shader source is reflected for declarations.");
    Runtime::shared().recordBootstrapTrace(
        "glCompileShader(" + std::to_string(shader) + ") -> " + (ok ? "ok" : "failed")
    );
}

void APIENTRY glGetShaderiv(GLuint shader, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetShaderiv");
    if (context == nullptr) {
        return;
    }
    if (context->getShaderiv(shader, pname, params)) {
        markShaderFunction(FunctionId::glGetShaderiv, "Shader integer queries expose stage, status, and lengths.");
    }
}

void APIENTRY glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    auto* context = requireCurrentContext("glGetShaderInfoLog");
    if (context == nullptr) {
        return;
    }
    if (context->getShaderInfoLog(shader, bufSize, length, infoLog)) {
        markShaderFunction(FunctionId::glGetShaderInfoLog, "Shader compile logs are queryable.");
    }
}

void APIENTRY glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source) {
    auto* context = requireCurrentContext("glGetShaderSource");
    if (context == nullptr) {
        return;
    }
    if (context->getShaderSource(shader, bufSize, length, source)) {
        markShaderFunction(FunctionId::glGetShaderSource, "Stored shader source is queryable.");
    }
}

GLuint APIENTRY glCreateProgram(void) {
    auto* context = requireCurrentContext("glCreateProgram");
    if (context == nullptr) {
        return 0;
    }
    const GLuint id = context->createProgram();
    markProgramFunction(FunctionId::glCreateProgram, "Program objects are created in the object store.");
    Runtime::shared().recordBootstrapTrace("glCreateProgram() -> " + std::to_string(id));
    return id;
}

void APIENTRY glDeleteProgram(GLuint program) {
    auto* context = requireCurrentContext("glDeleteProgram");
    if (context == nullptr) {
        return;
    }
    if (context->deleteProgram(program)) {
        markProgramFunction(FunctionId::glDeleteProgram, "Program objects are removed and unbound on delete.");
        Runtime::shared().recordBootstrapTrace("glDeleteProgram(" + std::to_string(program) + ")");
    }
}

GLboolean APIENTRY glIsProgram(GLuint program) {
    auto* context = requireCurrentContext("glIsProgram");
    if (context == nullptr) {
        return GL_FALSE;
    }
    markProgramFunction(FunctionId::glIsProgram, "Program existence queries are live.");
    return context->isProgram(program) ? GL_TRUE : GL_FALSE;
}

void APIENTRY glAttachShader(GLuint program, GLuint shader) {
    auto* context = requireCurrentContext("glAttachShader");
    if (context == nullptr) {
        return;
    }
    if (context->attachShader(program, shader)) {
        markProgramFunction(FunctionId::glAttachShader, "Shader attachments are tracked per program.");
        Runtime::shared().recordBootstrapTrace("glAttachShader(" + std::to_string(program) + ", " + std::to_string(shader) + ")");
    }
}

void APIENTRY glDetachShader(GLuint program, GLuint shader) {
    auto* context = requireCurrentContext("glDetachShader");
    if (context == nullptr) {
        return;
    }
    if (context->detachShader(program, shader)) {
        markProgramFunction(FunctionId::glDetachShader, "Shader attachments are removable.");
        Runtime::shared().recordBootstrapTrace("glDetachShader(" + std::to_string(program) + ", " + std::to_string(shader) + ")");
    }
}

void APIENTRY glLinkProgram(GLuint program) {
    auto* context = requireCurrentContext("glLinkProgram");
    if (context == nullptr) {
        return;
    }
    // GL 4.6 §7.3: INVALID_OPERATION if program is in use by any active XFB
    // (includes paused — the spec says "not active" meaning not ended).
    if (context->isTransformFeedbackActive() &&
        program == context->state().currentProgram()) {
        recordValidationError(context, "glLinkProgram", GL_INVALID_OPERATION,
                              "cannot link the active program while transform feedback is active");
        return;
    }
    const bool ok = context->linkProgram(program);
    markProgramFunction(FunctionId::glLinkProgram, "Program link merges shader reflections and assigns locations.");
    Runtime::shared().recordBootstrapTrace(
        "glLinkProgram(" + std::to_string(program) + ") -> " + (ok ? "ok" : "failed")
    );
}

void APIENTRY glUseProgram(GLuint program) {
    auto* context = requireCurrentContext("glUseProgram");
    if (context == nullptr) {
        return;
    }
    // GL 4.6 §7.3: INVALID_OPERATION if transform feedback is active and NOT paused.
    // CTS's tcu::glu::resetState (framework/opengl/gluStateReset.cpp:1109) calls
    // useProgram(0) BEFORE endTransformFeedback in its reset sequence. When a
    // transform-feedback test fails mid-stream and leaves TF active, this strict
    // gate blocks the reset's useProgram(0), leaks GL_INVALID_OPERATION, aborts
    // the rest of the reset, and cascades failures into the next ~648 tests
    // (observed: shaders30.* dropping from 100% → 0.5%). Since our TF
    // implementation is a stub that doesn't actually capture data, the only
    // effect of the gate is the cascade. Auto-end TF on useProgram(0) to unblock
    // the reset path; keep the gate for non-zero program switches so genuine TF
    // tests still observe the spec'd error.
    if (context->isTransformFeedbackActive() && !context->isTransformFeedbackPaused()) {
        if (program == 0) {
            context->setTransformFeedbackActive(false);
        } else {
            recordValidationError(context, "glUseProgram", GL_INVALID_OPERATION, "cannot change program while transform feedback is active and not paused");
            return;
        }
    }
    if (context->useProgram(program)) {
        markProgramFunction(FunctionId::glUseProgram, "Current program is tracked in the state mirror.");
        Runtime::shared().recordBootstrapTrace("glUseProgram(" + std::to_string(program) + ")");
    }
}

void APIENTRY glValidateProgram(GLuint program) {
    auto* context = requireCurrentContext("glValidateProgram");
    if (context == nullptr) {
        return;
    }
    context->validateProgram(program);
    markProgramFunction(FunctionId::glValidateProgram, "Program validation status is tracked.");
}

void APIENTRY glGetProgramiv(GLuint program, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetProgramiv");
    if (context == nullptr) {
        return;
    }
    if (context->getProgramiv(program, pname, params)) {
        markProgramFunction(FunctionId::glGetProgramiv, "Program integer queries expose link/validate state and counts.");
    }
}

void APIENTRY glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    auto* context = requireCurrentContext("glGetProgramInfoLog");
    if (context == nullptr) {
        return;
    }
    if (context->getProgramInfoLog(program, bufSize, length, infoLog)) {
        markProgramFunction(FunctionId::glGetProgramInfoLog, "Program info logs are queryable.");
    }
}

void APIENTRY glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders) {
    auto* context = requireCurrentContext("glGetAttachedShaders");
    if (context == nullptr) {
        return;
    }
    if (context->getAttachedShaders(program, maxCount, count, shaders)) {
        markProgramFunction(FunctionId::glGetAttachedShaders, "Attached shader names are enumerable.");
    }
}

void APIENTRY glBindAttribLocation(GLuint program, GLuint index, const GLchar* name) {
    auto* context = requireCurrentContext("glBindAttribLocation");
    if (context == nullptr) {
        return;
    }
    if (context->bindAttribLocation(program, index, name)) {
        markProgramFunction(FunctionId::glBindAttribLocation, "Pre-link attribute location requests are honored.");
    }
}

GLint APIENTRY glGetAttribLocation(GLuint program, const GLchar* name) {
    auto* context = requireCurrentContext("glGetAttribLocation");
    if (context == nullptr) {
        return -1;
    }
    markProgramFunction(FunctionId::glGetAttribLocation, "Vertex attribute locations are queryable post-link.");
    return context->getAttribLocation(program, name);
}

void APIENTRY glGetActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    auto* context = requireCurrentContext("glGetActiveAttrib");
    if (context == nullptr) {
        return;
    }
    if (context->getActiveAttrib(program, index, bufSize, length, size, type, name)) {
        markProgramFunction(FunctionId::glGetActiveAttrib, "Active vertex attribute reflection is live.");
    }
}

GLint APIENTRY glGetUniformLocation(GLuint program, const GLchar* name) {
    auto* context = requireCurrentContext("glGetUniformLocation");
    if (context == nullptr) {
        return -1;
    }
    markProgramFunction(FunctionId::glGetUniformLocation, "Uniform locations are queryable post-link.");
    return context->getUniformLocation(program, name);
}

void APIENTRY glGetActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    auto* context = requireCurrentContext("glGetActiveUniform");
    if (context == nullptr) {
        return;
    }
    if (context->getActiveUniform(program, index, bufSize, length, size, type, name)) {
        markProgramFunction(FunctionId::glGetActiveUniform, "Active uniform reflection is live.");
    }
}

void APIENTRY glGetUniformfv(GLuint program, GLint location, GLfloat* params) {
    auto* context = requireCurrentContext("glGetUniformfv");
    if (context == nullptr) {
        return;
    }
    if (context->getUniformfv(program, location, params)) {
        markProgramFunction(FunctionId::glGetUniformfv, "Uniform float readback is live.");
    }
}

void APIENTRY glGetUniformiv(GLuint program, GLint location, GLint* params) {
    auto* context = requireCurrentContext("glGetUniformiv");
    if (context == nullptr) {
        return;
    }
    if (context->getUniformiv(program, location, params)) {
        markProgramFunction(FunctionId::glGetUniformiv, "Uniform integer readback is live.");
    }
}

void APIENTRY glGetUniformuiv(GLuint program, GLint location, GLuint* params) {
    auto* context = requireCurrentContext("glGetUniformuiv");
    if (context == nullptr) {
        return;
    }
    if (context->getUniformuiv(program, location, params)) {
        markProgramFunction(FunctionId::glGetUniformuiv, "Uniform unsigned integer readback is live.");
    }
}

namespace {
constexpr GLContext::UniformElementType kFloatElement = GLContext::UniformElementType::Float;
constexpr GLContext::UniformElementType kIntElement = GLContext::UniformElementType::Int;
constexpr GLContext::UniformElementType kUIntElement = GLContext::UniformElementType::UnsignedInt;

inline void traceUniform(const char* name, GLint location) {
    Runtime::shared().recordBootstrapTrace(std::string(name) + "(" + std::to_string(location) + ")");
}
}  // namespace

void APIENTRY glUniform1f(GLint location, GLfloat v0) {
    auto* context = requireCurrentContext("glUniform1f");
    if (context == nullptr) return;
    GLfloat v[1] = {v0};
    if (context->setUniformScalarVector(location, kFloatElement, 1, 1, v)) {
        markProgramFunction(FunctionId::glUniform1f, "Float scalar uniforms are live.");
        traceUniform("glUniform1f", location);
    }
}
void APIENTRY glUniform2f(GLint location, GLfloat v0, GLfloat v1) {
    auto* context = requireCurrentContext("glUniform2f");
    if (context == nullptr) return;
    GLfloat v[2] = {v0, v1};
    if (context->setUniformScalarVector(location, kFloatElement, 2, 1, v)) {
        markProgramFunction(FunctionId::glUniform2f, "Float vec2 uniforms are live.");
        traceUniform("glUniform2f", location);
    }
}
void APIENTRY glUniform3f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2) {
    auto* context = requireCurrentContext("glUniform3f");
    if (context == nullptr) return;
    GLfloat v[3] = {v0, v1, v2};
    if (context->setUniformScalarVector(location, kFloatElement, 3, 1, v)) {
        markProgramFunction(FunctionId::glUniform3f, "Float vec3 uniforms are live.");
        traceUniform("glUniform3f", location);
    }
}
void APIENTRY glUniform4f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) {
    auto* context = requireCurrentContext("glUniform4f");
    if (context == nullptr) return;
    GLfloat v[4] = {v0, v1, v2, v3};
    if (context->setUniformScalarVector(location, kFloatElement, 4, 1, v)) {
        markProgramFunction(FunctionId::glUniform4f, "Float vec4 uniforms are live.");
        traceUniform("glUniform4f", location);
    }
}

void APIENTRY glUniform1i(GLint location, GLint v0) {
    auto* context = requireCurrentContext("glUniform1i");
    if (context == nullptr) return;
    GLint v[1] = {v0};
    if (context->setUniformScalarVector(location, kIntElement, 1, 1, v)) {
        markProgramFunction(FunctionId::glUniform1i, "Int scalar uniforms are live.");
        traceUniform("glUniform1i", location);
    }
}
void APIENTRY glUniform2i(GLint location, GLint v0, GLint v1) {
    auto* context = requireCurrentContext("glUniform2i");
    if (context == nullptr) return;
    GLint v[2] = {v0, v1};
    if (context->setUniformScalarVector(location, kIntElement, 2, 1, v)) {
        markProgramFunction(FunctionId::glUniform2i, "Int vec2 uniforms are live.");
        traceUniform("glUniform2i", location);
    }
}
void APIENTRY glUniform3i(GLint location, GLint v0, GLint v1, GLint v2) {
    auto* context = requireCurrentContext("glUniform3i");
    if (context == nullptr) return;
    GLint v[3] = {v0, v1, v2};
    if (context->setUniformScalarVector(location, kIntElement, 3, 1, v)) {
        markProgramFunction(FunctionId::glUniform3i, "Int vec3 uniforms are live.");
        traceUniform("glUniform3i", location);
    }
}
void APIENTRY glUniform4i(GLint location, GLint v0, GLint v1, GLint v2, GLint v3) {
    auto* context = requireCurrentContext("glUniform4i");
    if (context == nullptr) return;
    GLint v[4] = {v0, v1, v2, v3};
    if (context->setUniformScalarVector(location, kIntElement, 4, 1, v)) {
        markProgramFunction(FunctionId::glUniform4i, "Int vec4 uniforms are live.");
        traceUniform("glUniform4i", location);
    }
}

void APIENTRY glUniform1ui(GLint location, GLuint v0) {
    auto* context = requireCurrentContext("glUniform1ui");
    if (context == nullptr) return;
    GLuint v[1] = {v0};
    if (context->setUniformScalarVector(location, kUIntElement, 1, 1, v)) {
        markProgramFunction(FunctionId::glUniform1ui, "Unsigned scalar uniforms are live.");
        traceUniform("glUniform1ui", location);
    }
}
void APIENTRY glUniform2ui(GLint location, GLuint v0, GLuint v1) {
    auto* context = requireCurrentContext("glUniform2ui");
    if (context == nullptr) return;
    GLuint v[2] = {v0, v1};
    if (context->setUniformScalarVector(location, kUIntElement, 2, 1, v)) {
        markProgramFunction(FunctionId::glUniform2ui, "Unsigned uvec2 uniforms are live.");
        traceUniform("glUniform2ui", location);
    }
}
void APIENTRY glUniform3ui(GLint location, GLuint v0, GLuint v1, GLuint v2) {
    auto* context = requireCurrentContext("glUniform3ui");
    if (context == nullptr) return;
    GLuint v[3] = {v0, v1, v2};
    if (context->setUniformScalarVector(location, kUIntElement, 3, 1, v)) {
        markProgramFunction(FunctionId::glUniform3ui, "Unsigned uvec3 uniforms are live.");
        traceUniform("glUniform3ui", location);
    }
}
void APIENTRY glUniform4ui(GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3) {
    auto* context = requireCurrentContext("glUniform4ui");
    if (context == nullptr) return;
    GLuint v[4] = {v0, v1, v2, v3};
    if (context->setUniformScalarVector(location, kUIntElement, 4, 1, v)) {
        markProgramFunction(FunctionId::glUniform4ui, "Unsigned uvec4 uniforms are live.");
        traceUniform("glUniform4ui", location);
    }
}

void APIENTRY glUniform1fv(GLint location, GLsizei count, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniform1fv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kFloatElement, 1, count, value)) {
        markProgramFunction(FunctionId::glUniform1fv, "Float scalar uniform arrays are live.");
        traceUniform("glUniform1fv", location);
    }
}
void APIENTRY glUniform2fv(GLint location, GLsizei count, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniform2fv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kFloatElement, 2, count, value)) {
        markProgramFunction(FunctionId::glUniform2fv, "vec2 uniform arrays are live.");
        traceUniform("glUniform2fv", location);
    }
}
void APIENTRY glUniform3fv(GLint location, GLsizei count, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniform3fv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kFloatElement, 3, count, value)) {
        markProgramFunction(FunctionId::glUniform3fv, "vec3 uniform arrays are live.");
        traceUniform("glUniform3fv", location);
    }
}
void APIENTRY glUniform4fv(GLint location, GLsizei count, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniform4fv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kFloatElement, 4, count, value)) {
        markProgramFunction(FunctionId::glUniform4fv, "vec4 uniform arrays are live.");
        traceUniform("glUniform4fv", location);
    }
}
void APIENTRY glUniform1iv(GLint location, GLsizei count, const GLint* value) {
    auto* context = requireCurrentContext("glUniform1iv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kIntElement, 1, count, value)) {
        markProgramFunction(FunctionId::glUniform1iv, "Int scalar uniform arrays are live.");
        traceUniform("glUniform1iv", location);
    }
}
void APIENTRY glUniform2iv(GLint location, GLsizei count, const GLint* value) {
    auto* context = requireCurrentContext("glUniform2iv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kIntElement, 2, count, value)) {
        markProgramFunction(FunctionId::glUniform2iv, "ivec2 uniform arrays are live.");
        traceUniform("glUniform2iv", location);
    }
}
void APIENTRY glUniform3iv(GLint location, GLsizei count, const GLint* value) {
    auto* context = requireCurrentContext("glUniform3iv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kIntElement, 3, count, value)) {
        markProgramFunction(FunctionId::glUniform3iv, "ivec3 uniform arrays are live.");
        traceUniform("glUniform3iv", location);
    }
}
void APIENTRY glUniform4iv(GLint location, GLsizei count, const GLint* value) {
    auto* context = requireCurrentContext("glUniform4iv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kIntElement, 4, count, value)) {
        markProgramFunction(FunctionId::glUniform4iv, "ivec4 uniform arrays are live.");
        traceUniform("glUniform4iv", location);
    }
}
void APIENTRY glUniform1uiv(GLint location, GLsizei count, const GLuint* value) {
    auto* context = requireCurrentContext("glUniform1uiv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kUIntElement, 1, count, value)) {
        markProgramFunction(FunctionId::glUniform1uiv, "uint scalar uniform arrays are live.");
        traceUniform("glUniform1uiv", location);
    }
}
void APIENTRY glUniform2uiv(GLint location, GLsizei count, const GLuint* value) {
    auto* context = requireCurrentContext("glUniform2uiv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kUIntElement, 2, count, value)) {
        markProgramFunction(FunctionId::glUniform2uiv, "uvec2 uniform arrays are live.");
        traceUniform("glUniform2uiv", location);
    }
}
void APIENTRY glUniform3uiv(GLint location, GLsizei count, const GLuint* value) {
    auto* context = requireCurrentContext("glUniform3uiv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kUIntElement, 3, count, value)) {
        markProgramFunction(FunctionId::glUniform3uiv, "uvec3 uniform arrays are live.");
        traceUniform("glUniform3uiv", location);
    }
}
void APIENTRY glUniform4uiv(GLint location, GLsizei count, const GLuint* value) {
    auto* context = requireCurrentContext("glUniform4uiv");
    if (context == nullptr) return;
    if (context->setUniformScalarVector(location, kUIntElement, 4, count, value)) {
        markProgramFunction(FunctionId::glUniform4uiv, "uvec4 uniform arrays are live.");
        traceUniform("glUniform4uiv", location);
    }
}

void APIENTRY glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniformMatrix2fv");
    if (context == nullptr) return;
    if (context->setUniformMatrix(location, 2, 2, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix2fv, "mat2 uniforms are live.");
        traceUniform("glUniformMatrix2fv", location);
    }
}
void APIENTRY glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniformMatrix3fv");
    if (context == nullptr) return;
    if (context->setUniformMatrix(location, 3, 3, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix3fv, "mat3 uniforms are live.");
        traceUniform("glUniformMatrix3fv", location);
    }
}
void APIENTRY glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* context = requireCurrentContext("glUniformMatrix4fv");
    if (context == nullptr) return;
    if (context->setUniformMatrix(location, 4, 4, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix4fv, "mat4 uniforms are live.");
        traceUniform("glUniformMatrix4fv", location);
    }
}

// GL 4.0 double-precision uniform setters. The Metal pipeline receives f32;
// original f64 values are shadowed for lossless glGetUniformdv readback.
void APIENTRY glGetUniformdv(GLuint program, GLint location, GLdouble* params) {
    auto* context = requireCurrentContext("glGetUniformdv");
    if (context == nullptr) return;
    if (context->getUniformdv(program, location, params)) {
        markProgramFunction(FunctionId::glGetUniformdv, "Double uniform readback is live via CPU shadow.");
    }
}

void APIENTRY glUniform1d(GLint location, GLdouble x) {
    auto* context = requireCurrentContext("glUniform1d");
    if (context == nullptr) return;
    GLdouble v[1] = {x};
    if (context->setUniformDouble(location, 1, 1, v)) {
        markProgramFunction(FunctionId::glUniform1d, "Double scalar uniforms narrowed to float.");
        traceUniform("glUniform1d", location);
    }
}
void APIENTRY glUniform2d(GLint location, GLdouble x, GLdouble y) {
    auto* context = requireCurrentContext("glUniform2d");
    if (context == nullptr) return;
    GLdouble v[2] = {x, y};
    if (context->setUniformDouble(location, 2, 1, v)) {
        markProgramFunction(FunctionId::glUniform2d, "Double dvec2 uniforms narrowed to float.");
        traceUniform("glUniform2d", location);
    }
}
void APIENTRY glUniform3d(GLint location, GLdouble x, GLdouble y, GLdouble z) {
    auto* context = requireCurrentContext("glUniform3d");
    if (context == nullptr) return;
    GLdouble v[3] = {x, y, z};
    if (context->setUniformDouble(location, 3, 1, v)) {
        markProgramFunction(FunctionId::glUniform3d, "Double dvec3 uniforms narrowed to float.");
        traceUniform("glUniform3d", location);
    }
}
void APIENTRY glUniform4d(GLint location, GLdouble x, GLdouble y, GLdouble z, GLdouble w) {
    auto* context = requireCurrentContext("glUniform4d");
    if (context == nullptr) return;
    GLdouble v[4] = {x, y, z, w};
    if (context->setUniformDouble(location, 4, 1, v)) {
        markProgramFunction(FunctionId::glUniform4d, "Double dvec4 uniforms narrowed to float.");
        traceUniform("glUniform4d", location);
    }
}
void APIENTRY glUniform1dv(GLint location, GLsizei count, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniform1dv");
    if (context == nullptr) return;
    if (context->setUniformDouble(location, 1, count, value)) {
        markProgramFunction(FunctionId::glUniform1dv, "Double scalar uniform arrays narrowed to float.");
        traceUniform("glUniform1dv", location);
    }
}
void APIENTRY glUniform2dv(GLint location, GLsizei count, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniform2dv");
    if (context == nullptr) return;
    if (context->setUniformDouble(location, 2, count, value)) {
        markProgramFunction(FunctionId::glUniform2dv, "Double dvec2 uniform arrays narrowed to float.");
        traceUniform("glUniform2dv", location);
    }
}
void APIENTRY glUniform3dv(GLint location, GLsizei count, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniform3dv");
    if (context == nullptr) return;
    if (context->setUniformDouble(location, 3, count, value)) {
        markProgramFunction(FunctionId::glUniform3dv, "Double dvec3 uniform arrays narrowed to float.");
        traceUniform("glUniform3dv", location);
    }
}
void APIENTRY glUniform4dv(GLint location, GLsizei count, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniform4dv");
    if (context == nullptr) return;
    if (context->setUniformDouble(location, 4, count, value)) {
        markProgramFunction(FunctionId::glUniform4dv, "Double dvec4 uniform arrays narrowed to float.");
        traceUniform("glUniform4dv", location);
    }
}
void APIENTRY glUniformMatrix2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix2dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 2, 2, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix2dv, "Double dmat2 uniforms narrowed to float.");
        traceUniform("glUniformMatrix2dv", location);
    }
}
void APIENTRY glUniformMatrix3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix3dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 3, 3, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix3dv, "Double dmat3 uniforms narrowed to float.");
        traceUniform("glUniformMatrix3dv", location);
    }
}
void APIENTRY glUniformMatrix4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix4dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 4, 4, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix4dv, "Double dmat4 uniforms narrowed to float.");
        traceUniform("glUniformMatrix4dv", location);
    }
}
void APIENTRY glUniformMatrix2x3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix2x3dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 2, 3, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix2x3dv, "Double dmat2x3 uniforms narrowed to float.");
        traceUniform("glUniformMatrix2x3dv", location);
    }
}
void APIENTRY glUniformMatrix2x4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix2x4dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 2, 4, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix2x4dv, "Double dmat2x4 uniforms narrowed to float.");
        traceUniform("glUniformMatrix2x4dv", location);
    }
}
void APIENTRY glUniformMatrix3x2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix3x2dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 3, 2, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix3x2dv, "Double dmat3x2 uniforms narrowed to float.");
        traceUniform("glUniformMatrix3x2dv", location);
    }
}
void APIENTRY glUniformMatrix3x4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix3x4dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 3, 4, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix3x4dv, "Double dmat3x4 uniforms narrowed to float.");
        traceUniform("glUniformMatrix3x4dv", location);
    }
}
void APIENTRY glUniformMatrix4x2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix4x2dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 4, 2, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix4x2dv, "Double dmat4x2 uniforms narrowed to float.");
        traceUniform("glUniformMatrix4x2dv", location);
    }
}
void APIENTRY glUniformMatrix4x3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* context = requireCurrentContext("glUniformMatrix4x3dv");
    if (context == nullptr) return;
    if (context->setUniformDoubleMatrix(location, 4, 3, count, transpose, value)) {
        markProgramFunction(FunctionId::glUniformMatrix4x3dv, "Double dmat4x3 uniforms narrowed to float.");
        traceUniform("glUniformMatrix4x3dv", location);
    }
}

namespace {

bool isValidDrawMode(GLenum mode) {
    switch (mode) {
        case GL_POINTS:
        case GL_LINES:
        case GL_LINE_LOOP:
        case GL_LINE_STRIP:
        case GL_TRIANGLES:
        case GL_TRIANGLE_STRIP:
        case GL_TRIANGLE_FAN:
        case GL_LINES_ADJACENCY:
        case GL_LINE_STRIP_ADJACENCY:
        case GL_TRIANGLES_ADJACENCY:
        case GL_TRIANGLE_STRIP_ADJACENCY:
        case GL_PATCHES:
            return true;
        default:
            return false;
    }
}

bool isValidDrawElementsType(GLenum type) {
    return type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_SHORT || type == GL_UNSIGNED_INT;
}

// GL 4.6 §13.3: During transform feedback the draw mode must match the
// primitive type specified in BeginTransformFeedback.
// GL_PATCHES is always compatible because tessellation determines the output type.
bool isDrawModeCompatibleWithXfb(GLenum drawMode, GLenum xfbMode) {
    if (drawMode == GL_PATCHES) return true;
    switch (xfbMode) {
        case GL_POINTS:
            return drawMode == GL_POINTS;
        case GL_LINES:
            return drawMode == GL_LINES || drawMode == GL_LINE_STRIP ||
                   drawMode == GL_LINE_LOOP || drawMode == GL_LINES_ADJACENCY ||
                   drawMode == GL_LINE_STRIP_ADJACENCY;
        case GL_TRIANGLES:
            return drawMode == GL_TRIANGLES || drawMode == GL_TRIANGLE_STRIP ||
                   drawMode == GL_TRIANGLE_FAN || drawMode == GL_TRIANGLES_ADJACENCY ||
                   drawMode == GL_TRIANGLE_STRIP_ADJACENCY;
        default:
            return true;
    }
}

// GL 4.6 §13.3: When a GS is active, the XFB primitive mode must match
// the GS's output primitive type, not the draw mode. Returns true when
// the XFB mode is compatible with the GS output, false otherwise.
// GS output topologies are GL_POINTS / GL_LINE_STRIP / GL_TRIANGLE_STRIP;
// the XFB enum for line/triangle strips is GL_LINES / GL_TRIANGLES.
bool isXfbModeCompatibleWithGsOutput(GLenum xfbMode, GLenum gsOutputTopology) {
    switch (gsOutputTopology) {
        case GL_POINTS:         return xfbMode == GL_POINTS;
        case GL_LINE_STRIP:     return xfbMode == GL_LINES;
        case GL_TRIANGLE_STRIP: return xfbMode == GL_TRIANGLES;
        default:                return true;
    }
}

}  // namespace

void APIENTRY glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    auto* context = requireCurrentContext("glDrawArrays");
    if (context == nullptr) {
        return;
    }
    if (!isValidDrawMode(mode)) {
        recordValidationError(context, "glDrawArrays", GL_INVALID_ENUM, "mode is not a recognized primitive type");
        return;
    }
    if (first < 0 || count < 0) {
        recordValidationError(context, "glDrawArrays", GL_INVALID_VALUE, "first and count must be non-negative");
        return;
    }
    // GL 4.6 §13.3: draw mode must match XFB primitive mode when
    // active and not paused — EXCEPT when a geometry shader is in
    // the pipeline, in which case the XFB mode is matched against
    // the GS's OUTPUT primitive type (the draw mode is whatever
    // feeds the GS's input, which can differ). CTS primitive_counter
    // tests rely on this exception (points_to_line_strip draws with
    // GL_POINTS and captures with GL_LINES).
    if (context->isTransformFeedbackActive() && !context->isTransformFeedbackPaused()) {
        const GLuint progName = context->state().currentProgram();
        const GLProgramObject* prog = (progName != 0)
            ? context->objects().programs().get(progName) : nullptr;
        const bool compatible = (prog && prog->gsPresent)
            ? isXfbModeCompatibleWithGsOutput(
                  context->transformFeedbackPrimitiveMode(), prog->gsOutputTopology)
            : isDrawModeCompatibleWithXfb(
                  mode, context->transformFeedbackPrimitiveMode());
        if (!compatible) {
            recordValidationError(context, "glDrawArrays", GL_INVALID_OPERATION,
                                  "draw mode incompatible with transform feedback primitive mode");
            return;
        }
    }
    context->drawArrays(mode, first, count);
    markDrawFunction(
        FunctionId::glDrawArrays,
        "Metal-backed solid-color draw path encodes glDrawArrays triangles."
    );
    Runtime::shared().recordBootstrapTrace(
        "glDrawArrays(mode=" + std::to_string(mode) + ", first=" + std::to_string(first)
        + ", count=" + std::to_string(count) + ")"
    );
}

void APIENTRY glDrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices) {
    auto* context = requireCurrentContext("glDrawElements");
    if (context == nullptr) {
        return;
    }
    if (!isValidDrawMode(mode)) {
        recordValidationError(context, "glDrawElements", GL_INVALID_ENUM, "mode is not a recognized primitive type");
        return;
    }
    if (!isValidDrawElementsType(type)) {
        recordValidationError(context, "glDrawElements", GL_INVALID_ENUM, "type must be UNSIGNED_BYTE/SHORT/INT");
        return;
    }
    if (count < 0) {
        recordValidationError(context, "glDrawElements", GL_INVALID_VALUE, "count must be non-negative");
        return;
    }
    context->drawElements(mode, count, type, indices);
    markDrawFunction(
        FunctionId::glDrawElements,
        "Metal-backed solid-color draw path encodes glDrawElements triangles."
    );
    Runtime::shared().recordBootstrapTrace(
        "glDrawElements(mode=" + std::to_string(mode) + ", count=" + std::to_string(count)
        + ", type=" + std::to_string(type) + ")"
    );
}

// --- GL 4.0: Tessellation patch parameters (Group 7) ---

void APIENTRY glPatchParameteri(GLenum pname, GLint value) {
    auto* context = requireCurrentContext("glPatchParameteri");
    if (context == nullptr) return;
    if (pname != GL_PATCH_VERTICES) {
        recordValidationError(context, "glPatchParameteri", GL_INVALID_ENUM, "pname must be GL_PATCH_VERTICES");
        return;
    }
    if (value <= 0) {
        recordValidationError(context, "glPatchParameteri", GL_INVALID_VALUE, "value must be positive");
        return;
    }
    context->setPatchParameteri(pname, value);
    markStateFunction(FunctionId::glPatchParameteri, "Tessellation patch vertex count tracked.");
    Runtime::shared().recordBootstrapTrace("glPatchParameteri(pname=" + std::to_string(pname) + ", value=" + std::to_string(value) + ")");
}

void APIENTRY glPatchParameterfv(GLenum pname, const GLfloat* values) {
    auto* context = requireCurrentContext("glPatchParameterfv");
    if (context == nullptr) return;
    if (pname != GL_PATCH_DEFAULT_OUTER_LEVEL && pname != GL_PATCH_DEFAULT_INNER_LEVEL) {
        recordValidationError(context, "glPatchParameterfv", GL_INVALID_ENUM, "pname must be GL_PATCH_DEFAULT_OUTER_LEVEL or GL_PATCH_DEFAULT_INNER_LEVEL");
        return;
    }
    if (values == nullptr) {
        recordValidationError(context, "glPatchParameterfv", GL_INVALID_VALUE, "values must not be null");
        return;
    }
    context->setPatchParameterfv(pname, values);
    markStateFunction(FunctionId::glPatchParameterfv, "Tessellation default level state tracked.");
    Runtime::shared().recordBootstrapTrace("glPatchParameterfv(pname=" + std::to_string(pname) + ")");
}

// --- GL 4.0: Indexed queries (Group 5) — stub-with-state ---

// GL 4.6 §4.2 — max allowed index depends on the query target.
// Per-stream queries support up to MAX_VERTEX_STREAMS (= 4) for
// PRIMITIVES_GENERATED and TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN;
// all other targets are singletons (index must be 0).
static bool queryTargetMaxIndex(GLenum target, GLuint& outMax) {
    switch (target) {
        case GL_PRIMITIVES_GENERATED:
        case GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN:
            outMax = 4;  // MAX_VERTEX_STREAMS
            return true;
        case GL_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED_CONSERVATIVE:
        case GL_TIME_ELAPSED:
        case GL_TIMESTAMP:
        case GL_TRANSFORM_FEEDBACK_OVERFLOW:
        case GL_TRANSFORM_FEEDBACK_STREAM_OVERFLOW:
            outMax = 1;
            return true;
    }
    return false;
}

void APIENTRY glBeginQueryIndexed(GLenum target, GLuint index, GLuint id) {
    auto* context = requireCurrentContext("glBeginQueryIndexed");
    if (context == nullptr) return;
    GLuint maxIdx = 1;
    if (queryTargetMaxIndex(target, maxIdx) && index >= maxIdx) {
        recordValidationError(context, "glBeginQueryIndexed", GL_INVALID_VALUE,
                              "index out of range for query target");
        return;
    }
    // Index 0 for a singleton target is exactly equivalent to the
    // non-indexed `glBeginQuery`. Route through the state-updating
    // path so `glGetQueryiv(target, GL_CURRENT_QUERY, ...)` returns
    // the active query ID. CTS `transform_feedback_overflow_query_ARB.
    // context-state-update` asserts this.
    if (auto fn = Runtime::shared().dispatch().glBeginQuery) {
        fn(target, id);
    }
    markStateFunction(FunctionId::glBeginQueryIndexed, "Indexed query begin routes to non-indexed begin at index 0.");
    Runtime::shared().recordBootstrapTrace("glBeginQueryIndexed(target=" + std::to_string(target) + ", index=" + std::to_string(index) + ", id=" + std::to_string(id) + ")");
}

void APIENTRY glEndQueryIndexed(GLenum target, GLuint index) {
    auto* context = requireCurrentContext("glEndQueryIndexed");
    if (context == nullptr) return;
    GLuint maxIdx = 1;
    if (queryTargetMaxIndex(target, maxIdx) && index >= maxIdx) {
        recordValidationError(context, "glEndQueryIndexed", GL_INVALID_VALUE,
                              "index out of range for query target");
        return;
    }
    if (auto fn = Runtime::shared().dispatch().glEndQuery) {
        fn(target);
    }
    markStateFunction(FunctionId::glEndQueryIndexed, "Indexed query end routes to non-indexed end.");
}

void APIENTRY glGetQueryIndexediv(GLenum target, GLuint index, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetQueryIndexediv");
    if (context == nullptr) return;
    GLuint maxIdx = 1;
    if (queryTargetMaxIndex(target, maxIdx) && index >= maxIdx) {
        recordValidationError(context, "glGetQueryIndexediv", GL_INVALID_VALUE,
                              "index out of range for query target");
        return;
    }
    if (params == nullptr) return;
    if (pname == GL_CURRENT_QUERY) {
        // Look up the active query for this target.
        GLint activeId = 0;
        context->objects().queries().forEach(
            [target, &activeId](GLuint id, GLQueryObject& q) {
                if (q.active && q.target == target && activeId == 0) {
                    activeId = static_cast<GLint>(id);
                }
            });
        *params = activeId;
    } else if (pname == GL_QUERY_COUNTER_BITS) {
        *params = 64;
    } else {
        *params = 0;
    }
    markStateFunction(FunctionId::glGetQueryIndexediv, "Indexed query get returns per-target state.");
}

// --- GL 4.1: Viewport/Scissor/Depth arrays (Group 8) ---

void APIENTRY glViewportArrayv(GLuint first, GLsizei count, const GLfloat* v) {
    auto* context = requireCurrentContext("glViewportArrayv");
    if (context == nullptr) return;
    if (count < 0) {
        recordValidationError(context, "glViewportArrayv", GL_INVALID_VALUE, "count must be non-negative");
        return;
    }
    context->setViewportArray(first, count, v);
    markStateFunction(FunctionId::glViewportArrayv, "Per-viewport-index array state tracked.");
    Runtime::shared().recordBootstrapTrace("glViewportArrayv(first=" + std::to_string(first) + ", count=" + std::to_string(count) + ")");
}

void APIENTRY glViewportIndexedf(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h) {
    auto* context = requireCurrentContext("glViewportIndexedf");
    if (context == nullptr) return;
    context->setViewportIndexed(index, x, y, w, h);
    markStateFunction(FunctionId::glViewportIndexedf, "Per-viewport-index state tracked.");
    Runtime::shared().recordBootstrapTrace("glViewportIndexedf(index=" + std::to_string(index) + ")");
}

void APIENTRY glViewportIndexedfv(GLuint index, const GLfloat* v) {
    auto* context = requireCurrentContext("glViewportIndexedfv");
    if (context == nullptr) return;
    if (v == nullptr) {
        recordValidationError(context, "glViewportIndexedfv", GL_INVALID_VALUE, "v must not be null");
        return;
    }
    context->setViewportIndexed(index, v[0], v[1], v[2], v[3]);
    markStateFunction(FunctionId::glViewportIndexedfv, "Per-viewport-index state tracked.");
    Runtime::shared().recordBootstrapTrace("glViewportIndexedfv(index=" + std::to_string(index) + ")");
}

void APIENTRY glScissorArrayv(GLuint first, GLsizei count, const GLint* v) {
    auto* context = requireCurrentContext("glScissorArrayv");
    if (context == nullptr) return;
    if (count < 0) {
        recordValidationError(context, "glScissorArrayv", GL_INVALID_VALUE, "count must be non-negative");
        return;
    }
    context->setScissorArray(first, count, v);
    markStateFunction(FunctionId::glScissorArrayv, "Per-scissor-index array state tracked.");
    Runtime::shared().recordBootstrapTrace("glScissorArrayv(first=" + std::to_string(first) + ", count=" + std::to_string(count) + ")");
}

void APIENTRY glScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glScissorIndexed");
    if (context == nullptr) return;
    if (width < 0 || height < 0) {
        recordValidationError(context, "glScissorIndexed", GL_INVALID_VALUE, "width and height must be non-negative");
        return;
    }
    context->setScissorIndexed(index, left, bottom, width, height);
    markStateFunction(FunctionId::glScissorIndexed, "Per-scissor-index state tracked.");
    Runtime::shared().recordBootstrapTrace("glScissorIndexed(index=" + std::to_string(index) + ")");
}

void APIENTRY glScissorIndexedv(GLuint index, const GLint* v) {
    auto* context = requireCurrentContext("glScissorIndexedv");
    if (context == nullptr) return;
    if (v == nullptr) {
        recordValidationError(context, "glScissorIndexedv", GL_INVALID_VALUE, "v must not be null");
        return;
    }
    context->setScissorIndexed(index, v[0], v[1], static_cast<GLsizei>(v[2]), static_cast<GLsizei>(v[3]));
    markStateFunction(FunctionId::glScissorIndexedv, "Per-scissor-index state tracked.");
    Runtime::shared().recordBootstrapTrace("glScissorIndexedv(index=" + std::to_string(index) + ")");
}

void APIENTRY glDepthRangeArrayv(GLuint first, GLsizei count, const GLdouble* v) {
    auto* context = requireCurrentContext("glDepthRangeArrayv");
    if (context == nullptr) return;
    if (count < 0) {
        recordValidationError(context, "glDepthRangeArrayv", GL_INVALID_VALUE, "count must be non-negative");
        return;
    }
    context->setDepthRangeArray(first, count, v);
    markStateFunction(FunctionId::glDepthRangeArrayv, "Per-depth-range-index array state tracked.");
    Runtime::shared().recordBootstrapTrace("glDepthRangeArrayv(first=" + std::to_string(first) + ", count=" + std::to_string(count) + ")");
}

void APIENTRY glDepthRangeIndexed(GLuint index, GLdouble n, GLdouble f) {
    auto* context = requireCurrentContext("glDepthRangeIndexed");
    if (context == nullptr) return;
    context->setDepthRangeIndexed(index, n, f);
    markStateFunction(FunctionId::glDepthRangeIndexed, "Per-depth-range-index state tracked.");
    Runtime::shared().recordBootstrapTrace("glDepthRangeIndexed(index=" + std::to_string(index) + ")");
}

void APIENTRY glGetFloati_v(GLenum target, GLuint index, GLfloat* data) {
    auto* context = requireCurrentContext("glGetFloati_v");
    if (context == nullptr) return;
    if (data == nullptr) {
        recordValidationError(context, "glGetFloati_v", GL_INVALID_VALUE, "data must not be null");
        return;
    }
    if (!context->queryFloatIndexed(target, index, data)) {
        recordValidationError(context, "glGetFloati_v", GL_INVALID_ENUM, "target is not a recognized indexed state");
        return;
    }
    markStateFunction(FunctionId::glGetFloati_v, "Indexed float state query returns tracked values.");
    Runtime::shared().recordBootstrapTrace("glGetFloati_v(target=" + std::to_string(target) + ", index=" + std::to_string(index) + ")");
}

void APIENTRY glGetDoublei_v(GLenum target, GLuint index, GLdouble* data) {
    auto* context = requireCurrentContext("glGetDoublei_v");
    if (context == nullptr) return;
    if (data == nullptr) {
        recordValidationError(context, "glGetDoublei_v", GL_INVALID_VALUE, "data must not be null");
        return;
    }
    if (!context->queryDoubleIndexed(target, index, data)) {
        recordValidationError(context, "glGetDoublei_v", GL_INVALID_ENUM, "target is not a recognized indexed state");
        return;
    }
    markStateFunction(FunctionId::glGetDoublei_v, "Indexed double state query returns tracked values.");
    Runtime::shared().recordBootstrapTrace("glGetDoublei_v(target=" + std::to_string(target) + ", index=" + std::to_string(index) + ")");
}

void APIENTRY glClearDepthf(GLfloat d) {
    auto* context = requireCurrentContext("glClearDepthf");
    if (context == nullptr) return;
    context->setClearDepth(static_cast<GLdouble>(d));
    markStateFunction(FunctionId::glClearDepthf, "Float-precision depth clear state tracked.");
    Runtime::shared().recordBootstrapTrace("glClearDepthf(" + formatFloat(d) + ")");
}

// --- GL 4.1: Program uniforms (Group 10) — explicit program handle variants ---
// Macros for the 50 arity clones. Each delegates to the appropriate ForProgram method.

#define IMPL_PROGRAM_UNIFORM_SCALAR(N, TYPE, ELEM, FTYPE)                                     \
void APIENTRY glProgramUniform##N##FTYPE(GLuint program, GLint location, ARGLIST_##N##_##TYPE) { \
    auto* context = requireCurrentContext("glProgramUniform" #N #FTYPE);                       \
    if (context == nullptr) return;                                                             \
    TYPE v[] = { VALLIST_##N };                                                                 \
    if (context->setUniformScalarVectorForProgram(program, location, ELEM, N, 1, v)) {         \
        markProgramFunction(FunctionId::glProgramUniform##N##FTYPE,                            \
            "ProgramUniform" #N #FTYPE " (explicit program).");                                \
        traceUniform("glProgramUniform" #N #FTYPE, location);                                  \
    }                                                                                           \
}

// Expand argument lists via helper macros is too complex for the preprocessor.
// Instead, write all 50 functions directly for clarity and auditability.

void APIENTRY glProgramUniform1i(GLuint program, GLint location, GLint v0) {
    auto* ctx = requireCurrentContext("glProgramUniform1i"); if (!ctx) return;
    GLint v[] = {v0};
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 1, 1, v)) { markProgramFunction(FunctionId::glProgramUniform1i, "ProgramUniform1i."); traceUniform("glProgramUniform1i", location); }
}
void APIENTRY glProgramUniform1iv(GLuint program, GLint location, GLsizei count, const GLint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform1iv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 1, count, value)) { markProgramFunction(FunctionId::glProgramUniform1iv, "ProgramUniform1iv."); traceUniform("glProgramUniform1iv", location); }
}
void APIENTRY glProgramUniform1f(GLuint program, GLint location, GLfloat v0) {
    auto* ctx = requireCurrentContext("glProgramUniform1f"); if (!ctx) return;
    GLfloat v[] = {v0};
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 1, 1, v)) { markProgramFunction(FunctionId::glProgramUniform1f, "ProgramUniform1f."); traceUniform("glProgramUniform1f", location); }
}
void APIENTRY glProgramUniform1fv(GLuint program, GLint location, GLsizei count, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniform1fv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 1, count, value)) { markProgramFunction(FunctionId::glProgramUniform1fv, "ProgramUniform1fv."); traceUniform("glProgramUniform1fv", location); }
}
void APIENTRY glProgramUniform1d(GLuint program, GLint location, GLdouble x) {
    auto* ctx = requireCurrentContext("glProgramUniform1d"); if (!ctx) return;
    GLdouble v[] = {x};
    if (ctx->setUniformDoubleForProgram(program, location, 1, 1, v)) { markProgramFunction(FunctionId::glProgramUniform1d, "ProgramUniform1d."); traceUniform("glProgramUniform1d", location); }
}
void APIENTRY glProgramUniform1dv(GLuint program, GLint location, GLsizei count, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniform1dv"); if (!ctx) return;
    if (ctx->setUniformDoubleForProgram(program, location, 1, count, value)) { markProgramFunction(FunctionId::glProgramUniform1dv, "ProgramUniform1dv."); traceUniform("glProgramUniform1dv", location); }
}
void APIENTRY glProgramUniform1ui(GLuint program, GLint location, GLuint v0) {
    auto* ctx = requireCurrentContext("glProgramUniform1ui"); if (!ctx) return;
    GLuint v[] = {v0};
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 1, 1, v)) { markProgramFunction(FunctionId::glProgramUniform1ui, "ProgramUniform1ui."); traceUniform("glProgramUniform1ui", location); }
}
void APIENTRY glProgramUniform1uiv(GLuint program, GLint location, GLsizei count, const GLuint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform1uiv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 1, count, value)) { markProgramFunction(FunctionId::glProgramUniform1uiv, "ProgramUniform1uiv."); traceUniform("glProgramUniform1uiv", location); }
}
void APIENTRY glProgramUniform2i(GLuint program, GLint location, GLint v0, GLint v1) {
    auto* ctx = requireCurrentContext("glProgramUniform2i"); if (!ctx) return;
    GLint v[] = {v0, v1};
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 2, 1, v)) { markProgramFunction(FunctionId::glProgramUniform2i, "ProgramUniform2i."); traceUniform("glProgramUniform2i", location); }
}
void APIENTRY glProgramUniform2iv(GLuint program, GLint location, GLsizei count, const GLint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform2iv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 2, count, value)) { markProgramFunction(FunctionId::glProgramUniform2iv, "ProgramUniform2iv."); traceUniform("glProgramUniform2iv", location); }
}
void APIENTRY glProgramUniform2f(GLuint program, GLint location, GLfloat v0, GLfloat v1) {
    auto* ctx = requireCurrentContext("glProgramUniform2f"); if (!ctx) return;
    GLfloat v[] = {v0, v1};
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 2, 1, v)) { markProgramFunction(FunctionId::glProgramUniform2f, "ProgramUniform2f."); traceUniform("glProgramUniform2f", location); }
}
void APIENTRY glProgramUniform2fv(GLuint program, GLint location, GLsizei count, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniform2fv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 2, count, value)) { markProgramFunction(FunctionId::glProgramUniform2fv, "ProgramUniform2fv."); traceUniform("glProgramUniform2fv", location); }
}
void APIENTRY glProgramUniform2d(GLuint program, GLint location, GLdouble x, GLdouble y) {
    auto* ctx = requireCurrentContext("glProgramUniform2d"); if (!ctx) return;
    GLdouble v[] = {x, y};
    if (ctx->setUniformDoubleForProgram(program, location, 2, 1, v)) { markProgramFunction(FunctionId::glProgramUniform2d, "ProgramUniform2d."); traceUniform("glProgramUniform2d", location); }
}
void APIENTRY glProgramUniform2dv(GLuint program, GLint location, GLsizei count, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniform2dv"); if (!ctx) return;
    if (ctx->setUniformDoubleForProgram(program, location, 2, count, value)) { markProgramFunction(FunctionId::glProgramUniform2dv, "ProgramUniform2dv."); traceUniform("glProgramUniform2dv", location); }
}
void APIENTRY glProgramUniform2ui(GLuint program, GLint location, GLuint v0, GLuint v1) {
    auto* ctx = requireCurrentContext("glProgramUniform2ui"); if (!ctx) return;
    GLuint v[] = {v0, v1};
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 2, 1, v)) { markProgramFunction(FunctionId::glProgramUniform2ui, "ProgramUniform2ui."); traceUniform("glProgramUniform2ui", location); }
}
void APIENTRY glProgramUniform2uiv(GLuint program, GLint location, GLsizei count, const GLuint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform2uiv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 2, count, value)) { markProgramFunction(FunctionId::glProgramUniform2uiv, "ProgramUniform2uiv."); traceUniform("glProgramUniform2uiv", location); }
}
void APIENTRY glProgramUniform3i(GLuint program, GLint location, GLint v0, GLint v1, GLint v2) {
    auto* ctx = requireCurrentContext("glProgramUniform3i"); if (!ctx) return;
    GLint v[] = {v0, v1, v2};
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 3, 1, v)) { markProgramFunction(FunctionId::glProgramUniform3i, "ProgramUniform3i."); traceUniform("glProgramUniform3i", location); }
}
void APIENTRY glProgramUniform3iv(GLuint program, GLint location, GLsizei count, const GLint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform3iv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 3, count, value)) { markProgramFunction(FunctionId::glProgramUniform3iv, "ProgramUniform3iv."); traceUniform("glProgramUniform3iv", location); }
}
void APIENTRY glProgramUniform3f(GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2) {
    auto* ctx = requireCurrentContext("glProgramUniform3f"); if (!ctx) return;
    GLfloat v[] = {v0, v1, v2};
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 3, 1, v)) { markProgramFunction(FunctionId::glProgramUniform3f, "ProgramUniform3f."); traceUniform("glProgramUniform3f", location); }
}
void APIENTRY glProgramUniform3fv(GLuint program, GLint location, GLsizei count, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniform3fv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 3, count, value)) { markProgramFunction(FunctionId::glProgramUniform3fv, "ProgramUniform3fv."); traceUniform("glProgramUniform3fv", location); }
}
void APIENTRY glProgramUniform3d(GLuint program, GLint location, GLdouble x, GLdouble y, GLdouble z) {
    auto* ctx = requireCurrentContext("glProgramUniform3d"); if (!ctx) return;
    GLdouble v[] = {x, y, z};
    if (ctx->setUniformDoubleForProgram(program, location, 3, 1, v)) { markProgramFunction(FunctionId::glProgramUniform3d, "ProgramUniform3d."); traceUniform("glProgramUniform3d", location); }
}
void APIENTRY glProgramUniform3dv(GLuint program, GLint location, GLsizei count, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniform3dv"); if (!ctx) return;
    if (ctx->setUniformDoubleForProgram(program, location, 3, count, value)) { markProgramFunction(FunctionId::glProgramUniform3dv, "ProgramUniform3dv."); traceUniform("glProgramUniform3dv", location); }
}
void APIENTRY glProgramUniform3ui(GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2) {
    auto* ctx = requireCurrentContext("glProgramUniform3ui"); if (!ctx) return;
    GLuint v[] = {v0, v1, v2};
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 3, 1, v)) { markProgramFunction(FunctionId::glProgramUniform3ui, "ProgramUniform3ui."); traceUniform("glProgramUniform3ui", location); }
}
void APIENTRY glProgramUniform3uiv(GLuint program, GLint location, GLsizei count, const GLuint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform3uiv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 3, count, value)) { markProgramFunction(FunctionId::glProgramUniform3uiv, "ProgramUniform3uiv."); traceUniform("glProgramUniform3uiv", location); }
}
void APIENTRY glProgramUniform4i(GLuint program, GLint location, GLint v0, GLint v1, GLint v2, GLint v3) {
    auto* ctx = requireCurrentContext("glProgramUniform4i"); if (!ctx) return;
    GLint v[] = {v0, v1, v2, v3};
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 4, 1, v)) { markProgramFunction(FunctionId::glProgramUniform4i, "ProgramUniform4i."); traceUniform("glProgramUniform4i", location); }
}
void APIENTRY glProgramUniform4iv(GLuint program, GLint location, GLsizei count, const GLint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform4iv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kIntElement, 4, count, value)) { markProgramFunction(FunctionId::glProgramUniform4iv, "ProgramUniform4iv."); traceUniform("glProgramUniform4iv", location); }
}
void APIENTRY glProgramUniform4f(GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) {
    auto* ctx = requireCurrentContext("glProgramUniform4f"); if (!ctx) return;
    GLfloat v[] = {v0, v1, v2, v3};
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 4, 1, v)) { markProgramFunction(FunctionId::glProgramUniform4f, "ProgramUniform4f."); traceUniform("glProgramUniform4f", location); }
}
void APIENTRY glProgramUniform4fv(GLuint program, GLint location, GLsizei count, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniform4fv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kFloatElement, 4, count, value)) { markProgramFunction(FunctionId::glProgramUniform4fv, "ProgramUniform4fv."); traceUniform("glProgramUniform4fv", location); }
}
void APIENTRY glProgramUniform4d(GLuint program, GLint location, GLdouble x, GLdouble y, GLdouble z, GLdouble w) {
    auto* ctx = requireCurrentContext("glProgramUniform4d"); if (!ctx) return;
    GLdouble v[] = {x, y, z, w};
    if (ctx->setUniformDoubleForProgram(program, location, 4, 1, v)) { markProgramFunction(FunctionId::glProgramUniform4d, "ProgramUniform4d."); traceUniform("glProgramUniform4d", location); }
}
void APIENTRY glProgramUniform4dv(GLuint program, GLint location, GLsizei count, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniform4dv"); if (!ctx) return;
    if (ctx->setUniformDoubleForProgram(program, location, 4, count, value)) { markProgramFunction(FunctionId::glProgramUniform4dv, "ProgramUniform4dv."); traceUniform("glProgramUniform4dv", location); }
}
void APIENTRY glProgramUniform4ui(GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3) {
    auto* ctx = requireCurrentContext("glProgramUniform4ui"); if (!ctx) return;
    GLuint v[] = {v0, v1, v2, v3};
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 4, 1, v)) { markProgramFunction(FunctionId::glProgramUniform4ui, "ProgramUniform4ui."); traceUniform("glProgramUniform4ui", location); }
}
void APIENTRY glProgramUniform4uiv(GLuint program, GLint location, GLsizei count, const GLuint* value) {
    auto* ctx = requireCurrentContext("glProgramUniform4uiv"); if (!ctx) return;
    if (ctx->setUniformScalarVectorForProgram(program, location, kUIntElement, 4, count, value)) { markProgramFunction(FunctionId::glProgramUniform4uiv, "ProgramUniform4uiv."); traceUniform("glProgramUniform4uiv", location); }
}

// Float matrices.
void APIENTRY glProgramUniformMatrix2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 2, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2fv, "ProgramUniformMatrix2fv."); traceUniform("glProgramUniformMatrix2fv", location); }
}
void APIENTRY glProgramUniformMatrix3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 3, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3fv, "ProgramUniformMatrix3fv."); traceUniform("glProgramUniformMatrix3fv", location); }
}
void APIENTRY glProgramUniformMatrix4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 4, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4fv, "ProgramUniformMatrix4fv."); traceUniform("glProgramUniformMatrix4fv", location); }
}
void APIENTRY glProgramUniformMatrix2x3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2x3fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 2, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2x3fv, "ProgramUniformMatrix2x3fv."); traceUniform("glProgramUniformMatrix2x3fv", location); }
}
void APIENTRY glProgramUniformMatrix3x2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3x2fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 3, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3x2fv, "ProgramUniformMatrix3x2fv."); traceUniform("glProgramUniformMatrix3x2fv", location); }
}
void APIENTRY glProgramUniformMatrix2x4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2x4fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 2, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2x4fv, "ProgramUniformMatrix2x4fv."); traceUniform("glProgramUniformMatrix2x4fv", location); }
}
void APIENTRY glProgramUniformMatrix4x2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4x2fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 4, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4x2fv, "ProgramUniformMatrix4x2fv."); traceUniform("glProgramUniformMatrix4x2fv", location); }
}
void APIENTRY glProgramUniformMatrix3x4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3x4fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 3, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3x4fv, "ProgramUniformMatrix3x4fv."); traceUniform("glProgramUniformMatrix3x4fv", location); }
}
void APIENTRY glProgramUniformMatrix4x3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4x3fv"); if (!ctx) return;
    if (ctx->setUniformMatrixForProgram(program, location, 4, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4x3fv, "ProgramUniformMatrix4x3fv."); traceUniform("glProgramUniformMatrix4x3fv", location); }
}

// Double matrices.
void APIENTRY glProgramUniformMatrix2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 2, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2dv, "ProgramUniformMatrix2dv."); traceUniform("glProgramUniformMatrix2dv", location); }
}
void APIENTRY glProgramUniformMatrix3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 3, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3dv, "ProgramUniformMatrix3dv."); traceUniform("glProgramUniformMatrix3dv", location); }
}
void APIENTRY glProgramUniformMatrix4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 4, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4dv, "ProgramUniformMatrix4dv."); traceUniform("glProgramUniformMatrix4dv", location); }
}
void APIENTRY glProgramUniformMatrix2x3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2x3dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 2, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2x3dv, "ProgramUniformMatrix2x3dv."); traceUniform("glProgramUniformMatrix2x3dv", location); }
}
void APIENTRY glProgramUniformMatrix3x2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3x2dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 3, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3x2dv, "ProgramUniformMatrix3x2dv."); traceUniform("glProgramUniformMatrix3x2dv", location); }
}
void APIENTRY glProgramUniformMatrix2x4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix2x4dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 2, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix2x4dv, "ProgramUniformMatrix2x4dv."); traceUniform("glProgramUniformMatrix2x4dv", location); }
}
void APIENTRY glProgramUniformMatrix4x2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4x2dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 4, 2, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4x2dv, "ProgramUniformMatrix4x2dv."); traceUniform("glProgramUniformMatrix4x2dv", location); }
}
void APIENTRY glProgramUniformMatrix3x4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix3x4dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 3, 4, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix3x4dv, "ProgramUniformMatrix3x4dv."); traceUniform("glProgramUniformMatrix3x4dv", location); }
}
void APIENTRY glProgramUniformMatrix4x3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value) {
    auto* ctx = requireCurrentContext("glProgramUniformMatrix4x3dv"); if (!ctx) return;
    if (ctx->setUniformDoubleMatrixForProgram(program, location, 4, 3, count, transpose, value)) { markProgramFunction(FunctionId::glProgramUniformMatrix4x3dv, "ProgramUniformMatrix4x3dv."); traceUniform("glProgramUniformMatrix4x3dv", location); }
}

// --- GL 4.1: Program/Shader Binary and Release (Group 11) ---

void APIENTRY glGetProgramBinary(GLuint program, GLsizei bufSize, GLsizei* length, GLenum* binaryFormat, void* binary) {
    auto* ctx = requireCurrentContext("glGetProgramBinary"); if (!ctx) return;
    (void)program; (void)bufSize; (void)binary;
    // Spec-legal: report GL_INVALID_OPERATION when GL_NUM_PROGRAM_BINARY_FORMATS == 0
    // and GL_PROGRAM_BINARY_RETRIEVABLE_HINT is false (default).
    if (length != nullptr) *length = 0;
    if (binaryFormat != nullptr) *binaryFormat = 0;
    recordValidationError(ctx, "glGetProgramBinary", GL_INVALID_OPERATION, "no binary formats supported");
    markProgramFunction(FunctionId::glGetProgramBinary, "ProgramBinary stub (0 formats).");
    Runtime::shared().recordBootstrapTrace("glGetProgramBinary(program=" + std::to_string(program) + ")");
}

void APIENTRY glProgramBinary(GLuint program, GLenum binaryFormat, const void* binary, GLsizei length) {
    auto* ctx = requireCurrentContext("glProgramBinary"); if (!ctx) return;
    (void)program; (void)binaryFormat; (void)binary; (void)length;
    // Spec-legal: no supported binary formats → always fails.
    recordValidationError(ctx, "glProgramBinary", GL_INVALID_ENUM, "binaryFormat not recognized (0 supported formats)");
    markProgramFunction(FunctionId::glProgramBinary, "ProgramBinary stub (0 formats).");
    Runtime::shared().recordBootstrapTrace("glProgramBinary(program=" + std::to_string(program) + ")");
}

void APIENTRY glProgramParameteri(GLuint program, GLenum pname, GLint value) {
    auto* ctx = requireCurrentContext("glProgramParameteri"); if (!ctx) return;
    // GL 4.1 §7.3 / ARB_separate_shader_objects — GL_PROGRAM_
    // SEPARABLE actually has linker-visible semantics: once set,
    // the next `glLinkProgram` accepts incomplete stage
    // combinations (the missing stages are filled in by the
    // pipeline object the program is later bound into). Store
    // the flag on the program so the linker can read it.
    if (pname == GL_PROGRAM_SEPARABLE) {
        if (auto* obj = ctx->objects().programs().get(program)) {
            obj->separable = (value == GL_TRUE);
        }
    }
    // GL_PROGRAM_BINARY_RETRIEVABLE_HINT is still a no-op — we
    // don't support program binaries.
    markProgramFunction(FunctionId::glProgramParameteri, "ProgramParameteri GL_PROGRAM_SEPARABLE recorded.");
    Runtime::shared().recordBootstrapTrace("glProgramParameteri(program=" + std::to_string(program) + ", pname=" + std::to_string(pname) + ")");
}

void APIENTRY glShaderBinary(GLsizei count, const GLuint* shaders, GLenum binaryformat, const void* binary, GLsizei length) {
    auto* ctx = requireCurrentContext("glShaderBinary"); if (!ctx) return;
    (void)count; (void)shaders; (void)binaryformat; (void)binary; (void)length;
    // Spec-legal: report GL_INVALID_ENUM when binaryformat is not recognized (0 supported).
    recordValidationError(ctx, "glShaderBinary", GL_INVALID_ENUM, "binaryformat not recognized (0 supported formats)");
    markProgramFunction(FunctionId::glShaderBinary, "ShaderBinary stub (0 formats).");
    Runtime::shared().recordBootstrapTrace("glShaderBinary(count=" + std::to_string(count) + ")");
}

void APIENTRY glReleaseShaderCompiler(void) {
    auto* ctx = requireCurrentContext("glReleaseShaderCompiler"); if (!ctx) return;
    // Spec: this is a hint — the runtime may ignore it.
    markProgramFunction(FunctionId::glReleaseShaderCompiler, "ReleaseShaderCompiler hint accepted (no-op).");
    Runtime::shared().recordBootstrapTrace("glReleaseShaderCompiler()");
}

// --- GL 4.1: Double-precision vertex attributes (Group 12) ---

void APIENTRY glVertexAttribL1d(GLuint index, GLdouble x) {
    auto* context = requireCurrentContext("glVertexAttribL1d");
    if (context == nullptr) return;
    const GLdouble v[1] = {x};
    context->setVertexAttribLImmediate(index, 1, v);
    markStateFunction(FunctionId::glVertexAttribL1d, "Double vertex attrib immediate (L1d) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL1d(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL2d(GLuint index, GLdouble x, GLdouble y) {
    auto* context = requireCurrentContext("glVertexAttribL2d");
    if (context == nullptr) return;
    const GLdouble v[2] = {x, y};
    context->setVertexAttribLImmediate(index, 2, v);
    markStateFunction(FunctionId::glVertexAttribL2d, "Double vertex attrib immediate (L2d) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL2d(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL3d(GLuint index, GLdouble x, GLdouble y, GLdouble z) {
    auto* context = requireCurrentContext("glVertexAttribL3d");
    if (context == nullptr) return;
    const GLdouble v[3] = {x, y, z};
    context->setVertexAttribLImmediate(index, 3, v);
    markStateFunction(FunctionId::glVertexAttribL3d, "Double vertex attrib immediate (L3d) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL3d(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL4d(GLuint index, GLdouble x, GLdouble y, GLdouble z, GLdouble w) {
    auto* context = requireCurrentContext("glVertexAttribL4d");
    if (context == nullptr) return;
    const GLdouble v[4] = {x, y, z, w};
    context->setVertexAttribLImmediate(index, 4, v);
    markStateFunction(FunctionId::glVertexAttribL4d, "Double vertex attrib immediate (L4d) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL4d(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL1dv(GLuint index, const GLdouble* v) {
    auto* context = requireCurrentContext("glVertexAttribL1dv");
    if (context == nullptr) return;
    if (v == nullptr) { recordValidationError(context, "glVertexAttribL1dv", GL_INVALID_VALUE, "v must not be null"); return; }
    context->setVertexAttribLImmediate(index, 1, v);
    markStateFunction(FunctionId::glVertexAttribL1dv, "Double vertex attrib immediate (L1dv) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL1dv(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL2dv(GLuint index, const GLdouble* v) {
    auto* context = requireCurrentContext("glVertexAttribL2dv");
    if (context == nullptr) return;
    if (v == nullptr) { recordValidationError(context, "glVertexAttribL2dv", GL_INVALID_VALUE, "v must not be null"); return; }
    context->setVertexAttribLImmediate(index, 2, v);
    markStateFunction(FunctionId::glVertexAttribL2dv, "Double vertex attrib immediate (L2dv) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL2dv(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL3dv(GLuint index, const GLdouble* v) {
    auto* context = requireCurrentContext("glVertexAttribL3dv");
    if (context == nullptr) return;
    if (v == nullptr) { recordValidationError(context, "glVertexAttribL3dv", GL_INVALID_VALUE, "v must not be null"); return; }
    context->setVertexAttribLImmediate(index, 3, v);
    markStateFunction(FunctionId::glVertexAttribL3dv, "Double vertex attrib immediate (L3dv) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL3dv(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribL4dv(GLuint index, const GLdouble* v) {
    auto* context = requireCurrentContext("glVertexAttribL4dv");
    if (context == nullptr) return;
    if (v == nullptr) { recordValidationError(context, "glVertexAttribL4dv", GL_INVALID_VALUE, "v must not be null"); return; }
    context->setVertexAttribLImmediate(index, 4, v);
    markStateFunction(FunctionId::glVertexAttribL4dv, "Double vertex attrib immediate (L4dv) stored.");
    Runtime::shared().recordBootstrapTrace("glVertexAttribL4dv(index=" + std::to_string(index) + ")");
}

void APIENTRY glVertexAttribLPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    auto* context = requireCurrentContext("glVertexAttribLPointer");
    if (context == nullptr) return;
    if (!context->vertexAttribLPointer(index, size, type, stride, pointer)) {
        // Error already pushed by context method.
        return;
    }
    markStateFunction(FunctionId::glVertexAttribLPointer, "Double-precision vertex attribute pointer stored (f64→f32 at draw time).");
    Runtime::shared().recordBootstrapTrace("glVertexAttribLPointer(index=" + std::to_string(index) + ", size=" + std::to_string(size) + ")");
}

void APIENTRY glGetVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params) {
    auto* context = requireCurrentContext("glGetVertexAttribLdv");
    if (context == nullptr) return;
    if (!context->getVertexAttribLdv(index, pname, params)) {
        return;
    }
    markStateFunction(FunctionId::glGetVertexAttribLdv, "Double vertex attrib readback returns CPU-side shadow.");
    Runtime::shared().recordBootstrapTrace("glGetVertexAttribLdv(index=" + std::to_string(index) + ", pname=" + std::to_string(pname) + ")");
}

// --- GL 4.1: Shader precision (Group 13) ---

void APIENTRY glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range, GLint* precision) {
    auto* context = requireCurrentContext("glGetShaderPrecisionFormat");
    if (context == nullptr) return;
    context->getShaderPrecisionFormat(shadertype, precisiontype, range, precision);
    markStateFunction(FunctionId::glGetShaderPrecisionFormat, "Shader precision query returns Metal-appropriate ranges.");
    Runtime::shared().recordBootstrapTrace("glGetShaderPrecisionFormat(shadertype=" + std::to_string(shadertype) + ", precisiontype=" + std::to_string(precisiontype) + ")");
}

// --- GL 4.1: Program Pipeline Objects (Group 9) ---

void APIENTRY glGenProgramPipelines(GLsizei n, GLuint* pipelines) {
    auto* ctx = requireCurrentContext("glGenProgramPipelines");
    if (!ctx) return;
    if (n < 0) {
        recordValidationError(ctx, "glGenProgramPipelines", GL_INVALID_VALUE, "n < 0");
        return;
    }
    for (GLsizei i = 0; i < n; ++i) {
        pipelines[i] = ctx->objects().programPipelines().reserveName();
    }
    markProgramFunction(FunctionId::glGenProgramPipelines, "Program pipeline name generation.");
    Runtime::shared().recordBootstrapTrace("glGenProgramPipelines(n=" + std::to_string(n) + ")");
}

void APIENTRY glDeleteProgramPipelines(GLsizei n, const GLuint* pipelines) {
    auto* ctx = requireCurrentContext("glDeleteProgramPipelines");
    if (!ctx) return;
    if (n < 0) {
        recordValidationError(ctx, "glDeleteProgramPipelines", GL_INVALID_VALUE, "n < 0");
        return;
    }
    for (GLsizei i = 0; i < n; ++i) {
        if (pipelines[i] != 0) {
            ctx->objects().programPipelines().erase(pipelines[i]);
        }
    }
    markProgramFunction(FunctionId::glDeleteProgramPipelines, "Program pipeline deletion.");
    Runtime::shared().recordBootstrapTrace("glDeleteProgramPipelines(n=" + std::to_string(n) + ")");
}

GLboolean APIENTRY glIsProgramPipeline(GLuint pipeline) {
    auto* ctx = requireCurrentContext("glIsProgramPipeline");
    if (!ctx) return GL_FALSE;
    // GL 4.6 §7.4: glIsProgramPipeline returns TRUE only after a name
    // has been INSTANTIATED (via glBindProgramPipeline or the DSA
    // glCreateProgramPipelines path), not just reserved by
    // glGenProgramPipelines.
    auto* obj = ctx->objects().programPipelines().get(pipeline);
    GLboolean result = (obj != nullptr && obj->instantiated) ? GL_TRUE : GL_FALSE;
    markProgramFunction(FunctionId::glIsProgramPipeline, "Program pipeline existence query.");
    return result;
}

void APIENTRY glBindProgramPipeline(GLuint pipeline) {
    auto* ctx = requireCurrentContext("glBindProgramPipeline");
    if (!ctx) return;
    if (pipeline != 0) {
        auto* obj = ctx->objects().programPipelines().get(pipeline);
        if (!obj) {
            recordValidationError(ctx, "glBindProgramPipeline", GL_INVALID_OPERATION, "pipeline does not exist");
            return;
        }
        // First bind instantiates the glGen-reserved name.
        obj->instantiated = true;
    }
    // State-tracked binding (no Metal effect yet — separable programs
    // still aren't wired to Metal pipeline-state), but the state-
    // tracker record lets drawArrays / drawElements see which pipeline
    // is current so they can look up pipeline stages and reject draws
    // with no VS (CTS geometry_shader.api.fs_gs_draw_call etc.).
    ctx->state().setCurrentProgramPipeline(pipeline);
    markProgramFunction(FunctionId::glBindProgramPipeline, "Program pipeline binding (state-tracked).");
    Runtime::shared().recordBootstrapTrace("glBindProgramPipeline(pipeline=" + std::to_string(pipeline) + ")");
}

void APIENTRY glUseProgramStages(GLuint pipeline, GLbitfield stages, GLuint program) {
    auto* ctx = requireCurrentContext("glUseProgramStages");
    if (!ctx) return;
    // GL 4.6 §7.4.1 — `stages` must be either GL_ALL_SHADER_BITS
    // (the sentinel, 0xFFFFFFFF) or a subset of the six defined
    // shader-stage bits. Any other bit raises INVALID_VALUE.
    // CTS `sepshaderobjs.UseProgStagesApi` plants
    // `GL_ALL_SHADER_BITS ^ (VS|FS)` which has many reserved bits
    // set and asserts INVALID_VALUE.
    constexpr GLbitfield kAllowedStageMask =
        GL_VERTEX_SHADER_BIT |
        GL_TESS_CONTROL_SHADER_BIT |
        GL_TESS_EVALUATION_SHADER_BIT |
        GL_GEOMETRY_SHADER_BIT |
        GL_FRAGMENT_SHADER_BIT |
        GL_COMPUTE_SHADER_BIT;
    if (stages != GL_ALL_SHADER_BITS && (stages & ~kAllowedStageMask) != 0) {
        recordValidationError(ctx, "glUseProgramStages", GL_INVALID_VALUE,
                              "stages contains bits that are not valid shader stages");
        return;
    }
    auto* ppo = ctx->objects().programPipelines().get(pipeline);
    if (!ppo) {
        recordValidationError(ctx, "glUseProgramStages", GL_INVALID_OPERATION, "pipeline does not exist");
        return;
    }
    // GL 4.6 §7.4.1 — if `program` is non-zero, it must be the name
    // of an existing program that is linked and has GL_PROGRAM_SEPARABLE
    // set. Otherwise INVALID_OPERATION. CTS
    // `sepshaderobjs.UseProgStagesApi` re-links a program with
    // SEPARABLE=FALSE and asserts INVALID_OPERATION on the subsequent
    // useProgramStages.
    if (program != 0) {
        auto* prog = ctx->objects().programs().get(program);
        if (prog == nullptr || !prog->linked) {
            recordValidationError(ctx, "glUseProgramStages", GL_INVALID_OPERATION,
                                  "program is not a valid, linked program");
            return;
        }
        if (!prog->separable) {
            recordValidationError(ctx, "glUseProgramStages", GL_INVALID_OPERATION,
                                  "program was not linked with GL_PROGRAM_SEPARABLE=TRUE");
            return;
        }
    }
    // Track stage assignments on CPU.
    if (stages & GL_VERTEX_SHADER_BIT)          ppo->vertexProgram = program;
    if (stages & GL_FRAGMENT_SHADER_BIT)        ppo->fragmentProgram = program;
    if (stages & GL_GEOMETRY_SHADER_BIT)        ppo->geometryProgram = program;
    if (stages & GL_TESS_CONTROL_SHADER_BIT)    ppo->tessControlProgram = program;
    if (stages & GL_TESS_EVALUATION_SHADER_BIT) ppo->tessEvalProgram = program;
    if (stages & GL_COMPUTE_SHADER_BIT)         ppo->computeProgram = program;
    if (stages == GL_ALL_SHADER_BITS) {
        ppo->vertexProgram = program;
        ppo->fragmentProgram = program;
        ppo->geometryProgram = program;
        ppo->tessControlProgram = program;
        ppo->tessEvalProgram = program;
        ppo->computeProgram = program;
    }
    markProgramFunction(FunctionId::glUseProgramStages, "UseProgramStages stage assignment (state-tracked).");
    Runtime::shared().recordBootstrapTrace("glUseProgramStages(pipeline=" + std::to_string(pipeline) + ", stages=" + std::to_string(stages) + ", program=" + std::to_string(program) + ")");
}

void APIENTRY glActiveShaderProgram(GLuint pipeline, GLuint program) {
    auto* ctx = requireCurrentContext("glActiveShaderProgram");
    if (!ctx) return;
    auto* ppo = ctx->objects().programPipelines().get(pipeline);
    if (!ppo) {
        recordValidationError(ctx, "glActiveShaderProgram", GL_INVALID_OPERATION, "pipeline does not exist");
        return;
    }
    ppo->activeShaderProgram = program;
    markProgramFunction(FunctionId::glActiveShaderProgram, "ActiveShaderProgram sets default uniform target.");
    Runtime::shared().recordBootstrapTrace("glActiveShaderProgram(pipeline=" + std::to_string(pipeline) + ", program=" + std::to_string(program) + ")");
}

GLuint APIENTRY glCreateShaderProgramv(GLenum type, GLsizei count, const GLchar* const* strings) {
    auto* ctx = requireCurrentContext("glCreateShaderProgramv");
    if (!ctx) return 0;
    // GL 4.1 §7.3 / ARB_separate_shader_objects: glCreateShaderProgramv
    // validates count up-front. Negative count → INVALID_VALUE +
    // return 0. CTS `sepshaderobjs.CreateShadProgApi` asserts this.
    if (count < 0) {
        recordValidationError(ctx, "glCreateShaderProgramv", GL_INVALID_VALUE, "count must be non-negative");
        return 0;
    }
    // Convenience function: create shader, source, compile, create program, attach, link, delete shader.
    GLuint shader = ctx->createShader(type);
    if (shader == 0) {
        // `createShader(invalid)` already pushed INVALID_ENUM via
        // GLContext::pushError — don't double-push here. A second
        // push would pollute the error queue for the caller's next
        // glGetError (CTS `sepshaderobjs.CreateShadProgApi` sequences
        // invalid-type then negative-count, and the second check
        // previously saw the stale INVALID_ENUM instead of fresh
        // INVALID_VALUE from the negative-count path).
        return 0;
    }
    ctx->shaderSource(shader, count, strings, nullptr);
    ctx->compileShader(shader);
    GLint compiled = 0;
    ctx->getShaderiv(shader, GL_COMPILE_STATUS, &compiled);

    GLuint program = ctx->createProgram();
    if (compiled) {
        // GL 4.1 §7.3 / ARB_separate_shader_objects: the program
        // returned by glCreateShaderProgramv is always created
        // with PROGRAM_SEPARABLE = TRUE. Set the flag before
        // linking so the per-stage-only pipeline kind path
        // (e.g. VertexOnly) accepts it — otherwise the new
        // `incomplete_program_objects` stage-completeness check
        // rejects the link because there's no FS/GS attached.
        if (auto* obj = ctx->objects().programs().get(program)) {
            obj->separable = true;
        }
        ctx->attachShader(program, shader);
        ctx->linkProgram(program);
        ctx->detachShader(program, shader);
    }
    ctx->deleteShader(shader);

    markProgramFunction(FunctionId::glCreateShaderProgramv, "CreateShaderProgramv convenience (create+compile+link).");
    Runtime::shared().recordBootstrapTrace("glCreateShaderProgramv(type=" + std::to_string(type) + ", count=" + std::to_string(count) + ") -> " + std::to_string(program));
    return program;
}

void APIENTRY glValidateProgramPipeline(GLuint pipeline) {
    auto* ctx = requireCurrentContext("glValidateProgramPipeline");
    if (!ctx) return;
    auto* ppo = ctx->objects().programPipelines().get(pipeline);
    if (!ppo) {
        recordValidationError(ctx, "glValidateProgramPipeline", GL_INVALID_OPERATION, "pipeline does not exist");
        return;
    }
    // Always report validation success (state-only — no real separable pipeline in Metal yet).
    ppo->validated = true;
    ppo->infoLog = "Validation successful (AppGL stub).";
    markProgramFunction(FunctionId::glValidateProgramPipeline, "ValidateProgramPipeline (always passes, stub).");
    Runtime::shared().recordBootstrapTrace("glValidateProgramPipeline(pipeline=" + std::to_string(pipeline) + ")");
}

void APIENTRY glGetProgramPipelineiv(GLuint pipeline, GLenum pname, GLint* params) {
    auto* ctx = requireCurrentContext("glGetProgramPipelineiv");
    if (!ctx || !params) return;
    auto* ppo = ctx->objects().programPipelines().get(pipeline);
    if (!ppo) {
        recordValidationError(ctx, "glGetProgramPipelineiv", GL_INVALID_OPERATION, "pipeline does not exist");
        return;
    }
    switch (pname) {
        case GL_ACTIVE_PROGRAM:              *params = static_cast<GLint>(ppo->activeShaderProgram); break;
        case GL_VERTEX_SHADER:               *params = static_cast<GLint>(ppo->vertexProgram); break;
        case GL_FRAGMENT_SHADER:             *params = static_cast<GLint>(ppo->fragmentProgram); break;
        case GL_GEOMETRY_SHADER:             *params = static_cast<GLint>(ppo->geometryProgram); break;
        case GL_TESS_CONTROL_SHADER:         *params = static_cast<GLint>(ppo->tessControlProgram); break;
        case GL_TESS_EVALUATION_SHADER:      *params = static_cast<GLint>(ppo->tessEvalProgram); break;
        case GL_COMPUTE_SHADER:              *params = static_cast<GLint>(ppo->computeProgram); break;
        case GL_VALIDATE_STATUS:             *params = ppo->validated ? GL_TRUE : GL_FALSE; break;
        case GL_INFO_LOG_LENGTH:
            // GL 4.6 §7.13.1: 0 if no info log, else length + 1.
            *params = ppo->infoLog.empty()
                ? 0 : static_cast<GLint>(ppo->infoLog.size() + 1);
            break;
        default:
            recordValidationError(ctx, "glGetProgramPipelineiv", GL_INVALID_ENUM, "invalid pname");
            return;
    }
    markProgramFunction(FunctionId::glGetProgramPipelineiv, "GetProgramPipelineiv returns pipeline state.");
    Runtime::shared().recordBootstrapTrace("glGetProgramPipelineiv(pipeline=" + std::to_string(pipeline) + ", pname=" + std::to_string(pname) + ")");
}

void APIENTRY glGetProgramPipelineInfoLog(GLuint pipeline, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    auto* ctx = requireCurrentContext("glGetProgramPipelineInfoLog");
    if (!ctx) return;
    auto* ppo = ctx->objects().programPipelines().get(pipeline);
    if (!ppo) {
        recordValidationError(ctx, "glGetProgramPipelineInfoLog", GL_INVALID_OPERATION, "pipeline does not exist");
        return;
    }
    GLsizei logLen = static_cast<GLsizei>(ppo->infoLog.size());
    GLsizei copyLen = (bufSize > 0) ? std::min(logLen, bufSize - 1) : 0;
    if (infoLog && copyLen > 0) {
        std::memcpy(infoLog, ppo->infoLog.c_str(), static_cast<std::size_t>(copyLen));
        infoLog[copyLen] = '\0';
    } else if (infoLog && bufSize > 0) {
        infoLog[0] = '\0';
    }
    if (length) *length = copyLen;
    markProgramFunction(FunctionId::glGetProgramPipelineInfoLog, "GetProgramPipelineInfoLog returns validation log.");
    Runtime::shared().recordBootstrapTrace("glGetProgramPipelineInfoLog(pipeline=" + std::to_string(pipeline) + ")");
}

// --- GL 4.0: Subroutine Uniforms (Group 3, stub-with-state) ---
// Metal has no subroutine equivalent. These stubs report 0 subroutines/locations,
// making them spec-legal for programs without subroutine declarations.

GLint APIENTRY glGetSubroutineUniformLocation(GLuint program, GLenum shadertype, const GLchar* name) {
    auto* ctx = requireCurrentContext("glGetSubroutineUniformLocation");
    if (!ctx) return -1;
    if (name == nullptr) return -1;
    auto* prog = ctx->objects().programs().get(program);
    if (prog == nullptr || !prog->linked) return -1;
    int si = -1;
    switch (shadertype) {
        case GL_VERTEX_SHADER:          si = 0; break;
        case GL_TESS_CONTROL_SHADER:    si = 1; break;
        case GL_TESS_EVALUATION_SHADER: si = 2; break;
        case GL_GEOMETRY_SHADER:        si = 3; break;
        case GL_FRAGMENT_SHADER:        si = 4; break;
        case GL_COMPUTE_SHADER:         si = 5; break;
        default: return -1;
    }
    const std::string lookup = name;
    for (const auto& entry : prog->resourceSubroutineUniforms[si]) {
        if (entry.name == lookup) return entry.location;
    }
    // Array subroutine uniforms are stored with a "[0]" suffix. Bare
    // name → suffixed lookup.
    for (const auto& entry : prog->resourceSubroutineUniforms[si]) {
        if (entry.name == lookup + "[0]") return entry.location;
    }
    markProgramFunction(FunctionId::glGetSubroutineUniformLocation, "Subroutine uniform location via GL 4.0 program-resource tables.");
    Runtime::shared().recordBootstrapTrace("glGetSubroutineUniformLocation(program=" + std::to_string(program) + ", name=" + std::string(name) + ") -> -1 (not found)");
    return -1;
}

GLuint APIENTRY glGetSubroutineIndex(GLuint program, GLenum shadertype, const GLchar* name) {
    auto* ctx = requireCurrentContext("glGetSubroutineIndex");
    if (!ctx) return GL_INVALID_INDEX;
    if (name == nullptr) return GL_INVALID_INDEX;
    auto* prog = ctx->objects().programs().get(program);
    if (prog == nullptr || !prog->linked) return GL_INVALID_INDEX;
    int si = -1;
    switch (shadertype) {
        case GL_VERTEX_SHADER:          si = 0; break;
        case GL_TESS_CONTROL_SHADER:    si = 1; break;
        case GL_TESS_EVALUATION_SHADER: si = 2; break;
        case GL_GEOMETRY_SHADER:        si = 3; break;
        case GL_FRAGMENT_SHADER:        si = 4; break;
        case GL_COMPUTE_SHADER:         si = 5; break;
        default: return GL_INVALID_INDEX;
    }
    const std::string lookup = name;
    const auto& subs = prog->resourceSubroutines[si];
    for (std::size_t i = 0; i < subs.size(); ++i) {
        if (subs[i].name == lookup) return static_cast<GLuint>(i);
    }
    markProgramFunction(FunctionId::glGetSubroutineIndex, "Subroutine index via GL 4.0 program-resource tables.");
    Runtime::shared().recordBootstrapTrace("glGetSubroutineIndex(program=" + std::to_string(program) + ", name=" + std::string(name) + ") -> GL_INVALID_INDEX (not found)");
    return GL_INVALID_INDEX;
}

void APIENTRY glGetActiveSubroutineUniformiv(GLuint program, GLenum shadertype, GLuint index, GLenum pname, GLint* values) {
    auto* ctx = requireCurrentContext("glGetActiveSubroutineUniformiv");
    if (!ctx) return;
    (void)program; (void)shadertype; (void)index;
    // 0 active subroutine uniforms → any index is invalid.
    if (pname == GL_NUM_COMPATIBLE_SUBROUTINES && values) {
        *values = 0;
    } else if (values) {
        *values = 0;
    }
    markProgramFunction(FunctionId::glGetActiveSubroutineUniformiv, "Active subroutine uniform query stub (0 subroutines).");
    Runtime::shared().recordBootstrapTrace("glGetActiveSubroutineUniformiv(program=" + std::to_string(program) + ", index=" + std::to_string(index) + ")");
}

void APIENTRY glGetActiveSubroutineUniformName(GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei* length, GLchar* name) {
    auto* ctx = requireCurrentContext("glGetActiveSubroutineUniformName");
    if (!ctx) return;
    (void)program; (void)shadertype; (void)index;
    // 0 active subroutine uniforms → GL_INVALID_VALUE for any index.
    recordValidationError(ctx, "glGetActiveSubroutineUniformName", GL_INVALID_VALUE, "no active subroutine uniforms");
    if (name && bufsize > 0) name[0] = '\0';
    if (length) *length = 0;
    markProgramFunction(FunctionId::glGetActiveSubroutineUniformName, "Active subroutine uniform name stub (no subroutines).");
}

void APIENTRY glGetActiveSubroutineName(GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei* length, GLchar* name) {
    auto* ctx = requireCurrentContext("glGetActiveSubroutineName");
    if (!ctx) return;
    (void)program; (void)shadertype; (void)index;
    recordValidationError(ctx, "glGetActiveSubroutineName", GL_INVALID_VALUE, "no active subroutines");
    if (name && bufsize > 0) name[0] = '\0';
    if (length) *length = 0;
    markProgramFunction(FunctionId::glGetActiveSubroutineName, "Active subroutine name stub (no subroutines).");
}

void APIENTRY glUniformSubroutinesuiv(GLenum shadertype, GLsizei count, const GLuint* indices) {
    auto* ctx = requireCurrentContext("glUniformSubroutinesuiv");
    if (!ctx) return;
    (void)shadertype; (void)count; (void)indices;
    // No subroutine uniforms → count must be 0 for valid call, any >0 is technically invalid.
    // Accept silently for robustness (state-tracked stub).
    markProgramFunction(FunctionId::glUniformSubroutinesuiv, "UniformSubroutinesuiv stub (no subroutines, no-op).");
    Runtime::shared().recordBootstrapTrace("glUniformSubroutinesuiv(shadertype=" + std::to_string(shadertype) + ", count=" + std::to_string(count) + ")");
}

void APIENTRY glGetUniformSubroutineuiv(GLenum shadertype, GLint location, GLuint* params) {
    auto* ctx = requireCurrentContext("glGetUniformSubroutineuiv");
    if (!ctx) return;
    (void)shadertype; (void)location;
    if (params) *params = 0;
    markProgramFunction(FunctionId::glGetUniformSubroutineuiv, "GetUniformSubroutineuiv stub (returns 0).");
    Runtime::shared().recordBootstrapTrace("glGetUniformSubroutineuiv(shadertype=" + std::to_string(shadertype) + ", location=" + std::to_string(location) + ")");
}

void APIENTRY glGetProgramStageiv(GLuint program, GLenum shadertype, GLenum pname, GLint* values) {
    auto* ctx = requireCurrentContext("glGetProgramStageiv");
    if (!ctx || !values) return;
    int si = -1;
    switch (shadertype) {
        case GL_VERTEX_SHADER:          si = 0; break;
        case GL_TESS_CONTROL_SHADER:    si = 1; break;
        case GL_TESS_EVALUATION_SHADER: si = 2; break;
        case GL_GEOMETRY_SHADER:        si = 3; break;
        case GL_FRAGMENT_SHADER:        si = 4; break;
        case GL_COMPUTE_SHADER:         si = 5; break;
        default:
            recordValidationError(ctx, "glGetProgramStageiv", GL_INVALID_ENUM, "invalid shadertype");
            return;
    }
    auto* prog = ctx->objects().programs().get(program);
    const auto& subs = prog ? prog->resourceSubroutines[si]
                            : std::vector<appgl::GLProgramResourceEntry>{};
    const auto& unis = prog ? prog->resourceSubroutineUniforms[si]
                            : std::vector<appgl::GLProgramResourceEntry>{};
    auto maxNameLen = [](const std::vector<appgl::GLProgramResourceEntry>& v) -> GLint {
        GLint m = 0;
        for (const auto& e : v) {
            GLint n = static_cast<GLint>(e.name.size() + 1);
            if (n > m) m = n;
        }
        return m;
    };
    auto totalLocations = [](const std::vector<appgl::GLProgramResourceEntry>& v) -> GLint {
        GLint total = 0;
        for (const auto& e : v) {
            total += (e.arraySize > 0) ? e.arraySize : 1;
        }
        return total;
    };
    switch (pname) {
        case GL_ACTIVE_SUBROUTINES:
            *values = static_cast<GLint>(subs.size());
            break;
        case GL_ACTIVE_SUBROUTINE_UNIFORMS:
            *values = static_cast<GLint>(unis.size());
            break;
        case GL_ACTIVE_SUBROUTINE_UNIFORM_LOCATIONS:
            // Array subroutine uniforms each expand to arraySize
            // locations. CTS `uniformSubroutinesuiv` maxes out at
            // this count — still > 0 only when the program declared
            // subroutines. CTS `atomic_counter_buffer` is one caller.
            *values = totalLocations(unis);
            break;
        case GL_ACTIVE_SUBROUTINE_MAX_LENGTH:
            *values = maxNameLen(subs);
            break;
        case GL_ACTIVE_SUBROUTINE_UNIFORM_MAX_LENGTH:
            *values = maxNameLen(unis);
            break;
        default:
            recordValidationError(ctx, "glGetProgramStageiv", GL_INVALID_ENUM, "invalid pname");
            return;
    }
    markProgramFunction(FunctionId::glGetProgramStageiv, "GetProgramStageiv reads GL 4.0 subroutine program-resource tables.");
    Runtime::shared().recordBootstrapTrace("glGetProgramStageiv(program=" + std::to_string(program) + ", pname=" + std::to_string(pname) + ")");
}

// --- GL 4.0: Transform Feedback Objects (Group 4) ---

void APIENTRY glGenTransformFeedbacks(GLsizei n, GLuint* ids) {
    auto* ctx = requireCurrentContext("glGenTransformFeedbacks");
    if (!ctx) return;
    if (n < 0) {
        recordValidationError(ctx, "glGenTransformFeedbacks", GL_INVALID_VALUE, "n < 0");
        return;
    }
    for (GLsizei i = 0; i < n; ++i) {
        ids[i] = ctx->objects().transformFeedbacks().reserveName();
    }
    markStateFunction(FunctionId::glGenTransformFeedbacks, "Transform feedback object name generation.");
    Runtime::shared().recordBootstrapTrace("glGenTransformFeedbacks(n=" + std::to_string(n) + ")");
}

void APIENTRY glDeleteTransformFeedbacks(GLsizei n, const GLuint* ids) {
    auto* ctx = requireCurrentContext("glDeleteTransformFeedbacks");
    if (!ctx) return;
    if (n < 0) {
        recordValidationError(ctx, "glDeleteTransformFeedbacks", GL_INVALID_VALUE, "n < 0");
        return;
    }
    // GL 4.6 §6.1: INVALID_OPERATION if any of the named objects is active.
    if (ctx->isTransformFeedbackActive()) {
        for (GLsizei i = 0; i < n; ++i) {
            if (ids[i] != 0) {
                recordValidationError(ctx, "glDeleteTransformFeedbacks", GL_INVALID_OPERATION,
                                      "cannot delete transform feedback object while transform feedback is active");
                return;
            }
        }
    }
    for (GLsizei i = 0; i < n; ++i) {
        if (ids[i] != 0) {
            ctx->objects().transformFeedbacks().erase(ids[i]);
        }
    }
    markStateFunction(FunctionId::glDeleteTransformFeedbacks, "Transform feedback object deletion.");
    Runtime::shared().recordBootstrapTrace("glDeleteTransformFeedbacks(n=" + std::to_string(n) + ")");
}

GLboolean APIENTRY glIsTransformFeedback(GLuint id) {
    auto* ctx = requireCurrentContext("glIsTransformFeedback");
    if (!ctx) return GL_FALSE;
    // GL 4.6 §13.2.3: glIsTransformFeedback returns TRUE only if the
    // name has been both RESERVED (glGenTransformFeedbacks or
    // glCreateTransformFeedbacks) AND INSTANTIATED (first
    // glBindTransformFeedback, or the DSA Create path which
    // instantiates up-front).
    auto* obj = ctx->objects().transformFeedbacks().get(id);
    GLboolean result = (obj != nullptr && obj->instantiated) ? GL_TRUE : GL_FALSE;
    markStateFunction(FunctionId::glIsTransformFeedback, "Transform feedback object existence query.");
    return result;
}

void APIENTRY glBindTransformFeedback(GLenum target, GLuint id) {
    auto* ctx = requireCurrentContext("glBindTransformFeedback");
    if (!ctx) return;
    if (target != GL_TRANSFORM_FEEDBACK) {
        recordValidationError(ctx, "glBindTransformFeedback", GL_INVALID_ENUM, "target must be GL_TRANSFORM_FEEDBACK");
        return;
    }
    // GL 4.6 §6.1.1: INVALID_OPERATION if XFB is active and not paused.
    if (ctx->isTransformFeedbackActive() && !ctx->isTransformFeedbackPaused()) {
        recordValidationError(ctx, "glBindTransformFeedback", GL_INVALID_OPERATION,
                              "cannot bind transform feedback object while transform feedback is active and not paused");
        return;
    }
    if (id != 0) {
        auto* obj = ctx->objects().transformFeedbacks().get(id);
        if (obj == nullptr) {
            recordValidationError(ctx, "glBindTransformFeedback", GL_INVALID_OPERATION, "transform feedback object does not exist");
            return;
        }
        // First bind "instantiates" a glGen-reserved name.
        obj->instantiated = true;
    }
    ctx->setBoundTransformFeedback(id);
    markStateFunction(FunctionId::glBindTransformFeedback, "Transform feedback object binding (state-tracked).");
    Runtime::shared().recordBootstrapTrace("glBindTransformFeedback(target=GL_TRANSFORM_FEEDBACK, id=" + std::to_string(id) + ")");
}

void APIENTRY glPauseTransformFeedback(void) {
    auto* ctx = requireCurrentContext("glPauseTransformFeedback");
    if (!ctx) return;
    // GL 4.6 §13.3: INVALID_OPERATION if XFB is not active or already paused.
    if (!ctx->isTransformFeedbackActive() || ctx->isTransformFeedbackPaused()) {
        recordValidationError(ctx, "glPauseTransformFeedback", GL_INVALID_OPERATION,
                              "transform feedback is not active or is already paused");
        return;
    }
    ctx->setTransformFeedbackPaused(true);
    markStateFunction(FunctionId::glPauseTransformFeedback, "PauseTransformFeedback (state-tracked).");
    Runtime::shared().recordBootstrapTrace("glPauseTransformFeedback()");
}

void APIENTRY glResumeTransformFeedback(void) {
    auto* ctx = requireCurrentContext("glResumeTransformFeedback");
    if (!ctx) return;
    // GL 4.6 §13.3: INVALID_OPERATION if XFB is not active or not paused.
    if (!ctx->isTransformFeedbackActive() || !ctx->isTransformFeedbackPaused()) {
        recordValidationError(ctx, "glResumeTransformFeedback", GL_INVALID_OPERATION,
                              "transform feedback is not active or not paused");
        return;
    }
    ctx->setTransformFeedbackPaused(false);
    markStateFunction(FunctionId::glResumeTransformFeedback, "ResumeTransformFeedback (state-tracked).");
    Runtime::shared().recordBootstrapTrace("glResumeTransformFeedback()");
}

void APIENTRY glDrawTransformFeedback(GLenum mode, GLuint id) {
    auto* ctx = requireCurrentContext("glDrawTransformFeedback");
    if (!ctx) return;
    // GL 4.6 §10.5: INVALID_VALUE if id is not the name of a transform feedback object.
    if (id != 0 && !ctx->objects().transformFeedbacks().contains(id)) {
        recordValidationError(ctx, "glDrawTransformFeedback", GL_INVALID_VALUE,
                              "id is not a valid transform feedback object");
        return;
    }
    // GL 4.6 §10.5: INVALID_OPERATION if EndTransformFeedback was never called
    // for the object.
    auto* tfObj = (id != 0) ? ctx->objects().transformFeedbacks().get(id) : nullptr;
    if (tfObj && !tfObj->hasCompleted) {
        recordValidationError(ctx, "glDrawTransformFeedback", GL_INVALID_OPERATION,
                              "EndTransformFeedback has never been called for this object");
        return;
    }
    (void)mode;
    // Stub: no vertex capture → 0 primitives drawn.
    markStateFunction(FunctionId::glDrawTransformFeedback, "DrawTransformFeedback stub (0 primitives, no TF capture).");
    Runtime::shared().recordBootstrapTrace("glDrawTransformFeedback(mode=" + std::to_string(mode) + ", id=" + std::to_string(id) + ")");
}

void APIENTRY glDrawTransformFeedbackStream(GLenum mode, GLuint id, GLuint stream) {
    auto* ctx = requireCurrentContext("glDrawTransformFeedbackStream");
    if (!ctx) return;
    // GL 4.6 §10.5: INVALID_VALUE if stream >= GL_MAX_VERTEX_STREAMS.
    if (stream >= 4) {
        recordValidationError(ctx, "glDrawTransformFeedbackStream", GL_INVALID_VALUE,
                              "stream exceeds GL_MAX_VERTEX_STREAMS");
        return;
    }
    (void)mode; (void)id;
    // Stub: same as DrawTransformFeedback but with stream index. 0 primitives.
    markStateFunction(FunctionId::glDrawTransformFeedbackStream, "DrawTransformFeedbackStream stub (0 primitives).");
    Runtime::shared().recordBootstrapTrace("glDrawTransformFeedbackStream(mode=" + std::to_string(mode) + ", id=" + std::to_string(id) + ", stream=" + std::to_string(stream) + ")");
}

// --- GL 4.0: Indirect Drawing (Group 6) ---

void APIENTRY glDrawArraysIndirect(GLenum mode, const void* indirect) {
    auto* ctx = requireCurrentContext("glDrawArraysIndirect");
    if (!ctx) return;
    if (!isValidDrawMode(mode)) {
        recordValidationError(ctx, "glDrawArraysIndirect", GL_INVALID_ENUM, "mode is not a recognized primitive type");
        return;
    }
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (ctx->getBoundVertexArray() == 0) {
        recordValidationError(ctx, "glDrawArraysIndirect", GL_INVALID_OPERATION, "no VAO bound (default VAO 0 in core profile)");
        return;
    }
    // Offset into indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        recordValidationError(ctx, "glDrawArraysIndirect", GL_INVALID_VALUE, "indirect offset not aligned to 4 bytes");
        return;
    }
    // GL spec: if GL_DRAW_INDIRECT_BUFFER is bound, `indirect` is a byte offset
    // into that buffer; otherwise it is a client pointer to the command struct.
    // Decompose into a regular drawArraysInstancedBaseInstance call.
    struct DrawArraysIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint first;
        GLuint baseInstance;
    };
    DrawArraysIndirectCommand cmd{};
    if (!ctx->readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, indirect, sizeof(cmd), &cmd)) {
        return;  // error already recorded by readIndirectBuffer
    }
    if (cmd.count == 0 || cmd.instanceCount == 0) {
        // Valid no-op per spec.
        markDrawFunction(FunctionId::glDrawArraysIndirect, "DrawArraysIndirect: zero count/instanceCount, no-op.");
        return;
    }
    ctx->drawArraysInstancedBaseInstance(mode, static_cast<GLint>(cmd.first),
                                         static_cast<GLsizei>(cmd.count),
                                         static_cast<GLsizei>(cmd.instanceCount),
                                         cmd.baseInstance);
    markDrawFunction(FunctionId::glDrawArraysIndirect, "DrawArraysIndirect decomposed to drawArraysInstancedBaseInstance.");
    Runtime::shared().recordBootstrapTrace(
        "glDrawArraysIndirect(mode=" + std::to_string(mode)
        + ", count=" + std::to_string(cmd.count)
        + ", instanceCount=" + std::to_string(cmd.instanceCount)
        + ", first=" + std::to_string(cmd.first)
        + ", baseInstance=" + std::to_string(cmd.baseInstance) + ")");
}

void APIENTRY glDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect) {
    auto* ctx = requireCurrentContext("glDrawElementsIndirect");
    if (!ctx) return;
    if (!isValidDrawMode(mode)) {
        recordValidationError(ctx, "glDrawElementsIndirect", GL_INVALID_ENUM, "mode is not a recognized primitive type");
        return;
    }
    if (!isValidDrawElementsType(type)) {
        recordValidationError(ctx, "glDrawElementsIndirect", GL_INVALID_ENUM, "type must be UNSIGNED_BYTE/SHORT/INT");
        return;
    }
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (ctx->getBoundVertexArray() == 0) {
        recordValidationError(ctx, "glDrawElementsIndirect", GL_INVALID_OPERATION, "no VAO bound (default VAO 0 in core profile)");
        return;
    }
    // Offset into indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        recordValidationError(ctx, "glDrawElementsIndirect", GL_INVALID_VALUE, "indirect offset not aligned to 4 bytes");
        return;
    }
    // GL spec: if GL_DRAW_INDIRECT_BUFFER is bound, `indirect` is a byte offset
    // into that buffer; otherwise it is a client pointer to the command struct.
    struct DrawElementsIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint firstIndex;
        GLuint baseVertex;
        GLuint baseInstance;
    };
    DrawElementsIndirectCommand cmd{};
    if (!ctx->readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, indirect, sizeof(cmd), &cmd)) {
        return;
    }
    if (cmd.count == 0 || cmd.instanceCount == 0) {
        markDrawFunction(FunctionId::glDrawElementsIndirect, "DrawElementsIndirect: zero count/instanceCount, no-op.");
        return;
    }
    // Compute the byte offset for firstIndex: firstIndex * sizeof(index_type).
    GLsizei indexSize = (type == GL_UNSIGNED_INT) ? 4 : (type == GL_UNSIGNED_SHORT) ? 2 : 1;
    const void* indexOffset = reinterpret_cast<const void*>(
        static_cast<uintptr_t>(cmd.firstIndex) * static_cast<uintptr_t>(indexSize));
    ctx->drawElementsInstancedBaseVertexBaseInstance(mode,
        static_cast<GLsizei>(cmd.count), type, indexOffset,
        static_cast<GLsizei>(cmd.instanceCount),
        static_cast<GLint>(cmd.baseVertex),
        cmd.baseInstance);
    markDrawFunction(FunctionId::glDrawElementsIndirect, "DrawElementsIndirect decomposed to drawElementsInstancedBaseVertexBaseInstance.");
    Runtime::shared().recordBootstrapTrace(
        "glDrawElementsIndirect(mode=" + std::to_string(mode)
        + ", type=" + std::to_string(type)
        + ", count=" + std::to_string(cmd.count)
        + ", instanceCount=" + std::to_string(cmd.instanceCount)
        + ", firstIndex=" + std::to_string(cmd.firstIndex)
        + ", baseVertex=" + std::to_string(cmd.baseVertex)
        + ", baseInstance=" + std::to_string(cmd.baseInstance) + ")");
}

// --- GL 4.2: Memory Barriers ---

void APIENTRY glMemoryBarrier(GLbitfield barriers) {
    auto* ctx = requireCurrentContext("glMemoryBarrier");
    if (!ctx) return;
    if (!ctx->memoryBarrier(barriers)) {
        return;
    }
    markStateFunction(FunctionId::glMemoryBarrier, "MemoryBarrier validated no-op (Metal handles ordering implicitly).");
    Runtime::shared().recordBootstrapTrace("glMemoryBarrier(barriers=0x" + std::to_string(barriers) + ")");
}

// --- GL 4.3: Compute Shaders ---

void APIENTRY glDispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z) {
    auto* ctx = requireCurrentContext("glDispatchCompute");
    if (!ctx) return;
    if (!ctx->dispatchCompute(num_groups_x, num_groups_y, num_groups_z)) {
        return;
    }
    markStateFunction(FunctionId::glDispatchCompute, "DispatchCompute stub (validated, compute pipeline not yet wired).");
    Runtime::shared().recordBootstrapTrace(
        "glDispatchCompute(x=" + std::to_string(num_groups_x)
        + ", y=" + std::to_string(num_groups_y)
        + ", z=" + std::to_string(num_groups_z) + ")"
    );
}

void APIENTRY glDispatchComputeIndirect(GLintptr indirect) {
    auto* ctx = requireCurrentContext("glDispatchComputeIndirect");
    if (!ctx) return;
    if (!ctx->dispatchComputeIndirect(indirect)) {
        return;
    }
    markStateFunction(FunctionId::glDispatchComputeIndirect, "DispatchComputeIndirect stub (validated, compute pipeline not yet wired).");
    Runtime::shared().recordBootstrapTrace(
        "glDispatchComputeIndirect(indirect=" + std::to_string(indirect) + ")"
    );
}

// --- GL 4.2: Image Load/Store ---

void APIENTRY glBindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format) {
    auto* context = requireCurrentContext("glBindImageTexture");
    if (context == nullptr) {
        return;
    }
    if (!context->bindImageTexture(unit, texture, level, layered, layer, access, format)) {
        return;
    }
    markTextureFunction(FunctionId::glBindImageTexture, "Image unit binding state is tracked for load/store shaders.");
    Runtime::shared().recordBootstrapTrace(
        "glBindImageTexture(unit=" + std::to_string(unit)
        + ", texture=" + std::to_string(texture)
        + ", level=" + std::to_string(level)
        + ", layered=" + std::to_string(layered)
        + ", layer=" + std::to_string(layer)
        + ", access=0x" + std::to_string(access)
        + ", format=0x" + std::to_string(format) + ")"
    );
}

// --- GL 4.2: Atomic Counter Queries ---

void APIENTRY glGetActiveAtomicCounterBufferiv(GLuint program, GLuint bufferIndex, GLenum pname, GLint* params) {
    auto* context = requireCurrentContext("glGetActiveAtomicCounterBufferiv");
    if (context == nullptr) {
        return;
    }
    if (!context->getActiveAtomicCounterBufferiv(program, bufferIndex, pname, params)) {
        return;
    }
    markProgramFunction(FunctionId::glGetActiveAtomicCounterBufferiv, "Atomic counter buffer query returns sensible defaults (Metal has no native atomic counters).");
}

// --- GL 4.3: Program Resource Introspection ---

void APIENTRY glGetProgramInterfaceiv(GLuint program, GLenum programInterface, GLenum pname, GLint* params) {
    auto* ctx = requireCurrentContext("glGetProgramInterfaceiv");
    if (!ctx) return;
    if (!ctx->getProgramInterfaceiv(program, programInterface, pname, params)) {
        return;
    }
    markProgramFunction(FunctionId::glGetProgramInterfaceiv, "Program interface query returns resource counts from reflection tables.");
}

void APIENTRY glGetProgramResourceiv(GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum* props, GLsizei count, GLsizei* length, GLint* params) {
    auto* ctx = requireCurrentContext("glGetProgramResourceiv");
    if (!ctx) return;
    if (!ctx->getProgramResourceiv(program, programInterface, index, propCount, props, count, length, params)) {
        return;
    }
    markProgramFunction(FunctionId::glGetProgramResourceiv, "Program resource property query returns reflection data.");
}

void APIENTRY glGetProgramResourceName(GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei* length, GLchar* name) {
    auto* ctx = requireCurrentContext("glGetProgramResourceName");
    if (!ctx) return;
    if (!ctx->getProgramResourceName(program, programInterface, index, bufSize, length, name)) {
        return;
    }
    markProgramFunction(FunctionId::glGetProgramResourceName, "Program resource name query returns reflected names.");
}

GLuint APIENTRY glGetProgramResourceIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    auto* ctx = requireCurrentContext("glGetProgramResourceIndex");
    if (!ctx) return GL_INVALID_INDEX;
    GLuint result = ctx->getProgramResourceIndex(program, programInterface, name);
    markProgramFunction(FunctionId::glGetProgramResourceIndex, "Program resource index lookup by name.");
    return result;
}

GLint APIENTRY glGetProgramResourceLocation(GLuint program, GLenum programInterface, const GLchar* name) {
    auto* ctx = requireCurrentContext("glGetProgramResourceLocation");
    if (!ctx) return -1;
    GLint result = ctx->getProgramResourceLocation(program, programInterface, name);
    markProgramFunction(FunctionId::glGetProgramResourceLocation, "Program resource location lookup by name.");
    return result;
}

GLint APIENTRY glGetProgramResourceLocationIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    auto* ctx = requireCurrentContext("glGetProgramResourceLocationIndex");
    if (!ctx) return -1;
    GLint result = ctx->getProgramResourceLocationIndex(program, programInterface, name);
    markProgramFunction(FunctionId::glGetProgramResourceLocationIndex, "Program resource location index (dual-source blending).");
    return result;
}

// --- GL 4.3: SSBO Binding Remapping ---

void APIENTRY glShaderStorageBlockBinding(GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding) {
    auto* ctx = requireCurrentContext("glShaderStorageBlockBinding");
    if (!ctx) return;
    if (!ctx->shaderStorageBlockBinding(program, storageBlockIndex, storageBlockBinding)) {
        return;
    }
    markProgramFunction(FunctionId::glShaderStorageBlockBinding, "SSBO block binding remapping tracked on program object.");
    Runtime::shared().recordBootstrapTrace(
        "glShaderStorageBlockBinding(program=" + std::to_string(program)
        + ", blockIndex=" + std::to_string(storageBlockIndex)
        + ", binding=" + std::to_string(storageBlockBinding) + ")"
    );
}

// --- GL 4.2: Advanced Instanced Drawing ---

void APIENTRY glDrawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance) {
    auto* ctx = requireCurrentContext("glDrawArraysInstancedBaseInstance");
    if (!ctx) return;
    if (!ctx->drawArraysInstancedBaseInstance(mode, first, count, instancecount, baseinstance)) {
        return;
    }
    markDrawFunction(FunctionId::glDrawArraysInstancedBaseInstance, "DrawArraysInstancedBaseInstance stub (validated, Metal instancing ready).");
}

void APIENTRY glDrawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance) {
    auto* ctx = requireCurrentContext("glDrawElementsInstancedBaseInstance");
    if (!ctx) return;
    if (!ctx->drawElementsInstancedBaseInstance(mode, count, type, indices, instancecount, baseinstance)) {
        return;
    }
    markDrawFunction(FunctionId::glDrawElementsInstancedBaseInstance, "DrawElementsInstancedBaseInstance stub (validated, Metal instancing ready).");
}

void APIENTRY glDrawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance) {
    auto* ctx = requireCurrentContext("glDrawElementsInstancedBaseVertexBaseInstance");
    if (!ctx) return;
    if (!ctx->drawElementsInstancedBaseVertexBaseInstance(mode, count, type, indices, instancecount, basevertex, baseinstance)) {
        return;
    }
    markDrawFunction(FunctionId::glDrawElementsInstancedBaseVertexBaseInstance, "DrawElementsInstancedBaseVertexBaseInstance stub (validated).");
}

// --- GL 4.3: Multi-Draw Indirect ---

void APIENTRY glMultiDrawArraysIndirect(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride) {
    auto* ctx = requireCurrentContext("glMultiDrawArraysIndirect");
    if (!ctx) return;
    if (!ctx->multiDrawArraysIndirect(mode, indirect, drawcount, stride)) {
        return;
    }
    markDrawFunction(FunctionId::glMultiDrawArraysIndirect, "MultiDrawArraysIndirect decomposed to per-command drawArraysInstancedBaseInstance.");
}

void APIENTRY glMultiDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect, GLsizei drawcount, GLsizei stride) {
    auto* ctx = requireCurrentContext("glMultiDrawElementsIndirect");
    if (!ctx) return;
    if (!ctx->multiDrawElementsIndirect(mode, type, indirect, drawcount, stride)) {
        return;
    }
    markDrawFunction(FunctionId::glMultiDrawElementsIndirect, "MultiDrawElementsIndirect decomposed to per-command drawElementsInstancedBaseVertexBaseInstance.");
}

// --- GL 4.3: Buffer Clear ---

void APIENTRY glClearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearBufferData");
    if (!ctx) return;
    if (!ctx->clearBufferData(target, internalformat, format, type, data)) {
        return;
    }
    markStateFunction(FunctionId::glClearBufferData, "Buffer data cleared with pattern fill.");
}

void APIENTRY glClearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearBufferSubData");
    if (!ctx) return;
    if (!ctx->clearBufferSubData(target, internalformat, offset, size, format, type, data)) {
        return;
    }
    markStateFunction(FunctionId::glClearBufferSubData, "Buffer sub-range cleared with pattern fill.");
}

// --- GL 4.3: Framebuffer Parameters ---

void APIENTRY glFramebufferParameteri(GLenum target, GLenum pname, GLint param) {
    auto* ctx = requireCurrentContext("glFramebufferParameteri");
    if (!ctx) return;
    if (!ctx->framebufferParameteri(target, pname, param)) {
        return;
    }
    markStateFunction(FunctionId::glFramebufferParameteri, "Framebuffer default parameter hint accepted.");
}

void APIENTRY glGetFramebufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    auto* ctx = requireCurrentContext("glGetFramebufferParameteriv");
    if (!ctx) return;
    if (!ctx->getFramebufferParameteriv(target, pname, params)) {
        return;
    }
    markStateFunction(FunctionId::glGetFramebufferParameteriv, "Framebuffer default parameter query returns defaults.");
}

// --- GL 4.3: Invalidation Hints ---

void APIENTRY glInvalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments) {
    auto* ctx = requireCurrentContext("glInvalidateFramebuffer");
    if (!ctx) return;
    if (!ctx->invalidateFramebuffer(target, numAttachments, attachments)) {
        return;
    }
    markStateFunction(FunctionId::glInvalidateFramebuffer, "Framebuffer invalidation hint accepted (maps to MTLStoreAction.dontCare).");
}

void APIENTRY glInvalidateSubFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments, GLint x, GLint y, GLsizei width, GLsizei height) {
    auto* ctx = requireCurrentContext("glInvalidateSubFramebuffer");
    if (!ctx) return;
    if (!ctx->invalidateSubFramebuffer(target, numAttachments, attachments, x, y, width, height)) {
        return;
    }
    markStateFunction(FunctionId::glInvalidateSubFramebuffer, "Sub-framebuffer invalidation hint accepted.");
}

void APIENTRY glInvalidateBufferData(GLuint buffer) {
    auto* ctx = requireCurrentContext("glInvalidateBufferData");
    if (!ctx) return;
    if (!ctx->invalidateBufferData(buffer)) {
        return;
    }
    markStateFunction(FunctionId::glInvalidateBufferData, "Buffer data invalidation hint accepted.");
}

void APIENTRY glInvalidateBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    auto* ctx = requireCurrentContext("glInvalidateBufferSubData");
    if (!ctx) return;
    if (!ctx->invalidateBufferSubData(buffer, offset, length)) {
        return;
    }
    markStateFunction(FunctionId::glInvalidateBufferSubData, "Buffer sub-data invalidation hint accepted.");
}

// --- GL 4.3: Texture Operations ---

void APIENTRY glCopyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                                  GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                                  GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth) {
    auto* ctx = requireCurrentContext("glCopyImageSubData");
    if (!ctx) return;
    if (!ctx->copyImageSubData(srcName, srcTarget, srcLevel, srcX, srcY, srcZ,
                                dstName, dstTarget, dstLevel, dstX, dstY, dstZ,
                                srcWidth, srcHeight, srcDepth)) {
        return;
    }
    markTextureFunction(FunctionId::glCopyImageSubData, "CopyImageSubData stub (validated, Metal blit copy deferred).");
}

void APIENTRY glTextureView(GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat,
                             GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers) {
    auto* ctx = requireCurrentContext("glTextureView");
    if (!ctx) return;
    if (!ctx->textureView(texture, target, origtexture, internalformat, minlevel, numlevels, minlayer, numlayers)) {
        return;
    }
    markTextureFunction(FunctionId::glTextureView, "TextureView relationship recorded (Metal view creation deferred to draw).");
}

void APIENTRY glInvalidateTexImage(GLuint texture, GLint level) {
    auto* ctx = requireCurrentContext("glInvalidateTexImage");
    if (!ctx) return;
    if (!ctx->invalidateTexImage(texture, level)) {
        return;
    }
    markTextureFunction(FunctionId::glInvalidateTexImage, "Texture image invalidation hint accepted.");
}

void APIENTRY glInvalidateTexSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                       GLsizei width, GLsizei height, GLsizei depth) {
    auto* ctx = requireCurrentContext("glInvalidateTexSubImage");
    if (!ctx) return;
    if (!ctx->invalidateTexSubImage(texture, level, xoffset, yoffset, zoffset, width, height, depth)) {
        return;
    }
    markTextureFunction(FunctionId::glInvalidateTexSubImage, "Texture sub-image invalidation hint accepted.");
}

// --- GL 4.2: Transform Feedback Instanced Draw ---

void APIENTRY glDrawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount) {
    auto* ctx = requireCurrentContext("glDrawTransformFeedbackInstanced");
    if (!ctx) return;
    if (!isValidDrawMode(mode)) {
        recordValidationError(ctx, "glDrawTransformFeedbackInstanced", GL_INVALID_ENUM,
                              "mode is not a recognized primitive type");
        return;
    }
    // GL 4.6 §10.5: INVALID_VALUE if id is not a valid transform feedback object.
    if (!ctx->objects().transformFeedbacks().contains(id)) {
        recordValidationError(ctx, "glDrawTransformFeedbackInstanced", GL_INVALID_VALUE,
                              "id is not a valid transform feedback object");
        return;
    }
    // GL 4.6 §10.5: INVALID_OPERATION if mode is incompatible with the captured XFB mode.
    {
        auto* tfObj = ctx->objects().transformFeedbacks().get(id);
        if (tfObj && tfObj->hasCompleted &&
            !isDrawModeCompatibleWithXfb(mode, tfObj->capturedPrimitiveMode)) {
            recordValidationError(ctx, "glDrawTransformFeedbackInstanced", GL_INVALID_OPERATION,
                                  "draw mode incompatible with captured transform feedback primitive mode");
            return;
        }
    }
    if (!ctx->drawTransformFeedbackInstanced(mode, id, instancecount)) {
        return;
    }
    markDrawFunction(FunctionId::glDrawTransformFeedbackInstanced, "DrawTransformFeedbackInstanced stub (0 captured prims).");
}

void APIENTRY glDrawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount) {
    auto* ctx = requireCurrentContext("glDrawTransformFeedbackStreamInstanced");
    if (!ctx) return;
    if (!isValidDrawMode(mode)) {
        recordValidationError(ctx, "glDrawTransformFeedbackStreamInstanced", GL_INVALID_ENUM,
                              "mode is not a recognized primitive type");
        return;
    }
    // GL 4.6 §10.5: INVALID_VALUE if stream >= GL_MAX_VERTEX_STREAMS.
    if (stream >= 4) {
        recordValidationError(ctx, "glDrawTransformFeedbackStreamInstanced", GL_INVALID_VALUE,
                              "stream exceeds GL_MAX_VERTEX_STREAMS");
        return;
    }
    // GL 4.6 §10.5: INVALID_VALUE if id is not a valid transform feedback object.
    if (!ctx->objects().transformFeedbacks().contains(id)) {
        recordValidationError(ctx, "glDrawTransformFeedbackStreamInstanced", GL_INVALID_VALUE,
                              "id is not a valid transform feedback object");
        return;
    }
    // GL 4.6 §10.5: INVALID_OPERATION if EndTransformFeedback was never called.
    auto* tfObj = ctx->objects().transformFeedbacks().get(id);
    if (tfObj && !tfObj->hasCompleted) {
        recordValidationError(ctx, "glDrawTransformFeedbackStreamInstanced", GL_INVALID_OPERATION,
                              "EndTransformFeedback has never been called for this object");
        return;
    }
    // GL 4.6 §10.5: INVALID_OPERATION if mode is incompatible with captured XFB mode.
    if (tfObj && tfObj->hasCompleted &&
        !isDrawModeCompatibleWithXfb(mode, tfObj->capturedPrimitiveMode)) {
        recordValidationError(ctx, "glDrawTransformFeedbackStreamInstanced", GL_INVALID_OPERATION,
                              "draw mode incompatible with captured transform feedback primitive mode");
        return;
    }
    if (!ctx->drawTransformFeedbackStreamInstanced(mode, id, stream, instancecount)) {
        return;
    }
    markDrawFunction(FunctionId::glDrawTransformFeedbackStreamInstanced, "DrawTransformFeedbackStreamInstanced stub (0 captured prims).");
}

// --- GL 4.2/4.3: Internal Format Query ---

void APIENTRY glGetInternalformativ(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint* params) {
    auto* ctx = requireCurrentContext("glGetInternalformativ");
    if (!ctx) return;
    if (!ctx->getInternalformativ(target, internalformat, pname, count, params)) {
        return;
    }
    markStateFunction(FunctionId::glGetInternalformativ, "Internal format query returns Metal-appropriate capabilities.");
}

void APIENTRY glGetInternalformati64v(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint64* params) {
    auto* ctx = requireCurrentContext("glGetInternalformati64v");
    if (!ctx) return;
    if (!ctx->getInternalformati64v(target, internalformat, pname, count, params)) {
        return;
    }
    markStateFunction(FunctionId::glGetInternalformati64v, "Internal format i64 query returns Metal-appropriate capabilities.");
}

// ---------------------------------------------------------------------------
// GL 4.4 — Immutable buffer storage.
// ---------------------------------------------------------------------------

void APIENTRY glBufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags) {
    auto* ctx = requireCurrentContext("glBufferStorage");
    if (!ctx) return;
    if (!ctx->bufferStorage(target, size, data, flags)) return;
    markBufferFunction(FunctionId::glBufferStorage, "Immutable buffer storage created.");
}

// ---------------------------------------------------------------------------
// GL 4.4 — Multi-bind.
// ---------------------------------------------------------------------------

void APIENTRY glBindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers) {
    auto* ctx = requireCurrentContext("glBindBuffersBase");
    if (!ctx) return;
    if (!ctx->bindBuffersBase(target, first, count, buffers)) return;
    markBufferFunction(FunctionId::glBindBuffersBase, "Batch buffer base binding.");
}

void APIENTRY glBindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint* buffers,
                                  const GLintptr* offsets, const GLsizeiptr* sizes) {
    auto* ctx = requireCurrentContext("glBindBuffersRange");
    if (!ctx) return;
    if (!ctx->bindBuffersRange(target, first, count, buffers, offsets, sizes)) return;
    markBufferFunction(FunctionId::glBindBuffersRange, "Batch buffer range binding.");
}

void APIENTRY glBindVertexBuffers(GLuint first, GLsizei count, const GLuint* buffers,
                                   const GLintptr* offsets, const GLsizei* strides) {
    auto* ctx = requireCurrentContext("glBindVertexBuffers");
    if (!ctx) return;
    if (!ctx->bindVertexBuffers(first, count, buffers, offsets, strides)) return;
    markVertexInputFunction(FunctionId::glBindVertexBuffers, "Batch vertex buffer binding.");
}

void APIENTRY glBindTextures(GLuint first, GLsizei count, const GLuint* textures) {
    auto* ctx = requireCurrentContext("glBindTextures");
    if (!ctx) return;
    if (!ctx->bindTextures(first, count, textures)) return;
    markTextureFunction(FunctionId::glBindTextures, "Batch texture binding.");
}

void APIENTRY glBindSamplers(GLuint first, GLsizei count, const GLuint* samplers) {
    auto* ctx = requireCurrentContext("glBindSamplers");
    if (!ctx) return;
    if (!ctx->bindSamplers(first, count, samplers)) return;
    markTextureFunction(FunctionId::glBindSamplers, "Batch sampler binding.");
}

void APIENTRY glBindImageTextures(GLuint first, GLsizei count, const GLuint* textures) {
    auto* ctx = requireCurrentContext("glBindImageTextures");
    if (!ctx) return;
    if (!ctx->bindImageTextures(first, count, textures)) return;
    markTextureFunction(FunctionId::glBindImageTextures, "Batch image texture binding.");
}

// ---------------------------------------------------------------------------
// GL 4.4 — Texture clear.
// ---------------------------------------------------------------------------

void APIENTRY glClearTexImage(GLuint texture, GLint level, GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearTexImage");
    if (!ctx) return;
    if (!ctx->clearTexImage(texture, level, format, type, data)) return;
    markTextureFunction(FunctionId::glClearTexImage, "Texture image cleared.");
}

void APIENTRY glClearTexSubImage(GLuint texture, GLint level,
                                  GLint xoffset, GLint yoffset, GLint zoffset,
                                  GLsizei width, GLsizei height, GLsizei depth,
                                  GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearTexSubImage");
    if (!ctx) return;
    if (!ctx->clearTexSubImage(texture, level, xoffset, yoffset, zoffset, width, height, depth, format, type, data)) return;
    markTextureFunction(FunctionId::glClearTexSubImage, "Texture sub-image cleared.");
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA object creation.
// ---------------------------------------------------------------------------

void APIENTRY glCreateBuffers(GLsizei n, GLuint* buffers) {
    auto* ctx = requireCurrentContext("glCreateBuffers");
    if (!ctx) return;
    if (!ctx->createBuffers(n, buffers)) return;
    markBufferFunction(FunctionId::glCreateBuffers, "DSA buffer creation.");
}

void APIENTRY glCreateTextures(GLenum target, GLsizei n, GLuint* textures) {
    auto* ctx = requireCurrentContext("glCreateTextures");
    if (!ctx) return;
    if (!ctx->createTextures(target, n, textures)) return;
    markTextureFunction(FunctionId::glCreateTextures, "DSA texture creation.");
}

void APIENTRY glCreateSamplers(GLsizei n, GLuint* samplers) {
    auto* ctx = requireCurrentContext("glCreateSamplers");
    if (!ctx) return;
    if (!ctx->createSamplers(n, samplers)) return;
    markTextureFunction(FunctionId::glCreateSamplers, "DSA sampler creation.");
}

void APIENTRY glCreateFramebuffers(GLsizei n, GLuint* framebuffers) {
    auto* ctx = requireCurrentContext("glCreateFramebuffers");
    if (!ctx) return;
    if (!ctx->createFramebuffers(n, framebuffers)) return;
    markFramebufferFunction(FunctionId::glCreateFramebuffers, "DSA framebuffer creation.");
}

void APIENTRY glCreateRenderbuffers(GLsizei n, GLuint* renderbuffers) {
    auto* ctx = requireCurrentContext("glCreateRenderbuffers");
    if (!ctx) return;
    if (!ctx->createRenderbuffers(n, renderbuffers)) return;
    markFramebufferFunction(FunctionId::glCreateRenderbuffers, "DSA renderbuffer creation.");
}

void APIENTRY glCreateVertexArrays(GLsizei n, GLuint* arrays) {
    auto* ctx = requireCurrentContext("glCreateVertexArrays");
    if (!ctx) return;
    if (!ctx->createVertexArrays(n, arrays)) return;
    markVertexInputFunction(FunctionId::glCreateVertexArrays, "DSA vertex array creation.");
}

void APIENTRY glCreateTransformFeedbacks(GLsizei n, GLuint* ids) {
    auto* ctx = requireCurrentContext("glCreateTransformFeedbacks");
    if (!ctx) return;
    if (!ctx->createTransformFeedbacks(n, ids)) return;
    markStateFunction(FunctionId::glCreateTransformFeedbacks, "DSA transform feedback creation.");
}

void APIENTRY glCreateProgramPipelines(GLsizei n, GLuint* pipelines) {
    auto* ctx = requireCurrentContext("glCreateProgramPipelines");
    if (!ctx) return;
    if (!ctx->createProgramPipelines(n, pipelines)) return;
    markShaderFunction(FunctionId::glCreateProgramPipelines, "DSA program pipeline creation.");
}

void APIENTRY glCreateQueries(GLenum target, GLsizei n, GLuint* ids) {
    auto* ctx = requireCurrentContext("glCreateQueries");
    if (!ctx) return;
    if (!ctx->createQueries(target, n, ids)) return;
    markStateFunction(FunctionId::glCreateQueries, "DSA query creation.");
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA buffer operations.
// ---------------------------------------------------------------------------

#define DSA_BUF_VOID(glName, ctxMethod, ...) \
void APIENTRY glName(__VA_ARGS__) { \
    auto* ctx = requireCurrentContext(#glName); \
    if (!ctx) return; \
    if (!ctx->ctxMethod) return; \
    markBufferFunction(FunctionId::glName, "DSA " #glName "."); \
}

void APIENTRY glNamedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags) {
    auto* ctx = requireCurrentContext("glNamedBufferStorage"); if (!ctx) return;
    if (!ctx->namedBufferStorage(buffer, size, data, flags)) return;
    markBufferFunction(FunctionId::glNamedBufferStorage, "DSA immutable buffer storage.");
}
void APIENTRY glNamedBufferData(GLuint buffer, GLsizeiptr size, const void* data, GLenum usage) {
    auto* ctx = requireCurrentContext("glNamedBufferData"); if (!ctx) return;
    if (!ctx->namedBufferData(buffer, size, data, usage)) return;
    markBufferFunction(FunctionId::glNamedBufferData, "DSA buffer data upload.");
}
void APIENTRY glNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void* data) {
    auto* ctx = requireCurrentContext("glNamedBufferSubData"); if (!ctx) return;
    if (!ctx->namedBufferSubData(buffer, offset, size, data)) return;
    markBufferFunction(FunctionId::glNamedBufferSubData, "DSA buffer sub-data upload.");
}
void APIENTRY glCopyNamedBufferSubData(GLuint readBuffer, GLuint writeBuffer, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size) {
    auto* ctx = requireCurrentContext("glCopyNamedBufferSubData"); if (!ctx) return;
    if (!ctx->copyNamedBufferSubData(readBuffer, writeBuffer, readOffset, writeOffset, size)) return;
    markBufferFunction(FunctionId::glCopyNamedBufferSubData, "DSA buffer copy.");
}
void* APIENTRY glMapNamedBuffer(GLuint buffer, GLenum access) {
    auto* ctx = requireCurrentContext("glMapNamedBuffer"); if (!ctx) return nullptr;
    void* result = nullptr;
    ctx->mapNamedBuffer(buffer, access, &result);
    markBufferFunction(FunctionId::glMapNamedBuffer, "DSA buffer map.");
    return result;
}
void* APIENTRY glMapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    auto* ctx = requireCurrentContext("glMapNamedBufferRange"); if (!ctx) return nullptr;
    void* result = nullptr;
    ctx->mapNamedBufferRange(buffer, offset, length, access, &result);
    markBufferFunction(FunctionId::glMapNamedBufferRange, "DSA buffer range map.");
    return result;
}
GLboolean APIENTRY glUnmapNamedBuffer(GLuint buffer) {
    auto* ctx = requireCurrentContext("glUnmapNamedBuffer"); if (!ctx) return GL_FALSE;
    GLboolean result = GL_FALSE;
    ctx->unmapNamedBuffer(buffer, &result);
    markBufferFunction(FunctionId::glUnmapNamedBuffer, "DSA buffer unmap.");
    return result;
}
void APIENTRY glFlushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    auto* ctx = requireCurrentContext("glFlushMappedNamedBufferRange"); if (!ctx) return;
    if (!ctx->flushMappedNamedBufferRange(buffer, offset, length)) return;
    markBufferFunction(FunctionId::glFlushMappedNamedBufferRange, "DSA mapped buffer flush.");
}
void APIENTRY glClearNamedBufferData(GLuint buffer, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearNamedBufferData"); if (!ctx) return;
    if (!ctx->clearNamedBufferData(buffer, internalformat, format, type, data)) return;
    markBufferFunction(FunctionId::glClearNamedBufferData, "DSA buffer clear.");
}
void APIENTRY glClearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    auto* ctx = requireCurrentContext("glClearNamedBufferSubData"); if (!ctx) return;
    if (!ctx->clearNamedBufferSubData(buffer, internalformat, offset, size, format, type, data)) return;
    markBufferFunction(FunctionId::glClearNamedBufferSubData, "DSA buffer sub-range clear.");
}
void APIENTRY glGetNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint* params) {
    auto* ctx = requireCurrentContext("glGetNamedBufferParameteriv"); if (!ctx) return;
    if (!ctx->getNamedBufferParameteriv(buffer, pname, params)) return;
    markBufferFunction(FunctionId::glGetNamedBufferParameteriv, "DSA buffer parameter query.");
}
void APIENTRY glGetNamedBufferParameteri64v(GLuint buffer, GLenum pname, GLint64* params) {
    auto* ctx = requireCurrentContext("glGetNamedBufferParameteri64v"); if (!ctx) return;
    if (!ctx->getNamedBufferParameteri64v(buffer, pname, params)) return;
    markBufferFunction(FunctionId::glGetNamedBufferParameteri64v, "DSA buffer i64 parameter query.");
}
void APIENTRY glGetNamedBufferPointerv(GLuint buffer, GLenum pname, void** params) {
    auto* ctx = requireCurrentContext("glGetNamedBufferPointerv"); if (!ctx) return;
    if (!ctx->getNamedBufferPointerv(buffer, pname, params)) return;
    markBufferFunction(FunctionId::glGetNamedBufferPointerv, "DSA buffer pointer query.");
}
void APIENTRY glGetNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void* data) {
    auto* ctx = requireCurrentContext("glGetNamedBufferSubData"); if (!ctx) return;
    if (!ctx->getNamedBufferSubData(buffer, offset, size, data)) return;
    markBufferFunction(FunctionId::glGetNamedBufferSubData, "DSA buffer sub-data readback.");
}

#undef DSA_BUF_VOID

// ---------------------------------------------------------------------------
// GL 4.5 — DSA texture operations.
// ---------------------------------------------------------------------------

#define DSA_TEX_FN(glName, ctxCall) \
    auto* ctx = requireCurrentContext(#glName); if (!ctx) return; \
    if (!ctx->ctxCall) return; \
    markTextureFunction(FunctionId::glName, "DSA " #glName ".");

void APIENTRY glTextureStorage1D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width) {
    DSA_TEX_FN(glTextureStorage1D, textureStorage1D(texture, levels, internalformat, width))
}
void APIENTRY glTextureStorage2D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height) {
    DSA_TEX_FN(glTextureStorage2D, textureStorage2D(texture, levels, internalformat, width, height))
}
void APIENTRY glTextureStorage3D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth) {
    DSA_TEX_FN(glTextureStorage3D, textureStorage3D(texture, levels, internalformat, width, height, depth))
}
void APIENTRY glTextureStorage2DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixed) {
    DSA_TEX_FN(glTextureStorage2DMultisample, textureStorage2DMultisample(texture, samples, internalformat, width, height, fixed))
}
void APIENTRY glTextureStorage3DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixed) {
    DSA_TEX_FN(glTextureStorage3DMultisample, textureStorage3DMultisample(texture, samples, internalformat, width, height, depth, fixed))
}
void APIENTRY glTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_FN(glTextureSubImage1D, textureSubImage1D(texture, level, xoffset, width, format, type, pixels))
}
void APIENTRY glTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_FN(glTextureSubImage2D, textureSubImage2D(texture, level, xoffset, yoffset, width, height, format, type, pixels))
}
void APIENTRY glTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_FN(glTextureSubImage3D, textureSubImage3D(texture, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels))
}
void APIENTRY glTextureBuffer(GLuint texture, GLenum internalformat, GLuint buffer) {
    DSA_TEX_FN(glTextureBuffer, textureBuffer(texture, internalformat, buffer))
}
void APIENTRY glTextureBufferRange(GLuint texture, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    DSA_TEX_FN(glTextureBufferRange, textureBufferRange(texture, internalformat, buffer, offset, size))
}
void APIENTRY glCompressedTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLsizei imageSize, const void* data) {
    DSA_TEX_FN(glCompressedTextureSubImage1D, compressedTextureSubImage1D(texture, level, xoffset, width, format, imageSize, data))
}
void APIENTRY glCompressedTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void* data) {
    DSA_TEX_FN(glCompressedTextureSubImage2D, compressedTextureSubImage2D(texture, level, xoffset, yoffset, width, height, format, imageSize, data))
}
void APIENTRY glCompressedTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void* data) {
    DSA_TEX_FN(glCompressedTextureSubImage3D, compressedTextureSubImage3D(texture, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, data))
}
void APIENTRY glCopyTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width) {
    DSA_TEX_FN(glCopyTextureSubImage1D, copyTextureSubImage1D(texture, level, xoffset, x, y, width))
}
void APIENTRY glCopyTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_TEX_FN(glCopyTextureSubImage2D, copyTextureSubImage2D(texture, level, xoffset, yoffset, x, y, width, height))
}
void APIENTRY glCopyTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_TEX_FN(glCopyTextureSubImage3D, copyTextureSubImage3D(texture, level, xoffset, yoffset, zoffset, x, y, width, height))
}
void APIENTRY glTextureParameterf(GLuint texture, GLenum pname, GLfloat param) {
    DSA_TEX_FN(glTextureParameterf, textureParameterf(texture, pname, param))
}
void APIENTRY glTextureParameterfv(GLuint texture, GLenum pname, const GLfloat* param) {
    DSA_TEX_FN(glTextureParameterfv, textureParameterfv(texture, pname, param))
}
void APIENTRY glTextureParameteri(GLuint texture, GLenum pname, GLint param) {
    DSA_TEX_FN(glTextureParameteri, textureParameteri(texture, pname, param))
}
void APIENTRY glTextureParameteriv(GLuint texture, GLenum pname, const GLint* param) {
    DSA_TEX_FN(glTextureParameteriv, textureParameteriv(texture, pname, param))
}
void APIENTRY glTextureParameterIiv(GLuint texture, GLenum pname, const GLint* params) {
    DSA_TEX_FN(glTextureParameterIiv, textureParameterIiv(texture, pname, params))
}
void APIENTRY glTextureParameterIuiv(GLuint texture, GLenum pname, const GLuint* params) {
    DSA_TEX_FN(glTextureParameterIuiv, textureParameterIuiv(texture, pname, params))
}
void APIENTRY glGetTextureParameterfv(GLuint texture, GLenum pname, GLfloat* params) {
    DSA_TEX_FN(glGetTextureParameterfv, getTextureParameterfv(texture, pname, params))
}
void APIENTRY glGetTextureParameteriv(GLuint texture, GLenum pname, GLint* params) {
    DSA_TEX_FN(glGetTextureParameteriv, getTextureParameteriv(texture, pname, params))
}
void APIENTRY glGetTextureParameterIiv(GLuint texture, GLenum pname, GLint* params) {
    DSA_TEX_FN(glGetTextureParameterIiv, getTextureParameterIiv(texture, pname, params))
}
void APIENTRY glGetTextureParameterIuiv(GLuint texture, GLenum pname, GLuint* params) {
    DSA_TEX_FN(glGetTextureParameterIuiv, getTextureParameterIuiv(texture, pname, params))
}
void APIENTRY glGetTextureLevelParameterfv(GLuint texture, GLint level, GLenum pname, GLfloat* params) {
    DSA_TEX_FN(glGetTextureLevelParameterfv, getTextureLevelParameterfv(texture, level, pname, params))
}
void APIENTRY glGetTextureLevelParameteriv(GLuint texture, GLint level, GLenum pname, GLint* params) {
    DSA_TEX_FN(glGetTextureLevelParameteriv, getTextureLevelParameteriv(texture, level, pname, params))
}
void APIENTRY glGetTextureImage(GLuint texture, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels) {
    DSA_TEX_FN(glGetTextureImage, getTextureImage(texture, level, format, type, bufSize, pixels))
}
void APIENTRY glGetTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                    GLsizei width, GLsizei height, GLsizei depth,
                                    GLenum format, GLenum type, GLsizei bufSize, void* pixels) {
    DSA_TEX_FN(glGetTextureSubImage, getTextureSubImage(texture, level, xoffset, yoffset, zoffset, width, height, depth, format, type, bufSize, pixels))
}
void APIENTRY glGetCompressedTextureImage(GLuint texture, GLint level, GLsizei bufSize, void* pixels) {
    DSA_TEX_FN(glGetCompressedTextureImage, getCompressedTextureImage(texture, level, bufSize, pixels))
}
void APIENTRY glGetCompressedTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                              GLsizei width, GLsizei height, GLsizei depth,
                                              GLsizei bufSize, void* pixels) {
    DSA_TEX_FN(glGetCompressedTextureSubImage, getCompressedTextureSubImage(texture, level, xoffset, yoffset, zoffset, width, height, depth, bufSize, pixels))
}
void APIENTRY glGenerateTextureMipmap(GLuint texture) {
    DSA_TEX_FN(glGenerateTextureMipmap, generateTextureMipmap(texture))
}
void APIENTRY glBindTextureUnit(GLuint unit, GLuint texture) {
    DSA_TEX_FN(glBindTextureUnit, bindTextureUnit(unit, texture))
}

#undef DSA_TEX_FN

// ---------------------------------------------------------------------------
// Pass C — DSA framebuffer / renderbuffer (20 functions)
// ---------------------------------------------------------------------------

#define DSA_FB_FN(glName, ctxCall) \
    auto* ctx = requireCurrentContext(#glName); if (!ctx) return; \
    if (!ctx->ctxCall) return; \
    markFramebufferFunction(FunctionId::glName, "DSA " #glName ".");

void APIENTRY glNamedFramebufferRenderbuffer(GLuint framebuffer, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    DSA_FB_FN(glNamedFramebufferRenderbuffer, namedFramebufferRenderbuffer(framebuffer, attachment, renderbuffertarget, renderbuffer))
}
void APIENTRY glNamedFramebufferTexture(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level) {
    DSA_FB_FN(glNamedFramebufferTexture, namedFramebufferTexture(framebuffer, attachment, texture, level))
}
void APIENTRY glNamedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer) {
    DSA_FB_FN(glNamedFramebufferTextureLayer, namedFramebufferTextureLayer(framebuffer, attachment, texture, level, layer))
}
void APIENTRY glNamedFramebufferDrawBuffer(GLuint framebuffer, GLenum buf) {
    DSA_FB_FN(glNamedFramebufferDrawBuffer, namedFramebufferDrawBuffer(framebuffer, buf))
}
void APIENTRY glNamedFramebufferDrawBuffers(GLuint framebuffer, GLsizei n, const GLenum* bufs) {
    DSA_FB_FN(glNamedFramebufferDrawBuffers, namedFramebufferDrawBuffers(framebuffer, n, bufs))
}
void APIENTRY glNamedFramebufferReadBuffer(GLuint framebuffer, GLenum src) {
    DSA_FB_FN(glNamedFramebufferReadBuffer, namedFramebufferReadBuffer(framebuffer, src))
}
void APIENTRY glNamedFramebufferParameteri(GLuint framebuffer, GLenum pname, GLint param) {
    DSA_FB_FN(glNamedFramebufferParameteri, namedFramebufferParameteri(framebuffer, pname, param))
}
void APIENTRY glGetNamedFramebufferParameteriv(GLuint framebuffer, GLenum pname, GLint* param) {
    DSA_FB_FN(glGetNamedFramebufferParameteriv, getNamedFramebufferParameteriv(framebuffer, pname, param))
}
void APIENTRY glGetNamedFramebufferAttachmentParameteriv(GLuint framebuffer, GLenum attachment, GLenum pname, GLint* params) {
    DSA_FB_FN(glGetNamedFramebufferAttachmentParameteriv, getNamedFramebufferAttachmentParameteriv(framebuffer, attachment, pname, params))
}
GLenum APIENTRY glCheckNamedFramebufferStatus(GLuint framebuffer, GLenum target) {
    auto* ctx = requireCurrentContext("glCheckNamedFramebufferStatus");
    if (!ctx) return 0;
    GLenum result = ctx->checkNamedFramebufferStatus(framebuffer, target);
    markFramebufferFunction(FunctionId::glCheckNamedFramebufferStatus, "DSA glCheckNamedFramebufferStatus.");
    return result;
}
void APIENTRY glBlitNamedFramebuffer(GLuint readFramebuffer, GLuint drawFramebuffer,
                                     GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                                     GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                                     GLbitfield mask, GLenum filter) {
    DSA_FB_FN(glBlitNamedFramebuffer, blitNamedFramebuffer(readFramebuffer, drawFramebuffer, srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter))
}
void APIENTRY glClearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value) {
    DSA_FB_FN(glClearNamedFramebufferfv, clearNamedFramebufferfv(framebuffer, buffer, drawbuffer, value))
}
void APIENTRY glClearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value) {
    DSA_FB_FN(glClearNamedFramebufferiv, clearNamedFramebufferiv(framebuffer, buffer, drawbuffer, value))
}
void APIENTRY glClearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value) {
    DSA_FB_FN(glClearNamedFramebufferuiv, clearNamedFramebufferuiv(framebuffer, buffer, drawbuffer, value))
}
void APIENTRY glClearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil) {
    DSA_FB_FN(glClearNamedFramebufferfi, clearNamedFramebufferfi(framebuffer, buffer, drawbuffer, depth, stencil))
}
void APIENTRY glInvalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments) {
    DSA_FB_FN(glInvalidateNamedFramebufferData, invalidateNamedFramebufferData(framebuffer, numAttachments, attachments))
}
void APIENTRY glInvalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                                   GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_FB_FN(glInvalidateNamedFramebufferSubData, invalidateNamedFramebufferSubData(framebuffer, numAttachments, attachments, x, y, width, height))
}
void APIENTRY glNamedRenderbufferStorage(GLuint renderbuffer, GLenum internalformat, GLsizei width, GLsizei height) {
    DSA_FB_FN(glNamedRenderbufferStorage, namedRenderbufferStorage(renderbuffer, internalformat, width, height))
}
void APIENTRY glNamedRenderbufferStorageMultisample(GLuint renderbuffer, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height) {
    DSA_FB_FN(glNamedRenderbufferStorageMultisample, namedRenderbufferStorageMultisample(renderbuffer, samples, internalformat, width, height))
}
void APIENTRY glGetNamedRenderbufferParameteriv(GLuint renderbuffer, GLenum pname, GLint* params) {
    DSA_FB_FN(glGetNamedRenderbufferParameteriv, getNamedRenderbufferParameteriv(renderbuffer, pname, params))
}

#undef DSA_FB_FN

// ---------------------------------------------------------------------------
// Pass C — DSA vertex array (13 functions)
// ---------------------------------------------------------------------------

#define DSA_VAO_FN(glName, ctxCall) \
    auto* ctx = requireCurrentContext(#glName); if (!ctx) return; \
    if (!ctx->ctxCall) return; \
    markVertexInputFunction(FunctionId::glName, "DSA " #glName ".");

void APIENTRY glVertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    DSA_VAO_FN(glVertexArrayAttribFormat, vertexArrayAttribFormat(vaobj, attribindex, size, type, normalized, relativeoffset))
}
void APIENTRY glVertexArrayAttribIFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_FN(glVertexArrayAttribIFormat, vertexArrayAttribIFormat(vaobj, attribindex, size, type, relativeoffset))
}
void APIENTRY glVertexArrayAttribLFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_FN(glVertexArrayAttribLFormat, vertexArrayAttribLFormat(vaobj, attribindex, size, type, relativeoffset))
}
void APIENTRY glVertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex) {
    DSA_VAO_FN(glVertexArrayAttribBinding, vertexArrayAttribBinding(vaobj, attribindex, bindingindex))
}
void APIENTRY glVertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor) {
    DSA_VAO_FN(glVertexArrayBindingDivisor, vertexArrayBindingDivisor(vaobj, bindingindex, divisor))
}
void APIENTRY glVertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    DSA_VAO_FN(glVertexArrayVertexBuffer, vertexArrayVertexBuffer(vaobj, bindingindex, buffer, offset, stride))
}
void APIENTRY glVertexArrayVertexBuffers(GLuint vaobj, GLuint first, GLsizei count, const GLuint* buffers, const GLintptr* offsets, const GLsizei* strides) {
    DSA_VAO_FN(glVertexArrayVertexBuffers, vertexArrayVertexBuffers(vaobj, first, count, buffers, offsets, strides))
}
void APIENTRY glVertexArrayElementBuffer(GLuint vaobj, GLuint buffer) {
    DSA_VAO_FN(glVertexArrayElementBuffer, vertexArrayElementBuffer(vaobj, buffer))
}
void APIENTRY glEnableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_FN(glEnableVertexArrayAttrib, enableVertexArrayAttrib(vaobj, index))
}
void APIENTRY glDisableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_FN(glDisableVertexArrayAttrib, disableVertexArrayAttrib(vaobj, index))
}
void APIENTRY glGetVertexArrayiv(GLuint vaobj, GLenum pname, GLint* param) {
    DSA_VAO_FN(glGetVertexArrayiv, getVertexArrayiv(vaobj, pname, param))
}
void APIENTRY glGetVertexArrayIndexediv(GLuint vaobj, GLuint index, GLenum pname, GLint* param) {
    DSA_VAO_FN(glGetVertexArrayIndexediv, getVertexArrayIndexediv(vaobj, index, pname, param))
}
void APIENTRY glGetVertexArrayIndexed64iv(GLuint vaobj, GLuint index, GLenum pname, GLint64* param) {
    DSA_VAO_FN(glGetVertexArrayIndexed64iv, getVertexArrayIndexed64iv(vaobj, index, pname, param))
}

#undef DSA_VAO_FN

// ---------------------------------------------------------------------------
// Pass C — DSA transform feedback (5 functions)
// ---------------------------------------------------------------------------

#define DSA_TF_FN(glName, ctxCall) \
    auto* ctx = requireCurrentContext(#glName); if (!ctx) return; \
    if (!ctx->ctxCall) return; \
    markStateFunction(FunctionId::glName, "DSA " #glName ".");

void APIENTRY glTransformFeedbackBufferBase(GLuint xfb, GLuint index, GLuint buffer) {
    DSA_TF_FN(glTransformFeedbackBufferBase, transformFeedbackBufferBase(xfb, index, buffer))
}
void APIENTRY glTransformFeedbackBufferRange(GLuint xfb, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    DSA_TF_FN(glTransformFeedbackBufferRange, transformFeedbackBufferRange(xfb, index, buffer, offset, size))
}
void APIENTRY glGetTransformFeedbackiv(GLuint xfb, GLenum pname, GLint* param) {
    DSA_TF_FN(glGetTransformFeedbackiv, getTransformFeedbackiv(xfb, pname, param))
}
void APIENTRY glGetTransformFeedbacki_v(GLuint xfb, GLenum pname, GLuint index, GLint* param) {
    DSA_TF_FN(glGetTransformFeedbacki_v, getTransformFeedbacki_v(xfb, pname, index, param))
}
void APIENTRY glGetTransformFeedbacki64_v(GLuint xfb, GLenum pname, GLuint index, GLint64* param) {
    DSA_TF_FN(glGetTransformFeedbacki64_v, getTransformFeedbacki64_v(xfb, pname, index, param))
}

#undef DSA_TF_FN

// ---------------------------------------------------------------------------
// Pass D — ClipControl, robustness, barriers, query buffer objects (15 functions)
// ---------------------------------------------------------------------------

void APIENTRY glClipControl(GLenum origin, GLenum depth) {
    auto* ctx = requireCurrentContext("glClipControl");
    if (!ctx) return;
    if (!ctx->clipControl(origin, depth)) return;
    markStateFunction(FunctionId::glClipControl, "ClipControl origin/depth mode set.");
}
GLenum APIENTRY glGetGraphicsResetStatus(void) {
    auto* ctx = requireCurrentContext("glGetGraphicsResetStatus");
    if (!ctx) return GL_NO_ERROR;
    GLenum result = ctx->getGraphicsResetStatus();
    markStateFunction(FunctionId::glGetGraphicsResetStatus, "GetGraphicsResetStatus (always GL_NO_ERROR on Metal).");
    return result;
}
void APIENTRY glReadnPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                            GLenum format, GLenum type, GLsizei bufSize, void* data) {
    auto* ctx = requireCurrentContext("glReadnPixels");
    if (!ctx) return;
    if (!ctx->readnPixels(x, y, width, height, format, type, bufSize, data)) return;
    markFramebufferFunction(FunctionId::glReadnPixels, "ReadnPixels robustness delegate.");
}
void APIENTRY glGetnUniformfv(GLuint program, GLint location, GLsizei bufSize, GLfloat* params) {
    auto* ctx = requireCurrentContext("glGetnUniformfv");
    if (!ctx) return;
    if (!ctx->getnUniformfv(program, location, bufSize, params)) return;
    markProgramFunction(FunctionId::glGetnUniformfv, "GetnUniformfv robustness delegate.");
}
void APIENTRY glGetnUniformiv(GLuint program, GLint location, GLsizei bufSize, GLint* params) {
    auto* ctx = requireCurrentContext("glGetnUniformiv");
    if (!ctx) return;
    if (!ctx->getnUniformiv(program, location, bufSize, params)) return;
    markProgramFunction(FunctionId::glGetnUniformiv, "GetnUniformiv robustness delegate.");
}
void APIENTRY glGetnUniformuiv(GLuint program, GLint location, GLsizei bufSize, GLuint* params) {
    auto* ctx = requireCurrentContext("glGetnUniformuiv");
    if (!ctx) return;
    if (!ctx->getnUniformuiv(program, location, bufSize, params)) return;
    markProgramFunction(FunctionId::glGetnUniformuiv, "GetnUniformuiv robustness delegate.");
}
void APIENTRY glGetnUniformdv(GLuint program, GLint location, GLsizei bufSize, GLdouble* params) {
    auto* ctx = requireCurrentContext("glGetnUniformdv");
    if (!ctx) return;
    if (!ctx->getnUniformdv(program, location, bufSize, params)) return;
    markProgramFunction(FunctionId::glGetnUniformdv, "GetnUniformdv robustness delegate.");
}
void APIENTRY glGetnTexImage(GLenum target, GLint level, GLenum format, GLenum type,
                             GLsizei bufSize, void* pixels) {
    auto* ctx = requireCurrentContext("glGetnTexImage");
    if (!ctx) return;
    if (!ctx->getnTexImage(target, level, format, type, bufSize, pixels)) return;
    markTextureFunction(FunctionId::glGetnTexImage, "GetnTexImage robustness stub.");
}
void APIENTRY glGetnCompressedTexImage(GLenum target, GLint lod, GLsizei bufSize, void* pixels) {
    auto* ctx = requireCurrentContext("glGetnCompressedTexImage");
    if (!ctx) return;
    if (!ctx->getnCompressedTexImage(target, lod, bufSize, pixels)) return;
    markTextureFunction(FunctionId::glGetnCompressedTexImage, "GetnCompressedTexImage robustness stub.");
}
void APIENTRY glMemoryBarrierByRegion(GLbitfield barriers) {
    auto* ctx = requireCurrentContext("glMemoryBarrierByRegion");
    if (!ctx) return;
    if (!ctx->memoryBarrierByRegion(barriers)) return;
    markStateFunction(FunctionId::glMemoryBarrierByRegion, "MemoryBarrierByRegion no-op (Metal handles ordering).");
}
void APIENTRY glTextureBarrier(void) {
    auto* ctx = requireCurrentContext("glTextureBarrier");
    if (!ctx) return;
    if (!ctx->textureBarrier()) return;
    markStateFunction(FunctionId::glTextureBarrier, "TextureBarrier no-op hint.");
}
void APIENTRY glGetQueryBufferObjectiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* ctx = requireCurrentContext("glGetQueryBufferObjectiv");
    if (!ctx) return;
    if (!ctx->getQueryBufferObjectiv(id, buffer, pname, offset)) return;
    markStateFunction(FunctionId::glGetQueryBufferObjectiv, "GetQueryBufferObjectiv stub.");
}
void APIENTRY glGetQueryBufferObjectuiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* ctx = requireCurrentContext("glGetQueryBufferObjectuiv");
    if (!ctx) return;
    if (!ctx->getQueryBufferObjectuiv(id, buffer, pname, offset)) return;
    markStateFunction(FunctionId::glGetQueryBufferObjectuiv, "GetQueryBufferObjectuiv stub.");
}
void APIENTRY glGetQueryBufferObjecti64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* ctx = requireCurrentContext("glGetQueryBufferObjecti64v");
    if (!ctx) return;
    if (!ctx->getQueryBufferObjecti64v(id, buffer, pname, offset)) return;
    markStateFunction(FunctionId::glGetQueryBufferObjecti64v, "GetQueryBufferObjecti64v stub.");
}
void APIENTRY glGetQueryBufferObjectui64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* ctx = requireCurrentContext("glGetQueryBufferObjectui64v");
    if (!ctx) return;
    if (!ctx->getQueryBufferObjectui64v(id, buffer, pname, offset)) return;
    markStateFunction(FunctionId::glGetQueryBufferObjectui64v, "GetQueryBufferObjectui64v stub.");
}

// ---------------------------------------------------------------------------
// Pass E — GL 4.6 (4 functions)
// ---------------------------------------------------------------------------

void APIENTRY glMultiDrawArraysIndirectCount(GLenum mode, const void* indirect,
                                              GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    auto* ctx = requireCurrentContext("glMultiDrawArraysIndirectCount");
    if (!ctx) return;
    if (!ctx->multiDrawArraysIndirectCount(mode, indirect, drawcount, maxdrawcount, stride)) return;
    markDrawFunction(FunctionId::glMultiDrawArraysIndirectCount, "MultiDrawArraysIndirectCount (GPU-sourced count).");
}
void APIENTRY glMultiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect,
                                                GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    auto* ctx = requireCurrentContext("glMultiDrawElementsIndirectCount");
    if (!ctx) return;
    if (!ctx->multiDrawElementsIndirectCount(mode, type, indirect, drawcount, maxdrawcount, stride)) return;
    markDrawFunction(FunctionId::glMultiDrawElementsIndirectCount, "MultiDrawElementsIndirectCount (GPU-sourced count).");
}
void APIENTRY glSpecializeShader(GLuint shader, const GLchar* pEntryPoint,
                                  GLuint numSpecializationConstants,
                                  const GLuint* pConstantIndex, const GLuint* pConstantValue) {
    auto* ctx = requireCurrentContext("glSpecializeShader");
    if (!ctx) return;
    if (!ctx->specializeShader(shader, pEntryPoint, numSpecializationConstants, pConstantIndex, pConstantValue)) return;
    markShaderFunction(FunctionId::glSpecializeShader, "SpecializeShader SPIR-V stub.");
}
void APIENTRY glPolygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp) {
    auto* ctx = requireCurrentContext("glPolygonOffsetClamp");
    if (!ctx) return;
    if (!ctx->polygonOffsetClamp(factor, units, clamp)) return;
    markStateFunction(FunctionId::glPolygonOffsetClamp, "PolygonOffsetClamp extends PolygonOffset with clamp.");
}

}  // namespace impl

}  // namespace appgl

extern "C" AppGLContext* appglCreateContextForLayer(void* layer) {
    auto* context = new appgl::GLContext(layer);
    appgl::Runtime::shared().noteRenderer(context->rendererString());
    context->setClaimedVersionString(appgl::Runtime::shared().claimedVersionString());
    return reinterpret_cast<AppGLContext*>(context);
}

extern "C" AppGLContext* appglCreateOffscreenContext(int width, int height) {
    auto* context = new appgl::GLContext(width, height);
    appgl::Runtime::shared().noteRenderer(context->rendererString());
    context->setClaimedVersionString(appgl::Runtime::shared().claimedVersionString());
    return reinterpret_cast<AppGLContext*>(context);
}

extern "C" void appglDestroyContext(AppGLContext* context) {
    delete reinterpret_cast<appgl::GLContext*>(context);
}

extern "C" void appglMakeCurrent(AppGLContext* context) {
    appgl::Runtime::shared().makeCurrent(reinterpret_cast<appgl::GLContext*>(context));
}

extern "C" void appglSwapBuffers(AppGLContext* context) {
    if (context == nullptr) {
        return;
    }
    reinterpret_cast<appgl::GLContext*>(context)->swapBuffers();
}

extern "C" std::size_t appglCoverageSnapshotJSON(char* out, std::size_t cap) {
    return appgl::Runtime::shared().writeCoverageSnapshotJSON(out, cap);
}

extern "C" std::size_t appglDiagnosticsJSON(char* out, std::size_t cap) {
    return appgl::Runtime::shared().writeDiagnosticsJSON(out, cap);
}

extern "C" std::size_t appglLiveDiagnosticsJSON(char* out, std::size_t cap) {
    return appgl::Runtime::shared().writeLiveDiagnosticsJSON(out, cap);
}
