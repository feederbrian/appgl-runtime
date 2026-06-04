#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include <AppGL/AppGL.h>

#include "../src/context/MetalMemoryPressure.h"
#include "../src/context/MetalResourceResidency.h"

extern "C" std::uint64_t appglR5EvictDerivedCachesForTesting(
    std::uint64_t budget);
extern "C" std::uint64_t appglR5ForceMemoryPressureForTesting(
    std::uint64_t level);
extern "C" std::uint64_t appglR5ForceMemoryClassForTesting(
    std::uint64_t memoryClass);

namespace {

struct ProbeState {
    int failures = 0;
};

volatile std::uint64_t gTouchSelector = 0;
volatile std::uint64_t gTouchSink = 0;

void expect(ProbeState& state, bool condition, const std::string& message);

struct ContextGuard {
    explicit ContextGuard(AppGLContext* value) : context(value) {}
    ~ContextGuard() {
        if (context != nullptr) {
            appglMakeCurrent(nullptr);
            appglDestroyContext(context);
        }
    }
    AppGLContext* context = nullptr;
};

template <typename T>
T loadGL(ProbeState& state, const char* name) {
    AppGLProc proc = appglGetProcAddress(name);
    if (proc == nullptr) {
        ++state.failures;
        std::cerr << "FAIL: missing GL proc " << name << "\n";
        return nullptr;
    }
    return reinterpret_cast<T>(proc);
}

std::string diagnosticsJSON() {
    const std::size_t required = appglDiagnosticsJSON(nullptr, 0);
    std::string payload(required + 1, '\0');
    const std::size_t written =
        appglDiagnosticsJSON(payload.data(), payload.size());
    payload.resize(std::min(required, written));
    return payload;
}

std::uint64_t jsonCounter(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const std::size_t pos = json.find(needle);
    if (pos == std::string::npos) {
        return 0;
    }
    std::size_t cursor = pos + needle.size();
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }
    std::uint64_t value = 0;
    while (cursor < json.size() &&
           std::isdigit(static_cast<unsigned char>(json[cursor]))) {
        value = value * 10u + static_cast<unsigned>(json[cursor] - '0');
        ++cursor;
    }
    return value;
}

bool jsonContainsToken(const std::string& json, const char* token) {
    return json.find(token) != std::string::npos;
}

void expectNoGLError(ProbeState& state,
                     PFNGLGETERRORPROC getError,
                     const std::string& message) {
    if (getError == nullptr) {
        return;
    }
    const GLenum error = getError();
    expect(state, error == GL_NO_ERROR,
           message + " GL error=" + std::to_string(error));
}

void expectGLError(ProbeState& state,
                   PFNGLGETERRORPROC getError,
                   GLenum expected,
                   const std::string& message) {
    if (getError == nullptr) {
        return;
    }
    const GLenum error = getError();
    expect(state, error == expected,
           message + " GL error=" + std::to_string(error) +
               " expected=" + std::to_string(expected));
}

struct R5GL {
    PFNGLGETERRORPROC GetError = nullptr;
    PFNGLGENTEXTURESPROC GenTextures = nullptr;
    PFNGLDELETETEXTURESPROC DeleteTextures = nullptr;
    PFNGLBINDTEXTUREPROC BindTexture = nullptr;
    PFNGLTEXSTORAGE2DPROC TexStorage2D = nullptr;
    PFNGLTEXSTORAGE3DPROC TexStorage3D = nullptr;
    PFNGLTEXTUREVIEWPROC TextureView = nullptr;
    PFNGLTEXPARAMETERIPROC TexParameteri = nullptr;
    PFNGLGENFRAMEBUFFERSPROC GenFramebuffers = nullptr;
    PFNGLDELETEFRAMEBUFFERSPROC DeleteFramebuffers = nullptr;
    PFNGLBINDFRAMEBUFFERPROC BindFramebuffer = nullptr;
    PFNGLFRAMEBUFFERTEXTURE2DPROC FramebufferTexture2D = nullptr;
    PFNGLCHECKFRAMEBUFFERSTATUSPROC CheckFramebufferStatus = nullptr;
    PFNGLDRAWBUFFERPROC DrawBuffer = nullptr;
    PFNGLREADBUFFERPROC ReadBuffer = nullptr;
    PFNGLVIEWPORTPROC Viewport = nullptr;
    PFNGLCLEARCOLORPROC ClearColor = nullptr;
    PFNGLCLEARPROC Clear = nullptr;
    PFNGLREADPIXELSPROC ReadPixels = nullptr;
    PFNGLFINISHPROC Finish = nullptr;
    PFNGLCREATESHADERPROC CreateShader = nullptr;
    PFNGLSHADERSOURCEPROC ShaderSource = nullptr;
    PFNGLCOMPILESHADERPROC CompileShader = nullptr;
    PFNGLGETSHADERIVPROC GetShaderiv = nullptr;
    PFNGLGETSHADERINFOLOGPROC GetShaderInfoLog = nullptr;
    PFNGLCREATEPROGRAMPROC CreateProgram = nullptr;
    PFNGLATTACHSHADERPROC AttachShader = nullptr;
    PFNGLLINKPROGRAMPROC LinkProgram = nullptr;
    PFNGLGETPROGRAMIVPROC GetProgramiv = nullptr;
    PFNGLGETPROGRAMINFOLOGPROC GetProgramInfoLog = nullptr;
    PFNGLUSEPROGRAMPROC UseProgram = nullptr;
    PFNGLDELETESHADERPROC DeleteShader = nullptr;
    PFNGLDELETEPROGRAMPROC DeleteProgram = nullptr;
    PFNGLGENVERTEXARRAYSPROC GenVertexArrays = nullptr;
    PFNGLDELETEVERTEXARRAYSPROC DeleteVertexArrays = nullptr;
    PFNGLBINDVERTEXARRAYPROC BindVertexArray = nullptr;
    PFNGLGENBUFFERSPROC GenBuffers = nullptr;
    PFNGLDELETEBUFFERSPROC DeleteBuffers = nullptr;
    PFNGLBINDBUFFERPROC BindBuffer = nullptr;
    PFNGLBUFFERDATAPROC BufferData = nullptr;
    PFNGLBUFFERSUBDATAPROC BufferSubData = nullptr;
    PFNGLENABLEVERTEXATTRIBARRAYPROC EnableVertexAttribArray = nullptr;
    PFNGLVERTEXATTRIBPOINTERPROC VertexAttribPointer = nullptr;
    PFNGLDRAWARRAYSPROC DrawArrays = nullptr;
    PFNGLDRAWELEMENTSPROC DrawElements = nullptr;
};

R5GL loadR5GL(ProbeState& state) {
    R5GL gl;
    gl.GetError = loadGL<PFNGLGETERRORPROC>(state, "glGetError");
    gl.GenTextures = loadGL<PFNGLGENTEXTURESPROC>(state, "glGenTextures");
    gl.DeleteTextures =
        loadGL<PFNGLDELETETEXTURESPROC>(state, "glDeleteTextures");
    gl.BindTexture = loadGL<PFNGLBINDTEXTUREPROC>(state, "glBindTexture");
    gl.TexStorage2D =
        loadGL<PFNGLTEXSTORAGE2DPROC>(state, "glTexStorage2D");
    gl.TexStorage3D =
        loadGL<PFNGLTEXSTORAGE3DPROC>(state, "glTexStorage3D");
    gl.TextureView = loadGL<PFNGLTEXTUREVIEWPROC>(state, "glTextureView");
    gl.TexParameteri =
        loadGL<PFNGLTEXPARAMETERIPROC>(state, "glTexParameteri");
    gl.GenFramebuffers =
        loadGL<PFNGLGENFRAMEBUFFERSPROC>(state, "glGenFramebuffers");
    gl.DeleteFramebuffers =
        loadGL<PFNGLDELETEFRAMEBUFFERSPROC>(state, "glDeleteFramebuffers");
    gl.BindFramebuffer =
        loadGL<PFNGLBINDFRAMEBUFFERPROC>(state, "glBindFramebuffer");
    gl.FramebufferTexture2D =
        loadGL<PFNGLFRAMEBUFFERTEXTURE2DPROC>(state,
                                              "glFramebufferTexture2D");
    gl.CheckFramebufferStatus =
        loadGL<PFNGLCHECKFRAMEBUFFERSTATUSPROC>(state,
                                                "glCheckFramebufferStatus");
    gl.DrawBuffer = loadGL<PFNGLDRAWBUFFERPROC>(state, "glDrawBuffer");
    gl.ReadBuffer = loadGL<PFNGLREADBUFFERPROC>(state, "glReadBuffer");
    gl.Viewport = loadGL<PFNGLVIEWPORTPROC>(state, "glViewport");
    gl.ClearColor = loadGL<PFNGLCLEARCOLORPROC>(state, "glClearColor");
    gl.Clear = loadGL<PFNGLCLEARPROC>(state, "glClear");
    gl.ReadPixels = loadGL<PFNGLREADPIXELSPROC>(state, "glReadPixels");
    gl.Finish = loadGL<PFNGLFINISHPROC>(state, "glFinish");
    gl.CreateShader = loadGL<PFNGLCREATESHADERPROC>(state, "glCreateShader");
    gl.ShaderSource = loadGL<PFNGLSHADERSOURCEPROC>(state, "glShaderSource");
    gl.CompileShader =
        loadGL<PFNGLCOMPILESHADERPROC>(state, "glCompileShader");
    gl.GetShaderiv = loadGL<PFNGLGETSHADERIVPROC>(state, "glGetShaderiv");
    gl.GetShaderInfoLog =
        loadGL<PFNGLGETSHADERINFOLOGPROC>(state, "glGetShaderInfoLog");
    gl.CreateProgram =
        loadGL<PFNGLCREATEPROGRAMPROC>(state, "glCreateProgram");
    gl.AttachShader = loadGL<PFNGLATTACHSHADERPROC>(state, "glAttachShader");
    gl.LinkProgram = loadGL<PFNGLLINKPROGRAMPROC>(state, "glLinkProgram");
    gl.GetProgramiv = loadGL<PFNGLGETPROGRAMIVPROC>(state, "glGetProgramiv");
    gl.GetProgramInfoLog =
        loadGL<PFNGLGETPROGRAMINFOLOGPROC>(state, "glGetProgramInfoLog");
    gl.UseProgram = loadGL<PFNGLUSEPROGRAMPROC>(state, "glUseProgram");
    gl.DeleteShader = loadGL<PFNGLDELETESHADERPROC>(state, "glDeleteShader");
    gl.DeleteProgram =
        loadGL<PFNGLDELETEPROGRAMPROC>(state, "glDeleteProgram");
    gl.GenVertexArrays =
        loadGL<PFNGLGENVERTEXARRAYSPROC>(state, "glGenVertexArrays");
    gl.DeleteVertexArrays =
        loadGL<PFNGLDELETEVERTEXARRAYSPROC>(state, "glDeleteVertexArrays");
    gl.BindVertexArray =
        loadGL<PFNGLBINDVERTEXARRAYPROC>(state, "glBindVertexArray");
    gl.GenBuffers = loadGL<PFNGLGENBUFFERSPROC>(state, "glGenBuffers");
    gl.DeleteBuffers =
        loadGL<PFNGLDELETEBUFFERSPROC>(state, "glDeleteBuffers");
    gl.BindBuffer = loadGL<PFNGLBINDBUFFERPROC>(state, "glBindBuffer");
    gl.BufferData = loadGL<PFNGLBUFFERDATAPROC>(state, "glBufferData");
    gl.BufferSubData =
        loadGL<PFNGLBUFFERSUBDATAPROC>(state, "glBufferSubData");
    gl.EnableVertexAttribArray =
        loadGL<PFNGLENABLEVERTEXATTRIBARRAYPROC>(state,
                                                 "glEnableVertexAttribArray");
    gl.VertexAttribPointer =
        loadGL<PFNGLVERTEXATTRIBPOINTERPROC>(state,
                                             "glVertexAttribPointer");
    gl.DrawArrays = loadGL<PFNGLDRAWARRAYSPROC>(state, "glDrawArrays");
    gl.DrawElements =
        loadGL<PFNGLDRAWELEMENTSPROC>(state, "glDrawElements");
    return gl;
}

void expect(ProbeState& state, bool condition, const std::string& message) {
    if (!condition) {
        ++state.failures;
        std::cerr << "FAIL: " << message << "\n";
    }
}

appgl::ResourceResidencyRecord record(
    appgl::MetalResidencyKind kind,
    appgl::MetalResidencyAuthorityClass authority,
    appgl::MetalResidencyHeapClass heap,
    std::uint64_t metalBytes,
    std::uint64_t hostBytes) {
    appgl::ResourceResidencyRecord result;
    result.kind = kind;
    result.authority = authority;
    result.heapClass = heap;
    result.metalBytes = metalBytes;
    result.hostBytes = hostBytes;
    result.retainedBytes = metalBytes + hostBytes;
    result.purgeableEligible =
        (authority == appgl::MetalResidencyAuthorityClass::Reconstructable &&
         metalBytes != 0 &&
         appgl::metalR5FuturePurgeableEligibleKind(kind))
            ? 1
            : 0;
    return result;
}

appgl::ResourceResidencyRecord scopedRecord(
    appgl::MetalResidencyOwner owner,
    appgl::MetalResidencyKind kind,
    appgl::MetalResidencyHeapClass heap,
    std::uint32_t diagnosticBucketId,
    std::uint64_t lastUseSerial,
    std::uint64_t metalBytes,
    std::uint64_t hostBytes) {
    auto result = record(kind,
                         appgl::MetalResidencyAuthorityClass::Reconstructable,
                         heap,
                         metalBytes,
                         hostBytes);
    result.owner = owner;
    result.diagnosticBucketId = diagnosticBucketId;
    result.lastUseCommandSerial = lastUseSerial;
    result.lastUseFrame = lastUseSerial == 0 ? 0 : 3;
    return result;
}

void runClassifierProbe(ProbeState& state) {
    using appgl::MetalR5ResidencyClass;
    using appgl::MetalResidencyAuthorityClass;
    using appgl::MetalResidencyHeapClass;
    using appgl::MetalResidencyKind;

    appgl::MetalR5ResidencyDryRunSummary summary;
    summary.dryRunPasses = 1;

    const auto unknownKind = record(
        MetalResidencyKind::Unknown,
        MetalResidencyAuthorityClass::Reconstructable,
        MetalResidencyHeapClass::Cache,
        0,
        7);
    expect(state,
           appgl::classifyMetalR5ResidencyRecord(unknownKind) ==
               MetalR5ResidencyClass::Authoritative,
           "unknown kind defaults authoritative/excluded");
    appgl::accumulateR5ResidencyDryRunRecord(summary, unknownKind);

    const auto unknownAuthority = record(
        MetalResidencyKind::ExpandedIndexCache,
        MetalResidencyAuthorityClass::Unknown,
        MetalResidencyHeapClass::Cache,
        0,
        11);
    expect(state,
           appgl::classifyMetalR5ResidencyRecord(unknownAuthority) ==
               MetalR5ResidencyClass::Authoritative,
           "unknown authority defaults authoritative/excluded");
    appgl::accumulateR5ResidencyDryRunRecord(summary, unknownAuthority);

    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::ExpandedIndexCache,
               MetalResidencyAuthorityClass::Reconstructable,
               MetalResidencyHeapClass::Cache,
               0,
               16));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::MetalTexture,
               MetalResidencyAuthorityClass::Reconstructable,
               MetalResidencyHeapClass::MetalDevice,
               64,
               0));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::HostShadow,
               MetalResidencyAuthorityClass::Authoritative,
               MetalResidencyHeapClass::Host,
               0,
               32));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::FrameGraphResource,
               MetalResidencyAuthorityClass::Transient,
               MetalResidencyHeapClass::FrameGraph,
               128,
               0));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::SparsePageTable,
               MetalResidencyAuthorityClass::SparseSpecial,
               MetalResidencyHeapClass::Sparse,
               0,
               4));

    expect(state, summary.dryRunPasses == 1, "dry-run pass counted");
    expect(state, summary.recordsSeen == 7, "records seen");
    expect(state, summary.candidateRecords == 2, "candidate records");
    expect(state, summary.candidateBytes == 80, "candidate bytes");
    expect(state, summary.candidateHostBytes == 16, "candidate host bytes");
    expect(state, summary.candidateMetalBytes == 64, "candidate metal bytes");
    expect(state, summary.candidateCacheHeapBytes == 16,
           "cache heap candidate bytes");
    expect(state, summary.candidateMetalDeviceHeapBytes == 64,
           "metal heap candidate bytes");
    expect(state, summary.authoritativeRecords == 5,
           "authoritative/excluded records");
    expect(state, summary.authoritativeBytes == 182,
           "authoritative/excluded bytes");
    expect(state, summary.unknownKindRecords == 1, "unknown kind counter");
    expect(state, summary.unknownAuthorityRecords == 1,
           "unknown authority counter");
    expect(state, summary.transientExcludedRecords == 1,
           "transient excluded counter");
    expect(state, summary.sparseExcludedRecords == 1,
           "sparse excluded counter");
    expect(state, summary.futurePurgeableEligibleRecords == 1,
           "future purgeable count only tracks MTLResource reconstructables");
    expect(state, summary.pressureMutationAttempts == 0,
           "R5-0 performs no pressure mutation");
    expect(state, summary.purgeableStateCalls == 0,
           "R5-0 performs no purgeableState calls");
    expect(state, summary.drainRequests == 0, "R5-0 performs no drains");
}

void runOrderingProbe(ProbeState& state) {
    using appgl::MetalR5EvictionScope;
    using appgl::MetalResidencyAuthorityClass;
    using appgl::MetalResidencyHeapClass;
    using appgl::MetalResidencyKind;
    using appgl::MetalResidencyOwner;

    const auto textureView = scopedRecord(
        MetalResidencyOwner::Texture,
        MetalResidencyKind::TextureView,
        MetalResidencyHeapClass::MetalDevice,
        appgl::kMetalR5DiagnosticBucketTextureView,
        7,
        64,
        0);
    const auto expandedIndex = scopedRecord(
        MetalResidencyOwner::Buffer,
        MetalResidencyKind::ExpandedIndexCache,
        MetalResidencyHeapClass::Cache,
        appgl::kMetalR5DiagnosticBucketExpandedIndexCache,
        5,
        0,
        16);
    const auto swizzledUnknownUse = scopedRecord(
        MetalResidencyOwner::Texture,
        MetalResidencyKind::TextureView,
        MetalResidencyHeapClass::MetalDevice,
        appgl::kMetalR5DiagnosticBucketSwizzledTextureView,
        0,
        32,
        0);
    const auto samplingProxy = scopedRecord(
        MetalResidencyOwner::Texture,
        MetalResidencyKind::MetalTexture,
        MetalResidencyHeapClass::Cache,
        0,
        9,
        48,
        0);
    auto authoritativeTextureView = textureView;
    authoritativeTextureView.authority =
        MetalResidencyAuthorityClass::Authoritative;

    expect(state,
           appgl::metalR5EvictionScopeForRecord(textureView) ==
               MetalR5EvictionScope::TextureView,
           "texture-view scope detected");
    expect(state,
           appgl::metalR5EvictionScopeForRecord(expandedIndex) ==
               MetalR5EvictionScope::ExpandedIndexCache,
           "expanded-index-cache scope detected");
    expect(state,
           appgl::metalR5EvictionScopeForRecord(samplingProxy) ==
               MetalR5EvictionScope::None,
           "sampling proxy / reconstructable MetalTexture remains scoped none");
    expect(state,
           appgl::metalR5EvictionScopeForRecord(authoritativeTextureView) ==
               MetalR5EvictionScope::None,
           "authoritative resources excluded from R5-0.5 scope");
    expect(state,
           std::string(appgl::metalResidencyOwnerName(
               MetalResidencyOwner::Texture)) == "texture",
           "stable owner name");
    expect(state,
           std::string(appgl::metalResidencyKindName(
               MetalResidencyKind::ExpandedIndexCache)) ==
               "expanded-index-cache",
           "stable kind name");
    expect(state,
           std::string(appgl::metalR5EvictionScopeName(
               MetalR5EvictionScope::TextureView)) == "texture-view",
           "stable eviction-scope name");

    appgl::MetalR5ResidencyOrderingSummary ordering;
    appgl::accumulateR5ResidencyOrderingRecord(ordering, textureView);
    appgl::accumulateR5ResidencyOrderingRecord(ordering, expandedIndex);
    appgl::accumulateR5ResidencyOrderingRecord(ordering, swizzledUnknownUse);
    appgl::accumulateR5ResidencyOrderingRecord(ordering, samplingProxy);
    appgl::accumulateR5ResidencyOrderingRecord(ordering,
                                               authoritativeTextureView);
    expect(state, ordering.rowsSeen == 5, "ordering rows seen");
    expect(state, ordering.candidateRows == 3,
           "narrow R5 candidate rows");
    expect(state, ordering.candidateBytes == 112,
           "narrow R5 candidate bytes");
    expect(state, ordering.candidateMetalBytes == 96,
           "narrow R5 candidate metal bytes");
    expect(state, ordering.candidateHostBytes == 16,
           "narrow R5 candidate host bytes");
    expect(state, ordering.textureViewCandidateRows == 2,
           "texture-view candidate rows");
    expect(state, ordering.expandedIndexCandidateRows == 1,
           "expanded-index candidate rows");
    expect(state, ordering.missingLastUseCandidateRows == 1,
           "unknown last-use candidate tracked");
    expect(state, ordering.oldestLastUseCommandSerial == 5,
           "oldest known last-use serial");
    expect(state, ordering.newestLastUseCommandSerial == 7,
           "newest known last-use serial");

    expect(state,
           appgl::metalR5OrderingRecordLess(expandedIndex, textureView),
           "older known resource sorts first");
    expect(state,
           appgl::metalR5OrderingRecordLess(textureView,
                                            swizzledUnknownUse),
           "known last-use sorts before unknown last-use");

    std::vector<appgl::ResourceResidencyRecord> rows;
    constexpr std::uint64_t rowLimit = 4;
    std::uint64_t appended = 0;
    for (std::uint64_t i = 0; i < 100; ++i) {
        auto row = textureView;
        row.recordId = i + 1;
        if (appgl::metalR5AppendBoundedResidencyRow(rows, row, rowLimit)) {
            ++appended;
        }
    }
    expect(state, appended == rowLimit, "bounded row append count");
    expect(state, rows.size() == rowLimit, "bounded row vector size");
}

void runTouchProbe(ProbeState& state) {
    using appgl::MetalR5ResidencyTouchKind;

    appgl::MetalR5ResidencyTouchSummary touches;
    appgl::recordMetalR5ResidencyTouch(
        touches, MetalR5ResidencyTouchKind::BufferBind);
    appgl::recordMetalR5ResidencyTouch(
        touches, MetalR5ResidencyTouchKind::TextureBind);
    appgl::recordMetalR5ResidencyTouch(touches,
                                       MetalR5ResidencyTouchKind::Draw);
    appgl::recordMetalR5ResidencyTouch(touches,
                                       MetalR5ResidencyTouchKind::Dispatch);

    expect(state, touches.serial == 4, "touch serial");
    expect(state, touches.totalTouches == 4, "total touches");
    expect(state, touches.bufferBindTouches == 1, "buffer touch count");
    expect(state, touches.textureBindTouches == 1, "texture touch count");
    expect(state, touches.drawTouches == 1, "draw touch count");
    expect(state, touches.dispatchTouches == 1, "dispatch touch count");

    constexpr std::uint64_t iterations = 1000000;
    appgl::MetalR5ResidencyTouchSummary benchmarkTouches;
    const appgl::MetalR5ResidencyTouchKind benchmarkKinds[] = {
        MetalR5ResidencyTouchKind::BufferBind,
        MetalR5ResidencyTouchKind::TextureBind,
        MetalR5ResidencyTouchKind::Draw,
        MetalR5ResidencyTouchKind::Dispatch,
    };
    const auto start = std::chrono::steady_clock::now();
    for (std::uint64_t i = 0; i < iterations; ++i) {
        const std::size_t kindIndex =
            static_cast<std::size_t>((i + gTouchSelector) & 3u);
        appgl::recordMetalR5ResidencyTouch(
            benchmarkTouches, benchmarkKinds[kindIndex]);
    }
    const auto end = std::chrono::steady_clock::now();
    gTouchSink = benchmarkTouches.serial + benchmarkTouches.totalTouches +
        benchmarkTouches.drawTouches + benchmarkTouches.dispatchTouches;
    const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
        end - start).count();
    expect(state, benchmarkTouches.serial == iterations,
           "benchmark serial count");
    expect(state, benchmarkTouches.totalTouches == iterations,
           "benchmark total count");
    std::cout << "r5 touch benchmark ns_per_touch="
              << (static_cast<double>(nanos) /
                  static_cast<double>(iterations))
              << "\n";
}

bool pixelNear(const std::uint8_t* rgba,
               std::uint8_t r,
               std::uint8_t g,
               std::uint8_t b) {
    const auto near = [](std::uint8_t actual, std::uint8_t expected) {
        const int delta = static_cast<int>(actual) - static_cast<int>(expected);
        return delta >= -2 && delta <= 2;
    };
    return near(rgba[0], r) && near(rgba[1], g) && near(rgba[2], b) &&
           rgba[3] >= 250;
}

GLuint compileShader(ProbeState& state,
                     const R5GL& gl,
                     GLenum type,
                     const char* source) {
    const GLuint shader = gl.CreateShader(type);
    gl.ShaderSource(shader, 1, &source, nullptr);
    gl.CompileShader(shader);
    GLint ok = GL_FALSE;
    gl.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        gl.GetShaderInfoLog(shader, static_cast<GLsizei>(sizeof(log)),
                            nullptr, log);
        ++state.failures;
        std::cerr << "FAIL: shader compile failed: " << log << "\n";
    }
    return shader;
}

GLuint buildFlatProgram(ProbeState& state,
                        const R5GL& gl,
                        const char* colorExpr = "0.0, 1.0, 0.0") {
    const char* vertex =
        "#version 330 core\n"
        "layout(location=0) in vec2 a_pos;\n"
        "void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
    const std::string fragment =
        "#version 330 core\n"
        "out vec4 color;\n"
        "void main(){ color = vec4(" +
        std::string(colorExpr) + ", 1.0); }\n";
    const GLuint vs = compileShader(state, gl, GL_VERTEX_SHADER, vertex);
    const GLuint fs =
        compileShader(state, gl, GL_FRAGMENT_SHADER, fragment.c_str());
    const GLuint program = gl.CreateProgram();
    gl.AttachShader(program, vs);
    gl.AttachShader(program, fs);
    gl.LinkProgram(program);
    GLint ok = GL_FALSE;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        gl.GetProgramInfoLog(program, static_cast<GLsizei>(sizeof(log)),
                             nullptr, log);
        ++state.failures;
        std::cerr << "FAIL: program link failed: " << log << "\n";
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    return program;
}

GLuint buildCubeSampleProgram(ProbeState& state, const R5GL& gl) {
    const char* vertex =
        "#version 330 core\n"
        "layout(location=0) in vec2 a_pos;\n"
        "void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
    const char* fragment =
        "#version 330 core\n"
        "uniform samplerCube u_tex;\n"
        "out vec4 color;\n"
        "void main(){ color = texture(u_tex, vec3(1.0, 0.0, 0.0)); }\n";
    const GLuint vs = compileShader(state, gl, GL_VERTEX_SHADER, vertex);
    const GLuint fs = compileShader(state, gl, GL_FRAGMENT_SHADER, fragment);
    const GLuint program = gl.CreateProgram();
    gl.AttachShader(program, vs);
    gl.AttachShader(program, fs);
    gl.LinkProgram(program);
    GLint ok = GL_FALSE;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        gl.GetProgramInfoLog(program, static_cast<GLsizei>(sizeof(log)),
                             nullptr, log);
        ++state.failures;
        std::cerr << "FAIL: cube sample program link failed: " << log
                  << "\n";
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    return program;
}

GLuint buildTexture2DSampleProgram(ProbeState& state, const R5GL& gl) {
    const char* vertex =
        "#version 330 core\n"
        "layout(location=0) in vec2 a_pos;\n"
        "out vec2 v_uv;\n"
        "void main(){ v_uv = a_pos * 0.25 + vec2(0.5);"
        " gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
    const char* fragment =
        "#version 330 core\n"
        "uniform sampler2D u_tex;\n"
        "in vec2 v_uv;\n"
        "out vec4 color;\n"
        "void main(){ color = texture(u_tex, v_uv); }\n";
    const GLuint vs = compileShader(state, gl, GL_VERTEX_SHADER, vertex);
    const GLuint fs = compileShader(state, gl, GL_FRAGMENT_SHADER, fragment);
    const GLuint program = gl.CreateProgram();
    gl.AttachShader(program, vs);
    gl.AttachShader(program, fs);
    gl.LinkProgram(program);
    GLint ok = GL_FALSE;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        gl.GetProgramInfoLog(program, static_cast<GLsizei>(sizeof(log)),
                             nullptr, log);
        ++state.failures;
        std::cerr << "FAIL: texture2D sample program link failed: " << log
                  << "\n";
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    return program;
}

void drawDefaultTriangle(ProbeState& state,
                         const R5GL& gl,
                         GLuint program,
                         const std::string& label) {
    GLuint vao = 0;
    GLuint vbo = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.GenBuffers(1, &vbo);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    const float vertices[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    gl.BufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices,
                  GL_STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float),
                           nullptr);
    gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.Viewport(0, 0, 4, 4);
    gl.UseProgram(program);
    gl.DrawArrays(GL_TRIANGLES, 0, 3);
    gl.Finish();
    expectNoGLError(state, gl.GetError, label);
    gl.DeleteBuffers(1, &vbo);
    gl.DeleteVertexArrays(1, &vao);
}

void drawAndReadFBO(ProbeState& state,
                    const R5GL& gl,
                    GLuint framebuffer,
                    GLuint program,
                    std::uint8_t expectedR,
                    std::uint8_t expectedG,
                    std::uint8_t expectedB,
                    const std::string& label) {
    GLuint vao = 0;
    GLuint vbo = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.GenBuffers(1, &vbo);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    const float vertices[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    gl.BufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices,
                  GL_STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float),
                           nullptr);

    gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.DrawBuffer(GL_COLOR_ATTACHMENT0);
    gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
    gl.Viewport(0, 0, 4, 4);
    gl.UseProgram(program);
    gl.DrawArrays(GL_TRIANGLES, 0, 3);
    gl.Finish();
    std::uint8_t pixel[4] = {};
    gl.ReadPixels(2, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    expectNoGLError(state, gl.GetError, label);
    expect(state, pixelNear(pixel, expectedR, expectedG, expectedB), label);

    gl.DeleteBuffers(1, &vbo);
    gl.DeleteVertexArrays(1, &vao);
}

void runTextureViewEvictionProbe(ProbeState& state, const R5GL& gl) {
    const GLuint program = buildFlatProgram(state, gl, "1.0, 0.0, 0.0");
    GLuint base = 0;
    GLuint view = 0;
    GLuint framebuffer = 0;
    gl.GenTextures(1, &base);
    gl.BindTexture(GL_TEXTURE_2D, base);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 4, 4);
    expectNoGLError(state, gl.GetError, "texture-view base storage setup");
    gl.GenTextures(1, &view);
    gl.TextureView(view, GL_TEXTURE_2D, base, GL_RGBA8, 0, 1, 0, 1);
    expectNoGLError(state, gl.GetError, "texture-view object setup");
    gl.GenFramebuffers(1, &framebuffer);
    gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, view, 0);
    expectNoGLError(state, gl.GetError, "texture-view FBO attachment");
    expect(state,
           gl.CheckFramebufferStatus(GL_FRAMEBUFFER) ==
               GL_FRAMEBUFFER_COMPLETE,
           "texture-view FBO is complete");
    drawAndReadFBO(state, gl, framebuffer, program, 255, 0, 0,
                   "pre-evict rendered-to texture-view readback");

    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");
    const std::uint64_t disabledMutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, disabledMutations == 0,
           "disabled R5 eviction is a negative-control no-op");
    std::string disabledDiag = diagnosticsJSON();
    expect(state, jsonCounter(disabledDiag, "passSkippedDisabled") >= 1,
           "disabled negative control increments skip counter");
    const std::uint64_t beforePrimaryReleaseAttempts =
        jsonCounter(disabledDiag, "primaryTextureReleaseAttempts");
    const std::uint64_t beforePurgeableStateCalls =
        jsonCounter(disabledDiag, "setPurgeableStateCalls");

    setenv("APPGL_R5_EVICTION", "1", 1);
    const std::uint64_t enabledMutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, enabledMutations == 1,
           "budget=1 texture-view eviction mutates one record");
    std::string evictDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(evictDiag, "textureViewBaseReleaseSuccesses") >= 1,
           "texture-view base handle was released");
    expect(state,
           jsonCounter(evictDiag, "lastPostTextureViewCount") <
               jsonCounter(evictDiag, "lastPreTextureViewCount"),
           "texture-view accounting decreased after eviction");
    expect(state,
           jsonCounter(evictDiag, "primaryTextureReleaseAttempts") ==
               beforePrimaryReleaseAttempts,
           "texture-view eviction does not release primary textures");
    expect(state,
           jsonCounter(evictDiag, "setPurgeableStateCalls") ==
               beforePurgeableStateCalls,
           "texture-view eviction does not call purgeable state");

    drawAndReadFBO(state, gl, framebuffer, program, 255, 0, 0,
                   "post-evict rendered-to texture-view reconstruct AE=0");
    std::string rebuildDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(rebuildDiag, "textureViewRebuildsAfterR5Evict") >= 1,
           "texture-view rematerialized after R5 eviction");

    gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.DeleteFramebuffers(1, &framebuffer);
    GLuint textures[2] = {view, base};
    gl.DeleteTextures(2, textures);
    gl.DeleteProgram(program);
}

void runPrimaryTextureEvictionProbe(ProbeState& state, const R5GL& gl) {
    setenv("APPGL_R5_EVICTION", "1", 1);
    const GLuint program = buildTexture2DSampleProgram(state, gl);
    GLuint texture = 0;
    gl.GenTextures(1, &texture);
    gl.BindTexture(GL_TEXTURE_2D, texture);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 2048, 2048);
    expectNoGLError(state, gl.GetError, "primary texture storage setup");

    drawDefaultTriangle(state, gl, program,
                        "pre-evict primary texture sampler touch");
    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforeReleaseAttempts =
        jsonCounter(beforeDiag, "primaryTextureReleaseAttempts");
    const std::uint64_t beforeReleaseSuccesses =
        jsonCounter(beforeDiag, "primaryTextureReleaseSuccesses");
    const std::uint64_t beforeEvicted =
        jsonCounter(beforeDiag, "reconstructablePrimariesEvicted");
    const std::uint64_t beforePurgeable =
        jsonCounter(beforeDiag, "setPurgeableStateCalls");
    const std::uint64_t beforeDeviceBytesFreed =
        jsonCounter(beforeDiag, "deviceBytesFreed");
    const std::uint64_t beforeReconstructions =
        jsonCounter(beforeDiag, "primaryReconstructions");
    const std::uint64_t beforeVolatileAttempts =
        jsonCounter(beforeDiag, "primaryVolatileRestoreAttempts");
    const std::uint64_t beforeReconstructionFailures =
        jsonCounter(beforeDiag, "primaryReconstructionFailures");

    const std::uint64_t mutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, mutations == 1,
           "budget=1 primary texture eviction mutates one record");
    const std::string evictDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(evictDiag, "primaryTextureReleaseAttempts") >
               beforeReleaseAttempts,
           "primary texture release attempt was recorded");
    expect(state,
           jsonCounter(evictDiag, "primaryTextureReleaseSuccesses") >
               beforeReleaseSuccesses,
           "primary texture release success was recorded");
    expect(state,
           jsonCounter(evictDiag, "reconstructablePrimariesEvicted") >
               beforeEvicted,
           "reconstructable primary eviction was recorded");
    expect(state,
           jsonCounter(evictDiag, "authoritativePrimaryEvictAttempts") == 0,
           "authoritative primary eviction attempts stay fail-closed");
    expect(state,
           jsonCounter(evictDiag, "deviceBytesFreed") >
               beforeDeviceBytesFreed,
           "primary texture hard release records device-byte relief");
    expect(state,
           jsonCounter(evictDiag, "setPurgeableStateCalls") ==
               beforePurgeable,
           "primary hard release does not use purgeable retention");

    drawDefaultTriangle(state, gl, program,
                        "post-evict primary texture sampler reconstruct");
    const std::string restoreDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(restoreDiag, "primaryReconstructions") >
               beforeReconstructions,
           "primary texture reconstructs from mirrors on next sampler use");
    expect(state,
           jsonCounter(restoreDiag, "primaryVolatileRestoreAttempts") ==
               beforeVolatileAttempts,
           "primary hard release leaves volatile restore path unused");
    expect(state,
           jsonCounter(restoreDiag, "primaryReconstructionFailures") ==
               beforeReconstructionFailures,
           "primary reconstruction failures remain zero");

    gl.DeleteTextures(1, &texture);
    gl.DeleteProgram(program);
}

void runForcedPressureEvictionProbe(ProbeState& state, const R5GL& gl) {
    appglR5ForceMemoryClassForTesting(0);
    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    setenv("APPGL_R5_EVICTION", "1", 1);
    const GLuint program = buildFlatProgram(state, gl, "0.0, 0.0, 1.0");
    GLuint base = 0;
    GLuint view = 0;
    GLuint framebuffer = 0;
    gl.GenTextures(1, &base);
    gl.BindTexture(GL_TEXTURE_2D, base);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 4, 4);
    expectNoGLError(state, gl.GetError, "forced-pressure base storage setup");
    gl.GenTextures(1, &view);
    gl.TextureView(view, GL_TEXTURE_2D, base, GL_RGBA8, 0, 1, 0, 1);
    expectNoGLError(state, gl.GetError, "forced-pressure texture view setup");
    gl.GenFramebuffers(1, &framebuffer);
    gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, view, 0);
    expectNoGLError(state, gl.GetError, "forced-pressure FBO attachment");
    expect(state,
           gl.CheckFramebufferStatus(GL_FRAMEBUFFER) ==
               GL_FRAMEBUFFER_COMPLETE,
           "forced-pressure FBO is complete");
    drawAndReadFBO(state, gl, framebuffer, program, 0, 0, 255,
                   "pre-pressure rendered-to texture-view readback");

    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforeTriggered =
        jsonCounter(beforeDiag, "passesTriggered");
    const std::uint64_t beforeTextureEvictions =
        jsonCounter(beforeDiag, "recordsEvictedTextureView");
    const std::uint64_t beforeDeviceBytesFreed =
        jsonCounter(beforeDiag, "deviceBytesFreed");
    const std::uint64_t beforeTextureRebuilds =
        jsonCounter(beforeDiag, "textureViewRebuildsAfterR5Evict");
    const std::uint64_t beforeRetentionSkips =
        jsonCounter(beforeDiag, "policyRetentionSkippedRecords");

    const std::uint64_t forced =
        appglR5ForceMemoryPressureForTesting(
            appgl::metalMemoryPressureStateValue(
                appgl::MetalMemoryPressureState::Soft));
    expect(state,
           forced == appgl::metalMemoryPressureStateValue(
                         appgl::MetalMemoryPressureState::Soft),
           "forced pressure hook applies Soft");
    gl.Finish();
    expectNoGLError(state, gl.GetError, "forced-pressure boundary finish");

    std::string pressureDiag = diagnosticsJSON();
    const std::uint64_t pressureMemoryClass =
        jsonCounter(pressureDiag, "pressureMemoryClassAtEvict");
    if (pressureMemoryClass ==
        appgl::metalMemoryPressureClassValue(
            appgl::MetalMemoryPressureClass::High)) {
        expect(state,
               jsonCounter(pressureDiag, "policyRetentionSkippedRecords") >
                   beforeRetentionSkips,
               "high-memory Soft pressure retains fresh candidates");
        expect(state,
               jsonCounter(pressureDiag, "recordsEvictedTextureView") ==
                   beforeTextureEvictions,
               "high-memory Soft retention defers fresh texture-view eviction");
    }
    for (int retry = 0;
         retry < 6 &&
         jsonCounter(pressureDiag, "recordsEvictedTextureView") <=
             beforeTextureEvictions;
         ++retry) {
        gl.Finish();
        expectNoGLError(state, gl.GetError,
                        "forced-pressure retained candidate retry");
        pressureDiag = diagnosticsJSON();
    }
    expect(state,
           jsonContainsToken(pressureDiag, "\"metalResources\":{") &&
               jsonContainsToken(pressureDiag, "\"pressure\":{") &&
               jsonContainsToken(pressureDiag, "\"state\":") &&
               jsonContainsToken(pressureDiag, "\"memoryClass\":") &&
               jsonContainsToken(pressureDiag, "\"workingSetRatio\":") &&
               jsonContainsToken(pressureDiag, "\"r5Eviction\":{") &&
               jsonContainsToken(pressureDiag, "\"passesTriggered\":") &&
               jsonContainsToken(pressureDiag, "\"pressureLevelAtEvict\":") &&
               jsonContainsToken(pressureDiag,
                                 "\"pressureMemoryClassAtEvict\":") &&
               jsonContainsToken(pressureDiag,
                                 "\"pressurePolicySoftBudget\":") &&
               jsonContainsToken(pressureDiag,
                                 "\"pressurePolicyMinIdleBoundaryAge\":") &&
               jsonContainsToken(pressureDiag, "\"mutatedRecords\":") &&
               jsonContainsToken(pressureDiag, "\"recordsEvictedByBucket\":{") &&
               jsonContainsToken(pressureDiag, "\"textureView\":") &&
               jsonContainsToken(pressureDiag, "\"deviceBytesFreed\":"),
           "full appglDiagnosticsJSON exposes R5 pressure integrity fields");
    expect(state,
           jsonCounter(pressureDiag, "passesTriggered") >
               beforeTriggered,
           "forced pressure triggers pressure eviction pass");
    expect(state,
           jsonCounter(pressureDiag, "pressureLevelAtEvict") ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Soft),
           "forced pressure records Soft level");
    expect(state,
           jsonCounter(pressureDiag, "recordsEvictedTextureView") >
               beforeTextureEvictions,
           "forced pressure evicts a texture-view bucket record");
    if (pressureMemoryClass ==
        appgl::metalMemoryPressureClassValue(
            appgl::MetalMemoryPressureClass::Low)) {
        expect(state, jsonCounter(pressureDiag, "pressurePolicySoftBudget") == 4,
               "low-memory Soft policy budget");
    } else if (pressureMemoryClass ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::High)) {
        expect(state, jsonCounter(pressureDiag, "pressurePolicySoftBudget") == 12,
               "high-memory Soft policy budget");
        expect(state,
               jsonCounter(pressureDiag, "pressurePolicyMinIdleBoundaryAge") ==
                   4,
               "high-memory Soft retention age");
        expect(state, jsonCounter(pressureDiag, "highMemoryPolicyPasses") > 0,
               "high-memory policy pass recorded");
    } else {
        expect(state, jsonCounter(pressureDiag, "pressurePolicySoftBudget") == 8,
               "mid/unknown Soft policy budget");
    }
    expect(state,
           jsonCounter(pressureDiag, "deviceBytesFreed") ==
               beforeDeviceBytesFreed,
           "P1 forced pressure reports no device-byte relief");

    drawAndReadFBO(state, gl, framebuffer, program, 0, 0, 255,
                   "post-pressure texture-view reconstruct AE=0");
    const std::string rebuildDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(rebuildDiag, "textureViewRebuildsAfterR5Evict") >
               beforeTextureRebuilds,
           "forced pressure texture-view rematerialized");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    const std::string resetDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(resetDiag, "recommendedWorkingSetBytes") != 1000,
           "disabling forced pressure restores non-synthetic WSS input");
    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");

    gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.DeleteFramebuffers(1, &framebuffer);
    GLuint textures[2] = {view, base};
    gl.DeleteTextures(2, textures);
    gl.DeleteProgram(program);
}

void expectForcedMemoryClassPolicy(ProbeState& state,
                                   const R5GL& gl,
                                   appgl::MetalMemoryPressureClass memoryClass,
                                   std::uint64_t expectedSoftBudget,
                                   std::uint64_t expectedHardBudget,
                                   std::uint64_t expectedCriticalBudget,
                                   std::uint64_t expectedSoftRetentionAge) {
    const std::uint64_t classValue =
        appgl::metalMemoryPressureClassValue(memoryClass);
    const std::uint64_t forcedClass =
        appglR5ForceMemoryClassForTesting(classValue);
    expect(state, forcedClass == classValue,
           "forced memory-class hook returns applied class");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "forced memory-class idle boundary");

    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforeTriggered =
        jsonCounter(beforeDiag, "passesTriggered");
    const std::uint64_t forcedPressure =
        appglR5ForceMemoryPressureForTesting(
            appgl::metalMemoryPressureStateValue(
                appgl::MetalMemoryPressureState::Soft));
    expect(state,
           forcedPressure == appgl::metalMemoryPressureStateValue(
                                 appgl::MetalMemoryPressureState::Soft),
           "forced memory-class probe applies Soft pressure");
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "forced memory-class pressure boundary");

    const std::string pressureDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(pressureDiag, "passesTriggered") > beforeTriggered,
           "forced memory-class pressure pass triggered");
    expect(state, jsonCounter(pressureDiag, "memoryClass") == classValue,
           "forced memory class is visible in pressure diagnostics");
    expect(state,
           jsonCounter(pressureDiag, "pressureMemoryClassAtEvict") ==
               classValue,
           "forced memory class reaches R5 pressure policy");
    expect(state,
           jsonCounter(pressureDiag, "pressurePolicySoftBudget") ==
               expectedSoftBudget,
           "forced memory-class Soft budget");
    expect(state,
           jsonCounter(pressureDiag, "pressurePolicyHardBudget") ==
               expectedHardBudget,
           "forced memory-class Hard budget");
    expect(state,
           jsonCounter(pressureDiag, "pressurePolicyCriticalBudget") ==
               expectedCriticalBudget,
           "forced memory-class Critical budget");
    expect(state,
           jsonCounter(pressureDiag, "pressurePolicyMinIdleBoundaryAge") ==
               expectedSoftRetentionAge,
           "forced memory-class Soft retention age");
}

void runForcedMemoryClassPolicyProbe(ProbeState& state, const R5GL& gl) {
    setenv("APPGL_R5_EVICTION", "1", 1);
    expectForcedMemoryClassPolicy(
        state,
        gl,
        appgl::MetalMemoryPressureClass::Low,
        4,
        8,
        32,
        0);
    expectForcedMemoryClassPolicy(
        state,
        gl,
        appgl::MetalMemoryPressureClass::Mid,
        8,
        16,
        appgl::kMetalR5ResidencyCandidateLimit,
        0);
    expectForcedMemoryClassPolicy(
        state,
        gl,
        appgl::MetalMemoryPressureClass::High,
        12,
        32,
        appgl::kMetalR5ResidencyCandidateLimit,
        4);

    const std::uint64_t apiResetClass = appglR5ForceMemoryClassForTesting(0);
    expect(state, apiResetClass == 0,
           "forced memory-class API reset before env override");
    setenv("APPGL_R5_FORCE_MEMORY_CLASS", "low", 1);
    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "forced memory-class env idle boundary");
    const std::uint64_t beforeEnvTriggered =
        jsonCounter(diagnosticsJSON(), "passesTriggered");
    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Soft));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "forced memory-class env pressure boundary");
    const std::string envDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(envDiag, "passesTriggered") > beforeEnvTriggered,
           "forced memory-class env pressure pass triggered");
    expect(state,
           jsonCounter(envDiag, "pressureMemoryClassAtEvict") ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::Low),
           "APPGL_R5_FORCE_MEMORY_CLASS reaches R5 pressure policy");
    expect(state, jsonCounter(envDiag, "pressurePolicySoftBudget") == 4,
           "APPGL_R5_FORCE_MEMORY_CLASS uses low-class policy");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    const std::uint64_t resetClass = appglR5ForceMemoryClassForTesting(0);
    expect(state, resetClass == 0,
           "forced memory-class hook resets to detected class");
    gl.Finish();
    unsetenv("APPGL_R5_FORCE_MEMORY_CLASS");
    unsetenv("APPGL_FORCE_MEMORY_CLASS");
    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");
}

void runPendingPressureDirtyBitProbe(ProbeState& state, const R5GL& gl) {
    setenv("APPGL_R5_EVICTION", "1", 1);
    expectNoGLError(state, gl.GetError, "pending-pressure dirty setup");

    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforeTriggered =
        jsonCounter(beforeDiag, "passesTriggered");
    const std::uint64_t beforeConsumes =
        jsonCounter(beforeDiag, "pendingPressureBoundaryConsumes");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Critical));
    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "pending-pressure dirty boundary does not OOM");

    const std::string dirtyDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(dirtyDiag, "pendingPressureBoundaryConsumes") >
               beforeConsumes,
           "pending pressure dirty bit consumed at boundary");
    expect(state,
           jsonCounter(dirtyDiag, "pendingPressurePeakAtBoundary") ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Critical),
           "pending pressure dirty bit preserves critical peak");
    expect(state,
           jsonCounter(dirtyDiag, "passesTriggered") > beforeTriggered,
           "pending critical peak triggers pressure eviction pass");
    expect(state,
           jsonCounter(dirtyDiag, "pressureLevelAtEvict") ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Critical),
           "pending critical peak drives critical eviction level");

    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");
}

void runCriticalPressureOOMLatchProbe(ProbeState& state, const R5GL& gl) {
    setenv("APPGL_R5_EVICTION", "1", 1);
    expectNoGLError(state, gl.GetError, "critical-pressure OOM setup");

    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforeLatches =
        jsonCounter(beforeDiag, "criticalPressureExhaustionLatches");
    const std::uint64_t beforeOOMErrors =
        jsonCounter(beforeDiag, "criticalPressureOOMErrors");
    const std::uint64_t beforeNoCandidates =
        jsonCounter(beforeDiag, "criticalPressureNoCandidateLatches");
    const std::uint64_t beforeNoRelief =
        jsonCounter(beforeDiag, "criticalPressureNoReliefLatches");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Critical));
    gl.Finish();
    expectGLError(state, gl.GetError, GL_OUT_OF_MEMORY,
                  "critical pressure exhaustion surfaces GL_OUT_OF_MEMORY");

    const std::string oomDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(oomDiag, "criticalPressureExhaustionLatches") >
               beforeLatches,
           "critical pressure exhaustion latch recorded");
    expect(state,
           jsonCounter(oomDiag, "criticalPressureOOMErrors") >
               beforeOOMErrors,
           "critical pressure OOM emission recorded");
    expect(state,
           jsonCounter(oomDiag, "criticalPressureNoCandidateLatches") >
               beforeNoCandidates,
           "critical pressure no-candidate latch recorded");
    expect(state,
           jsonCounter(oomDiag, "criticalPressureNoReliefLatches") >
               beforeNoRelief,
           "critical pressure no-relief latch recorded");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    expectNoGLError(state, gl.GetError, "critical-pressure OOM cleanup");
    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");
}

void runCriticalPressurePrimaryReliefProbe(ProbeState& state, const R5GL& gl) {
    setenv("APPGL_R5_EVICTION", "1", 1);
    const GLuint program = buildTexture2DSampleProgram(state, gl);
    GLuint texture = 0;
    gl.GenTextures(1, &texture);
    gl.BindTexture(GL_TEXTURE_2D, texture);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.TexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 2048, 2048);
    expectNoGLError(state, gl.GetError,
                    "critical pressure primary relief storage setup");
    drawDefaultTriangle(state, gl, program,
                        "critical pressure primary relief seed draw");

    const std::string beforeDiag = diagnosticsJSON();
    const std::uint64_t beforePrimaryReleases =
        jsonCounter(beforeDiag, "primaryTextureReleaseSuccesses");
    const std::uint64_t beforeDeviceBytesFreed =
        jsonCounter(beforeDiag, "deviceBytesFreed");
    const std::uint64_t beforeOOMErrors =
        jsonCounter(beforeDiag, "criticalPressureOOMErrors");
    const std::uint64_t beforeHighCriticalRelief =
        jsonCounter(beforeDiag, "highMemoryCriticalReliefPasses");

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Critical));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "critical pressure primary relief does not OOM");

    const std::string reliefDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(reliefDiag, "pressureLevelAtEvict") ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Critical),
           "critical pressure primary relief records Critical level");
    expect(state,
           jsonCounter(reliefDiag, "pressurePolicyMinIdleBoundaryAge") == 0,
           "critical pressure policy has no retention age");
    expect(state,
           jsonCounter(reliefDiag, "primaryTextureReleaseSuccesses") >
               beforePrimaryReleases,
           "critical pressure evicts reconstructable primary");
    expect(state,
           jsonCounter(reliefDiag, "deviceBytesFreed") >
               beforeDeviceBytesFreed,
           "critical pressure records device-byte relief");
    expect(state,
           jsonCounter(reliefDiag, "criticalPressureOOMErrors") ==
               beforeOOMErrors,
           "critical pressure relief avoids OOM latch");
    if (jsonCounter(reliefDiag, "pressureMemoryClassAtEvict") ==
        appgl::metalMemoryPressureClassValue(
            appgl::MetalMemoryPressureClass::High)) {
        expect(state,
               jsonCounter(reliefDiag, "highMemoryCriticalReliefPasses") >
                   beforeHighCriticalRelief,
               "high-memory Critical pressure relief recorded");
    }

    appglR5ForceMemoryPressureForTesting(
        appgl::metalMemoryPressureStateValue(
            appgl::MetalMemoryPressureState::Idle));
    gl.Finish();
    expectNoGLError(state, gl.GetError,
                    "critical pressure primary relief cleanup");
    gl.DeleteTextures(1, &texture);
    gl.DeleteProgram(program);
    unsetenv("APPGL_R5_EVICTION");
    unsetenv("APPGL_R5_EVICTION_ENABLE");
}

void runSamplingProxySkipProbe(ProbeState& state, const R5GL& gl) {
    const GLuint program = buildCubeSampleProgram(state, gl);
    GLuint base = 0;
    GLuint view = 0;
    gl.GenTextures(1, &base);
    gl.BindTexture(GL_TEXTURE_2D_ARRAY, base);
    gl.TexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER,
                     GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER,
                     GL_NEAREST);
    gl.TexStorage3D(GL_TEXTURE_2D_ARRAY, 1, GL_RGBA8, 4, 4, 6);
    expectNoGLError(state, gl.GetError, "sampling-proxy base storage setup");

    gl.GenTextures(1, &view);
    gl.TextureView(view, GL_TEXTURE_CUBE_MAP, base, GL_RGBA8, 0, 1, 0, 6);
    expectNoGLError(state, gl.GetError, "sampling-proxy cube view setup");
    gl.BindTexture(GL_TEXTURE_CUBE_MAP, view);
    gl.TexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    drawDefaultTriangle(state, gl, program, "sampling-proxy cube-view draw");

    setenv("APPGL_R5_EVICTION", "1", 1);
    const std::uint64_t proxyMutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, proxyMutations == 0,
           "sampling-proxy texture-view candidate is skipped");
    const std::string proxyDiag = diagnosticsJSON();
    expect(state, jsonCounter(proxyDiag, "samplingProxySkipped") >= 1,
           "sampling-proxy skip counter increments");
    expect(state,
           jsonCounter(proxyDiag, "textureViewBaseReleaseSuccesses") == 0,
           "sampling-proxy path does not release view base");

    GLuint textures[2] = {view, base};
    gl.DeleteTextures(2, textures);
    gl.DeleteProgram(program);
}

void drawIndexedTriangle(ProbeState& state,
                         const R5GL& gl,
                         GLuint program,
                         const std::string& label) {
    gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.Viewport(0, 0, 4, 4);
    gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.Clear(GL_COLOR_BUFFER_BIT);
    gl.UseProgram(program);
    gl.DrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_BYTE, nullptr);
    gl.Finish();
    std::uint8_t pixel[4] = {};
    gl.ReadPixels(2, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    expectNoGLError(state, gl.GetError, label);
    expect(state, pixelNear(pixel, 0, 255, 0), label);
}

void runExpandedIndexEvictionProbe(ProbeState& state, const R5GL& gl) {
    const GLuint program = buildFlatProgram(state, gl);
    GLuint vao = 0;
    GLuint vbo = 0;
    GLuint ebo = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.GenBuffers(1, &vbo);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    const float vertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
         0.0f,  1.0f,
    };
    gl.BufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices,
                  GL_STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float),
                           nullptr);
    gl.GenBuffers(1, &ebo);
    gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
    const std::uint8_t indices[] = {0, 1, 2};
    gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices,
                  GL_STATIC_DRAW);
    drawIndexedTriangle(state, gl, program,
                        "pre-evict GL_UNSIGNED_BYTE indexed draw");

    std::uint8_t changed[] = {0, 1, 2};
    gl.BufferSubData(GL_ELEMENT_ARRAY_BUFFER, 0, sizeof(changed), changed);
    const std::uint64_t staleMutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, staleMutations == 0,
           "stale expanded-index generation skips eviction");
    std::string staleDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(staleDiag, "generationMismatchSkipped") >= 1,
           "stale generation skip counter increments");

    drawIndexedTriangle(state, gl, program,
                        "post-stale-skip indexed draw rebuilds cache");
    const std::uint64_t evictMutations =
        appglR5EvictDerivedCachesForTesting(1);
    expect(state, evictMutations == 1,
           "budget=1 expanded-index eviction mutates one record");
    std::string evictDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(evictDiag, "expandedIndexClearSuccesses") >= 1,
           "expanded-index cache was cleared");
    expect(state,
           jsonCounter(evictDiag, "lastPostExpandedIndexBuffers") <
               jsonCounter(evictDiag, "lastPreExpandedIndexBuffers"),
           "expanded-index accounting decreased after eviction");
    expect(state, jsonCounter(evictDiag, "primaryBufferReleaseAttempts") == 0,
           "no primary buffer release attempts");
    expect(state, jsonCounter(evictDiag, "hostShadowMutationAttempts") == 0,
           "no host shadow mutation attempts");

    drawIndexedTriangle(state, gl, program,
                        "post-evict expanded-index reconstruct AE=0");
    std::string rebuildDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(rebuildDiag, "expandedIndexRebuildsAfterR5Evict") >= 1,
           "expanded-index cache rebuilt after R5 eviction");

    gl.DeleteBuffers(1, &ebo);
    gl.DeleteBuffers(1, &vbo);
    gl.DeleteVertexArrays(1, &vao);
    gl.DeleteProgram(program);
}

void runLiveEvictionProbe(ProbeState& state) {
    ContextGuard context(appglCreateOffscreenContext(4, 4));
    expect(state, context.context != nullptr,
           "offscreen context created for live R5 probe");
    if (context.context == nullptr) {
        return;
    }
    appglMakeCurrent(context.context);
    R5GL gl = loadR5GL(state);
    if (state.failures != 0) {
        return;
    }
    runPrimaryTextureEvictionProbe(state, gl);
    runSamplingProxySkipProbe(state, gl);
    runForcedPressureEvictionProbe(state, gl);
    runForcedMemoryClassPolicyProbe(state, gl);
    runPendingPressureDirtyBitProbe(state, gl);
    runCriticalPressurePrimaryReliefProbe(state, gl);
    runCriticalPressureOOMLatchProbe(state, gl);
    runTextureViewEvictionProbe(state, gl);
    runExpandedIndexEvictionProbe(state, gl);

    const std::string finalDiag = diagnosticsJSON();
    expect(state,
           jsonCounter(finalDiag, "authoritativePrimaryEvictAttempts") == 0,
           "gate-wide authoritative primary eviction attempts remain zero");
    expect(state,
           jsonCounter(finalDiag, "primaryReconstructionFailures") == 0,
           "gate-wide primary reconstruction failures remain zero");
    expect(state, jsonCounter(finalDiag, "primaryBufferReleaseAttempts") == 0,
           "gate-wide primary buffer release counter remains zero");
    expect(state, jsonCounter(finalDiag, "hostShadowMutationAttempts") == 0,
           "gate-wide host-shadow mutation counter remains zero");
}

}  // namespace

int main() {
    ProbeState state;
    runClassifierProbe(state);
    runOrderingProbe(state);
    runTouchProbe(state);
    runLiveEvictionProbe(state);

    if (state.failures != 0) {
        std::cerr << state.failures << " R5 residency dry-run probe failures\n";
        return EXIT_FAILURE;
    }
    std::cout << "R5 residency dry-run probe passed\n";
    return EXIT_SUCCESS;
}
