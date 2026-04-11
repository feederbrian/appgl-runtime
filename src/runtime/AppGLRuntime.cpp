#include "AppGLRuntime.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>

#include "../../include/AppGL/AppGL.h"
#include "../loader/DispatchInstall.h"

namespace appgl {

namespace {
thread_local GLContext* gCurrentContext = nullptr;
constexpr const char* kBootstrapTestId = "bootstrap.clear-loop";
constexpr const char* kPhaseAStateTestId = "phase-a.state";
constexpr const char* kPhaseADebugTestId = "phase-a.debug";
constexpr const char* kPhaseABufferTestId = "phase-a.buffers";
constexpr GLuint kPhaseAMaxDrawBuffers = 8;
constexpr GLuint kPhaseAMaxIndexedBufferBindings = 32;

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

void recordValidationError(GLContext* context, std::string_view functionName, GLenum error, std::string_view message) {
    if (context == nullptr) {
        return;
    }
    context->pushError(error);
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
            return true;
        default:
            return false;
    }
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
        | GL_MAP_UNSYNCHRONIZED_BIT;
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
        gCurrentContext->pushError(GL_INVALID_OPERATION);
        gCurrentContext->emitDebugMessage(
            GL_DEBUG_SOURCE_APPLICATION,
            GL_DEBUG_TYPE_ERROR,
            1,
            GL_DEBUG_SEVERITY_HIGH,
            std::string(functionName) + " is not implemented in AppGL yet."
        );
    }
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

std::string Runtime::claimedVersionString() const {
    return coverageStore_.highestFullyImplementedVersion();
}

void Runtime::refreshCurrentContextClaimedVersion() {
    if (gCurrentContext != nullptr) {
        gCurrentContext->setClaimedVersionString(claimedVersionString());
    }
}

void Runtime::noteRenderer(std::string renderer) {
    rendererString_ = std::move(renderer);
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
    if (index >= kPhaseAMaxIndexedBufferBindings) {
        recordValidationError(context, "glBindBufferBase", GL_INVALID_VALUE, "binding index exceeds Phase A limit");
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
    if (index >= kPhaseAMaxIndexedBufferBindings) {
        recordValidationError(context, "glBindBufferRange", GL_INVALID_VALUE, "binding index exceeds Phase A limit");
        return;
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
    if (!isValidMapBufferRangeAccess(access)) {
        recordValidationError(context, "glMapBufferRange", GL_INVALID_VALUE, "access flags are not a supported Phase A map combination");
        return nullptr;
    }
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

void APIENTRY glEnable(GLenum cap) {
    auto* context = requireCurrentContext("glEnable");
    if (context == nullptr) {
        return;
    }
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glEnable", GL_INVALID_ENUM, "cap is not supported by the Phase A state mirror");
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
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glDisable", GL_INVALID_ENUM, "cap is not supported by the Phase A state mirror");
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
    if (!isValidEnableCap(cap)) {
        recordValidationError(context, "glIsEnabled", GL_INVALID_ENUM, "cap is not supported by the Phase A state mirror");
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
