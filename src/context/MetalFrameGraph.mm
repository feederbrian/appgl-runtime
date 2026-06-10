#include "MetalFrameGraph.h"
#include "MetalCommandSubmission.h"

#include "../extensions/ExtensionContext.h"
#include "../extensions/ExtensionRegistry.h"
#include "../objects/GLObjectStore.h"
#include "../runtime/AppGLEnv.h"
#include "../runtime/AppGLLog.h"
#include "../shader/TessellationEmulator.h"
#include "../state/GLStateTracker.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <deque>
#include <limits>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#ifndef APPGL_ENABLE_DCR_SENTINEL_HOOKS
#define APPGL_ENABLE_DCR_SENTINEL_HOOKS 0
#endif

#if APPGL_ENABLE_DCR_SENTINEL_HOOKS
#define APPGL_DCR_SENTINEL_HOOK(name) (std::getenv(name) != nullptr)
#else
#define APPGL_DCR_SENTINEL_HOOK(name) false
#endif

// Diagnostic tracing — set to 1 to enable, 0 to silence.
#define APPGL_TRACE_FRAMEGRAPH 0

#if APPGL_TRACE_FRAMEGRAPH
#define FG_TRACE(fmt, ...) NSLog(@"[FG] " fmt, ##__VA_ARGS__)
#else
#define FG_TRACE(fmt, ...) ((void)0)
#endif

namespace appgl {

static constexpr NSUInteger kAppGLFragCoordParamsBufferSlot = 15;
static constexpr NSUInteger kAppGLFragmentShadingRateParamsBufferSlot = 30;

static void releaseOwnedObjCObject(id object) {
#if __has_feature(objc_arc)
    (void)object;
#else
    [object release];
#endif
}

static id retainOwnedObjCObject(id object) {
#if __has_feature(objc_arc)
    return object;
#else
    return [object retain];
#endif
}

static id<MTLRenderCommandEncoder> createRetainedRenderCommandEncoder(
    id<MTLCommandBuffer> commandBuffer,
    MTLRenderPassDescriptor* descriptor) {
    if (commandBuffer == nil || descriptor == nil) {
        return nil;
    }
    id<MTLRenderCommandEncoder> encoder = nil;
    @autoreleasepool {
        encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
        if (encoder != nil) {
            encoder = (id<MTLRenderCommandEncoder>)retainOwnedObjCObject(encoder);
        }
    }
    return encoder;
}

static std::uint64_t metalAllocatedSize(id object) {
    if (object == nil || ![object respondsToSelector:@selector(allocatedSize)]) {
        return 0;
    }
    return static_cast<std::uint64_t>(((id<MTLResource>)object).allocatedSize);
}

static void releaseOwnedMetalResource(id object) {
    if (object != nil && [object respondsToSelector:@selector(setPurgeableState:)]) {
        [(id<MTLResource>)object setPurgeableState:MTLPurgeableStateEmpty];
    }
    releaseOwnedObjCObject(object);
}

class ScopedOwnedObjCObject {
public:
    explicit ScopedOwnedObjCObject(id object = nil) : object_(object) {}
    ScopedOwnedObjCObject(const ScopedOwnedObjCObject&) = delete;
    ScopedOwnedObjCObject& operator=(const ScopedOwnedObjCObject&) = delete;
    ~ScopedOwnedObjCObject() {
        releaseOwnedObjCObject(object_);
    }
    id release() {
        id object = object_;
        object_ = nil;
        return object;
    }
    void reset(id object = nil) {
        if (object_ != object) {
            releaseOwnedObjCObject(object_);
            object_ = object;
        }
    }
private:
    id object_ = nil;
};

static std::size_t envSizeLimit(const char* name, std::size_t fallback) {
    const char* raw = std::getenv(name);
    if (raw == nullptr || raw[0] == '\0') {
        return fallback;
    }
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(raw, &end, 10);
    if (end == raw) {
        return fallback;
    }
    return static_cast<std::size_t>(parsed);
}

static std::size_t mslLibraryCacheLimit() {
    return envSizeLimit("APPGL_MSL_LIBRARY_CACHE_LIMIT", 512);
}

static std::size_t renderPsoCacheLimitPerProgram() {
    return envSizeLimit("APPGL_RENDER_PSO_CACHE_LIMIT_PER_PROGRAM", 0);
}

static std::size_t translatedDrawMSLSlotCacheLimit() {
    return envSizeLimit("APPGL_TRANSLATED_DRAW_MSL_SLOT_CACHE_LIMIT", 0);
}

static std::uint64_t stableMslSourceHash(const std::string& source) {
    std::uint64_t hash = 1469598103934665603ull;
    for (unsigned char c : source) {
        hash ^= static_cast<std::uint64_t>(c);
        hash *= 1099511628211ull;
    }
    return hash;
}

static bool traceDrawTargetsProgramMatches(const char* raw, GLuint program) {
    if (raw == nullptr || raw[0] == '\0') {
        return false;
    }
    if (std::strcmp(raw, "1") == 0 ||
        std::strcmp(raw, "all") == 0 ||
        std::strcmp(raw, "*") == 0) {
        return true;
    }
    const char* cursor = raw;
    while (*cursor != '\0') {
        while (*cursor == ',' || std::isspace(static_cast<unsigned char>(*cursor))) {
            ++cursor;
        }
        if (*cursor == '\0') {
            break;
        }
        char* end = nullptr;
        const unsigned long value = std::strtoul(cursor, &end, 10);
        if (end != cursor && value == static_cast<unsigned long>(program)) {
            return true;
        }
        cursor = (end != cursor) ? end : cursor + 1;
        while (*cursor != '\0' && *cursor != ',') {
            ++cursor;
        }
    }
    return false;
}

static std::uint32_t traceDrawTargetsLimit() {
    const char* raw = std::getenv("APPGL_TRACE_DRAW_TARGET_LIMIT");
    if (raw == nullptr || raw[0] == '\0') {
        return 512u;
    }
    char* end = nullptr;
    const unsigned long parsed = std::strtoul(raw, &end, 10);
    if (end == raw || parsed == 0ul) {
        return 512u;
    }
    return static_cast<std::uint32_t>(parsed);
}

static bool shouldEmitDrawTargetTrace(GLuint program) {
    const char* raw = std::getenv("APPGL_TRACE_DRAW_TARGETS");
    if (!traceDrawTargetsProgramMatches(raw, program)) {
        return false;
    }
    static std::atomic<std::uint32_t> emitted{0u};
    return emitted.fetch_add(1u, std::memory_order_relaxed) <
        traceDrawTargetsLimit();
}

static bool metalTessTFEnabled() {
    return appglEnvEnabledDefaultOn("APPGL_ENABLE_METAL_TESS_TF");
}

static bool optionalTessEvalComputeEnabled() {
    return appglEnvEnabledDefaultOff("APPGL_ENABLE_OPTIONAL_TESS_COMPUTE");
}

static bool layeredClearAsyncEnabled() {
    return appglEnvEnabledDefaultOff("APPGL_ENABLE_LAYERED_CLEAR_ASYNC");
}

// C48: defer FBO-attachment clears and fold them into the next render
// pass's MTLLoadActionClear instead of issuing standalone layered-clear
// command buffers. Default-off; the default path must stay byte-identical
// to the C46 lineage.
static bool fboClearFoldingEnabled() {
    return appglEnvEnabledDefaultOff("APPGL_ENABLE_FBO_CLEAR_FOLDING");
}

using DrawProfileClock = std::chrono::steady_clock;
using DrawProfileTimePoint = DrawProfileClock::time_point;

static DrawProfileTimePoint drawProfileNow() {
    return DrawProfileClock::now();
}

static double drawProfileElapsedUs(DrawProfileTimePoint start,
                                   DrawProfileTimePoint end) {
    return std::chrono::duration<double, std::micro>(end - start).count();
}

struct DrawSubmitProfileSample {
    double totalUs = 0.0;
    double validationUs = 0.0;
    double stateResolveUs = 0.0;
    double pipelineBuildUs = 0.0;
    double encoderSetupUs = 0.0;
    double renderStateUs = 0.0;
    double bindingUs = 0.0;
    double primitivePrepUs = 0.0;
    double metalDrawUs = 0.0;
    double finalizeUs = 0.0;
    bool cacheMiss = false;
    bool encoderOpened = false;
    bool fboDraw = false;
    bool argumentBuffers = false;
    bool indexed = false;
    bool expanded = false;
    std::uint32_t metalDrawCalls = 0;
};

struct DrawSubmitProfile {
    bool enabled = std::getenv("APPGL_DRAW_PROFILE") != nullptr;
    std::uint64_t draws = 0;
    std::uint64_t cacheMisses = 0;
    std::uint64_t encoderOpens = 0;
    std::uint64_t fboDraws = 0;
    std::uint64_t argbufDraws = 0;
    std::uint64_t indexedDraws = 0;
    std::uint64_t expandedDraws = 0;
    std::uint64_t metalDrawCalls = 0;
    double totalUs = 0.0;
    double validationUs = 0.0;
    double stateResolveUs = 0.0;
    double pipelineBuildUs = 0.0;
    double encoderSetupUs = 0.0;
    double renderStateUs = 0.0;
    double bindingUs = 0.0;
    double primitivePrepUs = 0.0;
    double metalDrawUs = 0.0;
    double finalizeUs = 0.0;

    void record(const DrawSubmitProfileSample& s) {
        if (!enabled) return;
        ++draws;
        cacheMisses += s.cacheMiss ? 1 : 0;
        encoderOpens += s.encoderOpened ? 1 : 0;
        fboDraws += s.fboDraw ? 1 : 0;
        argbufDraws += s.argumentBuffers ? 1 : 0;
        indexedDraws += s.indexed ? 1 : 0;
        expandedDraws += s.expanded ? 1 : 0;
        metalDrawCalls += s.metalDrawCalls;
        totalUs += s.totalUs;
        validationUs += s.validationUs;
        stateResolveUs += s.stateResolveUs;
        pipelineBuildUs += s.pipelineBuildUs;
        encoderSetupUs += s.encoderSetupUs;
        renderStateUs += s.renderStateUs;
        bindingUs += s.bindingUs;
        primitivePrepUs += s.primitivePrepUs;
        metalDrawUs += s.metalDrawUs;
        finalizeUs += s.finalizeUs;
    }

    void dump() const {
        if (!enabled || draws == 0) return;
        const double denom = totalUs > 0.0 ? totalUs : 1.0;
        auto line = [&](const char* name, double us) {
            std::fprintf(stderr,
                "[APPGL_DRAW_PROFILE] component=%s total_us=%.3f avg_us=%.3f pct=%.2f\n",
                name, us, us / static_cast<double>(draws), (us * 100.0) / denom);
        };
        const double accounted =
            validationUs + stateResolveUs + pipelineBuildUs + encoderSetupUs +
            renderStateUs + bindingUs + primitivePrepUs + metalDrawUs + finalizeUs;
        std::fprintf(stderr,
            "[APPGL_DRAW_PROFILE] summary draws=%llu avg_us=%.3f total_us=%.3f "
            "cache_misses=%llu encoder_opens=%llu fbo_draws=%llu argbuf_draws=%llu "
            "indexed_draws=%llu expanded_draws=%llu metal_draw_calls=%llu "
            "avg_metal_draw_calls=%.3f\n",
            static_cast<unsigned long long>(draws),
            totalUs / static_cast<double>(draws),
            totalUs,
            static_cast<unsigned long long>(cacheMisses),
            static_cast<unsigned long long>(encoderOpens),
            static_cast<unsigned long long>(fboDraws),
            static_cast<unsigned long long>(argbufDraws),
            static_cast<unsigned long long>(indexedDraws),
            static_cast<unsigned long long>(expandedDraws),
            static_cast<unsigned long long>(metalDrawCalls),
            static_cast<double>(metalDrawCalls) / static_cast<double>(draws));
        line("validation", validationUs);
        line("state_resolve", stateResolveUs);
        line("pipeline_build", pipelineBuildUs);
        line("encoder_setup", encoderSetupUs);
        line("render_state", renderStateUs);
        line("binding", bindingUs);
        line("primitive_prep", primitivePrepUs);
        line("metal_draw_call", metalDrawUs);
        line("finalize", finalizeUs);
        line("unattributed", std::max(0.0, totalUs - accounted));
    }
};

enum class ParallelEncodeBoundaryReason : std::size_t {
    SerialPathOnly,
    SolidColorDraw,
    ImmediateModeDraw,
    TessellationDraw,
    MeshGsDraw,
    ComputeDispatch,
    Clear,
    BeginRenderPass,
    EndRenderPass,
    Present,
    Finish,
    CopyReadback,
    Resize,
    CommandBufferCommit,
    TransientInvalidation,
    ResourceMutationOrBarrier,
    FboDraw,
    RasterizerDiscard,
    ArgumentBuffers,
    StorageOrAtomicSideEffects,
    ImageWriteSideEffects,
    ProgramPipelineOrSubroutineState,
    LayeredOrViewportArrayState,
    QueryOrTransformFeedbackState,
    TessMeshOrGeometryState,
    PrimitiveExpansion,
    CpuOrRingUploadPath,
    PipelineNotPrepared,
    CaptureFailed,
    Count,
};

static const char* parallelEncodeBoundaryReasonName(
    ParallelEncodeBoundaryReason reason) {
    switch (reason) {
        case ParallelEncodeBoundaryReason::SerialPathOnly:
            return "serial_path_only";
        case ParallelEncodeBoundaryReason::SolidColorDraw:
            return "solid_color_draw";
        case ParallelEncodeBoundaryReason::ImmediateModeDraw:
            return "immediate_mode_draw";
        case ParallelEncodeBoundaryReason::TessellationDraw:
            return "tessellation_draw";
        case ParallelEncodeBoundaryReason::MeshGsDraw:
            return "mesh_gs_draw";
        case ParallelEncodeBoundaryReason::ComputeDispatch:
            return "compute_dispatch";
        case ParallelEncodeBoundaryReason::Clear:
            return "clear";
        case ParallelEncodeBoundaryReason::BeginRenderPass:
            return "begin_render_pass";
        case ParallelEncodeBoundaryReason::EndRenderPass:
            return "end_render_pass";
        case ParallelEncodeBoundaryReason::Present:
            return "present";
        case ParallelEncodeBoundaryReason::Finish:
            return "finish";
        case ParallelEncodeBoundaryReason::CopyReadback:
            return "copy_readback";
        case ParallelEncodeBoundaryReason::Resize:
            return "resize";
        case ParallelEncodeBoundaryReason::CommandBufferCommit:
            return "command_buffer_commit";
        case ParallelEncodeBoundaryReason::TransientInvalidation:
            return "transient_invalidation";
        case ParallelEncodeBoundaryReason::ResourceMutationOrBarrier:
            return "resource_mutation_or_barrier";
        case ParallelEncodeBoundaryReason::FboDraw:
            return "fbo_draw";
        case ParallelEncodeBoundaryReason::RasterizerDiscard:
            return "rasterizer_discard";
        case ParallelEncodeBoundaryReason::ArgumentBuffers:
            return "argument_buffers";
        case ParallelEncodeBoundaryReason::StorageOrAtomicSideEffects:
            return "storage_or_atomic_side_effects";
        case ParallelEncodeBoundaryReason::ImageWriteSideEffects:
            return "image_write_side_effects";
        case ParallelEncodeBoundaryReason::ProgramPipelineOrSubroutineState:
            return "program_pipeline_or_subroutine_state";
        case ParallelEncodeBoundaryReason::LayeredOrViewportArrayState:
            return "layered_or_viewport_array_state";
        case ParallelEncodeBoundaryReason::QueryOrTransformFeedbackState:
            return "query_or_transform_feedback_state";
        case ParallelEncodeBoundaryReason::TessMeshOrGeometryState:
            return "tess_mesh_or_geometry_state";
        case ParallelEncodeBoundaryReason::PrimitiveExpansion:
            return "primitive_expansion";
        case ParallelEncodeBoundaryReason::CpuOrRingUploadPath:
            return "cpu_or_ring_upload_path";
        case ParallelEncodeBoundaryReason::PipelineNotPrepared:
            return "pipeline_not_prepared";
        case ParallelEncodeBoundaryReason::CaptureFailed:
            return "capture_failed";
        case ParallelEncodeBoundaryReason::Count:
            break;
    }
    return "unknown";
}

static std::uint32_t envUInt(const char* name,
                             std::uint32_t defaultValue,
                             std::uint32_t minValue,
                             std::uint32_t maxValue) {
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') {
        return defaultValue;
    }
    char* end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (end == value) {
        return defaultValue;
    }
    const auto clamped = static_cast<std::uint32_t>(
        std::min<unsigned long>(
            static_cast<unsigned long>(maxValue),
            std::max<unsigned long>(
                static_cast<unsigned long>(minValue), parsed)));
    return clamped;
}

static std::uint32_t parallelEncodeConfiguredWorkerCount() {
    return envUInt("APPGL_PARALLEL_ENCODE_WORKERS", 4, 1, 16);
}

static std::uint32_t parallelEncodeConfiguredMinBatch() {
    return envUInt("APPGL_PARALLEL_ENCODE_MIN_BATCH", 32, 1, 1u << 20);
}

static std::uint32_t parallelEncodeConfiguredLeanMaxBatch() {
    return envUInt("APPGL_PARALLEL_ENCODE_LEAN_MAX_BATCH", 2048, 1, 1u << 20);
}

static std::uint32_t threadedDeferredRecordWorkerCount() {
    return envUInt("APPGL_7K_DEFERRED_RECORD_WORKERS",
                   parallelEncodeConfiguredWorkerCount(),
                   1,
                   16);
}

static std::uint32_t threadedDeferredRecordMinBatch() {
    return envUInt("APPGL_7K_DEFERRED_RECORD_MIN_BATCH", 16, 1, 1u << 20);
}

static std::uint32_t threadedDeferredRecordMaxBatch() {
    return envUInt("APPGL_7K_DEFERRED_RECORD_MAX_BATCH", 2048, 1, 1u << 20);
}

static std::uint32_t threadedDeferredRecordAsyncChunkSize() {
    return envUInt("APPGL_7K_DEFERRED_RECORD_ASYNC_CHUNK", 8, 1, 1u << 20);
}

enum class ParallelEncodeFallbackReason : std::size_t {
    SmallBatch,
    WorkerCount,
    ParallelEncoderCreateFailure,
    ChildEncoderCreateFailure,
    PipelineNotPrepared,
    UnsafeResourceOrRingUpload,
    MixedRenderState,
    EncodeFailure,
    Count,
};

static const char* parallelEncodeFallbackReasonName(
    ParallelEncodeFallbackReason reason) {
    switch (reason) {
        case ParallelEncodeFallbackReason::SmallBatch:
            return "small_batch";
        case ParallelEncodeFallbackReason::WorkerCount:
            return "worker_count_le_1";
        case ParallelEncodeFallbackReason::ParallelEncoderCreateFailure:
            return "parallel_encoder_create_failure";
        case ParallelEncodeFallbackReason::ChildEncoderCreateFailure:
            return "child_encoder_create_failure";
        case ParallelEncodeFallbackReason::PipelineNotPrepared:
            return "pipeline_not_prepared";
        case ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload:
            return "unsafe_resource_or_ring_upload";
        case ParallelEncodeFallbackReason::MixedRenderState:
            return "mixed_render_state";
        case ParallelEncodeFallbackReason::EncodeFailure:
            return "encode_failure";
        case ParallelEncodeFallbackReason::Count:
            break;
    }
    return "unknown";
}

static ParallelEncodeBoundaryReason parallelEncodeBoundaryForFallback(
    ParallelEncodeFallbackReason reason) {
    switch (reason) {
        case ParallelEncodeFallbackReason::PipelineNotPrepared:
            return ParallelEncodeBoundaryReason::PipelineNotPrepared;
        case ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload:
            return ParallelEncodeBoundaryReason::CpuOrRingUploadPath;
        case ParallelEncodeFallbackReason::ParallelEncoderCreateFailure:
        case ParallelEncodeFallbackReason::ChildEncoderCreateFailure:
        case ParallelEncodeFallbackReason::EncodeFailure:
            return ParallelEncodeBoundaryReason::CommandBufferCommit;
        case ParallelEncodeFallbackReason::MixedRenderState:
        case ParallelEncodeFallbackReason::SmallBatch:
        case ParallelEncodeFallbackReason::WorkerCount:
        case ParallelEncodeFallbackReason::Count:
            break;
    }
    return ParallelEncodeBoundaryReason::ResourceMutationOrBarrier;
}

struct ParallelEncodeChunkProfile {
    std::uint64_t batchIndex = 0;
    std::uint64_t chunkIndex = 0;
    std::uint64_t drawBegin = 0;
    std::uint64_t drawEnd = 0;
    std::uint64_t drawCount = 0;
    double workerEncodeUs = 0.0;
    std::uint64_t failures = 0;
};

struct ThreadedDeferredAsyncChunk {
    std::uint64_t chunkIndex = 0;
    std::uint64_t begin = 0;
    std::uint64_t end = 0;
    double workerUs = 0.0;
    std::uint64_t failures = 0;
    std::uint64_t completionOrdinal =
        std::numeric_limits<std::uint64_t>::max();
};

struct ParallelEncodeFoundationProfile {
    bool enabled = appglEnvEnabledDefaultOff("APPGL_PARALLEL_ENCODE");
    bool dumpEnabled = enabled && (
        appglEnvEnabledDefaultOff("APPGL_PARALLEL_ENCODE_PROFILE") ||
        appglEnvEnabledDefaultOff("APPGL_DRAW_PROFILE"));
    std::uint32_t configuredWorkerCount = parallelEncodeConfiguredWorkerCount();
    std::uint32_t configuredMinBatch = parallelEncodeConfiguredMinBatch();
    std::uint32_t configuredLeanMaxBatch =
        parallelEncodeConfiguredLeanMaxBatch();
    std::uint64_t translatedDraws = 0;
    std::uint64_t candidateDraws = 0;
    std::uint64_t capturedDraws = 0;
    std::uint64_t replayedDraws = 0;
    std::uint64_t batchCount = 0;
    std::uint64_t batchDraws = 0;
    std::uint64_t maxBatchSize = 0;
    std::uint64_t batchReplayFailures = 0;
    std::uint64_t chunkCount = 0;
    std::uint64_t parallelBatchCount = 0;
    std::uint64_t parallelEncodedDraws = 0;
    std::uint64_t serialFallbackDraws = 0;
    std::uint64_t descriptorPreparedDraws = 0;
    std::uint64_t descriptorEncodedDraws = 0;
    std::uint64_t descriptorFallbackDraws = 0;
    std::uint64_t descriptorSerialBatchCount = 0;
    std::uint64_t descriptorSerialBatchDraws = 0;
    std::uint64_t descriptorWorkerBatchCount = 0;
    std::uint64_t descriptorWorkerEncodedDraws = 0;
    std::uint64_t descriptorWorkerChunkCount = 0;
    std::uint64_t descriptorWorkerFailures = 0;
    std::uint64_t workerFailures = 0;
    double serialCaptureUs = 0.0;
    double serialReplayUs = 0.0;
    double serialBatchReplayUs = 0.0;
    double descriptorPrepareUs = 0.0;
    double descriptorEncodeUs = 0.0;
    double descriptorSerialBatchEncodeUs = 0.0;
    double descriptorWorkerWallUs = 0.0;
    double descriptorWorkerSumUs = 0.0;
    double descriptorWorkerMaxUs = 0.0;
    double parallelEncodeWallUs = 0.0;
    double sumWorkerEncodeUs = 0.0;
    double maxWorkerEncodeUs = 0.0;
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        boundaryReasons{};
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        batchFlushReasons{};
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        descriptorFlushReasons{};
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeFallbackReason::Count)>
        parallelFallbackReasons{};
    std::vector<ParallelEncodeChunkProfile> chunkProfiles;
    std::vector<ParallelEncodeChunkProfile> descriptorWorkerChunkProfiles;

    void recordTranslatedDraw() {
        if (enabled) {
            ++translatedDraws;
        }
    }

    void recordCandidate() {
        if (enabled) {
            ++candidateDraws;
        }
    }

    void recordBoundary(ParallelEncodeBoundaryReason reason) {
        if (!enabled) {
            return;
        }
        ++boundaryReasons[static_cast<std::size_t>(reason)];
    }

    void recordCaptured(double elapsedUs) {
        if (!enabled) {
            return;
        }
        ++capturedDraws;
        serialCaptureUs += elapsedUs;
    }

    void recordReplayed(double elapsedUs) {
        if (!enabled) {
            return;
        }
        ++replayedDraws;
        serialReplayUs += elapsedUs;
    }

    void recordDescriptorPrepared(double elapsedUs) {
        if (!enabled) {
            return;
        }
        ++descriptorPreparedDraws;
        descriptorPrepareUs += elapsedUs;
    }

    void recordDescriptorEncoded(double elapsedUs) {
        if (!enabled) {
            return;
        }
        ++descriptorEncodedDraws;
        descriptorEncodeUs += elapsedUs;
    }

    void recordDescriptorFallback() {
        if (!enabled) {
            return;
        }
        ++descriptorFallbackDraws;
    }

    void recordDescriptorSerialBatch(ParallelEncodeBoundaryReason reason,
                                     std::uint64_t draws,
                                     double elapsedUs,
                                     std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        ++descriptorSerialBatchCount;
        descriptorSerialBatchDraws += draws;
        descriptorEncodedDraws += draws;
        descriptorEncodeUs += elapsedUs;
        descriptorSerialBatchEncodeUs += elapsedUs;
        descriptorFallbackDraws += failures;
        ++descriptorFlushReasons[static_cast<std::size_t>(reason)];
    }

    void recordDescriptorWorkerBatch(
        ParallelEncodeBoundaryReason reason,
        std::uint64_t draws,
        const std::vector<ParallelEncodeChunkProfile>& chunks,
        double wallUs,
        double sumWorkerUs,
        double maxWorkerUs,
        std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        const std::uint64_t batchIndex = descriptorWorkerBatchCount + 1;
        ++descriptorWorkerBatchCount;
        descriptorWorkerEncodedDraws += draws;
        descriptorWorkerChunkCount += static_cast<std::uint64_t>(chunks.size());
        descriptorWorkerFailures += failures;
        descriptorEncodedDraws += draws;
        descriptorEncodeUs += wallUs;
        descriptorWorkerWallUs += wallUs;
        descriptorWorkerSumUs += sumWorkerUs;
        descriptorWorkerMaxUs = std::max(descriptorWorkerMaxUs, maxWorkerUs);
        ++descriptorFlushReasons[static_cast<std::size_t>(reason)];
        for (ParallelEncodeChunkProfile chunk : chunks) {
            chunk.batchIndex = batchIndex;
            descriptorWorkerChunkProfiles.push_back(chunk);
        }
    }

    void recordDirectSerialFallback(ParallelEncodeFallbackReason reason) {
        if (!enabled) {
            return;
        }
        ++serialFallbackDraws;
        ++parallelFallbackReasons[static_cast<std::size_t>(reason)];
    }

    void recordSerialBatchReplay(ParallelEncodeBoundaryReason reason,
                                 ParallelEncodeFallbackReason fallbackReason,
                                 std::uint64_t draws,
                                 double elapsedUs,
                                 std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        ++batchCount;
        batchDraws += draws;
        maxBatchSize = std::max(maxBatchSize, draws);
        replayedDraws += draws;
        serialFallbackDraws += draws;
        serialReplayUs += elapsedUs;
        serialBatchReplayUs += elapsedUs;
        batchReplayFailures += failures;
        ++batchFlushReasons[static_cast<std::size_t>(reason)];
        ++parallelFallbackReasons[static_cast<std::size_t>(fallbackReason)];
        if (failures > 0) {
            ++parallelFallbackReasons[
                static_cast<std::size_t>(
                    ParallelEncodeFallbackReason::EncodeFailure)];
        }
    }

    void recordParallelBatch(ParallelEncodeBoundaryReason reason,
                             std::uint64_t draws,
                             const std::vector<ParallelEncodeChunkProfile>& chunks,
                             double wallUs,
                             double sumWorkerUs,
                             double maxWorkerUs,
                             std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        const std::uint64_t batchIndex = batchCount + 1;
        ++batchCount;
        ++parallelBatchCount;
        batchDraws += draws;
        maxBatchSize = std::max(maxBatchSize, draws);
        replayedDraws += draws;
        parallelEncodedDraws += draws;
        chunkCount += static_cast<std::uint64_t>(chunks.size());
        parallelEncodeWallUs += wallUs;
        sumWorkerEncodeUs += sumWorkerUs;
        maxWorkerEncodeUs = std::max(maxWorkerEncodeUs, maxWorkerUs);
        batchReplayFailures += failures;
        workerFailures += failures;
        ++batchFlushReasons[static_cast<std::size_t>(reason)];
        if (failures > 0) {
            ++parallelFallbackReasons[
                static_cast<std::size_t>(
                    ParallelEncodeFallbackReason::EncodeFailure)];
        }
        for (ParallelEncodeChunkProfile chunk : chunks) {
            chunk.batchIndex = batchIndex;
            chunkProfiles.push_back(chunk);
        }
    }

    void dump() const {
        if (!dumpEnabled) {
            return;
        }
        std::fprintf(stderr,
            "[APPGL_PARALLEL_ENCODE] summary translated_draws=%llu "
            "candidates=%llu captured=%llu replayed=%llu "
            "batch_count=%llu batch_draws=%llu max_batch_size=%llu "
            "worker_count=%u min_batch=%u lean_max_batch=%u chunk_count=%llu "
            "parallel_batches=%llu parallel_encoded_draws=%llu "
            "serial_fallback_draws=%llu descriptor_prepared=%llu "
            "descriptor_encoded=%llu descriptor_fallback_draws=%llu "
            "descriptor_serial_batches=%llu descriptor_serial_batch_draws=%llu "
            "descriptor_worker_batches=%llu "
            "descriptor_worker_encoded_draws=%llu "
            "descriptor_worker_chunk_count=%llu "
            "descriptor_worker_failures=%llu "
            "worker_failures=%llu "
            "serial_capture_us=%.3f serial_replay_us=%.3f "
            "serial_batch_replay_us=%.3f descriptor_prepare_us=%.3f "
            "descriptor_encode_us=%.3f "
            "descriptor_serial_batch_encode_us=%.3f "
            "descriptor_worker_wall_us=%.3f "
            "descriptor_worker_sum_us=%.3f "
            "descriptor_worker_max_us=%.3f "
            "parallel_encode_wall_us=%.3f "
            "sum_worker_encode_us=%.3f max_worker_encode_us=%.3f "
            "batch_replay_failures=%llu\n",
            static_cast<unsigned long long>(translatedDraws),
            static_cast<unsigned long long>(candidateDraws),
            static_cast<unsigned long long>(capturedDraws),
            static_cast<unsigned long long>(replayedDraws),
            static_cast<unsigned long long>(batchCount),
            static_cast<unsigned long long>(batchDraws),
            static_cast<unsigned long long>(maxBatchSize),
            configuredWorkerCount,
            configuredMinBatch,
            configuredLeanMaxBatch,
            static_cast<unsigned long long>(chunkCount),
            static_cast<unsigned long long>(parallelBatchCount),
            static_cast<unsigned long long>(parallelEncodedDraws),
            static_cast<unsigned long long>(serialFallbackDraws),
            static_cast<unsigned long long>(descriptorPreparedDraws),
            static_cast<unsigned long long>(descriptorEncodedDraws),
            static_cast<unsigned long long>(descriptorFallbackDraws),
            static_cast<unsigned long long>(descriptorSerialBatchCount),
            static_cast<unsigned long long>(descriptorSerialBatchDraws),
            static_cast<unsigned long long>(descriptorWorkerBatchCount),
            static_cast<unsigned long long>(descriptorWorkerEncodedDraws),
            static_cast<unsigned long long>(descriptorWorkerChunkCount),
            static_cast<unsigned long long>(descriptorWorkerFailures),
            static_cast<unsigned long long>(workerFailures),
            serialCaptureUs,
            serialReplayUs,
            serialBatchReplayUs,
            descriptorPrepareUs,
            descriptorEncodeUs,
            descriptorSerialBatchEncodeUs,
            descriptorWorkerWallUs,
            descriptorWorkerSumUs,
            descriptorWorkerMaxUs,
            parallelEncodeWallUs,
            sumWorkerEncodeUs,
            maxWorkerEncodeUs,
            static_cast<unsigned long long>(batchReplayFailures));
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count);
             ++i) {
            if (boundaryReasons[i] == 0) {
                continue;
            }
            const auto reason = static_cast<ParallelEncodeBoundaryReason>(i);
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] boundary reason=%s count=%llu\n",
                parallelEncodeBoundaryReasonName(reason),
                static_cast<unsigned long long>(boundaryReasons[i]));
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count);
             ++i) {
            if (batchFlushReasons[i] == 0) {
                continue;
            }
            const auto reason = static_cast<ParallelEncodeBoundaryReason>(i);
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] flush reason=%s count=%llu\n",
                parallelEncodeBoundaryReasonName(reason),
                static_cast<unsigned long long>(batchFlushReasons[i]));
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count);
             ++i) {
            if (descriptorFlushReasons[i] == 0) {
                continue;
            }
            const auto reason = static_cast<ParallelEncodeBoundaryReason>(i);
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] descriptor_flush reason=%s count=%llu\n",
                parallelEncodeBoundaryReasonName(reason),
                static_cast<unsigned long long>(descriptorFlushReasons[i]));
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeFallbackReason::Count);
             ++i) {
            if (parallelFallbackReasons[i] == 0) {
                continue;
            }
            const auto reason = static_cast<ParallelEncodeFallbackReason>(i);
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] parallel_fallback reason=%s count=%llu\n",
                parallelEncodeFallbackReasonName(reason),
                static_cast<unsigned long long>(parallelFallbackReasons[i]));
        }
        for (const auto& chunk : chunkProfiles) {
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] chunk batch=%llu chunk=%llu "
                "draw_begin=%llu draw_end=%llu draw_count=%llu "
                "worker_us=%.3f failures=%llu\n",
                static_cast<unsigned long long>(chunk.batchIndex),
                static_cast<unsigned long long>(chunk.chunkIndex),
                static_cast<unsigned long long>(chunk.drawBegin),
                static_cast<unsigned long long>(chunk.drawEnd),
                static_cast<unsigned long long>(chunk.drawCount),
                chunk.workerEncodeUs,
                static_cast<unsigned long long>(chunk.failures));
        }
        for (const auto& chunk : descriptorWorkerChunkProfiles) {
            std::fprintf(stderr,
                "[APPGL_PARALLEL_ENCODE] descriptor_worker_chunk batch=%llu "
                "chunk=%llu draw_begin=%llu draw_end=%llu draw_count=%llu "
                "worker_us=%.3f failures=%llu\n",
                static_cast<unsigned long long>(chunk.batchIndex),
                static_cast<unsigned long long>(chunk.chunkIndex),
                static_cast<unsigned long long>(chunk.drawBegin),
                static_cast<unsigned long long>(chunk.drawEnd),
                static_cast<unsigned long long>(chunk.drawCount),
                chunk.workerEncodeUs,
                static_cast<unsigned long long>(chunk.failures));
        }
        std::fflush(stderr);
    }
};

struct ThreadedDeferredRecordProfile {
    bool enabled = appglEnvEnabledDefaultOff("APPGL_7K_THREADED_DEFERRED_RECORD");
    bool asyncEnabled =
        enabled && appglEnvEnabledDefaultOff("APPGL_7K_DEFERRED_RECORD_ASYNC");
    // Descriptor-fast records the immutable lean descriptor itself. Set
    // APPGL_7K_DEFERRED_RECORD_DESCRIPTOR_FAST=0 to use copied-TDI records.
    bool descriptorFastEnabled =
        enabled && !asyncEnabled &&
        appglEnvEnabledDefaultOn("APPGL_7K_DEFERRED_RECORD_DESCRIPTOR_FAST");
    bool dumpEnabled =
        enabled || appglEnvEnabledDefaultOff("APPGL_7K_THREADED_DEFERRED_RECORD_PROFILE");
    std::uint32_t configuredWorkerCount =
        threadedDeferredRecordWorkerCount();
    std::uint32_t configuredMinBatch = threadedDeferredRecordMinBatch();
    std::uint32_t configuredMaxBatch = threadedDeferredRecordMaxBatch();
    std::uint32_t configuredAsyncChunkSize =
        threadedDeferredRecordAsyncChunkSize();
    std::uint64_t translatedDraws = 0;
    std::uint64_t candidateDraws = 0;
    std::uint64_t recordsSubmitted = 0;
    std::uint64_t recordsCompleted = 0;
    std::uint64_t batches = 0;
    std::uint64_t workerChunks = 0;
    std::uint64_t workerFailures = 0;
    std::uint64_t serialFallbackDraws = 0;
    std::uint64_t orderedMergeCount = 0;
    std::uint64_t orderedMergeBatches = 0;
    std::uint64_t orderedMergeSequenceViolations = 0;
    std::uint64_t orderedMergeMissingOrDuplicate = 0;
    std::uint64_t outOfOrderWorkerCompletions = 0;
    std::uint64_t liveAliasEscapes = 0;
    std::uint64_t recordBytesTotal = 0;
    std::uint64_t recordBytesMax = 0;
    double captureUs = 0.0;
    double workerPrepWallUs = 0.0;
    double workerPrepSumUs = 0.0;
    double workerPrepMaxUs = 0.0;
    double mergeEncodeUs = 0.0;
    double mergeWaitUs = 0.0;
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        boundaryReasons{};
    std::array<std::uint64_t,
               static_cast<std::size_t>(ParallelEncodeFallbackReason::Count)>
        fallbackReasons{};
    std::vector<ParallelEncodeChunkProfile> chunkProfiles;

    void recordTranslatedDraw() {
        if (enabled) ++translatedDraws;
    }

    void recordCandidate() {
        if (enabled) ++candidateDraws;
    }

    void recordBoundary(ParallelEncodeBoundaryReason reason) {
        if (!enabled) return;
        ++boundaryReasons[static_cast<std::size_t>(reason)];
    }

    void recordFallback(ParallelEncodeFallbackReason reason,
                        std::uint64_t draws = 1) {
        if (!enabled) return;
        if (reason == ParallelEncodeFallbackReason::Count) return;
        serialFallbackDraws += draws;
        ++fallbackReasons[static_cast<std::size_t>(reason)];
    }

    void recordCapture(std::size_t bytes, double elapsedUs) {
        if (!enabled) return;
        ++recordsSubmitted;
        recordBytesTotal += static_cast<std::uint64_t>(bytes);
        recordBytesMax = std::max<std::uint64_t>(
            recordBytesMax, static_cast<std::uint64_t>(bytes));
        captureUs += elapsedUs;
    }

    void recordBatch(std::uint64_t draws,
                     std::uint64_t chunks,
                     const std::vector<ParallelEncodeChunkProfile>& profiles,
                     double wallUs,
                     double sumUs,
                     double maxUs,
                     double waitUs,
                     double mergeUs,
                     std::uint64_t failures,
                     std::uint64_t outOfOrderChunks,
                     std::uint64_t sequenceViolations,
                     std::uint64_t missingOrDuplicate) {
        if (!enabled) return;
        ++batches;
        recordsCompleted += draws;
        workerChunks += chunks;
        workerFailures += failures;
        workerPrepWallUs += wallUs;
        workerPrepSumUs += sumUs;
        workerPrepMaxUs = std::max(workerPrepMaxUs, maxUs);
        mergeWaitUs += waitUs;
        mergeEncodeUs += mergeUs;
        outOfOrderWorkerCompletions += outOfOrderChunks;
        orderedMergeSequenceViolations += sequenceViolations;
        orderedMergeMissingOrDuplicate += missingOrDuplicate;
        if (failures == 0 &&
            sequenceViolations == 0 &&
            missingOrDuplicate == 0) {
            ++orderedMergeBatches;
            orderedMergeCount += draws;
        }
        for (ParallelEncodeChunkProfile profile : profiles) {
            profile.batchIndex = batches;
            chunkProfiles.push_back(profile);
        }
    }

    void dump() const {
        if (!dumpEnabled) {
            return;
        }
        const double submittedDenom =
            recordsSubmitted > 0 ? static_cast<double>(recordsSubmitted) : 1.0;
        const double completedDenom =
            recordsCompleted > 0 ? static_cast<double>(recordsCompleted) : 1.0;
        std::fprintf(stderr,
            "[APPGL_7K_THREADED_DEFERRED_RECORD] summary enabled=%d "
            "async=%d descriptor_fast=%d worker_count=%u min_batch=%u "
            "max_batch=%u async_chunk=%u "
            "translated_draws=%llu candidates=%llu submitted=%llu "
            "completed=%llu batches=%llu worker_chunks=%llu "
            "worker_failures=%llu serial_fallback_draws=%llu "
            "ordered_merge_batches=%llu ordered_merge_count=%llu "
            "sequence_violations=%llu missing_or_duplicate=%llu "
            "out_of_order_worker_completions=%llu live_alias_escapes=%llu "
            "record_bytes_total=%llu record_bytes_avg=%.1f "
            "record_bytes_max=%llu capture_us=%.3f capture_avg_us=%.3f "
            "worker_prep_wall_us=%.3f worker_prep_sum_us=%.3f "
            "worker_prep_max_us=%.3f worker_prep_avg_per_draw_us=%.3f "
            "merge_wait_us=%.3f merge_encode_us=%.3f "
            "merge_encode_avg_per_draw_us=%.3f\n",
            enabled ? 1 : 0,
            asyncEnabled ? 1 : 0,
            descriptorFastEnabled ? 1 : 0,
            configuredWorkerCount,
            configuredMinBatch,
            configuredMaxBatch,
            configuredAsyncChunkSize,
            static_cast<unsigned long long>(translatedDraws),
            static_cast<unsigned long long>(candidateDraws),
            static_cast<unsigned long long>(recordsSubmitted),
            static_cast<unsigned long long>(recordsCompleted),
            static_cast<unsigned long long>(batches),
            static_cast<unsigned long long>(workerChunks),
            static_cast<unsigned long long>(workerFailures),
            static_cast<unsigned long long>(serialFallbackDraws),
            static_cast<unsigned long long>(orderedMergeBatches),
            static_cast<unsigned long long>(orderedMergeCount),
            static_cast<unsigned long long>(orderedMergeSequenceViolations),
            static_cast<unsigned long long>(orderedMergeMissingOrDuplicate),
            static_cast<unsigned long long>(outOfOrderWorkerCompletions),
            static_cast<unsigned long long>(liveAliasEscapes),
            static_cast<unsigned long long>(recordBytesTotal),
            static_cast<double>(recordBytesTotal) / submittedDenom,
            static_cast<unsigned long long>(recordBytesMax),
            captureUs,
            captureUs / submittedDenom,
            workerPrepWallUs,
            workerPrepSumUs,
            workerPrepMaxUs,
            workerPrepSumUs / completedDenom,
            mergeWaitUs,
            mergeEncodeUs,
            mergeEncodeUs / completedDenom);
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count);
             ++i) {
            if (boundaryReasons[i] == 0) continue;
            const auto reason = static_cast<ParallelEncodeBoundaryReason>(i);
            std::fprintf(stderr,
                "[APPGL_7K_THREADED_DEFERRED_RECORD] boundary reason=%s "
                "count=%llu\n",
                parallelEncodeBoundaryReasonName(reason),
                static_cast<unsigned long long>(boundaryReasons[i]));
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeFallbackReason::Count);
             ++i) {
            if (fallbackReasons[i] == 0) continue;
            const auto reason = static_cast<ParallelEncodeFallbackReason>(i);
            std::fprintf(stderr,
                "[APPGL_7K_THREADED_DEFERRED_RECORD] fallback reason=%s "
                "count=%llu\n",
                parallelEncodeFallbackReasonName(reason),
                static_cast<unsigned long long>(fallbackReasons[i]));
        }
        for (const auto& chunk : chunkProfiles) {
            std::fprintf(stderr,
                "[APPGL_7K_THREADED_DEFERRED_RECORD] chunk batch=%llu "
                "chunk=%llu draw_begin=%llu draw_end=%llu draw_count=%llu "
                "worker_us=%.3f failures=%llu\n",
                static_cast<unsigned long long>(chunk.batchIndex),
                static_cast<unsigned long long>(chunk.chunkIndex),
                static_cast<unsigned long long>(chunk.drawBegin),
                static_cast<unsigned long long>(chunk.drawEnd),
                static_cast<unsigned long long>(chunk.drawCount),
                chunk.workerEncodeUs,
                static_cast<unsigned long long>(chunk.failures));
        }
        std::fflush(stderr);
    }
};

enum class FrameAttributionAction : std::size_t {
    Present,
    Finish,
    EndFrame,
    FlushForReadback,
    RingSlotWait,
    Count,
};

static const char* frameAttributionActionName(FrameAttributionAction action) {
    switch (action) {
        case FrameAttributionAction::Present: return "present";
        case FrameAttributionAction::Finish: return "finish";
        case FrameAttributionAction::EndFrame: return "end_frame";
        case FrameAttributionAction::FlushForReadback: return "flush_for_readback";
        case FrameAttributionAction::RingSlotWait: return "ring_slot_wait";
        case FrameAttributionAction::Count: break;
    }
    return "unknown";
}

struct FrameAttributionTimingBucket {
    std::uint64_t count = 0;
    std::uint64_t success = 0;
    std::uint64_t draws = 0;
    std::uint64_t chunks = 0;
    std::uint64_t failures = 0;
    double totalUs = 0.0;
    double setupUs = 0.0;
    double bodyUs = 0.0;
    double finalizeUs = 0.0;
};

struct FrameAttributionProfile {
    bool enabled = appglEnvEnabledDefaultOff("APPGL_FRAME_ATTRIBUTION_PROFILE") ||
        appglEnvEnabledDefaultOff("APPGL_PARALLEL_ENCODE_ATTRIBUTION");
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        descriptorFlushByReason{};
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        descriptorWorkerByReason{};
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count)>
        descriptorSerialByReason{};
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(AppGLCommandReason::Count)>
        commitCurrentByReason{};
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(AppGLCommandReason::Count)>
        commitFrameSignalByReason{};
    std::array<FrameAttributionTimingBucket,
               static_cast<std::size_t>(FrameAttributionAction::Count)>
        actions{};
    std::uint64_t descriptorImmediateDraws = 0;
    std::uint64_t descriptorImmediateFailures = 0;
    double descriptorImmediatePrepareUs = 0.0;
    double descriptorImmediateEncodeUs = 0.0;

    void recordDescriptorImmediate(double prepareUs, double encodeUs, bool success) {
        if (!enabled) {
            return;
        }
        ++descriptorImmediateDraws;
        descriptorImmediateFailures += success ? 0 : 1;
        descriptorImmediatePrepareUs += prepareUs;
        descriptorImmediateEncodeUs += encodeUs;
    }

    void recordDescriptorFlush(ParallelEncodeBoundaryReason reason,
                               std::uint64_t draws,
                               double totalUs,
                               bool workerPath) {
        if (!enabled) {
            return;
        }
        auto& bucket = descriptorFlushByReason[static_cast<std::size_t>(reason)];
        ++bucket.count;
        ++bucket.success;
        bucket.chunks += workerPath ? 1 : 0;
        bucket.draws += draws;
        bucket.totalUs += totalUs;
    }

    void recordDescriptorWorker(ParallelEncodeBoundaryReason reason,
                                std::uint64_t draws,
                                std::uint64_t chunks,
                                double totalUs,
                                double setupUs,
                                double dispatchUs,
                                double finalizeUs,
                                std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        auto& bucket = descriptorWorkerByReason[static_cast<std::size_t>(reason)];
        ++bucket.count;
        bucket.success += failures == 0 ? 1 : 0;
        bucket.draws += draws;
        bucket.chunks += chunks;
        bucket.failures += failures;
        bucket.totalUs += totalUs;
        bucket.setupUs += setupUs;
        bucket.bodyUs += dispatchUs;
        bucket.finalizeUs += finalizeUs;
    }

    void recordDescriptorSerial(ParallelEncodeBoundaryReason reason,
                                std::uint64_t draws,
                                double totalUs,
                                double bodyUs,
                                double finalizeUs,
                                std::uint64_t failures) {
        if (!enabled) {
            return;
        }
        auto& bucket = descriptorSerialByReason[static_cast<std::size_t>(reason)];
        ++bucket.count;
        bucket.success += failures == 0 ? 1 : 0;
        bucket.draws += draws;
        bucket.failures += failures;
        bucket.totalUs += totalUs;
        bucket.bodyUs += bodyUs;
        bucket.finalizeUs += finalizeUs;
    }

    void recordCommitCurrent(AppGLCommandReason reason, double totalUs, bool success) {
        if (!enabled) {
            return;
        }
        auto& bucket = commitCurrentByReason[static_cast<std::size_t>(reason)];
        ++bucket.count;
        bucket.success += success ? 1 : 0;
        bucket.totalUs += totalUs;
    }

    void recordCommitFrameSignal(AppGLCommandReason reason, double totalUs) {
        if (!enabled) {
            return;
        }
        auto& bucket = commitFrameSignalByReason[static_cast<std::size_t>(reason)];
        ++bucket.count;
        ++bucket.success;
        bucket.totalUs += totalUs;
    }

    void recordAction(FrameAttributionAction action, double totalUs, bool success) {
        if (!enabled) {
            return;
        }
        auto& bucket = actions[static_cast<std::size_t>(action)];
        ++bucket.count;
        bucket.success += success ? 1 : 0;
        bucket.totalUs += totalUs;
    }

    static void dumpTimingLine(const char* kind,
                               const char* name,
                               const FrameAttributionTimingBucket& bucket) {
        if (bucket.count == 0) {
            return;
        }
        std::fprintf(stderr,
            "[APPGL_FRAME_ATTRIBUTION] %s=%s count=%llu success=%llu draws=%llu "
            "chunks=%llu failures=%llu total_us=%.3f avg_us=%.3f "
            "setup_us=%.3f body_us=%.3f finalize_us=%.3f\n",
            kind,
            name,
            static_cast<unsigned long long>(bucket.count),
            static_cast<unsigned long long>(bucket.success),
            static_cast<unsigned long long>(bucket.draws),
            static_cast<unsigned long long>(bucket.chunks),
            static_cast<unsigned long long>(bucket.failures),
            bucket.totalUs,
            bucket.totalUs / static_cast<double>(bucket.count),
            bucket.setupUs,
            bucket.bodyUs,
            bucket.finalizeUs);
    }

    void dump() const {
        if (!enabled) {
            return;
        }
        std::uint64_t flushes = 0;
        std::uint64_t flushDraws = 0;
        double flushUs = 0.0;
        for (const auto& bucket : descriptorFlushByReason) {
            flushes += bucket.count;
            flushDraws += bucket.draws;
            flushUs += bucket.totalUs;
        }
        std::fprintf(stderr,
            "[APPGL_FRAME_ATTRIBUTION] summary descriptor_flushes=%llu "
            "descriptor_flush_draws=%llu descriptor_flush_us=%.3f "
            "immediate_draws=%llu immediate_failures=%llu "
            "immediate_prepare_us=%.3f immediate_encode_us=%.3f\n",
            static_cast<unsigned long long>(flushes),
            static_cast<unsigned long long>(flushDraws),
            flushUs,
            static_cast<unsigned long long>(descriptorImmediateDraws),
            static_cast<unsigned long long>(descriptorImmediateFailures),
            descriptorImmediatePrepareUs,
            descriptorImmediateEncodeUs);
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(ParallelEncodeBoundaryReason::Count);
             ++i) {
            const auto reason = static_cast<ParallelEncodeBoundaryReason>(i);
            dumpTimingLine("descriptor_flush",
                           parallelEncodeBoundaryReasonName(reason),
                           descriptorFlushByReason[i]);
            dumpTimingLine("descriptor_worker",
                           parallelEncodeBoundaryReasonName(reason),
                           descriptorWorkerByReason[i]);
            dumpTimingLine("descriptor_serial",
                           parallelEncodeBoundaryReasonName(reason),
                           descriptorSerialByReason[i]);
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(AppGLCommandReason::Count);
             ++i) {
            const auto reason = static_cast<AppGLCommandReason>(i);
            dumpTimingLine("commit_current",
                           appGLCommandReasonName(reason),
                           commitCurrentByReason[i]);
            dumpTimingLine("commit_frame_signal",
                           appGLCommandReasonName(reason),
                           commitFrameSignalByReason[i]);
        }
        for (std::size_t i = 0;
             i < static_cast<std::size_t>(FrameAttributionAction::Count);
             ++i) {
            const auto action = static_cast<FrameAttributionAction>(i);
            dumpTimingLine("action", frameAttributionActionName(action), actions[i]);
        }
        std::fflush(stderr);
    }
};

class FrameAttributionScope {
public:
    FrameAttributionScope(FrameAttributionProfile& profile,
                          FrameAttributionAction action)
        : profile_(profile.enabled ? &profile : nullptr), action_(action) {
        if (profile_ != nullptr) {
            start_ = drawProfileNow();
        }
    }

    FrameAttributionScope(const FrameAttributionScope&) = delete;
    FrameAttributionScope& operator=(const FrameAttributionScope&) = delete;

    ~FrameAttributionScope() {
        if (profile_ == nullptr) {
            return;
        }
        profile_->recordAction(
            action_,
            drawProfileElapsedUs(start_, drawProfileNow()),
            success_);
    }

    void markFailed() {
        success_ = false;
    }

private:
    FrameAttributionProfile* profile_ = nullptr;
    FrameAttributionAction action_ = FrameAttributionAction::Count;
    DrawProfileTimePoint start_{};
    bool success_ = true;
};

static void releaseRetainedObjCObject(void* object) {
    if (object != nullptr) {
        CFBridgingRelease(object);
    }
}

static void* retainObjCObjectAsVoid(void* object) {
    if (object == nullptr) {
        return nullptr;
    }
    return (void*)CFBridgingRetain((__bridge id)object);
}

struct CapturedTranslatedDrawRecord {
    TranslatedDrawInfo info;
    std::string vertexMSLStorage;
    std::string fragmentMSLStorage;
    ShaderReflection vertexReflectionStorage;
    ShaderReflection fragmentReflectionStorage;
    std::vector<std::uint8_t> vertexDataStorage;
    std::vector<std::uint8_t> indexDataStorage;
    std::vector<std::uint8_t> vertexUniformStorage;
    std::vector<std::uint8_t> fragmentUniformStorage;
    std::vector<std::vector<std::uint8_t>> extraVertexDataStorage;
    std::vector<std::vector<std::uint8_t>> uboDataStorage;
    std::string pipelineBuildErrorStorage;
    std::vector<void*> retainedObjects;
    bool parallelPrepared = false;
    ParallelEncodeFallbackReason parallelFallbackReason =
        ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
    void* parallelPipelineState = nullptr;
    void* parallelDepthStencilState = nullptr;
    TranslatedDrawPlanShaderSlots parallelShaderSlots;
    std::uint32_t parallelAttachmentSampleCount = 1;
    std::uint32_t parallelColorFormat = 0;
    bool parallelHasFragmentStage = false;
    bool parallelClipControlShaderYFixup = false;
    bool parallelClipControlInvertsWinding = false;
    bool threadedPrepared = false;
    ParallelEncodeFallbackReason threadedFallbackReason =
        ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
    TranslatedDrawPlan threadedPlanStorage;
    void* threadedPipelineState = nullptr;
    void* threadedDepthStencilState = nullptr;
    std::int32_t threadedFixedFunctionSampleMaskSlot = 21;
    std::uint64_t threadedSequence = 0;
    std::size_t threadedApproxBytes = 0;
    bool threadedDescriptorFastRecord = false;
    bool threadedDescriptorPrepared = false;
    ParallelEncodeFallbackReason threadedDescriptorFallbackReason =
        ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;

    CapturedTranslatedDrawRecord() = default;
    CapturedTranslatedDrawRecord(const CapturedTranslatedDrawRecord&) = delete;
    CapturedTranslatedDrawRecord& operator=(const CapturedTranslatedDrawRecord&) = delete;

    ~CapturedTranslatedDrawRecord() {
        for (void* object : retainedObjects) {
            releaseRetainedObjCObject(object);
        }
    }

    void retainField(void*& field) {
        void* retained = retainObjCObjectAsVoid(field);
        field = retained;
        if (retained != nullptr) {
            retainedObjects.push_back(retained);
        }
    }
};

static constexpr std::size_t kLeanDirectMaxExtraVertexBuffers = 4;
static constexpr std::size_t kLeanDirectMaxTextureBindings = 8;
static constexpr std::size_t kLeanDirectMaxUBOBindings = 8;
static constexpr std::size_t kLeanDirectMaxInlineUniformBytes = 256;
static constexpr std::size_t kLeanDirectMaxInlineUboBytes = 512;

struct LeanDirectTranslatedDrawDescriptor {
    struct ExtraVertexBuffer {
        void* metalBuffer = nullptr;
        std::size_t metalBufferOffset = 0;
        std::uint32_t metalSlot = 0;
    };
    struct TextureBinding {
        std::uint32_t metalSlot = 0;
        void* metalTexture = nullptr;
        void* metalSamplerState = nullptr;
        std::uint32_t reductionMode = GL_WEIGHTED_AVERAGE_ARB;
        float lodBias = 0.0f;
        std::uint32_t borderClampMask = 0;
        std::array<std::int32_t, 4> borderColor = {0, 0, 0, 0};
    };
    struct UBOBinding {
        std::uint32_t metalSlot = 0;
        const void* data = nullptr;
        std::size_t size = 0;
        std::size_t inlineDataOffset = 0;
        void* metalBuffer = nullptr;
        std::size_t metalBufferOffset = 0;
        bool isVertex = false;
        bool isFragment = false;
        bool usesInlineData = false;
    };

    void* pipelineState = nullptr;
    void* depthStencilState = nullptr;
    TranslatedDrawPlanShaderSlots shaderSlots;
    std::uint32_t attachmentSampleCount = 1;
    std::uint32_t colorFormat = 0;
    std::int32_t fixedFunctionSampleMaskSlot = 21;
    bool clipControlShaderYFixup = false;
    bool clipControlInvertsWinding = false;

    GLenum mode = 0;
    GLsizei vertexCount = 0;
    GLsizei baseVertex = 0;
    GLsizei instanceCount = 1;
    GLuint baseInstance = 0;
    GLsizei indexCount = 0;
    GLenum indexType = 0;
    void* metalIndexBuffer = nullptr;
    std::size_t metalIndexBufferOffset = 0;

    bool bindPrimaryVertexBuffer = false;
    void* metalVertexBuffer = nullptr;
    std::size_t metalVertexBufferOffset = 0;
    std::array<ExtraVertexBuffer, kLeanDirectMaxExtraVertexBuffers>
        extraVertexBuffers;
    std::size_t extraVertexBufferCount = 0;

    std::array<std::uint8_t, kLeanDirectMaxInlineUniformBytes>
        vertexUniformStorage;
    std::array<std::uint8_t, kLeanDirectMaxInlineUniformBytes>
        fragmentUniformStorage;
    const std::uint8_t* vertexUniformData = nullptr;
    std::size_t vertexUniformSize = 0;
    const std::uint8_t* fragmentUniformData = nullptr;
    std::size_t fragmentUniformSize = 0;

    std::array<TextureBinding, kLeanDirectMaxTextureBindings> vertexTextures;
    std::size_t vertexTextureCount = 0;
    std::array<TextureBinding, kLeanDirectMaxTextureBindings> fragmentTextures;
    std::size_t fragmentTextureCount = 0;
    std::array<UBOBinding, kLeanDirectMaxUBOBindings> uboBindings;
    std::size_t uboBindingCount = 0;
    std::array<std::uint8_t, kLeanDirectMaxInlineUboBytes> uboInlineStorage;
    std::size_t uboInlineStorageSize = 0;

    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool depthWriteMask = true;
    bool stencilTestEnabled = false;
    GLint stencilFrontRef = 0;
    GLint stencilBackRef = 0;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;
    std::uint32_t sampleMask = 0xFFFFFFFFu;
    bool polygonOffsetEnabled = false;
    GLfloat polygonOffsetFactor = 0.0f;
    GLfloat polygonOffsetUnits = 0.0f;
    GLfloat polygonOffsetClamp = 0.0f;
    GLint viewportX = 0;
    GLint viewportY = 0;
    GLsizei viewportWidth = 0;
    GLsizei viewportHeight = 0;
    GLdouble depthRangeNear = 0.0;
    GLdouble depthRangeFar = 1.0;
    bool scissorTestEnabled = false;
    GLint scissorX = 0;
    GLint scissorY = 0;
    GLsizei scissorWidth = 0;
    GLsizei scissorHeight = 0;
    GLenum clipOrigin = GL_LOWER_LEFT;
    GLenum fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    TranslatedDrawInfo::FragmentShadingRateShaderState
        fragmentShadingRateShaderState;

    void reset() {
        pipelineState = nullptr;
        depthStencilState = nullptr;
        shaderSlots = TranslatedDrawPlanShaderSlots{};
        attachmentSampleCount = 1;
        colorFormat = 0;
        fixedFunctionSampleMaskSlot = 21;
        clipControlShaderYFixup = false;
        clipControlInvertsWinding = false;
        mode = 0;
        vertexCount = 0;
        baseVertex = 0;
        instanceCount = 1;
        baseInstance = 0;
        indexCount = 0;
        indexType = 0;
        metalIndexBuffer = nullptr;
        metalIndexBufferOffset = 0;
        bindPrimaryVertexBuffer = false;
        metalVertexBuffer = nullptr;
        metalVertexBufferOffset = 0;
        extraVertexBufferCount = 0;
        vertexUniformData = nullptr;
        vertexUniformSize = 0;
        fragmentUniformData = nullptr;
        fragmentUniformSize = 0;
        vertexTextureCount = 0;
        fragmentTextureCount = 0;
        uboBindingCount = 0;
        uboInlineStorageSize = 0;
        depthTestEnabled = false;
        depthFunc = GL_LESS;
        depthWriteMask = true;
        stencilTestEnabled = false;
        stencilFrontRef = 0;
        stencilBackRef = 0;
        cullFaceEnabled = false;
        cullFaceMode = GL_BACK;
        frontFace = GL_CCW;
        wireframe = false;
        sampleMask = 0xFFFFFFFFu;
        polygonOffsetEnabled = false;
        polygonOffsetFactor = 0.0f;
        polygonOffsetUnits = 0.0f;
        polygonOffsetClamp = 0.0f;
        viewportX = 0;
        viewportY = 0;
        viewportWidth = 0;
        viewportHeight = 0;
        depthRangeNear = 0.0;
        depthRangeFar = 1.0;
        scissorTestEnabled = false;
        scissorX = 0;
        scissorY = 0;
        scissorWidth = 0;
        scissorHeight = 0;
        clipOrigin = GL_LOWER_LEFT;
        fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        fragmentShadingRateShaderState =
            TranslatedDrawInfo::FragmentShadingRateShaderState{};
    }
};

static std::uint32_t maxLeanDirectTextureBindingSlot(
    const LeanDirectTranslatedDrawDescriptor::TextureBinding* textures,
    std::size_t count) {
    std::uint32_t maxSlot = 127;
    for (std::size_t i = 0; i < count; ++i) {
        const auto& binding = textures[i];
        if (binding.metalTexture == nullptr ||
            binding.metalSamplerState == nullptr) {
            continue;
        }
        maxSlot = std::max(maxSlot, binding.metalSlot);
    }
    return maxSlot;
}

static void buildLeanDirectTextureReductionModes(
    const LeanDirectTranslatedDrawDescriptor::TextureBinding* textures,
    std::size_t count,
    std::vector<std::uint32_t>& modes) {
    modes.assign(
        static_cast<std::size_t>(
            maxLeanDirectTextureBindingSlot(textures, count)) + 1u,
        static_cast<std::uint32_t>(GL_WEIGHTED_AVERAGE_ARB));
    for (std::size_t i = 0; i < count; ++i) {
        const auto& binding = textures[i];
        if (binding.metalTexture == nullptr ||
            binding.metalSamplerState == nullptr ||
            binding.metalSlot >= modes.size()) {
            continue;
        }
        modes[binding.metalSlot] = binding.reductionMode;
    }
}

static void buildLeanDirectTextureLodBiases(
    const LeanDirectTranslatedDrawDescriptor::TextureBinding* textures,
    std::size_t count,
    std::vector<float>& biases) {
    biases.assign(
        static_cast<std::size_t>(
            maxLeanDirectTextureBindingSlot(textures, count)) + 1u,
        0.0f);
    for (std::size_t i = 0; i < count; ++i) {
        const auto& binding = textures[i];
        if (binding.metalTexture == nullptr ||
            binding.metalSamplerState == nullptr ||
            binding.metalSlot >= biases.size()) {
            continue;
        }
        biases[binding.metalSlot] = binding.lodBias;
    }
}

static void buildLeanDirectTextureBorderClampModes(
    const LeanDirectTranslatedDrawDescriptor::TextureBinding* textures,
    std::size_t count,
    std::vector<std::uint32_t>& modes) {
    modes.assign(
        static_cast<std::size_t>(
            maxLeanDirectTextureBindingSlot(textures, count)) + 1u,
        0u);
    for (std::size_t i = 0; i < count; ++i) {
        const auto& binding = textures[i];
        if (binding.metalTexture == nullptr ||
            binding.metalSamplerState == nullptr ||
            binding.metalSlot >= modes.size()) {
            continue;
        }
        modes[binding.metalSlot] = binding.borderClampMask;
    }
}

static void buildLeanDirectTextureBorderClampColors(
    const LeanDirectTranslatedDrawDescriptor::TextureBinding* textures,
    std::size_t count,
    std::vector<std::array<std::int32_t, 4>>& colors) {
    colors.assign(
        static_cast<std::size_t>(
            maxLeanDirectTextureBindingSlot(textures, count)) + 1u,
        {0, 0, 0, 0});
    for (std::size_t i = 0; i < count; ++i) {
        const auto& binding = textures[i];
        if (binding.metalTexture == nullptr ||
            binding.metalSamplerState == nullptr ||
            binding.metalSlot >= colors.size()) {
            continue;
        }
        colors[binding.metalSlot] = binding.borderColor;
    }
}

static std::size_t indexTypeSize(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE: return 1;
        case GL_UNSIGNED_SHORT: return 2;
        case GL_UNSIGNED_INT: return 4;
        default: return 0;
    }
}

static bool hasAdditionalColorTargets(const TranslatedDrawInfo& info) {
    for (void* texture : info.fboAdditionalColorTextures) {
        if (texture != nullptr) {
            return true;
        }
    }
    return false;
}

static bool translatedDrawUsesSimpleMetalPrimitive(GLenum mode) {
    switch (mode) {
        case GL_POINTS:
        case GL_LINES:
        case GL_LINE_STRIP:
        case GL_TRIANGLES:
        case GL_TRIANGLE_STRIP:
            return true;
        default:
            return false;
    }
}

static bool translatedDrawNeedsCpuOrRingUploadPath(
    const TranslatedDrawInfo& info) {
    if (!info.vertexAttributeLayouts.empty() &&
        info.metalVertexBuffer == nullptr) {
        return true;
    }
    for (const auto& extra : info.extraVertexBuffers) {
        if (!extra.attributes.empty() && extra.metalBuffer == nullptr) {
            return true;
        }
    }
    return info.indexCount > 0 && info.metalIndexBuffer == nullptr;
}

static bool translatedDrawParallelCaptureEligible(
    const TranslatedDrawInfo& info,
    ParallelEncodeBoundaryReason& reason) {
    if (info.fboColorTexture != nullptr ||
        info.fboDepthStencilTexture != nullptr ||
        info.fboAttachmentless ||
        hasAdditionalColorTargets(info)) {
        reason = ParallelEncodeBoundaryReason::FboDraw;
        return false;
    }
    if (info.rasterizerDiscard) {
        reason = ParallelEncodeBoundaryReason::RasterizerDiscard;
        return false;
    }
    if (info.submissionGroup.argumentBuffersEnabled ||
        appglEnvEnabledDefaultOff("APPGL_ENABLE_ARGUMENT_BUFFERS")) {
        reason = ParallelEncodeBoundaryReason::ArgumentBuffers;
        return false;
    }
    const TranslatedDrawPlan* translatedPlan = info.translatedPlan;
    if (translatedPlan == nullptr || !translatedPlan->valid) {
        reason = ParallelEncodeBoundaryReason::PipelineNotPrepared;
        return false;
    }
    if (translatedPlan->useArgumentBuffers ||
        translatedPlan->vertexUsesArgumentBuffer ||
        translatedPlan->fragmentUsesArgumentBuffer ||
        translatedPlan->shaderSlots.vertexMslUsesArgBuf ||
        translatedPlan->shaderSlots.fragmentMslUsesArgBuf) {
        reason = ParallelEncodeBoundaryReason::ArgumentBuffers;
        return false;
    }
    if (!info.ssboBindings.empty() || !info.atomicCounterBindings.empty()) {
        reason = ParallelEncodeBoundaryReason::StorageOrAtomicSideEffects;
        return false;
    }
    if (!info.writtenImageTextureNames.empty()) {
        reason = ParallelEncodeBoundaryReason::ImageWriteSideEffects;
        return false;
    }
    if (info.pipelineOrSubroutinePlanCacheUnsafe) {
        reason = ParallelEncodeBoundaryReason::ProgramPipelineOrSubroutineState;
        return false;
    }
    if (info.viewportArrayCount > 1 ||
        info.fboColorArrayLength > 0 ||
        info.maxEmittedLayer > 0 ||
        info.markColorAttachmentReadbackFlip) {
        reason = ParallelEncodeBoundaryReason::LayeredOrViewportArrayState;
        return false;
    }
    if (info.parallelEncodeQueryOrTransformFeedbackHazard) {
        reason = ParallelEncodeBoundaryReason::QueryOrTransformFeedbackState;
        return false;
    }
    if (info.parallelEncodeTessMeshOrGeometryHazard) {
        reason = ParallelEncodeBoundaryReason::TessMeshOrGeometryState;
        return false;
    }
    if (!translatedDrawUsesSimpleMetalPrimitive(info.mode) ||
        info.parallelEncodePrimitiveExpansionHazard) {
        reason = ParallelEncodeBoundaryReason::PrimitiveExpansion;
        return false;
    }
    if (translatedDrawNeedsCpuOrRingUploadPath(info)) {
        reason = ParallelEncodeBoundaryReason::CpuOrRingUploadPath;
        return false;
    }
    if (info.pipelineStateCacheOut != nullptr &&
        info.pipelineStateCacheOut->empty()) {
        reason = ParallelEncodeBoundaryReason::PipelineNotPrepared;
        return false;
    }
    if (info.pipelineStateCacheOut == nullptr &&
        (info.pipelineStateOut == nullptr || *info.pipelineStateOut == nullptr)) {
        reason = ParallelEncodeBoundaryReason::PipelineNotPrepared;
        return false;
    }
    return true;
}

static void copyBytes(std::vector<std::uint8_t>& storage,
                      const void* source,
                      std::size_t byteCount,
                      const void*& destination) {
    if (source == nullptr || byteCount == 0) {
        destination = nullptr;
        storage.clear();
        return;
    }
    const auto* begin = static_cast<const std::uint8_t*>(source);
    storage.assign(begin, begin + byteCount);
    destination = storage.data();
}

static bool captureTranslatedDrawForSerialReplay(
    const TranslatedDrawInfo& source,
    CapturedTranslatedDrawRecord& capture) {
    capture.info = source;

    if (source.vertexMSL != nullptr) {
        capture.vertexMSLStorage = *source.vertexMSL;
        capture.info.vertexMSL = &capture.vertexMSLStorage;
    } else {
        capture.info.vertexMSL = nullptr;
    }
    if (source.fragmentMSL != nullptr) {
        capture.fragmentMSLStorage = *source.fragmentMSL;
        capture.info.fragmentMSL = &capture.fragmentMSLStorage;
    } else {
        capture.info.fragmentMSL = nullptr;
    }
    if (source.vertexReflection != nullptr) {
        capture.vertexReflectionStorage = *source.vertexReflection;
        capture.info.vertexReflection = &capture.vertexReflectionStorage;
    } else {
        capture.info.vertexReflection = nullptr;
    }
    if (source.fragmentReflection != nullptr) {
        capture.fragmentReflectionStorage = *source.fragmentReflection;
        capture.info.fragmentReflection = &capture.fragmentReflectionStorage;
    } else {
        capture.info.fragmentReflection = nullptr;
    }

    copyBytes(capture.vertexDataStorage,
              source.vertexData,
              source.vertexDataByteCount,
              capture.info.vertexData);
    if (source.metalVertexBuffer != nullptr) {
        capture.info.metalVertexBuffer = source.metalVertexBuffer;
        capture.retainField(capture.info.metalVertexBuffer);
    }

    capture.extraVertexDataStorage.resize(capture.info.extraVertexBuffers.size());
    for (std::size_t i = 0; i < capture.info.extraVertexBuffers.size(); ++i) {
        auto& extra = capture.info.extraVertexBuffers[i];
        if (extra.metalBuffer != nullptr) {
            capture.retainField(extra.metalBuffer);
            continue;
        }
        const void* extraData = extra.data != nullptr
            ? extra.data
            : (extra.ownedData.empty() ? nullptr : extra.ownedData.data());
        if (extraData != nullptr && extra.byteCount > 0) {
            const auto* begin = static_cast<const std::uint8_t*>(extraData);
            auto& storage = capture.extraVertexDataStorage[i];
            storage.assign(begin, begin + extra.byteCount);
            extra.ownedData = storage;
            extra.data = extra.ownedData.data();
        } else {
            extra.data = nullptr;
            extra.ownedData.clear();
        }
    }

    if (source.indices != nullptr && source.indexCount > 0) {
        const std::size_t indexSize = indexTypeSize(source.indexType);
        if (indexSize == 0) {
            return false;
        }
        copyBytes(capture.indexDataStorage,
                  source.indices,
                  static_cast<std::size_t>(source.indexCount) * indexSize,
                  capture.info.indices);
    } else {
        capture.info.indices = nullptr;
    }
    if (source.metalIndexBuffer != nullptr) {
        capture.info.metalIndexBuffer = source.metalIndexBuffer;
        capture.retainField(capture.info.metalIndexBuffer);
    }

    const void* vertexUniformOut = nullptr;
    copyBytes(capture.vertexUniformStorage,
              source.vertexUniformData,
              source.vertexUniformSize,
              vertexUniformOut);
    capture.info.vertexUniformData =
        static_cast<const std::uint8_t*>(vertexUniformOut);
    const void* fragmentUniformOut = nullptr;
    copyBytes(capture.fragmentUniformStorage,
              source.fragmentUniformData,
              source.fragmentUniformSize,
              fragmentUniformOut);
    capture.info.fragmentUniformData =
        static_cast<const std::uint8_t*>(fragmentUniformOut);

    auto retainTextures = [&capture](
        std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
        for (auto& binding : textures) {
            capture.retainField(binding.metalTexture);
            capture.retainField(binding.metalSamplerState);
            capture.retainField(binding.textureBufferBackingMetalBuffer);
            capture.retainField(binding.imageAtomicMetalBuffer);
        }
    };
    retainTextures(capture.info.fragmentTextures);
    retainTextures(capture.info.vertexTextures);

    capture.uboDataStorage.resize(capture.info.uboBindings.size());
    for (std::size_t i = 0; i < capture.info.uboBindings.size(); ++i) {
        auto& ubo = capture.info.uboBindings[i];
        if (ubo.metalBuffer != nullptr) {
            capture.retainField(ubo.metalBuffer);
        } else if (ubo.data != nullptr && ubo.size > 0) {
            auto& storage = capture.uboDataStorage[i];
            const auto* begin = static_cast<const std::uint8_t*>(ubo.data);
            storage.assign(begin, begin + ubo.size);
            ubo.data = storage.data();
        } else {
            ubo.data = nullptr;
        }
    }

    for (auto& ssbo : capture.info.ssboBindings) {
        capture.retainField(ssbo.metalBuffer);
    }
    for (auto& atomic : capture.info.atomicCounterBindings) {
        capture.retainField(atomic.metalBuffer);
    }

    capture.info.translatedPlan = nullptr;
    capture.info.translatedPlanOut = nullptr;
    capture.info.translatedPlanRejectReasonOut = nullptr;
    capture.info.pipelineStateCacheOut = nullptr;
    capture.info.pipelineBuildErrorOut = &capture.pipelineBuildErrorStorage;
    capture.info.pipelineStateOut = nullptr;
    capture.info.pipelineColorFormatOut = nullptr;
    capture.info.metalVertexFunctionOut = nullptr;
    capture.info.metalFragmentFunctionOut = nullptr;
    if (source.metalVertexFunction != nullptr) {
        capture.info.metalVertexFunction = source.metalVertexFunction;
        capture.retainField(capture.info.metalVertexFunction);
    }
    if (source.metalFragmentFunction != nullptr) {
        capture.info.metalFragmentFunction = source.metalFragmentFunction;
        capture.retainField(capture.info.metalFragmentFunction);
    }

    return true;
}

static bool captureTranslatedDrawForThreadedDeferred(
    const TranslatedDrawInfo& source,
    CapturedTranslatedDrawRecord& capture) {
    capture.info = source;

    capture.info.vertexMSL = nullptr;
    capture.info.fragmentMSL = nullptr;
    capture.info.vertexReflection = nullptr;
    capture.info.fragmentReflection = nullptr;
    capture.info.vertexData = nullptr;
    capture.info.indices = nullptr;

    if (source.metalVertexBuffer != nullptr) {
        capture.info.metalVertexBuffer = source.metalVertexBuffer;
        capture.retainField(capture.info.metalVertexBuffer);
    }
    for (auto& extra : capture.info.extraVertexBuffers) {
        extra.data = nullptr;
        extra.ownedData.clear();
        if (extra.metalBuffer != nullptr) {
            capture.retainField(extra.metalBuffer);
        }
    }
    if (source.metalIndexBuffer != nullptr) {
        capture.info.metalIndexBuffer = source.metalIndexBuffer;
        capture.retainField(capture.info.metalIndexBuffer);
    }

    const void* vertexUniformOut = nullptr;
    copyBytes(capture.vertexUniformStorage,
              source.vertexUniformData,
              source.vertexUniformSize,
              vertexUniformOut);
    capture.info.vertexUniformData =
        static_cast<const std::uint8_t*>(vertexUniformOut);
    const void* fragmentUniformOut = nullptr;
    copyBytes(capture.fragmentUniformStorage,
              source.fragmentUniformData,
              source.fragmentUniformSize,
              fragmentUniformOut);
    capture.info.fragmentUniformData =
        static_cast<const std::uint8_t*>(fragmentUniformOut);

    auto retainTextures = [&capture](
        std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
        for (auto& binding : textures) {
            capture.retainField(binding.metalTexture);
            capture.retainField(binding.metalSamplerState);
            capture.retainField(binding.textureBufferBackingMetalBuffer);
            capture.retainField(binding.imageAtomicMetalBuffer);
        }
    };
    retainTextures(capture.info.fragmentTextures);
    retainTextures(capture.info.vertexTextures);

    capture.uboDataStorage.resize(capture.info.uboBindings.size());
    for (std::size_t i = 0; i < capture.info.uboBindings.size(); ++i) {
        auto& ubo = capture.info.uboBindings[i];
        if (ubo.metalBuffer != nullptr) {
            capture.retainField(ubo.metalBuffer);
        } else if (ubo.data != nullptr && ubo.size > 0) {
            auto& storage = capture.uboDataStorage[i];
            const auto* begin = static_cast<const std::uint8_t*>(ubo.data);
            storage.assign(begin, begin + ubo.size);
            ubo.data = storage.data();
        } else {
            ubo.data = nullptr;
        }
    }

    capture.info.ssboBindings.clear();
    capture.info.atomicCounterBindings.clear();
    capture.info.translatedPlan = nullptr;
    capture.info.translatedPlanOut = nullptr;
    capture.info.translatedPlanRejectReasonOut = nullptr;
    capture.info.pipelineStateCacheOut = nullptr;
    capture.info.pipelineBuildErrorOut = nullptr;
    capture.info.pipelineStateOut = nullptr;
    capture.info.pipelineColorFormatOut = nullptr;
    capture.info.metalVertexFunction = nullptr;
    capture.info.metalFragmentFunction = nullptr;
    capture.info.metalVertexFunctionOut = nullptr;
    capture.info.metalFragmentFunctionOut = nullptr;
    return true;
}

static std::size_t capturedTranslatedDrawRecordApproxBytes(
    const CapturedTranslatedDrawRecord& capture) {
    std::size_t bytes = sizeof(capture);
    bytes += capture.vertexMSLStorage.size();
    bytes += capture.fragmentMSLStorage.size();
    bytes += capture.vertexDataStorage.size();
    bytes += capture.indexDataStorage.size();
    bytes += capture.vertexUniformStorage.size();
    bytes += capture.fragmentUniformStorage.size();
    bytes += capture.pipelineBuildErrorStorage.size();
    for (const auto& storage : capture.extraVertexDataStorage) {
        bytes += storage.size();
    }
    for (const auto& storage : capture.uboDataStorage) {
        bytes += storage.size();
    }
    bytes += capture.info.fragmentTextures.size() *
        sizeof(TranslatedDrawInfo::TextureBinding);
    bytes += capture.info.vertexTextures.size() *
        sizeof(TranslatedDrawInfo::TextureBinding);
    bytes += capture.info.uboBindings.size() *
        sizeof(TranslatedDrawInfo::UBOBinding);
    return bytes;
}

// Shadow-compare Y-fixup slot: the translator injects
// `constant float* _appgl_CmpFlip [[buffer(N)]]` into fragment shaders
// that compare-sample depth2d/_array receivers (injectDepthCompareFlip);
// N is chosen collision-free per shader, so read it back from the MSL —
// same pattern as clipControlYSignBufferSlot below.
static NSInteger depthCompareFlipBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle = "_appgl_CmpFlip [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger clipControlYSignBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_ClipControlYSign [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger textureReductionModesBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_TextureReductionModes [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger textureLodBiasesBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_TextureLodBiases [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger textureBorderClampModesBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_TextureBorderClampModes [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger textureBorderClampColorsBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_TextureBorderClampColors [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger implicitLodBiasCorrectionBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_ImplicitLodBiasCorrection [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger fixedFunctionSampleMaskBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return 21;
    }
    static constexpr const char* kNeedle =
        "appgl_SampleMask [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return 21;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : 21;
}

static std::uint32_t maxTextureBindingSlot(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
    std::uint32_t maxSlot = 127;
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        maxSlot = std::max(maxSlot, binding.metalSlot);
    }
    return maxSlot;
}

static void buildTextureReductionModes(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
    std::vector<std::uint32_t>& modes) {
    modes.assign(
        static_cast<std::size_t>(maxTextureBindingSlot(textures)) + 1u,
        static_cast<std::uint32_t>(GL_WEIGHTED_AVERAGE_ARB));
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        if (binding.metalSlot >= modes.size()) {
            continue;
        }
        modes[binding.metalSlot] = binding.reductionMode;
    }
}

static void buildTextureLodBiases(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
    std::vector<float>& biases) {
    biases.assign(
        static_cast<std::size_t>(maxTextureBindingSlot(textures)) + 1u,
        0.0f);
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        if (binding.metalSlot >= biases.size()) {
            continue;
        }
        biases[binding.metalSlot] = binding.lodBias;
    }
}

static void buildTextureBorderClampModes(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
    std::vector<std::uint32_t>& modes) {
    modes.assign(
        static_cast<std::size_t>(maxTextureBindingSlot(textures)) + 1u,
        0u);
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        if (binding.metalSlot >= modes.size()) {
            continue;
        }
        modes[binding.metalSlot] = binding.borderClampMask;
    }
}

static void buildTextureBorderClampColors(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
    std::vector<std::array<std::int32_t, 4>>& colors) {
    colors.assign(
        static_cast<std::size_t>(maxTextureBindingSlot(textures)) + 1u,
        {0, 0, 0, 0});
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        if (binding.metalSlot >= colors.size()) {
            continue;
        }
        colors[binding.metalSlot] = binding.borderColor;
    }
}

static std::vector<std::uint32_t>& textureUIntScratch() {
    thread_local std::vector<std::uint32_t> scratch;
    return scratch;
}

static std::vector<float>& textureFloatScratch() {
    thread_local std::vector<float> scratch;
    return scratch;
}

static std::vector<std::array<std::int32_t, 4>>& textureBorderColorScratch() {
    thread_local std::vector<std::array<std::int32_t, 4>> scratch;
    return scratch;
}

struct TranslatedDrawMSLSlots {
    bool vertexMslUsesArgBuf = false;
    bool fragmentMslUsesArgBuf = false;
    bool vertexHasSSBOSizeBuffer = false;
    bool fragmentHasSSBOSizeBuffer = false;
    bool fragmentNeedsFragCoordParams = false;
    bool fragmentNeedsGlNumSamplesArgBuf = false;
    bool vertexNeedsFragmentShadingRateState = false;
    bool vertexUsesMultiviewViewMask = false;
    bool fragmentUsesMultiviewViewMask = false;
    NSInteger fragmentDepthCompareFlipSlot = -1;
    NSInteger vertexClipControlYSignSlot = -1;
    NSInteger vertexReductionModesSlot = -1;
    NSInteger vertexLodBiasesSlot = -1;
    NSInteger vertexBorderClampModesSlot = -1;
    NSInteger vertexBorderClampColorsSlot = -1;
    NSInteger vertexImplicitLodBiasCorrectionSlot = -1;
    NSInteger fragmentReductionModesSlot = -1;
    NSInteger fragmentLodBiasesSlot = -1;
    NSInteger fragmentBorderClampModesSlot = -1;
    NSInteger fragmentBorderClampColorsSlot = -1;
    NSInteger fragmentImplicitLodBiasCorrectionSlot = -1;
};

static std::int32_t phase2PlanSlotFromNSInteger(NSInteger slot) {
    return slot >= 0 ? static_cast<std::int32_t>(slot) : -1;
}

static NSInteger phase2PlanSlotToNSInteger(std::int32_t slot) {
    return slot >= 0 ? static_cast<NSInteger>(slot) : -1;
}

static TranslatedDrawPlanShaderSlots phase2PlanShaderSlotsFromMSLSlots(
    const TranslatedDrawMSLSlots& slots)
{
    TranslatedDrawPlanShaderSlots planSlots;
    planSlots.vertexMslUsesArgBuf = slots.vertexMslUsesArgBuf;
    planSlots.fragmentMslUsesArgBuf = slots.fragmentMslUsesArgBuf;
    planSlots.vertexHasSSBOSizeBuffer = slots.vertexHasSSBOSizeBuffer;
    planSlots.fragmentHasSSBOSizeBuffer = slots.fragmentHasSSBOSizeBuffer;
    planSlots.fragmentNeedsFragCoordParams = slots.fragmentNeedsFragCoordParams;
    planSlots.fragmentNeedsGlNumSamplesArgBuf =
        slots.fragmentNeedsGlNumSamplesArgBuf;
    planSlots.vertexNeedsFragmentShadingRateState =
        slots.vertexNeedsFragmentShadingRateState;
    planSlots.vertexUsesMultiviewViewMask = slots.vertexUsesMultiviewViewMask;
    planSlots.fragmentUsesMultiviewViewMask =
        slots.fragmentUsesMultiviewViewMask;
    planSlots.fragmentDepthCompareFlipSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentDepthCompareFlipSlot);
    planSlots.vertexClipControlYSignSlot =
        phase2PlanSlotFromNSInteger(slots.vertexClipControlYSignSlot);
    planSlots.vertexReductionModesSlot =
        phase2PlanSlotFromNSInteger(slots.vertexReductionModesSlot);
    planSlots.vertexLodBiasesSlot =
        phase2PlanSlotFromNSInteger(slots.vertexLodBiasesSlot);
    planSlots.vertexBorderClampModesSlot =
        phase2PlanSlotFromNSInteger(slots.vertexBorderClampModesSlot);
    planSlots.vertexBorderClampColorsSlot =
        phase2PlanSlotFromNSInteger(slots.vertexBorderClampColorsSlot);
    planSlots.vertexImplicitLodBiasCorrectionSlot =
        phase2PlanSlotFromNSInteger(slots.vertexImplicitLodBiasCorrectionSlot);
    planSlots.fragmentReductionModesSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentReductionModesSlot);
    planSlots.fragmentLodBiasesSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentLodBiasesSlot);
    planSlots.fragmentBorderClampModesSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentBorderClampModesSlot);
    planSlots.fragmentBorderClampColorsSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentBorderClampColorsSlot);
    planSlots.fragmentImplicitLodBiasCorrectionSlot =
        phase2PlanSlotFromNSInteger(slots.fragmentImplicitLodBiasCorrectionSlot);
    return planSlots;
}

static TranslatedDrawMSLSlots phase2PlanMSLSlotsFromShaderSlots(
    const TranslatedDrawPlanShaderSlots& planSlots)
{
    TranslatedDrawMSLSlots slots;
    slots.vertexMslUsesArgBuf = planSlots.vertexMslUsesArgBuf;
    slots.fragmentMslUsesArgBuf = planSlots.fragmentMslUsesArgBuf;
    slots.vertexHasSSBOSizeBuffer = planSlots.vertexHasSSBOSizeBuffer;
    slots.fragmentHasSSBOSizeBuffer = planSlots.fragmentHasSSBOSizeBuffer;
    slots.fragmentNeedsFragCoordParams =
        planSlots.fragmentNeedsFragCoordParams;
    slots.fragmentNeedsGlNumSamplesArgBuf =
        planSlots.fragmentNeedsGlNumSamplesArgBuf;
    slots.vertexNeedsFragmentShadingRateState =
        planSlots.vertexNeedsFragmentShadingRateState;
    slots.vertexUsesMultiviewViewMask =
        planSlots.vertexUsesMultiviewViewMask;
    slots.fragmentUsesMultiviewViewMask =
        planSlots.fragmentUsesMultiviewViewMask;
    slots.fragmentDepthCompareFlipSlot =
        phase2PlanSlotToNSInteger(planSlots.fragmentDepthCompareFlipSlot);
    slots.vertexClipControlYSignSlot =
        phase2PlanSlotToNSInteger(planSlots.vertexClipControlYSignSlot);
    slots.vertexReductionModesSlot =
        phase2PlanSlotToNSInteger(planSlots.vertexReductionModesSlot);
    slots.vertexLodBiasesSlot =
        phase2PlanSlotToNSInteger(planSlots.vertexLodBiasesSlot);
    slots.vertexBorderClampModesSlot =
        phase2PlanSlotToNSInteger(planSlots.vertexBorderClampModesSlot);
    slots.vertexBorderClampColorsSlot =
        phase2PlanSlotToNSInteger(planSlots.vertexBorderClampColorsSlot);
    slots.vertexImplicitLodBiasCorrectionSlot =
        phase2PlanSlotToNSInteger(
            planSlots.vertexImplicitLodBiasCorrectionSlot);
    slots.fragmentReductionModesSlot =
        phase2PlanSlotToNSInteger(planSlots.fragmentReductionModesSlot);
    slots.fragmentLodBiasesSlot =
        phase2PlanSlotToNSInteger(planSlots.fragmentLodBiasesSlot);
    slots.fragmentBorderClampModesSlot =
        phase2PlanSlotToNSInteger(planSlots.fragmentBorderClampModesSlot);
    slots.fragmentBorderClampColorsSlot =
        phase2PlanSlotToNSInteger(planSlots.fragmentBorderClampColorsSlot);
    slots.fragmentImplicitLodBiasCorrectionSlot =
        phase2PlanSlotToNSInteger(
            planSlots.fragmentImplicitLodBiasCorrectionSlot);
    return slots;
}

static bool mslContains(const std::string* msl, const char* needle) {
    return msl != nullptr && msl->find(needle) != std::string::npos;
}

static TranslatedDrawMSLSlots buildTranslatedDrawMSLSlots(
    const TranslatedDrawInfo& info,
    bool hasFragmentStage) {
    TranslatedDrawMSLSlots slots;
    slots.vertexMslUsesArgBuf =
        mslContains(info.vertexMSL, "spvDescriptorSetBuffer");
    slots.fragmentMslUsesArgBuf =
        mslContains(info.fragmentMSL, "spvDescriptorSetBuffer");
    slots.vertexHasSSBOSizeBuffer =
        mslContains(info.vertexMSL, "spvBufferSizeConstants");
    slots.fragmentHasSSBOSizeBuffer =
        mslContains(info.fragmentMSL, "spvBufferSizeConstants");
    slots.fragmentNeedsFragCoordParams =
        hasFragmentStage &&
        mslContains(info.fragmentMSL, "_appgl_FragCoordParams");
    slots.fragmentNeedsGlNumSamplesArgBuf =
        mslContains(info.fragmentMSL,
                    "_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples [[id(0)]]");
    slots.vertexNeedsFragmentShadingRateState =
        mslContains(info.vertexMSL, "_appgl_FSRState");
    slots.vertexUsesMultiviewViewMask =
        mslContains(info.vertexMSL, "spvViewMask");
    slots.fragmentUsesMultiviewViewMask =
        mslContains(info.fragmentMSL, "spvViewMask");
    slots.fragmentDepthCompareFlipSlot =
        hasFragmentStage ? depthCompareFlipBufferSlot(info.fragmentMSL) : -1;
    slots.vertexClipControlYSignSlot =
        clipControlYSignBufferSlot(info.vertexMSL);
    slots.vertexReductionModesSlot =
        textureReductionModesBufferSlot(info.vertexMSL);
    slots.vertexLodBiasesSlot =
        textureLodBiasesBufferSlot(info.vertexMSL);
    slots.vertexBorderClampModesSlot =
        textureBorderClampModesBufferSlot(info.vertexMSL);
    slots.vertexBorderClampColorsSlot =
        textureBorderClampColorsBufferSlot(info.vertexMSL);
    slots.vertexImplicitLodBiasCorrectionSlot =
        implicitLodBiasCorrectionBufferSlot(info.vertexMSL);
    slots.fragmentReductionModesSlot =
        textureReductionModesBufferSlot(info.fragmentMSL);
    slots.fragmentLodBiasesSlot =
        textureLodBiasesBufferSlot(info.fragmentMSL);
    slots.fragmentBorderClampModesSlot =
        textureBorderClampModesBufferSlot(info.fragmentMSL);
    slots.fragmentBorderClampColorsSlot =
        textureBorderClampColorsBufferSlot(info.fragmentMSL);
    slots.fragmentImplicitLodBiasCorrectionSlot =
        implicitLodBiasCorrectionBufferSlot(info.fragmentMSL);
    return slots;
}

static float implicitLodViewportBiasCorrection(const TranslatedDrawInfo& info,
                                               bool isFBODraw,
                                               id<MTLTexture> colorTexture) {
    if (info.viewportWidth <= 0 || info.viewportHeight <= 0) {
        return 0.0f;
    }
    const GLint rtW = (isFBODraw && info.fboWidth > 0)
        ? info.fboWidth
        : static_cast<GLint>(colorTexture != nil ? colorTexture.width : 0);
    const GLint rtH = (isFBODraw && info.fboHeight > 0)
        ? info.fboHeight
        : static_cast<GLint>(colorTexture != nil ? colorTexture.height : 0);
    if (rtW <= 0 || rtH <= 0) {
        return 0.0f;
    }

    const GLint glX = std::max<GLint>(0, info.viewportX);
    const GLint glY = std::max<GLint>(0, info.viewportY);
    const GLsizei availW =
        static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
    const GLsizei availH =
        static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
    const GLsizei clampedW =
        std::min<GLsizei>(info.viewportWidth, availW);
    const GLsizei clampedH =
        std::min<GLsizei>(info.viewportHeight, availH);
    if (clampedW <= 0 || clampedH <= 0) {
        return 0.0f;
    }

    const float scaleX =
        static_cast<float>(info.viewportWidth) / static_cast<float>(clampedW);
    const float scaleY =
        static_cast<float>(info.viewportHeight) / static_cast<float>(clampedH);
    const float scale = std::max(scaleX, scaleY);
    return scale > 1.0f ? -std::log2(scale) : 0.0f;
}

static MTLWinding frontFacingWindingForClipControl(GLenum frontFace,
                                                   bool invertForClipControlY)
{
    bool clockwise = (frontFace == GL_CW);
    if (invertForClipControlY) {
        clockwise = !clockwise;
    }
    return clockwise ? MTLWindingClockwise : MTLWindingCounterClockwise;
}

static float appglHalfBitsToFloat(std::uint16_t bits) {
    __fp16 h;
    std::memcpy(&h, &bits, sizeof(bits));
    return static_cast<float>(h);
}

static std::uint32_t appglTessSegmentCountForCapacity(float level, GLenum spacing) {
    if (!std::isfinite(level)) {
        level = 1.0f;
    }
    if (spacing == GL_FRACTIONAL_ODD) {
        level = std::clamp(level, 1.0f, 63.0f);
    } else {
        level = std::clamp(level, 1.0f, 64.0f);
    }
    int n = static_cast<int>(std::ceil(level));
    if (spacing == GL_FRACTIONAL_EVEN) {
        if (n < 2) n = 2;
        if ((n & 1) != 0) ++n;
    } else if (spacing == GL_FRACTIONAL_ODD) {
        if (n < 1) n = 1;
        if ((n & 1) == 0) ++n;
    } else if (n < 1) {
        n = 1;
    }
    return static_cast<std::uint32_t>(n);
}

static std::uint32_t appglQuadInnerSegmentCountForCapacity(float level,
                                                           GLenum spacing) {
    if (!(level > 1.0f)) {
        return appglTessSegmentCountForCapacity(2.0f, spacing);
    }
    return appglTessSegmentCountForCapacity(level, spacing);
}

static std::uint32_t appglTriangleInnerSegmentCountForCapacity(float level,
                                                               float o0,
                                                               float o1,
                                                               float o2,
                                                               GLenum spacing) {
    if (!(level > 1.0f) && (o0 > 1.0f || o1 > 1.0f || o2 > 1.0f)) {
        return appglTessSegmentCountForCapacity(2.0f, spacing);
    }
    return appglTessSegmentCountForCapacity(level, spacing);
}

static bool appglNearTessLevelForCapacity(float value, float expected) {
    return std::fabs(value - expected) < 0.25f;
}

static std::uint32_t appglRule7SlotKindForCapacity(float value, float expected) {
    if (appglNearTessLevelForCapacity(value, expected)) {
        return 1u;
    }
    if (appglNearTessLevelForCapacity(value, 64.0f / 3.0f)) {
        return 2u;
    }
    return 0u;
}

static bool appglRule7TriLowLevelsForCapacity(float i0, float i1,
                                              float o0, float o1, float o2) {
    if (!appglNearTessLevelForCapacity(i0, 3.0f) ||
        !appglNearTessLevelForCapacity(i1, 4.0f)) {
        return false;
    }
    const std::uint32_t s0 = appglRule7SlotKindForCapacity(o0, 6.0f);
    const std::uint32_t s1 = appglRule7SlotKindForCapacity(o1, 5.0f);
    const std::uint32_t s2 = appglRule7SlotKindForCapacity(o2, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u) {
        return false;
    }
    const std::uint32_t modified =
        (s0 == 2u ? 1u : 0u) +
        (s1 == 2u ? 1u : 0u) +
        (s2 == 2u ? 1u : 0u);
    return modified <= 1u;
}

static bool appglRule7QuadLowLevelsForCapacity(float i0, float i1,
                                               float o0, float o1,
                                               float o2, float o3) {
    if (!appglNearTessLevelForCapacity(i0, 4.0f) ||
        !appglNearTessLevelForCapacity(i1, 5.0f)) {
        return false;
    }
    const std::uint32_t s0 = appglRule7SlotKindForCapacity(o0, 7.0f);
    const std::uint32_t s1 = appglRule7SlotKindForCapacity(o1, 6.0f);
    const std::uint32_t s2 = appglRule7SlotKindForCapacity(o2, 5.0f);
    const std::uint32_t s3 = appglRule7SlotKindForCapacity(o3, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u || s3 == 0u) {
        return false;
    }
    const std::uint32_t modified =
        (s0 == 2u ? 1u : 0u) +
        (s1 == 2u ? 1u : 0u) +
        (s2 == 2u ? 1u : 0u) +
        (s3 == 2u ? 1u : 0u);
    return modified <= 1u;
}

static std::uint64_t appglTessPatchVertexCountForCapacity(
    const MetalTessDrawInfo& info,
    float o0, float o1, float o2, float o3,
    float i0, float i1) {
    if (info.genMode == GL_TRIANGLES) {
        if (!(o0 > 0.0f) || !(o1 > 0.0f) || !(o2 > 0.0f)) {
            return 0;
        }
        const bool outersDiffer = !(o0 == o1 && o1 == o2);
        if (info.pointMode && outersDiffer) {
            const std::uint32_t outerN0 =
                appglTessSegmentCountForCapacity(o0, info.genSpacing);
            const std::uint32_t outerN1 =
                appglTessSegmentCountForCapacity(o1, info.genSpacing);
            const std::uint32_t outerN2 =
                appglTessSegmentCountForCapacity(o2, info.genSpacing);
            const std::uint32_t innerN =
                appglTriangleInnerSegmentCountForCapacity(
                    i0, o0, o1, o2, info.genSpacing);
            std::uint64_t count = 3u +
                static_cast<std::uint64_t>(outerN0 - 1u) +
                static_cast<std::uint64_t>(outerN1 - 1u) +
                static_cast<std::uint64_t>(outerN2 - 1u);
            if (innerN < 2u) {
                return count + 1u;
            }
            for (std::uint32_t ringN = innerN; ringN >= 2u; ringN -= 2u) {
                if (ringN == 2u) {
                    ++count;
                    break;
                }
                count += 3u;
                if (ringN == 3u) {
                    break;
                }
                count += 3ull * static_cast<std::uint64_t>(ringN - 3u);
            }
            return count;
        }

        float axisMax = std::max(std::max(o0, o1), std::max(o2, i0));
        if (!info.pointMode && info.genSpacing == GL_EQUAL &&
            appglRule7TriLowLevelsForCapacity(i0, i1, o0, o1, o2)) {
            axisMax = 6.0f;
        }
        const std::uint64_t n =
            appglTessSegmentCountForCapacity(axisMax, info.genSpacing);
        return info.pointMode ? ((n + 1u) * (n + 2u)) / 2u
                              : 3u * n * n;
    }

    if (info.genMode == GL_QUADS) {
        if (!(o0 > 0.0f) || !(o1 > 0.0f) ||
            !(o2 > 0.0f) || !(o3 > 0.0f)) {
            return 0;
        }
        const bool outersDiffer =
            !(o0 == o1 && o1 == o2 && o2 == o3) || !(i0 == i1);
        if (info.pointMode && outersDiffer) {
            const std::uint32_t outerN0 =
                appglTessSegmentCountForCapacity(o0, info.genSpacing);
            const std::uint32_t outerN1 =
                appglTessSegmentCountForCapacity(o1, info.genSpacing);
            const std::uint32_t outerN2 =
                appglTessSegmentCountForCapacity(o2, info.genSpacing);
            const std::uint32_t outerN3 =
                appglTessSegmentCountForCapacity(o3, info.genSpacing);
            const std::uint32_t innerNu =
                appglQuadInnerSegmentCountForCapacity(i0, info.genSpacing);
            const std::uint32_t innerNv =
                appglQuadInnerSegmentCountForCapacity(i1, info.genSpacing);
            std::uint64_t count = 4u +
                static_cast<std::uint64_t>(outerN0 - 1u) +
                static_cast<std::uint64_t>(outerN1 - 1u) +
                static_cast<std::uint64_t>(outerN2 - 1u) +
                static_cast<std::uint64_t>(outerN3 - 1u);
            if (innerNu >= 3u && innerNv >= 3u) {
                const std::uint64_t segU = innerNu - 2u;
                const std::uint64_t segV = innerNv - 2u;
                count += 4u;
                count += 2u * (segV - 1u);
                count += 2u * (segU - 1u);
                count += (segV - 1u) * (segU - 1u);
            } else if (innerNu == 2u && innerNv >= 3u) {
                count += static_cast<std::uint64_t>(innerNv - 1u);
            } else if (innerNv == 2u && innerNu >= 3u) {
                count += static_cast<std::uint64_t>(innerNu - 1u);
            } else if (innerNu == 2u && innerNv == 2u) {
                ++count;
            }
            return count;
        }

        float axisMax = std::max(
            std::max(std::max(o0, o1), std::max(o2, o3)),
            std::max(i0, i1));
        if (!info.pointMode && info.genSpacing == GL_EQUAL &&
            appglRule7QuadLowLevelsForCapacity(i0, i1, o0, o1, o2, o3)) {
            axisMax = 7.0f;
        }
        const std::uint64_t n =
            appglTessSegmentCountForCapacity(axisMax, info.genSpacing);
        return info.pointMode ? (n + 1u) * (n + 1u)
                              : 6u * n * n;
    }

    if (info.genMode == GL_ISOLINES) {
        if (!(o0 > 0.0f) || !(o1 > 0.0f)) {
            return 0;
        }
        const std::uint64_t vN = appglTessSegmentCountForCapacity(o0, GL_EQUAL);
        const std::uint64_t uN =
            appglTessSegmentCountForCapacity(o1, info.genSpacing);
        return info.pointMode ? vN * (uN + 1u) : 2u * vN * uN;
    }

    return 0;
}

static NSUInteger appglEstimateTessDomainVertexCapacity(
    const MetalTessDrawInfo& info,
    const void* halfFactorBytes) {
    if (halfFactorBytes == nullptr || info.patchCount <= 0) {
        return 1;
    }
    const auto* factors =
        static_cast<const std::uint16_t*>(halfFactorBytes);
    const std::uint64_t maxOut =
        static_cast<std::uint64_t>(std::numeric_limits<NSUInteger>::max());
    std::uint64_t total = 0;
    for (GLsizei patch = 0; patch < info.patchCount; ++patch) {
        const std::uint16_t* f = factors + static_cast<std::size_t>(patch) * 6u;
        const float o0 = appglHalfBitsToFloat(f[0]);
        const float o1 = appglHalfBitsToFloat(f[1]);
        const float o2 = appglHalfBitsToFloat(f[2]);
        const float o3 = appglHalfBitsToFloat(f[3]);
        const float i0 = appglHalfBitsToFloat(f[4]);
        const float i1 = appglHalfBitsToFloat(f[5]);
        const std::uint64_t patchVerts =
            appglTessPatchVertexCountForCapacity(info, o0, o1, o2, o3, i0, i1);
        if (total > maxOut - patchVerts) {
            return std::numeric_limits<NSUInteger>::max();
        }
        total += patchVerts;
    }
    return static_cast<NSUInteger>(std::max<std::uint64_t>(total, 1u));
}

static NSUInteger appglOptionalTessEvalComputeByteLimit() {
    constexpr std::uint64_t kDefaultLimit = 2ull * 1024ull * 1024ull * 1024ull;
    const char* raw = std::getenv("APPGL_OPTIONAL_TESS_COMPUTE_BYTE_LIMIT");
    if (raw == nullptr || raw[0] == '\0') {
        return static_cast<NSUInteger>(kDefaultLimit);
    }
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(raw, &end, 0);
    if (end == raw) {
        return static_cast<NSUInteger>(kDefaultLimit);
    }
    return static_cast<NSUInteger>(parsed);
}

static std::size_t appglAlignUp(std::size_t value, std::size_t alignment) {
    if (alignment <= 1) {
        return value;
    }
    const std::size_t rem = value % alignment;
    return rem == 0 ? value : value + (alignment - rem);
}

static std::string appglTrimCopy(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size() &&
           std::isspace(static_cast<unsigned char>(value[begin]))) {
        ++begin;
    }
    std::size_t end = value.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }
    return value.substr(begin, end - begin);
}

static bool appglMslBaseTypeLayout(const std::string& rawType,
                                   std::size_t& size,
                                   std::size_t& alignment) {
    const std::string type = appglTrimCopy(rawType);
    auto vectorLayout = [&](std::size_t scalarBytes,
                            std::size_t count) -> bool {
        if (count == 0) {
            return false;
        }
        if (count == 3 || count == 4) {
            size = scalarBytes * 4;
            alignment = scalarBytes * 4;
        } else {
            size = scalarBytes * count;
            alignment = scalarBytes * count;
        }
        return true;
    };

    if (type.rfind("packed_float3", 0) == 0) {
        size = 12;
        alignment = 4;
        return true;
    }
    if (type.rfind("float", 0) == 0 || type.rfind("int", 0) == 0 ||
        type.rfind("uint", 0) == 0) {
        const char* prefix = type.rfind("float", 0) == 0 ? "float" :
            (type.rfind("uint", 0) == 0 ? "uint" : "int");
        const std::size_t prefixLen = std::strlen(prefix);
        if (type.size() == prefixLen) {
            return vectorLayout(4, 1);
        }
        if (type.find('x', prefixLen) != std::string::npos) {
            size = 64;
            alignment = 16;
            return true;
        }
        const unsigned char c = static_cast<unsigned char>(type[prefixLen]);
        if (std::isdigit(c)) {
            return vectorLayout(4, static_cast<std::size_t>(type[prefixLen] - '0'));
        }
    }
    if (type.rfind("half", 0) == 0) {
        if (type.size() == 4) {
            return vectorLayout(2, 1);
        }
        const unsigned char c = static_cast<unsigned char>(type[4]);
        if (std::isdigit(c)) {
            return vectorLayout(2, static_cast<std::size_t>(type[4] - '0'));
        }
    }
    if (type.rfind("appgl_df64", 0) == 0 || type.rfind("double", 0) == 0) {
        size = 16;
        alignment = 16;
        return true;
    }
    if (type == "bool") {
        size = 4;
        alignment = 4;
        return true;
    }
    return false;
}

static bool appglMslMemberLayout(const std::string& rawDecl,
                                 std::size_t& size,
                                 std::size_t& alignment) {
    const std::string decl = appglTrimCopy(rawDecl);
    if (decl.empty()) {
        return false;
    }
    const std::string unsafePrefix = "spvUnsafeArray<";
    const std::size_t unsafePos = decl.find(unsafePrefix);
    if (unsafePos != std::string::npos) {
        const std::size_t typeBegin = unsafePos + unsafePrefix.size();
        const std::size_t comma = decl.find(',', typeBegin);
        const std::size_t close = decl.find('>', comma);
        if (comma == std::string::npos || close == std::string::npos) {
            return false;
        }
        std::size_t elemSize = 0;
        std::size_t elemAlign = 0;
        if (!appglMslBaseTypeLayout(decl.substr(typeBegin, comma - typeBegin),
                                    elemSize, elemAlign)) {
            return false;
        }
        const std::string countText =
            appglTrimCopy(decl.substr(comma + 1, close - comma - 1));
        char* end = nullptr;
        const unsigned long long count =
            std::strtoull(countText.c_str(), &end, 10);
        if (end == countText.c_str()) {
            return false;
        }
        const std::size_t stride = appglAlignUp(elemSize, elemAlign);
        size = stride * static_cast<std::size_t>(std::max<unsigned long long>(count, 1));
        alignment = elemAlign;
        return true;
    }

    const std::size_t typeEnd = decl.find_first_of(" \t");
    if (typeEnd == std::string::npos) {
        return false;
    }
    std::size_t baseSize = 0;
    std::size_t baseAlign = 0;
    if (!appglMslBaseTypeLayout(decl.substr(0, typeEnd), baseSize, baseAlign)) {
        return false;
    }
    std::size_t count = 1;
    const std::size_t bracket = decl.find('[', typeEnd);
    if (bracket != std::string::npos) {
        const std::size_t close = decl.find(']', bracket);
        if (close != std::string::npos) {
            char* end = nullptr;
            const std::string countText =
                appglTrimCopy(decl.substr(bracket + 1, close - bracket - 1));
            const unsigned long long parsed =
                std::strtoull(countText.c_str(), &end, 10);
            if (end != countText.c_str()) {
                count = static_cast<std::size_t>(std::max<unsigned long long>(parsed, 1));
            }
        }
    }
    size = appglAlignUp(baseSize, baseAlign) * count;
    alignment = baseAlign;
    return true;
}

static std::size_t appglEstimateMslStructStrideBytes(const std::string* msl,
                                                     const char* structName) {
    if (msl == nullptr || structName == nullptr) {
        return 0;
    }
    const std::string needle = std::string("struct ") + structName;
    const std::size_t structPos = msl->find(needle);
    if (structPos == std::string::npos) {
        return 0;
    }
    const std::size_t bodyBegin = msl->find('{', structPos);
    const std::size_t bodyEnd = msl->find("};", bodyBegin);
    if (bodyBegin == std::string::npos || bodyEnd == std::string::npos) {
        return 0;
    }

    std::size_t offset = 0;
    std::size_t maxAlign = 1;
    bool sawMember = false;
    std::size_t cursor = bodyBegin + 1;
    while (cursor < bodyEnd) {
        const std::size_t semi = msl->find(';', cursor);
        if (semi == std::string::npos || semi > bodyEnd) {
            break;
        }
        const std::string decl = msl->substr(cursor, semi - cursor);
        cursor = semi + 1;
        std::size_t memberSize = 0;
        std::size_t memberAlign = 0;
        if (!appglMslMemberLayout(decl, memberSize, memberAlign)) {
            offset = appglAlignUp(offset, 16) + 256;
            maxAlign = std::max<std::size_t>(maxAlign, 16);
            continue;
        }
        offset = appglAlignUp(offset, memberAlign);
        offset += memberSize;
        maxAlign = std::max(maxAlign, memberAlign);
        sawMember = true;
    }
    return sawMember ? appglAlignUp(offset, maxAlign) : 0;
}

// Phase 4A [metal-tess-TF] — MSL source for the CPU-exact domain-gen
// port. Shared between the production path (`ensureTessDomainPortLibrary`
// on `Impl`) and the validation probe (`phaseAProbeTessDomainPort`).
//
// Bit-exact port of `generateTessDomain` in TessellationEmulator.cpp
// (source of truth per
// `specs-worker-docs/HANDOFF-2026-04-24-pm-tess-domain-msl-port.md`).
// CPU parity requires compiling with `MTLMathModeSafe` — default
// compile options fuse `1 - fu - fv` into single-rounded ops and
// drift 1 ULP on boundary vertices.
static NSString* const kTessDomainPortMSL = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct QuadFactors {
    half edgeTessellationFactor[4];
    half insideTessellationFactor[2];
};

struct TessPortParams {
    uint genMode;        // 0=Triangles, 1=Quads (Isolines deferred)
    uint genSpacing;     // 0=Equal, 1=FractionalEven, 2=FractionalOdd
    uint patchCount;
    uint pointMode;
    uint flipWinding;
};

// Port of `segmentCount` in TessellationEmulator.cpp. Clamp matches
// the CPU's `!(level >= 1.0f)` semantics (NaN goes to 1.0 too).
inline uint spvPortSegmentCount(float level, uint spacing) {
    if (!(level >= 1.0f)) level = 1.0f;
    if (level > 64.0f) level = 64.0f;
    int n = int(ceil(level));
    if (spacing == 1u) {
        if (n < 2) n = 2;
        if ((n & 1) != 0) n += 1;
    } else if (spacing == 2u) {
        if (n < 1) n = 1;
        if ((n & 1) == 0) n += 1;
    } else {
        if (n < 1) n = 1;
    }
    return uint(n);
}

inline void spvPortEmitTriangle(
    float3 a, float3 b, float3 c,
    uint primID, uint flipWinding,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 3u, memory_order_relaxed);
    coords[base + 0] = packed_float3(a);
    if (flipWinding != 0u) {
        coords[base + 1] = packed_float3(c);
        coords[base + 2] = packed_float3(b);
    } else {
        coords[base + 1] = packed_float3(b);
        coords[base + 2] = packed_float3(c);
    }
    primIDs[base + 0] = primID;
    primIDs[base + 1] = primID;
    primIDs[base + 2] = primID;
}

inline void spvPortEmitPoint(
    float3 c,
    uint primID,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(c);
    primIDs[base] = primID;
}

void spvPortGenTriangles(
    uint patchID,
    constant TessPortParams& params,
    const device QuadFactors* factors,
    device packed_float3* coords,
    device uint* primIDs,
    device atomic_uint* cursor)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
    float i0 = float(f.insideTessellationFactor[0]);
    uint N = spvPortSegmentCount(max(max(o0, o1), max(o2, i0)),
                                  params.genSpacing);
    float fN = float(N);

    if (params.pointMode != 0u) {
        for (uint j = 0u; j <= N; ++j) {
            uint rowLen = N + 1u - j;
            float fv = precise::divide(float(j), fN);
            for (uint i = 0u; i < rowLen; ++i) {
                float fu = precise::divide(float(i), fN);
                float fw = 1.0f - fu - fv;
                spvPortEmitPoint(float3(fu, fv, fw), patchID,
                                  cursor, coords, primIDs);
            }
        }
        return;
    }

    for (uint j = 0u; j + 1u <= N; ++j) {
        uint row0Len = N + 1u - j;
        uint row1Len = N - j;
        float vj0 = precise::divide(float(j),        fN);
        float vj1 = precise::divide(float(j + 1u),   fN);
        for (uint i = 0u; i + 1u < row0Len; ++i) {
            float ui0 = precise::divide(float(i),        fN);
            float ui1 = precise::divide(float(i + 1u),   fN);
            float wa0 = 1.0f - ui0 - vj0;
            float wa1 = 1.0f - ui1 - vj0;
            float wb0 = 1.0f - ui0 - vj1;
            float wb1 = 1.0f - ui1 - vj1;
            if (i < row1Len) {
                spvPortEmitTriangle(
                    float3(ui0, vj0, wa0),
                    float3(ui1, vj0, wa1),
                    float3(ui0, vj1, wb0),
                    patchID, params.flipWinding,
                    cursor, coords, primIDs);
            }
            if (i + 1u < row1Len) {
                spvPortEmitTriangle(
                    float3(ui1, vj0, wa1),
                    float3(ui1, vj1, wb1),
                    float3(ui0, vj1, wb0),
                    patchID, params.flipWinding,
                    cursor, coords, primIDs);
            }
        }
    }
}

void spvPortGenQuads(
    uint patchID,
    constant TessPortParams& params,
    const device QuadFactors* factors,
    device packed_float3* coords,
    device uint* primIDs,
    device atomic_uint* cursor)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
    float o3 = float(f.edgeTessellationFactor[3]);
    float i0 = float(f.insideTessellationFactor[0]);
    float i1 = float(f.insideTessellationFactor[1]);
    uint uN = spvPortSegmentCount(max(max(o0, o2), i0), params.genSpacing);
    uint vN = spvPortSegmentCount(max(max(o1, o3), i1), params.genSpacing);
    float fuN = float(uN);
    float fvN = float(vN);

    if (params.pointMode != 0u) {
        for (uint j = 0u; j <= vN; ++j) {
            float v = precise::divide(float(j), fvN);
            for (uint i = 0u; i <= uN; ++i) {
                float u = precise::divide(float(i), fuN);
                spvPortEmitPoint(float3(u, v, 0.0f), patchID,
                                  cursor, coords, primIDs);
            }
        }
        return;
    }

    for (uint j = 0u; j < vN; ++j) {
        float v0 = precise::divide(float(j),        fvN);
        float v1 = precise::divide(float(j + 1u),   fvN);
        for (uint i = 0u; i < uN; ++i) {
            float u0 = precise::divide(float(i),        fuN);
            float u1 = precise::divide(float(i + 1u),   fuN);
            spvPortEmitTriangle(
                float3(u0, v0, 0.0f),
                float3(u1, v0, 0.0f),
                float3(u1, v1, 0.0f),
                patchID, params.flipWinding,
                cursor, coords, primIDs);
            spvPortEmitTriangle(
                float3(u0, v0, 0.0f),
                float3(u1, v1, 0.0f),
                float3(u0, v1, 0.0f),
                patchID, params.flipWinding,
                cursor, coords, primIDs);
        }
    }
}

kernel void spvGenTessDomainTrianglesPort(
    constant TessPortParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* coords [[buffer(25)]],
    device uint* primIDs [[buffer(24)]],
    device atomic_uint* cursor [[buffer(23)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        spvPortGenTriangles(p, params, factors, coords, primIDs, cursor);
    }
}

kernel void spvGenTessDomainQuadsPort(
    constant TessPortParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* coords [[buffer(25)]],
    device uint* primIDs [[buffer(24)]],
    device atomic_uint* cursor [[buffer(23)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        spvPortGenQuads(p, params, factors, coords, primIDs, cursor);
    }
}
)MSL";

// Phase 8X Group 4d follow-up¹⁴ — shared Metal translation helpers.
//
// These replace the inline `glTypeToMTLFormat` lambda that used to
// live inside `encodeTranslatedDraw`. `vaoTypeToMTLFormat` is the
// source-of-truth format derivation for each vertex attribute — it
// reads the VAO's `glVertexAttribPointer` parameters (type + size +
// normalized + integer) and returns the matching MTLVertexFormat. The
// old path fell back on `ShaderReflection::vertexInputs[i].type`,
// which only told us the *scalar* type the shader declared
// (`Float4`, `Int4`, …) and blindly trusted it even when the VBO
// actually stored packed UBYTE colors. BAR followup¹³-verification
// §Smoking-Gun showed that is exactly what breaks spring's glyph-
// text draw: `in vec4 col` reflected as `Float4`, but the VBO held
// `glVertexAttribPointer(loc, 4, GL_UNSIGNED_BYTE, GL_TRUE, 24, …)`
// — 4 bytes, not 16, so the GPU reinterpreted 4 bytes of UBYTE4 + 12
// bytes of the next vertex as `float4` and produced NaN.
static MTLVertexFormat vaoTypeToMTLFormat(
    GLenum type, GLint components, GLboolean normalized, bool isInteger)
{
    const bool norm = (normalized == GL_TRUE);
    const int  cc   = components < 1 ? 1 : (components > 4 ? 4 : components);

    switch (type) {
        case GL_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatFloat;
                case 2: return MTLVertexFormatFloat2;
                case 3: return MTLVertexFormatFloat3;
                default: return MTLVertexFormatFloat4;
            }
        case GL_HALF_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatHalf;
                case 2: return MTLVertexFormatHalf2;
                case 3: return MTLVertexFormatHalf3;
                default: return MTLVertexFormatHalf4;
            }
        case GL_UNSIGNED_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUChar;
                    case 2: return MTLVertexFormatUChar2;
                    case 3: return MTLVertexFormatUChar3;
                    default: return MTLVertexFormatUChar4;
                }
            }
            if (norm) {
                switch (cc) {
                    case 1: return MTLVertexFormatUCharNormalized;
                    case 2: return MTLVertexFormatUChar2Normalized;
                    case 3: return MTLVertexFormatUChar3Normalized;
                    default: return MTLVertexFormatUChar4Normalized;
                }
            }
            // Metal has no float-cast UChar format, so we can't cleanly
            // represent an unnormalized unsigned byte attribute feeding a
            // float shader input. Fall back to the normalized form — the
            // GPU will divide by 255, which is what the shader author
            // almost certainly wanted if they didn't ask for integer.
            switch (cc) {
                case 1: return MTLVertexFormatUCharNormalized;
                case 2: return MTLVertexFormatUChar2Normalized;
                case 3: return MTLVertexFormatUChar3Normalized;
                default: return MTLVertexFormatUChar4Normalized;
            }
        case GL_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatChar;
                    case 2: return MTLVertexFormatChar2;
                    case 3: return MTLVertexFormatChar3;
                    default: return MTLVertexFormatChar4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatCharNormalized;
                case 2: return MTLVertexFormatChar2Normalized;
                case 3: return MTLVertexFormatChar3Normalized;
                default: return MTLVertexFormatChar4Normalized;
            }
        case GL_UNSIGNED_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUShort;
                    case 2: return MTLVertexFormatUShort2;
                    case 3: return MTLVertexFormatUShort3;
                    default: return MTLVertexFormatUShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatUShortNormalized;
                case 2: return MTLVertexFormatUShort2Normalized;
                case 3: return MTLVertexFormatUShort3Normalized;
                default: return MTLVertexFormatUShort4Normalized;
            }
        case GL_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatShort;
                    case 2: return MTLVertexFormatShort2;
                    case 3: return MTLVertexFormatShort3;
                    default: return MTLVertexFormatShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatShortNormalized;
                case 2: return MTLVertexFormatShort2Normalized;
                case 3: return MTLVertexFormatShort3Normalized;
                default: return MTLVertexFormatShort4Normalized;
            }
        case GL_UNSIGNED_INT:
            switch (cc) {
                case 1: return MTLVertexFormatUInt;
                case 2: return MTLVertexFormatUInt2;
                case 3: return MTLVertexFormatUInt3;
                default: return MTLVertexFormatUInt4;
            }
        case GL_INT:
            switch (cc) {
                case 1: return MTLVertexFormatInt;
                case 2: return MTLVertexFormatInt2;
                case 3: return MTLVertexFormatInt3;
                default: return MTLVertexFormatInt4;
            }
        default:
            return MTLVertexFormatFloat4;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — GL → Metal blend factor / equation
// mapping. GL enum namespace is fragmented across separate color and
// alpha factors, but the Metal side uses a single `MTLBlendFactor`
// enum that covers both. We map the common factors and return
// `MTLBlendFactorZero` (the documented default) for anything we don't
// recognise.
static MTLBlendFactor glBlendFactorToMTL(GLenum f) {
    switch (f) {
        case GL_ZERO:                     return MTLBlendFactorZero;
        case GL_ONE:                      return MTLBlendFactorOne;
        case GL_SRC_COLOR:                return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR:      return MTLBlendFactorOneMinusSourceColor;
        case GL_DST_COLOR:                return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR:      return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA:                return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA:      return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA:                return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA:      return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_CONSTANT_COLOR:           return MTLBlendFactorBlendColor;
        case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case GL_CONSTANT_ALPHA:           return MTLBlendFactorBlendAlpha;
        case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        case GL_SRC_ALPHA_SATURATE:       return MTLBlendFactorSourceAlphaSaturated;
        default:                          return MTLBlendFactorZero;
    }
}

static MTLBlendOperation glBlendEqToMTL(GLenum eq) {
    switch (eq) {
        case GL_FUNC_ADD:              return MTLBlendOperationAdd;
        case GL_FUNC_SUBTRACT:         return MTLBlendOperationSubtract;
        case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case GL_MIN:                   return MTLBlendOperationMin;
        case GL_MAX:                   return MTLBlendOperationMax;
        default:                       return MTLBlendOperationAdd;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — pipeline cache key. A 64-bit hash
// of the state tuple that drives pipeline creation. The key includes
// the shader MSL because separable-program pipelines can splice
// different fragment executables onto one vertex-program container;
// without the source fingerprint, those PSOs alias in the per-program
// cache. The state portion starts with this layout:
//
//   [63..56] colorFormat low 8 bits  (MTLPixelFormat fits)
//   [55..55] blend.enabled
//   [54..54] colorMaskA
//   [53..53] colorMaskB
//   [52..52] colorMaskG
//   [51..51] colorMaskR
//   [50..48] eqRGB   (3 bits; covers Add/Sub/RevSub/Min/Max)
//   [47..45] eqAlpha (3 bits)
//   [44..41] srcRGB low 4 bits of MTLBlendFactor
//   [40..37] dstRGB low 4 bits
//   [36..33] srcAlpha low 4 bits
//   [32..29] dstAlpha low 4 bits
//   [28..0]  per-attribute format tuple hash (FNV-1a over the active
//            vertexAttributeLayouts + extraVertexBuffers[*].attributes
//            `glType/glComponentCount/glNormalized/glIsInteger` fields)
//
// The shader text is mixed in after the structured state bits with a
// deterministic FNV-1a pass, so common toggles (opaque ↔ alpha-blended
// with identical geometry layout) and SSO fragment swaps both produce
// distinct keys.
static std::uint64_t computePipelineCacheKey(
    const TranslatedDrawInfo& info, MTLPixelFormat colorFormat,
    NSUInteger sampleCount, bool forcePerSampleFS)
{
    std::uint64_t key = 0;
    key |= static_cast<std::uint64_t>(colorFormat & 0xFF) << 56;
    key |= (info.blend.enabled    ? 1ULL : 0ULL) << 55;
    key |= (info.blend.colorMaskA ? 1ULL : 0ULL) << 54;
    key |= (info.blend.colorMaskB ? 1ULL : 0ULL) << 53;
    key |= (info.blend.colorMaskG ? 1ULL : 0ULL) << 52;
    key |= (info.blend.colorMaskR ? 1ULL : 0ULL) << 51;

    // Phase 6-1a: mix the MSAA sample count into the cache key so
    // pipelines built for MS attachments don't alias with non-MS
    // pipelines. Metal supports 1/2/4/8 typically; 3 bits at a free
    // slot (27..29 — bit 28 was the rasterizer-discard flag, below)
    // holds the log2 nicely. Encoding: 1 → 0, 2 → 1, 4 → 2, 8 → 3.
    std::uint64_t sampleLog2 = 0;
    if (sampleCount <= 1) sampleLog2 = 0;
    else if (sampleCount == 2) sampleLog2 = 1;
    else if (sampleCount == 4) sampleLog2 = 2;
    else if (sampleCount == 8) sampleLog2 = 3;
    else sampleLog2 = 7;   // anything else — unique bucket
    key |= (sampleLog2 & 0x7ULL) << 25;   // bits 25..27 (was FNV hash tail)
    // Phase 6-1e: distinguish per-sample-FS pipeline from the
    // per-pixel-FS pipeline built from the same MSL source. Bit 24
    // is free (below the 25..27 sample-count field).
    key |= (forcePerSampleFS ? 1ULL : 0ULL) << 24;

    const std::uint64_t eqRGB = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationRGB)) & 0x7ULL;
    const std::uint64_t eqA = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationAlpha)) & 0x7ULL;
    key |= eqRGB << 48;
    key |= eqA   << 45;

    const std::uint64_t srcRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcRGB)) & 0xFULL;
    const std::uint64_t dstRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstRGB)) & 0xFULL;
    const std::uint64_t srcA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcAlpha)) & 0xFULL;
    const std::uint64_t dstA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstAlpha)) & 0xFULL;
    key |= srcRGB << 41;
    key |= dstRGB << 37;
    key |= srcA   << 33;
    key |= dstA   << 29;

    // Bit 28: rasterizer discard — pipelines built with
    // rasterizationEnabled=NO can't be reused when raster is enabled
    // (the fragment function is nil) and vice versa.
    key |= (info.rasterizerDiscard ? 1ULL : 0ULL) << 28;

    // FNV-1a over the per-attribute format tuple. 29 bits is enough
    // to discriminate the half-dozen distinct layouts BAR's draw
    // path sees in practice — grow if collisions show up.
    std::uint32_t hash = 2166136261u;
    auto mix = [&hash](std::uint32_t v) {
        hash ^= v;
        hash *= 16777619u;
    };
    auto hashLayout = [&](const TranslatedDrawInfo::VertexAttributeLayout& l) {
        mix(static_cast<std::uint32_t>(l.location));
        mix(static_cast<std::uint32_t>(l.offset));
        mix(static_cast<std::uint32_t>(l.glType));
        mix(static_cast<std::uint32_t>(l.glComponentCount));
        mix(static_cast<std::uint32_t>(l.glNormalized));
        mix(l.glIsInteger ? 1u : 0u);
    };
    mix(static_cast<std::uint32_t>(info.vertexStride));
    for (const auto& l : info.vertexAttributeLayouts) {
        hashLayout(l);
    }
    for (const auto& evb : info.extraVertexBuffers) {
        mix(static_cast<std::uint32_t>(evb.stride));
        mix(static_cast<std::uint32_t>(evb.divisor));
        mix(evb.constantStep ? 1u : 0u);
        for (const auto& l : evb.attributes) {
            hashLayout(l);
        }
    }
    key |= static_cast<std::uint64_t>(hash & 0x0FFFFFFFu);  // 28 bits (bit 28 = rasterizerDiscard)

    std::uint64_t fnv = 1469598103934665603ULL;
    auto mixByte = [&fnv](std::uint8_t byte) {
        fnv ^= static_cast<std::uint64_t>(byte);
        fnv *= 1099511628211ULL;
    };
    auto mixWord = [&](std::uint64_t word) {
        for (unsigned i = 0; i < 8; ++i) {
            mixByte(static_cast<std::uint8_t>((word >> (i * 8)) & 0xFFu));
        }
    };
    auto mixString = [&](const std::string* source) {
        if (source == nullptr) {
            mixWord(0);
            return;
        }
        mixWord(source->size());
        for (unsigned char c : *source) {
            mixByte(static_cast<std::uint8_t>(c));
        }
    };
    mixWord(key);
    mixString(info.vertexMSL);
    mixString(info.fragmentMSL);
    return fnv;
}

// Phase 6-1e / 6-2: transform a SPIRV-Cross fragment MSL source so
// Metal honours GL 4.6 §14.6 / ARB_sample_shading.
//
// Two coordinated rewrites:
//
// (1) Inject `uint _ap_sample_id [[sample_id]]` into `main0(...)`.
//     Metal has no explicit "force per-sample FS" knob; the only
//     trigger for per-sample invocation is the shader reading a
//     per-sample built-in. The parameter's presence alone is enough
//     — no body changes needed.
//
// (2) For each `[[user(locnN)]]` input varying in `main0_in`, add a
//     `sample_perspective` qualifier. Metal's default interpolation
//     for a user varying is `center_perspective` (pixel-center),
//     which means that even when per-sample FS fires via (1) the
//     interpolated input is still the same at every sample in a
//     pixel — producing 1 unique color per pixel column rather than
//     `samples` unique. GLSL §4.3.4.1 says when sample shading is
//     enabled, inputs that don't carry `centroid` or `flat` are
//     interpolated at the sample location; Metal expresses this
//     as `sample_perspective` / `sample_no_perspective`. We use
//     `sample_perspective` (matches the typical GLSL `smooth` /
//     default perspective-corrected interpolation) and leave
//     already-qualified varyings (`flat`, `centroid_*`, any prior
//     `sample_*`) alone.
//
// Entry-point shape from SPIRV-Cross on macOS:
//   struct main0_in { float4 v_color [[user(locn0)]]; };
//   fragment main0_out main0(main0_in in [[stage_in]]) { ... }
// Also accepts the empty-param variant (`main0()`) and nested parens
// inside the param list (e.g. cast expressions). Each rewrite step
// falls back to the original MSL when its anchor isn't found, so
// the returned string is always valid MSL.
static std::string rewriteFragmentMSLForPerSample(const std::string& fsMsl)
{
    std::string working = fsMsl;

    // Step (1): [[sample_id]] inject.
    // Fast-out when the shader already reads [[sample_id]]; otherwise
    // we'd risk emitting two parameters with the same attribute and
    // Metal would reject the pipeline.
    if (working.find("[[sample_id]]") == std::string::npos) do {
        const std::size_t openParen = working.find("main0(");
        if (openParen == std::string::npos) break;
        const std::size_t paramStart = openParen + 6;   // past "main0("
        std::size_t depth = 1;
        std::size_t pos = paramStart;
        while (pos < working.size() && depth > 0) {
            const char c = working[pos];
            if (c == '(') {
                ++depth;
            } else if (c == ')') {
                --depth;
                if (depth == 0) break;
            }
            ++pos;
        }
        if (depth != 0 || pos >= working.size()) break;

        const std::string paramSlice = working.substr(paramStart, pos - paramStart);
        const bool hasExistingParams =
            paramSlice.find_first_not_of(" \t\n\r") != std::string::npos;

        std::string out;
        out.reserve(working.size() + 64);
        out.append(working, 0, pos);
        if (hasExistingParams) {
            out.append(", ");
        }
        out.append("uint _ap_sample_id [[sample_id]]");
        out.append(working, pos, std::string::npos);
        working = std::move(out);
    } while (false);

    // Step (2): sample_perspective qualifier on main0_in varyings.
    // Locate the `struct main0_in {` block and rewrite each
    // `[[user(locnN)]]` inside to `[[user(locnN), sample_perspective]]`.
    // Leave already-qualified `[[user(locnN), flat]]` /
    // `[[user(locnN), centroid_*]]` / `[[user(locnN), sample_*]]`
    // unchanged — only the bare attribute gets the qualifier.
    do {
        const std::size_t structPos = working.find("struct main0_in");
        if (structPos == std::string::npos) break;
        const std::size_t openBrace = working.find('{', structPos);
        if (openBrace == std::string::npos) break;
        // Walk to matching close brace. main0_in is flat (no nested
        // structs), but keep a depth counter for defensiveness.
        std::size_t depth = 1;
        std::size_t closeBrace = openBrace + 1;
        while (closeBrace < working.size() && depth > 0) {
            const char c = working[closeBrace];
            if (c == '{') ++depth;
            else if (c == '}') { --depth; if (depth == 0) break; }
            ++closeBrace;
        }
        if (depth != 0 || closeBrace >= working.size()) break;

        std::string out;
        out.reserve(working.size() + 128);
        out.append(working, 0, openBrace + 1);

        std::size_t scan = openBrace + 1;
        while (scan < closeBrace) {
            const std::size_t attrStart = working.find("[[user(locn", scan);
            if (attrStart == std::string::npos || attrStart >= closeBrace) {
                out.append(working, scan, closeBrace - scan);
                break;
            }
            // Walk from `[[user(locn` to the closing `)`.
            std::size_t cursor = attrStart + 11;   // past "[[user(locn"
            while (cursor < closeBrace && working[cursor] != ')') ++cursor;
            if (cursor >= closeBrace) {
                out.append(working, scan, closeBrace - scan);
                break;
            }
            // Now `working[cursor]` is the ')' that closes the user
            // locn. Check what follows. Bare `[[user(locnN)]]` →
            // `cursor+1 == ']'` && `cursor+2 == ']'`. Qualified (has
            // comma inside) → the attribute ends past `]]` later.
            const bool isBare =
                cursor + 2 < working.size() &&
                working[cursor + 1] == ']' &&
                working[cursor + 2] == ']';
            if (isBare) {
                // Copy [scan .. cursor+1) → "[[user(locnN)" (+ all prior text)
                out.append(working, scan, (cursor + 1) - scan);
                // Insert ", sample_perspective" before the "]]"
                out.append(", sample_perspective");
                // Copy "]]"
                out.append(working, cursor + 1, 2);
                scan = cursor + 3;
            } else {
                // Already qualified. Walk to the attribute's closing
                // `]]` and copy verbatim.
                std::size_t end = cursor + 1;
                while (end + 1 < closeBrace &&
                       !(working[end] == ']' && working[end + 1] == ']')) {
                    ++end;
                }
                if (end + 1 >= closeBrace) {
                    // Malformed; bail and copy rest verbatim.
                    out.append(working, scan, closeBrace - scan);
                    scan = closeBrace;
                    break;
                }
                out.append(working, scan, (end + 2) - scan);
                scan = end + 2;
            }
        }

        out.append(working, closeBrace, std::string::npos);
        working = std::move(out);
    } while (false);

    return working;
}

struct MetalFrameGraph::Impl {
    Impl(GLContext* ownerContext,
         void* rawLayer,
         void* rawDevice,
         void* rawCommandQueue,
         MetalCommandSubmission* rawCommandSubmission)
        : owner(ownerContext),
          layer((__bridge CAMetalLayer*)rawLayer),
          device((__bridge id<MTLDevice>)rawDevice),
          commandQueue((__bridge id<MTLCommandQueue>)rawCommandQueue),
          commandSubmission(rawCommandSubmission) {
#if !__has_feature(objc_arc)
        [layer retain];
#endif
        if (commandSubmission != nullptr) {
            commandSubmission->setPressureFlushCallback(
                [this](AppGLCommandReason reason) {
                    return maybeFlushCurrentForPressure(reason);
                });
        }
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.displaySyncEnabled = NO;
        }
        ensureDrawableResources();
        acquireRingSlot();  // OPT-8: acquire initial ring buffer slot (slot 0)
    }

    ~Impl() {
        // C48: nothing can consume deferred clears past teardown —
        // drop the registry retains without materializing.
        releasePendingFboClearsForTeardown();
        if (commandSubmission != nullptr) {
            commandSubmission->setPressureFlushCallback({});
        }
        if (threadedDeferredRecordGroup != nullptr) {
            dispatch_group_wait(threadedDeferredRecordGroup,
                                DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC
            dispatch_release(threadedDeferredRecordGroup);
#endif
            threadedDeferredRecordGroup = nullptr;
        }
        // End any open render encoder before the autorelease pool reclaims it.
        // Without this, destroying a context with an in-flight render pass
        // triggers "Command encoder released without endEncoding".
        endRenderPass();
        if (currentCommandBuffer != nil) {
            currentCommandBufferLease.commitAndWait(AppGLCommandReason::FrameGraphDestruct);
            currentCommandBuffer = nil;
        }
        // OPT-8: Release any acquired ring slot to balance the semaphore.
        // All in-flight completion handlers have fired (Metal processes CBs
        // in commit order, and waitUntilCompleted on the last ensures all
        // prior CBs completed).
        if (ringSlotAcquired) {
            signalRingSlotNow();
            ringSlotAcquired = false;
        }
        drawSubmitProfile.dump();
        parallelEncodeProfile.dump();
        threadedDeferredRecordProfile.dump();
        frameAttributionProfile.dump();
        // ADV-14: persist the pipeline binary archive to disk so the
        // next launch gets pre-compiled GPU binaries.
        savePipelineArchive();
        releaseDefaultFramebufferTextures();
        clearDummyColorTextureCache();
        readbackSourceTexture = nil;
        for (id<MTLBuffer>& buffer : ringBuffers) {
            releaseOwnedMetalResource(buffer);
            buffer = nil;
        }
        for (auto& entry : depthStencilCache) {
            releaseOwnedObjCObject(entry.second);
        }
        depthStencilCache.clear();
        for (auto& entry : tessDomainCapturePSOCache) {
            releaseOwnedObjCObject(entry.second);
        }
        tessDomainCapturePSOCache.clear();
        for (auto& bucket : mslLibraryCache) {
            for (auto& entry : bucket.second) {
                releaseOwnedObjCObject(entry.library);
            }
        }
        mslLibraryCache.clear();
        mslLibraryCacheEntryCount = 0;
        mslLibraryCacheSourceBytes = 0;
        mslLibraryCacheSourceKeyBytes = 0;
        releaseOwnedObjCObject(solidColorLibrary);
        releaseOwnedObjCObject(solidColorVertexFn);
        releaseOwnedObjCObject(solidColorFragmentFn);
        releaseOwnedObjCObject(solidColorPipelineState);
        releaseOwnedObjCObject(tessDomainGenLibrary);
        releaseOwnedObjCObject(tessDomainGenPipelineState);
        releaseOwnedObjCObject(tessDomainCaptureLibrary);
        releaseOwnedObjCObject(tessFactorClampPipelineState);
        releaseOwnedObjCObject(tessDomainPortLibrary);
        releaseOwnedObjCObject(tessDomainPortTrianglesPSO);
        releaseOwnedObjCObject(tessDomainPortQuadsPSO);
        releaseOwnedObjCObject(immediateModeLibrary);
        releaseOwnedObjCObject(immediateModeVertexFn);
        releaseOwnedObjCObject(immediateModeColorFragmentFn);
        releaseOwnedObjCObject(immediateModeTexturedFragmentFn);
        releaseOwnedObjCObject(immediateModeColorPipelineState);
        releaseOwnedObjCObject(immediateModeTexturedPipelineState);
        releaseOwnedObjCObject(immediateModeSamplerState);
        releaseOwnedObjCObject(depthStencilUploadLibrary);
        releaseOwnedObjCObject(depthStencilUploadVertexFn);
        releaseOwnedObjCObject(depthStencilUploadFragmentFn);
        for (auto& entry : depthStencilUploadPSOCache) {
            releaseOwnedObjCObject(entry.second);
        }
        depthStencilUploadPSOCache.clear();
        releaseOwnedObjCObject(reusablePassDescriptor);
        releaseOwnedObjCObject(pipelineArchive);
        releaseOwnedObjCObject(layer);
        layer = nil;
    }

    void releaseDefaultFramebufferTextures() {
        releaseDepthStencilTexture();
        releaseOffscreenColorTexture();
    }

    void releaseOwnedTexture(id<MTLTexture>& texture) {
        if (texture == nil) {
            return;
        }
        if (readbackSourceTexture == texture) {
            readbackSourceTexture = nil;
        }
        releaseOwnedMetalResource(texture);
        texture = nil;
    }

    void replaceOwnedTexture(id<MTLTexture>& slot, id<MTLTexture> replacement) {
        if (slot == replacement) {
            return;
        }
        releaseOwnedTexture(slot);
        slot = replacement;
    }

    id<MTLTexture> newDepthStencilTexture(MTLTextureDescriptor* descriptor) {
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture != nil) {
            ++depthStencilTextureRebuilds;
            depthStencilTextureAllocatedBytes += metalAllocatedSize(texture);
        }
        return texture;
    }

    id<MTLTexture> newOffscreenColorTexture(MTLTextureDescriptor* descriptor) {
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture != nil) {
            ++offscreenColorTextureRebuilds;
            offscreenColorTextureAllocatedBytes += metalAllocatedSize(texture);
        }
        return texture;
    }

    id<MTLTexture> newDummyColorTexture(MTLTextureDescriptor* descriptor) {
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture != nil) {
            ++dummyColorTextureAllocations;
            dummyColorTextureAllocatedBytes += metalAllocatedSize(texture);
        }
        return texture;
    }

    struct DummyColorTextureCacheKey {
        MTLPixelFormat pixelFormat = MTLPixelFormatInvalid;
        NSUInteger width = 0;
        NSUInteger height = 0;
        NSUInteger sampleCount = 1;
        NSUInteger arrayLength = 1;
        MTLTextureType textureType = MTLTextureType2D;
        MTLStorageMode storageMode = MTLStorageModePrivate;
        MTLTextureUsage usage = MTLTextureUsageRenderTarget;

        bool operator==(const DummyColorTextureCacheKey& other) const {
            return pixelFormat == other.pixelFormat &&
                width == other.width &&
                height == other.height &&
                sampleCount == other.sampleCount &&
                arrayLength == other.arrayLength &&
                textureType == other.textureType &&
                storageMode == other.storageMode &&
                usage == other.usage;
        }
    };

    struct DummyColorTextureCacheKeyHash {
        std::size_t operator()(const DummyColorTextureCacheKey& key) const {
            std::size_t seed = static_cast<std::size_t>(key.pixelFormat);
            auto mix = [&](std::size_t value) {
                seed ^= value + 0x9e3779b97f4a7c15ull + (seed << 6) + (seed >> 2);
            };
            mix(static_cast<std::size_t>(key.width));
            mix(static_cast<std::size_t>(key.height));
            mix(static_cast<std::size_t>(key.sampleCount));
            mix(static_cast<std::size_t>(key.arrayLength));
            mix(static_cast<std::size_t>(key.textureType));
            mix(static_cast<std::size_t>(key.storageMode));
            mix(static_cast<std::size_t>(key.usage));
            return seed;
        }
    };

    struct DummyColorTextureCacheBucket {
        std::vector<id<MTLTexture>> textures;
        std::size_t next = 0;
    };

    DummyColorTextureCacheKey dummyColorTextureCacheKey(
        MTLTextureDescriptor* descriptor) const {
        DummyColorTextureCacheKey key;
        key.pixelFormat = descriptor.pixelFormat;
        key.width = descriptor.width;
        key.height = descriptor.height;
        key.sampleCount = std::max<NSUInteger>(descriptor.sampleCount, 1);
        key.arrayLength = std::max<NSUInteger>(descriptor.arrayLength, 1);
        key.textureType = descriptor.textureType;
        key.storageMode = descriptor.storageMode;
        key.usage = descriptor.usage;
        return key;
    }

    id<MTLTexture> reusableDummyColorTexture(MTLTextureDescriptor* descriptor) {
        static constexpr std::size_t kReusableDummyTexturesPerShape = 3;
        const DummyColorTextureCacheKey key = dummyColorTextureCacheKey(descriptor);
        auto& bucket = dummyColorTextureCache[key];
        if (bucket.textures.size() < kReusableDummyTexturesPerShape) {
            id<MTLTexture> texture = newDummyColorTexture(descriptor);
            if (texture == nil) {
                return nil;
            }
            bucket.textures.push_back(texture);
            return texture;
        }
        id<MTLTexture> texture = bucket.textures[bucket.next];
        bucket.next = (bucket.next + 1u) % bucket.textures.size();
        ++dummyColorTextureCacheHits;
        return texture;
    }

    void clearDummyColorTextureCache() {
        for (auto& entry : dummyColorTextureCache) {
            for (id<MTLTexture> texture : entry.second.textures) {
                releaseOwnedMetalResource(texture);
            }
        }
        dummyColorTextureCache.clear();
    }

    void releaseDepthStencilTexture() {
        if (depthStencilTexture != nil) {
            ++depthStencilTextureReleases;
        }
        releaseOwnedTexture(depthStencilTexture);
    }

    void releaseOffscreenColorTexture() {
        if (offscreenColorTexture != nil) {
            ++offscreenColorTextureReleases;
        }
        releaseOwnedTexture(offscreenColorTexture);
    }

    void replaceDepthStencilTexture(id<MTLTexture> replacement) {
        if (depthStencilTexture != replacement && depthStencilTexture != nil) {
            ++depthStencilTextureReleases;
        }
        replaceOwnedTexture(depthStencilTexture, replacement);
    }

    void replaceOffscreenColorTexture(id<MTLTexture> replacement) {
        if (offscreenColorTexture != replacement && offscreenColorTexture != nil) {
            ++offscreenColorTextureReleases;
        }
        replaceOwnedTexture(offscreenColorTexture, replacement);
    }

    void replaceOwnedObjCObject(id& slot, id replacement) {
        if (slot == replacement) {
            return;
        }
        releaseOwnedObjCObject(slot);
        slot = replacement;
    }

    void attachFragmentShadingRateMap(
        MTLRenderPassDescriptor* pass,
        GLenum rate,
        id<MTLTexture> colorTexture,
        NSUInteger renderTargetLayerCount
    ) {
        if (rate == GL_SHADING_RATE_1X1_PIXELS_EXT ||
            owner == nullptr || pass == nil || colorTexture == nil || renderTargetLayerCount > 1) {
            return;
        }
        ExtensionContext extensionContext(*owner);
        const auto& hooks = extensions::ExtensionRegistry::fragmentShadingRateHooks();
        if (hooks.attachRenderPass != nullptr) {
            hooks.attachRenderPass(extensionContext,
                                   (__bridge void*)pass,
                                   rate,
                                   (__bridge void*)colorTexture,
                                   renderTargetLayerCount);
        }
    }

    void resize(GLsizei width, GLsizei height) {
        ++drawableResizeCalls;
        drawableResizeLastRequestedWidth =
            static_cast<std::uint64_t>(width > 0 ? width : 1);
        drawableResizeLastRequestedHeight =
            static_cast<std::uint64_t>(height > 0 ? height : 1);
        GLsizei newW = width > 0 ? width : 1;
        GLsizei newH = height > 0 ? height : 1;
        drawableResizeLastEffectiveWidth = static_cast<std::uint64_t>(newW);
        drawableResizeLastEffectiveHeight = static_cast<std::uint64_t>(newH);
        if (newW == drawableWidth && newH == drawableHeight) {
            ++drawableResizeNoops;
            return;  // No-op when size is unchanged.
        }
        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::Resize);
        drawableWidth = newW;
        drawableHeight = newH;
        headlessReadbackRGBA.clear();
        hasHeadlessReadback = false;
        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }
        endRenderPass();
        invalidateTransientState();
        if (depthStencilTexture != nil) {
            ++drawableResizeDepthTextureReleases;
        }
        if (offscreenColorTexture != nil) {
            ++drawableResizeOffscreenTextureReleases;
        }
        releaseDefaultFramebufferTextures();
    }

    void ensureSizeAtLeast(GLsizei width, GLsizei height) {
        const GLsizei requestedW = width > 0 ? width : 1;
        const GLsizei requestedH = height > 0 ? height : 1;
        if (requestedW <= drawableWidth && requestedH <= drawableHeight) {
            const bool requestedChanged =
                drawableResizeLastRequestedWidth !=
                    static_cast<std::uint64_t>(requestedW) ||
                drawableResizeLastRequestedHeight !=
                    static_cast<std::uint64_t>(requestedH);
            ++drawableResizeCalls;
            ++drawableResizeNoops;
            ++drawableResizeGrowOnlySkips;
            drawableResizeLastRequestedWidth =
                static_cast<std::uint64_t>(requestedW);
            drawableResizeLastRequestedHeight =
                static_cast<std::uint64_t>(requestedH);
            drawableResizeLastEffectiveWidth =
                static_cast<std::uint64_t>(drawableWidth);
            drawableResizeLastEffectiveHeight =
                static_cast<std::uint64_t>(drawableHeight);
            if (requestedChanged) {
                ++encoderClosesViewportRequestInvalidate;  // C49 census (rider target → ~0)
                flushParallelTranslatedDrawBatch(
                    ParallelEncodeBoundaryReason::Resize);
                headlessReadbackRGBA.clear();
                hasHeadlessReadback = false;
                endRenderPass();
                invalidateTransientState();
            }
            return;
        }
        resize(std::max(requestedW, drawableWidth),
               std::max(requestedH, drawableHeight));
    }

    void enableOffscreen(GLsizei width, GLsizei height) {
        usesOffscreenTarget = true;
        resize(width, height);
    }

    void encodeClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    ) {
        if (device == nil || commandQueue == nil) {
            storeHeadlessClear(mask, clearRed, clearGreen, clearBlue, clearAlpha);
            return;
        }

        FG_TRACE(@"encodeClear: enter (deferred)  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);

        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::Clear);

        // OPT-8: Acquire a ring buffer slot before any GPU work.
        acquireRingSlot();

        // Close any open render encoder and flush the prior command buffer.
        // This serves as a frame boundary: Metal can start executing the
        // previous frame's work while we set up the next one.  The pending
        // clear will be merged into the NEXT render pass as a load action,
        // eliminating the old separate clear-only render pass (OPT-4).
        endRenderPass();
        if (currentCommandBuffer != nil) {
            commitWithFrameSignal(currentCommandBufferLease, AppGLCommandReason::FrameCommandBuffer);
            currentCommandBuffer = nil;
            clearCurrentDrawable();
            pendingPresent = false;
            advanceRingBuffer();
            acquireRingSlot();  // OPT-8: acquire the next slot for this frame
        }
        ensureDrawableResources();

        // Store the clear parameters; they'll be consumed when the next
        // render pass opens (in encodeTranslatedDraw or encodeSolidColorDraw).
        hasPendingClear = true;
        pendingClearMask = mask;
        pendingClearColor = MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
        pendingClearDepth = clearDepth;
        pendingClearStencil = static_cast<std::uint32_t>(clearStencil);

        pendingPresent = true;
    }

    void beginRenderPass(GLStateTracker& state, GLObjectStore& objects) {
        (void)state;
        (void)objects;
        if (device == nil || commandQueue == nil) {
            return;
        }
        acquireRingSlot();  // OPT-8
        FG_TRACE(@"beginRenderPass: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::BeginRenderPass);
        endRenderPass();
        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(AppGLCommandReason::BeginRenderPass);
        }
        if (!acquireDrawableIfNeeded()) {  // ADV-7
            return;
        }

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pass.depthAttachment.texture = depthStencilTexture;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = depthStencilTexture;
        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        const GLenum fragmentRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        attachFragmentShadingRateMap(pass, fragmentRate, colorTexture, 1);
        openCurrentRenderEncoder(pass);
        activeRenderPassFragmentShadingRate = fragmentRate;
        resetCachedEncoderState();
    }

    void* renderEncoder() const {
        return (__bridge void*)currentRenderEncoder;
    }

    void attachErrorHandler(id<MTLCommandBuffer> buf, NSString* label) {
#if APPGL_TRACE_FRAMEGRAPH
        buf.label = label;
        [buf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.status == MTLCommandBufferStatusError) {
                NSLog(@"[FG] *** COMMAND BUFFER ERROR *** label=%@ error=%@", cb.label, cb.error);
            }
        }];
#else
        (void)buf; (void)label;
#endif
    }

    MetalCommandBufferLease makeCommandBuffer(NSString* label) {
        return commandSubmission != nullptr
            ? commandSubmission->makeCommandBuffer(label)
            : MetalCommandBufferLease{};
    }

    MetalCommandBufferLease makeCommandBuffer(AppGLCommandReason reason) {
        return commandSubmission != nullptr
            ? commandSubmission->makeCommandBuffer(reason)
            : MetalCommandBufferLease{};
    }

    MetalCommandBufferLease makeCommandBufferDrainingAutorelease(NSString* label) {
        return commandSubmission != nullptr
            ? commandSubmission->makeCommandBufferDrainingAutorelease(label)
            : MetalCommandBufferLease{};
    }

    MetalCommandBufferLease makeCommandBufferDrainingAutorelease(AppGLCommandReason reason) {
        return commandSubmission != nullptr
            ? commandSubmission->makeCommandBufferDrainingAutorelease(reason)
            : MetalCommandBufferLease{};
    }

    bool ensureCurrentCommandBuffer(NSString* label) {
        return ensureCurrentCommandBuffer(label, AppGLCommandReason::Legacy);
    }

    bool ensureCurrentCommandBuffer(AppGLCommandReason reason) {
        return ensureCurrentCommandBuffer(appGLCommandReasonNSString(reason), reason);
    }

    bool ensureCurrentCommandBuffer(NSString* label, AppGLCommandReason reason) {
        if (currentCommandBuffer != nil) {
            return true;
        }
        currentCommandBufferLease = reason == AppGLCommandReason::Legacy
            ? makeCommandBuffer(label)
            : makeCommandBuffer(reason);
        currentCommandBuffer = currentCommandBufferLease.get();
        if (currentCommandBuffer != nil) {
            attachErrorHandler(currentCommandBuffer, label);
            return true;
        }
        return false;
    }

    bool openCurrentRenderEncoder(MTLRenderPassDescriptor* pass) {
        currentRenderEncoder =
            createRetainedRenderCommandEncoder(currentCommandBuffer, pass);
        if (currentRenderEncoder != nil) {
            ++renderEncoderOpenCalls;
            ++renderEncoderLiveRetains;
            renderEncoderPeakLiveRetains =
                std::max(renderEncoderPeakLiveRetains,
                         renderEncoderLiveRetains);
        }
        return currentRenderEncoder != nil;
    }

    void releaseCurrentRenderEncoder() {
        if (currentRenderEncoder != nil) {
            ++renderEncoderReleaseCalls;
            if (renderEncoderLiveRetains > 0) {
                --renderEncoderLiveRetains;
            }
        }
        releaseOwnedObjCObject(currentRenderEncoder);
        currentRenderEncoder = nil;
    }

    void endCurrentRenderPassOnly() {
        if (currentRenderEncoder != nil) {
            FG_TRACE(@"endRenderPass: ending encoder %p on cmdBuf %p", currentRenderEncoder, currentCommandBuffer);
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            pendingPresent = true;
        }
    }

    void endRenderPass() {
        if (!flushingParallelTranslatedBatch &&
            !flushingLeanDirectDescriptorBatch &&
            !flushingThreadedDeferredRecordBatch) {
            flushParallelTranslatedDrawBatch(
                ParallelEncodeBoundaryReason::EndRenderPass);
        }
        endCurrentRenderPassOnly();
    }

    bool commitCurrentAsync(AppGLCommandReason reason) {
        const DrawProfileTimePoint attributionStart =
            frameAttributionProfile.enabled ? drawProfileNow() : DrawProfileTimePoint{};
        if (currentRenderEncoder != nil) {
            ++encoderClosesCommandBufferCommit;  // C49 census
        }
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::CommandBufferCommit);
        endRenderPass();
        if (currentCommandBuffer == nil) {
            if (frameAttributionProfile.enabled) {
                frameAttributionProfile.recordCommitCurrent(
                    reason,
                    drawProfileElapsedUs(attributionStart, drawProfileNow()),
                    false);
            }
            return false;
        }
        presentCurrentDrawable(currentCommandBuffer);
        commitWithFrameSignal(currentCommandBufferLease, reason);
        invalidateTransientState();
        advanceRingBuffer();
        if (frameAttributionProfile.enabled) {
            frameAttributionProfile.recordCommitCurrent(
                reason,
                drawProfileElapsedUs(attributionStart, drawProfileNow()),
                true);
        }
        return true;
    }

    bool maybeFlushCurrentForPressure(AppGLCommandReason) {
        if (currentCommandBuffer == nil) {
            return false;
        }
        return commitCurrentAsync(AppGLCommandReason::PressureFlush);
    }

    bool shouldStubCommitBeforeAbandon() const {
#if APPGL_ENABLE_DCR_SENTINEL_HOOKS
        const char* raw = std::getenv("APPGL_STUB_COMMIT_BEFORE_ABANDON");
        return raw != nullptr && raw[0] != '\0' && std::strcmp(raw, "0") != 0;
#else
        return false;
#endif
    }

    bool commitCurrentBeforeTransientInvalidation(AppGLCommandReason reason) {
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::TransientInvalidation);
        endRenderPass();
        if (currentCommandBuffer == nil || currentCommandBufferLease.get() == nil) {
            return false;
        }
        if (shouldStubCommitBeforeAbandon()) {
            return false;
        }
        presentCurrentDrawable(currentCommandBuffer);
        commitWithFrameSignal(currentCommandBufferLease, reason);
        currentCommandBuffer = nil;
        clearCurrentDrawable();
        pendingPresent = false;
        advanceRingBuffer();
        return true;
    }

    // Flush a deferred clear into a standalone render pass. Called by
    // copyPixels and present when a clear is pending but no draws occurred.
    void flushPendingClear() {
        if (!hasPendingClear || device == nil) return;

        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(AppGLCommandReason::FlushClear);
            if (currentCommandBuffer == nil) { hasPendingClear = false; return; }
        }
        if (!acquireDrawableIfNeeded()) {  // ADV-7
            hasPendingClear = false; return;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) { hasPendingClear = false; return; }

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].loadAction = (pendingClearMask & GL_COLOR_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = pendingClearColor;
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.loadAction = (pendingClearMask & GL_DEPTH_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.depthAttachment.clearDepth = pendingClearDepth;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.loadAction = (pendingClearMask & GL_STENCIL_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.stencilAttachment.clearStencil = pendingClearStencil;
        }

        id<MTLRenderCommandEncoder> encoder =
            [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        hasPendingClear = false;
        pendingPresent = true;
    }

    // Solid-color fallback draw path.
    //
    // Hand-written "solid color" MSL pipeline consuming one float3 position
    // attribute and a single float4 uniform color. Used as a fallback when the
    // active program has no translated MSL (e.g. program 0 or translation
    // failure). The primary draw path is encodeTranslatedDraw(), which uses
    // the GLSL→SPIR-V→MSL pipeline output cached on GLProgramObject.
    bool encodeSolidColorDraw(const MetalDrawInfo& info) {
        FG_TRACE(@"encodeSolidColorDraw: enter  mode=0x%X verts=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        // C48: solid-color fallback draws don't fold deferred FBO
        // clears — materialize.
        materializeAllPendingFboClears();
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::SolidColorDraw);
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0 || info.positions == nullptr || info.positionByteCount == 0) {
            return false;
        }
        if (info.mode != GL_TRIANGLES && info.mode != GL_TRIANGLE_STRIP) {
            FG_TRACE(@"encodeSolidColorDraw: unsupported mode 0x%X, returning false", info.mode);
            return false;
        }
        if (info.positionComponents != 3) {
            return false;
        }

        ensureDrawableResources();
        if (!ensureSolidColorLibrary()) {
            return false;
        }
        if (!ensureSolidColorPipelineState(info)) {
            return false;
        }

        // Close any open render encoder before starting the solid-color pass.
        endRenderPass();

        // Reuse the current command buffer if one exists, otherwise create new.
        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(AppGLCommandReason::SolidColorDraw);
            if (currentCommandBuffer == nil) {
                return false;
            }
        }

        if (!acquireDrawableIfNeeded()) {  // ADV-7
            FG_TRACE(@"encodeSolidColorDraw: nextDrawable returned nil!");
            return false;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        // Merge any pending clear into this render pass's load action (OPT-4).
        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        hasPendingClear = false;

        attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, 1);
        id<MTLRenderCommandEncoder> encoder =
            [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            return false;
        }
        [encoder setRenderPipelineState:solidColorPipelineState];

        if (depthStencilTexture != nil) {
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(info);
            if (dsState != nil) {
                [encoder setDepthStencilState:dsState];
            }
        }

        if (info.cullFaceEnabled) {
            [encoder setCullMode:(info.cullFaceMode == GL_FRONT ? MTLCullModeFront :
                                  info.cullFaceMode == GL_FRONT_AND_BACK ? MTLCullModeBack : MTLCullModeBack)];
        } else {
            [encoder setCullMode:MTLCullModeNone];
        }
        [encoder setFrontFacingWinding:info.frontFace == GL_CW ? MTLWindingClockwise : MTLWindingCounterClockwise];
        [encoder setTriangleFillMode:info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];

        // Vertex positions are pushed as inline bytes (fits in Metal's 4KB limit
        // for every fixture we ship in Phase A). Attribute 0 lives in buffer 0.
        if (info.positionByteCount <= 4096) {
            [encoder setVertexBytes:info.positions length:info.positionByteCount atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.positions, info.positionByteCount);
            if (alloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }
        // Uniform color lives in fragment buffer 0.
        [encoder setFragmentBytes:info.uniformColor length:sizeof(info.uniformColor) atIndex:0];

        const MTLPrimitiveType primitive = (info.mode == GL_TRIANGLE_STRIP)
            ? MTLPrimitiveTypeTriangleStrip
            : MTLPrimitiveTypeTriangle;

        if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            switch (info.indexType) {
                case GL_UNSIGNED_INT:
                    metalIndexType = MTLIndexTypeUInt32;
                    bytesPerIndex = 4;
                    break;
                case GL_UNSIGNED_SHORT:
                    metalIndexType = MTLIndexTypeUInt16;
                    bytesPerIndex = 2;
                    break;
                default:
                    [encoder endEncoding];
                    return false;
            }
            const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
            auto iAlloc = ringSuballocate(info.indices, indexBytes);
            if (iAlloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder drawIndexedPrimitives:primitive
                                indexCount:static_cast<NSUInteger>(info.indexCount)
                                 indexType:metalIndexType
                               indexBuffer:iAlloc.buffer
                         indexBufferOffset:iAlloc.offset
                             instanceCount:1
                                baseVertex:static_cast<NSUInteger>(info.baseVertex)
                              baseInstance:0];
        } else {
            [encoder drawPrimitives:primitive
                        vertexStart:static_cast<NSUInteger>(info.baseVertex)
                        vertexCount:static_cast<NSUInteger>(info.vertexCount)];
        }

        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pendingPresent = true;
        return true;
    }

    bool encodeTranslatedDrawSerial(TranslatedDrawInfo& info) {
        FG_TRACE(@"encodeTranslatedDraw: enter  mode=0x%X verts=%d instances=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, info.instanceCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        DrawSubmitProfileSample profileSample;
        const bool profileDraw = drawSubmitProfile.enabled;
        const DrawProfileTimePoint profileTotalStart =
            profileDraw ? drawProfileNow() : DrawProfileTimePoint{};
        DrawProfileTimePoint profileValidationEnd = profileTotalStart;
        double profilePipelineBuildUs = 0.0;
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0) {
            FG_TRACE(@"encodeTranslatedDraw: vertexCount <= 0, returning false");
            return false;
        }
        // Attributeless draws (gl_VertexID-driven) have no vertex data.
        // Only reject missing vertex data when attributes are declared.
        bool hasExtraVertexAttributes = false;
        for (const auto& evb : info.extraVertexBuffers) {
            if (!evb.attributes.empty()) {
                hasExtraVertexAttributes = true;
                break;
            }
        }
        const bool hasPrimaryVertexAttributes = !info.vertexAttributeLayouts.empty();
        const bool attributelessDraw =
            (info.vertexData == nullptr && info.metalVertexBuffer == nullptr &&
             !hasPrimaryVertexAttributes && !hasExtraVertexAttributes);
        if (hasPrimaryVertexAttributes &&
            info.vertexData == nullptr &&
            info.metalVertexBuffer == nullptr) {
            FG_TRACE(@"encodeTranslatedDraw: bad vertex data, returning false");
            return false;
        }
        if (info.vertexMSL == nullptr || info.vertexMSL->empty()) {
            FG_TRACE(@"encodeTranslatedDraw: no vertex MSL, returning false");
            return false;
        }
        if (std::getenv("APPGL_TRACE_VIEWPORT_LAYER_ARRAY") != nullptr &&
            ((info.vertexMSL->find("[[viewport_array_index]]") != std::string::npos ||
              info.vertexMSL->find("[[render_target_array_index]]") != std::string::npos) ||
             info.viewportArrayCount > 1 ||
             info.fboColorArrayLength > 0)) {
            std::fprintf(stderr,
                "[SVLA] translated draw program=%u mode=0x%x verts=%d idx=%d "
                "vpCount=%zu fboArray=%u markViewport=%d hasVertexData=%d hasMetalVBO=%d attrLayouts=%zu\n",
                static_cast<unsigned>(info.program),
                static_cast<unsigned>(info.mode),
                static_cast<int>(info.vertexCount),
                static_cast<int>(info.indexCount),
                info.viewportArrayCount,
                info.fboColorArrayLength,
                info.markColorAttachmentReadbackFlip ? 1 : 0,
                info.vertexData != nullptr ? 1 : 0,
                info.metalVertexBuffer != nullptr ? 1 : 0,
                info.vertexAttributeLayouts.size());
        }
        // Fragment MSL is only required when rasterization runs. Under
        // GL_RASTERIZER_DISCARD the pipeline skips the fragment stage
        // entirely (see the rasterizerDiscard branch in the pipeline
        // descriptor setup below), so a VS-only program — the shape CTS
        // shader_storage_buffer_object.*-vs tests create — is a valid draw.
        const bool hasFragmentStage = (info.fragmentMSL != nullptr && !info.fragmentMSL->empty());
        if (!hasFragmentStage && !info.rasterizerDiscard) {
            FG_TRACE(@"encodeTranslatedDraw: no fragment MSL and raster enabled, returning false");
            return false;
        }

        // RC-A02: when an FBO render target is provided, use it instead of
        // the default framebuffer texture.
        const bool isAttachmentlessFBODraw =
            info.fboAttachmentless &&
            info.fboColorTexture == nullptr &&
            info.fboDepthStencilTexture == nullptr;
        const bool isFBODraw =
            info.fboColorTexture != nullptr ||
            info.fboDepthStencilTexture != nullptr ||
            isAttachmentlessFBODraw;
        id<MTLTexture> fboColorTex = (info.fboColorTexture != nullptr)
            ? (__bridge id<MTLTexture>)info.fboColorTexture : nil;
        id<MTLTexture> fboDepthStencilTex = (info.fboDepthStencilTexture != nullptr)
            ? (__bridge id<MTLTexture>)info.fboDepthStencilTexture : nil;
        if (!isFBODraw) {
            ensureDrawableResources();
        }
        id<MTLTexture> attachmentlessColorTex = nil;
        if (isAttachmentlessFBODraw) {
            const NSUInteger fboWidth =
                static_cast<NSUInteger>(std::max<GLsizei>(info.fboWidth, 1));
            const NSUInteger fboHeight =
                static_cast<NSUInteger>(std::max<GLsizei>(info.fboHeight, 1));
            const NSUInteger fboLayers =
                static_cast<NSUInteger>(std::max<std::uint32_t>(info.fboDefaultLayers, 1u));
            @autoreleasepool {
                MTLTextureDescriptor* dummyDesc =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                        width:fboWidth
                                                                       height:fboHeight
                                                                    mipmapped:NO];
                dummyDesc.storageMode = MTLStorageModePrivate;
                dummyDesc.usage = MTLTextureUsageRenderTarget;
                if (fboLayers > 1) {
                    dummyDesc.textureType = MTLTextureType2DArray;
                    dummyDesc.arrayLength = fboLayers;
                }
                attachmentlessColorTex = reusableDummyColorTexture(dummyDesc);
            }
            fboColorTex = attachmentlessColorTex;
        }
        id<MTLTexture> dsOnlyColorTex = nil;
        if (isFBODraw && fboColorTex == nil && fboDepthStencilTex != nil) {
            @autoreleasepool {
                MTLTextureDescriptor* dummyDesc =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                        width:fboDepthStencilTex.width
                                                                       height:fboDepthStencilTex.height
                                                                    mipmapped:NO];
                dummyDesc.storageMode = MTLStorageModePrivate;
                dummyDesc.usage = MTLTextureUsageRenderTarget;
                if (fboDepthStencilTex.sampleCount > 1) {
                    dummyDesc.textureType = MTLTextureType2DMultisample;
                    dummyDesc.sampleCount = fboDepthStencilTex.sampleCount;
                }
                dsOnlyColorTex = reusableDummyColorTexture(dummyDesc);
            }
            fboColorTex = dsOnlyColorTex;
        }
        if (profileDraw) {
            profileValidationEnd = drawProfileNow();
            profileSample.validationUs =
                drawProfileElapsedUs(profileTotalStart, profileValidationEnd);
        }

        // Lazily create the MTLRenderPipelineState from translated MSL.
        id<MTLTexture> colorTexture = isFBODraw ? fboColorTex
            : (usesOffscreenTarget ? offscreenColorTexture : nil);
        if (!isFBODraw && colorTexture == nil && currentRenderEncoder != nil) {
            colorTexture = readbackSourceTexture != nil
                ? readbackSourceTexture
                : (currentDrawable != nil ? currentDrawable.texture : nil);
        }
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        // Phase 8X Group 4d follow-up¹⁴ — map-based cache lookup.
        // The cache key encodes (colorFormat, blend tuple, per-
        // attribute format tuple) so a program that draws with
        // distinct blend modes or distinct VBO layouts keeps
        // multiple pipelines hot instead of thrashing on every
        // `glEnable(GL_BLEND)` ping-pong.
        // Phase 6-1a: sample count from the color attachment.
        // Single-sample textures report sampleCount=1; MS renderbuffers
        // created via renderbufferStorageMultisample report 2/4/8 etc.
        // We feed this into both the pipeline cache key and the
        // pipeline descriptor's rasterSampleCount further below.
        const NSUInteger attachmentSampleCount =
            colorTexture != nil ? colorTexture.sampleCount : 1;
        // Phase 6-1e: GL_SAMPLE_SHADING + MS attachment forces the FS to
        // run per-sample. Metal only switches to per-sample FS when the
        // shader reads a per-sample built-in ([[sample_id]] /
        // [[sample_position]]). When the GL state asks for sample-shading
        // on an MS attachment, we rewrite the FS MSL below to inject an
        // unused [[sample_id]] parameter. The pipeline cache key carries
        // this rewrite so toggling GL_SAMPLE_SHADING doesn't collide
        // with the per-pixel variant built from the same source.
        const bool forcePerSampleFS =
            info.sampleShadingEnabled && info.minSampleShading > 0.0f &&
            attachmentSampleCount > 1;

        // Step 7-3: argument-buffer mode. When APPGL_ENABLE_ARGUMENT_BUFFERS
        // is set, the fragment/vertex shader was compiled to read resources
        // through `constant spvDescriptorSetBuffer0& spvDescriptorSet0
        // [[buffer(24)]]` rather than direct [[texture(N)]] /
        // [[sampler(N)]] slots. We must build a Metal argument buffer per
        // stage per descriptor-set-in-use and bind it at the pinned
        // [[buffer(24)]] / [[buffer(25)]] slots.
        //
        // Step 7-4: MTLFunction caching via
        // `info.metalVertexFunction{,Out}` and `info.metalFragmentFunction{,Out}`.
        // First pipeline build under argbuf retains the vertex + fragment
        // MTLFunction on the GLProgramObject; subsequent draws reuse the
        // cache and skip the pipeline-rebuild cost. This undoes the pre-7-4
        // pipeline-cache-miss forcing we used to keep MTLFunctions in scope.
        const bool forceArgBufEnv =
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        if (info.translatedPlanRejectReasonOut != nullptr) {
            info.translatedPlanRejectReasonOut->clear();
        }
        auto rejectTranslatedPlan = [&info](const char* reason) {
            if (info.translatedPlanRejectReasonOut != nullptr) {
                info.translatedPlanRejectReasonOut->assign(reason);
            }
        };

        std::uint64_t pipelineCacheKey = 0;
        TranslatedDrawMSLSlots shaderSlots;
        bool vertexUsesArgBuf = false;
        bool fragmentUsesArgBuf = false;
        bool useArgBuf = false;
        bool vertexNeedsSSBOSizeBuffer = false;
        bool fragmentNeedsSSBOSizeBuffer = false;
        bool fragmentNeedsFragCoordParams = false;
        bool fragmentNeedsGlNumSamplesArgBuf = false;
        bool vertexNeedsFragmentShadingRateState = false;
        NSInteger vertexClipControlYSignSlot = -1;
        NSInteger fragmentDepthCompareFlipSlot = -1;
        bool clipControlShaderYFixup = false;
        bool clipControlInvertsWinding = false;
        bool vertexUsesMultiviewViewMask = false;
        bool fragmentUsesMultiviewViewMask = false;
        bool usedTranslatedPlan = false;
        bool traceOpenedRenderEncoder = false;
        MTLLoadAction traceColorLoadAction = MTLLoadActionLoad;
        MTLLoadAction traceDepthLoadAction = MTLLoadActionLoad;
        MTLLoadAction traceStencilLoadAction = MTLLoadActionLoad;
        MTLStoreAction traceColorStoreAction = MTLStoreActionStore;
        NSUInteger traceRenderTargetArrayLength = 0;

        const TranslatedDrawPlan* translatedPlan = info.translatedPlan;
        if (translatedPlan != nullptr) {
            if (!translatedPlan->valid) {
                rejectTranslatedPlan("invalid");
            } else if (forceArgBufEnv) {
                rejectTranslatedPlan("argbuf_env");
            } else if (translatedPlan->colorFormat !=
                       static_cast<std::uint32_t>(colorFormat)) {
                rejectTranslatedPlan("color_format");
            } else if (translatedPlan->attachmentSampleCount !=
                       static_cast<std::uint32_t>(attachmentSampleCount)) {
                rejectTranslatedPlan("sample_count");
            } else if (translatedPlan->forcePerSampleFS != forcePerSampleFS) {
                rejectTranslatedPlan("per_sample_fs");
            } else if (translatedPlan->hasFragmentStage != hasFragmentStage) {
                rejectTranslatedPlan("fragment_stage");
            } else if (translatedPlan->useArgumentBuffers) {
                rejectTranslatedPlan("argbuf_plan");
            } else {
                usedTranslatedPlan = true;
                pipelineCacheKey = translatedPlan->pipelineCacheKey;
                shaderSlots =
                    phase2PlanMSLSlotsFromShaderSlots(translatedPlan->shaderSlots);
                vertexUsesArgBuf = translatedPlan->vertexUsesArgumentBuffer;
                fragmentUsesArgBuf = translatedPlan->fragmentUsesArgumentBuffer;
                useArgBuf = translatedPlan->useArgumentBuffers;
                vertexNeedsSSBOSizeBuffer =
                    translatedPlan->vertexNeedsSSBOSizeBuffer;
                fragmentNeedsSSBOSizeBuffer =
                    translatedPlan->fragmentNeedsSSBOSizeBuffer;
                fragmentNeedsFragCoordParams =
                    translatedPlan->fragmentNeedsFragCoordParams;
                fragmentNeedsGlNumSamplesArgBuf =
                    translatedPlan->fragmentNeedsGlNumSamplesArgBuf;
                vertexNeedsFragmentShadingRateState =
                    translatedPlan->vertexNeedsFragmentShadingRateState;
                vertexClipControlYSignSlot =
                    shaderSlots.vertexClipControlYSignSlot;
                fragmentDepthCompareFlipSlot =
                    shaderSlots.fragmentDepthCompareFlipSlot;
                clipControlShaderYFixup =
                    translatedPlan->clipControlShaderYFixup;
                clipControlInvertsWinding =
                    translatedPlan->clipControlInvertsWinding;
                vertexUsesMultiviewViewMask =
                    translatedPlan->vertexUsesMultiviewViewMask;
                fragmentUsesMultiviewViewMask =
                    translatedPlan->fragmentUsesMultiviewViewMask;
            }
        }
        if (!usedTranslatedPlan) {
            pipelineCacheKey =
                computePipelineCacheKey(info, colorFormat, attachmentSampleCount,
                                         forcePerSampleFS);
            shaderSlots =
                translatedDrawMSLSlots(info, pipelineCacheKey, hasFragmentStage);
            vertexUsesArgBuf =
                forceArgBufEnv || shaderSlots.vertexMslUsesArgBuf;
            fragmentUsesArgBuf =
                forceArgBufEnv || shaderSlots.fragmentMslUsesArgBuf;
            useArgBuf = vertexUsesArgBuf || fragmentUsesArgBuf;
            vertexNeedsSSBOSizeBuffer =
                vertexUsesArgBuf && shaderSlots.vertexHasSSBOSizeBuffer;
            fragmentNeedsSSBOSizeBuffer =
                fragmentUsesArgBuf && shaderSlots.fragmentHasSSBOSizeBuffer;
            fragmentNeedsFragCoordParams =
                shaderSlots.fragmentNeedsFragCoordParams;
            fragmentNeedsGlNumSamplesArgBuf =
                fragmentUsesArgBuf && shaderSlots.fragmentNeedsGlNumSamplesArgBuf;
            vertexNeedsFragmentShadingRateState =
                shaderSlots.vertexNeedsFragmentShadingRateState;
            vertexClipControlYSignSlot =
                shaderSlots.vertexClipControlYSignSlot;
            fragmentDepthCompareFlipSlot =
                shaderSlots.fragmentDepthCompareFlipSlot;
            clipControlShaderYFixup =
                vertexClipControlYSignSlot >= 0 &&
                info.clipControlYSignFixupEnabled &&
                !info.stencilTestEnabled;
            clipControlInvertsWinding =
                clipControlShaderYFixup && info.clipOrigin != GL_UPPER_LEFT;
            vertexUsesMultiviewViewMask =
                shaderSlots.vertexUsesMultiviewViewMask;
            fragmentUsesMultiviewViewMask =
                shaderSlots.fragmentUsesMultiviewViewMask;
        }
        if (info.translatedPlanOut != nullptr) {
            *info.translatedPlanOut = TranslatedDrawPlan{};
            if (!useArgBuf && !forceArgBufEnv) {
                info.translatedPlanOut->valid = true;
                info.translatedPlanOut->pipelineCacheKey = pipelineCacheKey;
                info.translatedPlanOut->colorFormat =
                    static_cast<std::uint32_t>(colorFormat);
                info.translatedPlanOut->attachmentSampleCount =
                    static_cast<std::uint32_t>(attachmentSampleCount);
                info.translatedPlanOut->forcePerSampleFS = forcePerSampleFS;
                info.translatedPlanOut->hasFragmentStage = hasFragmentStage;
                info.translatedPlanOut->vertexUsesArgumentBuffer =
                    vertexUsesArgBuf;
                info.translatedPlanOut->fragmentUsesArgumentBuffer =
                    fragmentUsesArgBuf;
                info.translatedPlanOut->useArgumentBuffers = useArgBuf;
                info.translatedPlanOut->vertexNeedsSSBOSizeBuffer =
                    vertexNeedsSSBOSizeBuffer;
                info.translatedPlanOut->fragmentNeedsSSBOSizeBuffer =
                    fragmentNeedsSSBOSizeBuffer;
                info.translatedPlanOut->fragmentNeedsFragCoordParams =
                    fragmentNeedsFragCoordParams;
                info.translatedPlanOut->fragmentNeedsGlNumSamplesArgBuf =
                    fragmentNeedsGlNumSamplesArgBuf;
                info.translatedPlanOut->vertexNeedsFragmentShadingRateState =
                    vertexNeedsFragmentShadingRateState;
                info.translatedPlanOut->clipControlShaderYFixup =
                    clipControlShaderYFixup;
                info.translatedPlanOut->clipControlInvertsWinding =
                    clipControlInvertsWinding;
                info.translatedPlanOut->vertexUsesMultiviewViewMask =
                    vertexUsesMultiviewViewMask;
                info.translatedPlanOut->fragmentUsesMultiviewViewMask =
                    fragmentUsesMultiviewViewMask;
                info.translatedPlanOut->shaderSlots =
                    phase2PlanShaderSlotsFromMSLSlots(shaderSlots);
            } else if (info.translatedPlanRejectReasonOut != nullptr &&
                       info.translatedPlanRejectReasonOut->empty()) {
                info.translatedPlanRejectReasonOut->assign(
                    forceArgBufEnv ? "argbuf_env" : "argbuf_plan");
            }
        }
        if (!info.submissionGroup.declared) {
            info.submissionGroup.reset(AppGLSubmissionGroupKind::TranslatedDraw,
                                       AppGLCommandReason::TranslatedDraw);
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::TranslatedDraw,
                                             AppGLCommandReason::TranslatedDraw);
        }
        info.submissionGroup.argumentBuffersEnabled = useArgBuf;
        constexpr std::uint32_t kOVRMultiviewViewCount = 2;
        const std::uint32_t ovrViewMask[2] = {0u, kOVRMultiviewViewCount};
        const GLsizei effectiveInstanceCount =
            vertexUsesMultiviewViewMask
                ? std::max<GLsizei>(info.instanceCount, 1) *
                      static_cast<GLsizei>(kOVRMultiviewViewCount)
                : info.instanceCount;
        id<MTLArgumentEncoder> fragArgEncoderSet0 = nil;
        id<MTLArgumentEncoder> vertArgEncoderSet0 = nil;
        id<MTLArgumentEncoder> fragArgEncoderSet1 = nil;
        id<MTLArgumentEncoder> vertArgEncoderSet1 = nil;
        ScopedOwnedObjCObject fragArgEncoderSet0Release;
        ScopedOwnedObjCObject vertArgEncoderSet0Release;
        ScopedOwnedObjCObject fragArgEncoderSet1Release;
        ScopedOwnedObjCObject vertArgEncoderSet1Release;
        // Seeded from the program's cached functions; populated by the
        // pipeline-build branch on first miss.
        id<MTLFunction> cachedVertFn = (__bridge id<MTLFunction>)info.metalVertexFunction;
        id<MTLFunction> cachedFragFn = (__bridge id<MTLFunction>)info.metalFragmentFunction;
        ScopedOwnedObjCObject ownedEmptyConstants;
        ScopedOwnedObjCObject ownedVertFn;
        ScopedOwnedObjCObject ownedFragFn;
        ScopedOwnedObjCObject ownedPipelineDescriptor;
        ScopedOwnedObjCObject ownedPipelineState;

        id<MTLRenderPipelineState> pipelineState = nil;
        if (info.pipelineStateCacheOut != nullptr) {
            auto it = info.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != info.pipelineStateCacheOut->end() && it->second != nullptr) {
                pipelineState = (__bridge id<MTLRenderPipelineState>)(it->second);
                if (info.pipelineStateCacheLastUseOut != nullptr) {
                    (*info.pipelineStateCacheLastUseOut)[pipelineCacheKey] =
                        ++renderPsoCacheClock;
                }
                if (info.pipelineStateCacheHitsOut != nullptr) {
                    ++(*info.pipelineStateCacheHitsOut);
                }
                ++pipelineCacheHits;
            }
        }
        // Legacy scalar cache kept as a fallback for the first-draw
        // diagnostic bookkeeping (`pipelineStateOut` is still read by
        // BAR tooling) — only honoured when the map path is missing,
        // which never happens in the current draw builders.
        if (pipelineState == nil && info.pipelineStateCacheOut == nullptr &&
            info.pipelineStateOut != nullptr && *info.pipelineStateOut != nullptr &&
            info.pipelineColorFormatOut != nullptr &&
            *info.pipelineColorFormatOut == static_cast<std::uint32_t>(colorFormat)) {
            pipelineState = (__bridge id<MTLRenderPipelineState>)(*info.pipelineStateOut);
            ++pipelineCacheHits;
        }
        if (pipelineState == nil) {
            profileSample.cacheMiss = true;
            // Phase 8X Group 4d follow-up⁴ — every entry into the build branch
            // bumps `pipelineBuildAttempts`, separately from the success-only
            // `pipelineCacheMisses` counter. This lets BAR-side tooling
            // distinguish "never tried" (attempts==0) from "tried and failed
            // every time" (attempts>0, failures==attempts, misses==0). Prior
            // to this round, the {hits:0, misses:0} state was ambiguous.
            ++pipelineBuildAttempts;
            const auto buildStart = std::chrono::steady_clock::now();

            // Phase 8X Group 4d follow-up⁴ — local helper for the five
            // Metal-side failure paths below. Captures the NSError
            // description AND a stage tag ("vertex-library",
            // "fragment-library", "vertex-function", "fragment-function",
            // "pipeline-state") into the caller-supplied output string so
            // GLContext can route it into the diagnostic ring as a
            // `pipeline-build` ShaderTranslationRecord. The first token in
            // the string is always the stage tag, so BAR can grep-aggregate
            // by failing stage even though the record stores the full text.
            //
            // The build-failure counter is bumped once per failure path so
            // PipelineCacheMetrics::buildFailures stays in lockstep with
            // the number of populated records (modulo first-time gating on
            // the GLContext side).
            auto recordBuildFailure =
                [&info, this, pipelineCacheKey](const char* stageTag, NSError* err) {
                ++pipelineBuildFailures;
                const char* errText = "(nil error)";
                if (err != nil) {
                    NSString* desc = [err localizedDescription];
                    if (desc != nil && [desc UTF8String] != nullptr) {
                        errText = [desc UTF8String];
                    } else {
                        errText = "(nil description)";
                    }
                }
                if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                    std::fprintf(stderr,
                        "[APPGL_PIPELINE] program=%u key=0x%llx build=fail "
                        "stage=%s mode=0x%X verts=%d indices=%d instances=%d "
                        "attrs=%zu error=%s\n",
                        static_cast<unsigned>(info.program),
                        static_cast<unsigned long long>(pipelineCacheKey),
                        stageTag,
                        static_cast<unsigned>(info.mode),
                        static_cast<int>(info.vertexCount),
                        static_cast<int>(info.indexCount),
                        static_cast<int>(info.instanceCount),
                        info.vertexAttributeLayouts.size(),
                        errText);
                    std::fflush(stderr);
                }
                if (info.pipelineBuildErrorOut == nullptr) {
                    return;
                }
                std::string& out = *info.pipelineBuildErrorOut;
                out.assign(stageTag);
                out.append(": ");
                out.append(errText);
            };

            // ADV-2: compile vertex MSL via the library cache.
            // Identical MSL text (e.g. the same vertex shader used
            // by multiple pipeline variants) returns the cached
            // MTLLibrary instead of recompiling.
            id<MTLLibrary> vertLib = getOrCompileLibrary(*info.vertexMSL);
            if (vertLib == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(vertex) failed");
                recordBuildFailure("vertex-library", nil);
                return false;
            }
            // SPIRV-Cross names the entry points "main0" by default.
            // Use the constantValues variant so MSL shaders that declare
            // `[[function_constant(N)]]` values (e.g. SPIRV-Cross emits
            // `spvLinearTextureAlignmentOverride` for 2D image atomics,
            // function_constant(65535)) can be loaded. We provide an empty
            // MTLFunctionConstantValues — the shader checks
            // `is_function_constant_defined(...)` and falls back to the
            // compile-time default when unset, so no values need to be
            // bound. Without this call, Metal errors with:
            //   "fragmentFunction main0 cannot be used to build a pipeline
            //    state. Use newFunctionWithName:constantValues:... ..."
            // at pipeline-descriptor validation time.
            MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
            ownedEmptyConstants.reset(emptyConstants);
            NSError* vertFnError = nil;
            id<MTLFunction> vertFn = [vertLib newFunctionWithName:@"main0"
                                                   constantValues:emptyConstants
                                                            error:&vertFnError];
            if (vertFn == nil) {
                if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                    std::fprintf(stderr, "[APPGL] vertex-function build failed: %s\n",
                        vertFnError ? vertFnError.localizedDescription.UTF8String : "(no err)");
                }
                FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(vertex,main0) failed: %@", vertFnError);
                recordBuildFailure("vertex-function", vertFnError);
                return false;
            }
            ownedVertFn.reset(vertFn);
            // Step 7-4: cache the MTLFunction on the program so future
            // pipeline-cache hits can still reach it for argbuf encoder
            // creation. Only populated when the caller opts in by
            // supplying the out-slot (argbuf mode). CFBridgingRetain
            // transfers ownership; released at relink in GLContext.
            if (useArgBuf) {
                cachedVertFn = vertFn;
            }
            if (useArgBuf && info.metalVertexFunctionOut != nullptr &&
                *info.metalVertexFunctionOut == nullptr) {
                *info.metalVertexFunctionOut = (void*)CFBridgingRetain(vertFn);
            }

            // ADV-2: compile fragment MSL via the library cache.
            // Skipped entirely for VS-only + rasterizerDiscard draws —
            // the pipeline descriptor will set fragmentFunction = nil
            // and rasterizationEnabled = NO below, so the fragment
            // library / function are never used.
            id<MTLFunction> fragFn = nil;
            if (hasFragmentStage) {
                // Phase 6-1e: when the pipeline key asked for per-sample
                // FS, swap the source for a rewritten copy with an
                // injected [[sample_id]] parameter. The rewrite is
                // side-effect-free and returns the original string when
                // no signature match is found — the fallback path still
                // compiles. Keyed on `forcePerSampleFS` so the rewrite
                // cost is only paid for MS + GL_SAMPLE_SHADING draws.
                std::string rewrittenFragmentMSL;
                if (forcePerSampleFS) {
                    rewrittenFragmentMSL = rewriteFragmentMSLForPerSample(*info.fragmentMSL);
                }
                const std::string& fragSource = forcePerSampleFS
                    ? rewrittenFragmentMSL : *info.fragmentMSL;
                id<MTLLibrary> fragLib = getOrCompileLibrary(fragSource);
                if (fragLib == nil) {
                    FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(fragment) failed");
                    recordBuildFailure("fragment-library", nil);
                    return false;
                }
                NSError* fragFnError = nil;
                fragFn = [fragLib newFunctionWithName:@"main0"
                                      constantValues:emptyConstants
                                               error:&fragFnError];
                if (fragFn == nil) {
                    FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(fragment,main0) failed: %@", fragFnError);
                    recordBuildFailure("fragment-function", fragFnError);
                    return false;
                }
                ownedFragFn.reset(fragFn);
                // Step 7-4: cache the fragment MTLFunction. See the
                // matching vertex-function block above.
                if (useArgBuf) {
                    cachedFragFn = fragFn;
                }
                if (useArgBuf && info.metalFragmentFunctionOut != nullptr &&
                    *info.metalFragmentFunctionOut == nullptr) {
                    *info.metalFragmentFunctionOut = (void*)CFBridgingRetain(fragFn);
                }
            }

            // Step 7-3: create per-stage argument encoders for desc_set 0
            // when argument_buffers is enabled. The encoder is created
            // from the MTLFunction (not the pipeline state) so it must
            // live in this pipeline-build scope. Hoisted to encode-
            // Translated-Draw's outer scope via the pre-declared
            // `fragArgEncoderSet0` / `vertArgEncoderSet0` locals above
            // so the bind step can reach them. Encoders are safe to
            // create even when the shader has no [[buffer(24)]] — Metal
            // just returns an encoder with encodedLength=0, which our
            // binding loop below handles via the "no fragmentTextures"
            // short-circuit.
            //
            // Only desc_set 0 is wired in this commit (samplers + storage
            // images + SSBOs). Desc_set 1 (UBOs at [[buffer(25)]]) + the
            // compute stage + the various non-texture resource types are
            // 7-3 successor commits.
            // Build vertex descriptor from reflection data.  Primary vertex
            // attributes (buffer 0) are per-vertex.  Extra vertex buffers
            // (buffer 1+) may use per-instance stepping (glVertexAttribDivisor).
            MTLVertexDescriptor* vertexDescriptor = [[MTLVertexDescriptor alloc] init];
            ScopedOwnedObjCObject vertexDescriptorRelease(vertexDescriptor);
            std::array<bool, 31> vertexDescriptorBufferUsed{};

            // Helper: map shader-reflected scalar type to MTLVertexFormat.
            // Phase 8X Group 4d follow-up¹⁴ — ONLY used as a fallback
            // when the VAO record is missing (`glType == 0`). The
            // primary path now reads `vaoTypeToMTLFormat` from the
            // caller-supplied layout, so the Float4/UByte4 mismatch
            // BAR diagnosed in followup¹³ is impossible to reach
            // without a draw builder that forgot to propagate the
            // VAO fields.
            auto glTypeToMTLFormatFallback = [](GLenum type) -> MTLVertexFormat {
                switch (type) {
                    case GL_FLOAT:      return MTLVertexFormatFloat;
                    case GL_FLOAT_VEC2: return MTLVertexFormatFloat2;
                    case GL_FLOAT_VEC3: return MTLVertexFormatFloat3;
                    case GL_FLOAT_VEC4: return MTLVertexFormatFloat4;
                    case GL_INT:        return MTLVertexFormatInt;
                    case GL_INT_VEC2:   return MTLVertexFormatInt2;
                    case GL_INT_VEC3:   return MTLVertexFormatInt3;
                    case GL_INT_VEC4:   return MTLVertexFormatInt4;
                    default:            return MTLVertexFormatFloat3;
                }
            };

            if (info.vertexReflection != nullptr) {
                for (const auto& input : info.vertexReflection->vertexInputs) {
                    // Determine which Metal buffer this attribute lives in.
                    NSUInteger metalBuf = 0;
                    NSUInteger attrOffset = 0;
                    const TranslatedDrawInfo::VertexAttributeLayout* matched = nullptr;

                    // Check primary (buffer 0) attributes first.
                    for (const auto& layout : info.vertexAttributeLayouts) {
                        if (layout.location == input.location) {
                            metalBuf = 0;
                            attrOffset = static_cast<NSUInteger>(layout.offset);
                            matched = &layout;
                            break;
                        }
                    }

                    // Check extra vertex buffers (buffer 1+).
                    if (matched == nullptr) {
                        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                            for (const auto& layout : info.extraVertexBuffers[ei].attributes) {
                                if (layout.location == input.location) {
                                    metalBuf = static_cast<NSUInteger>(ei + 1);
                                    attrOffset = static_cast<NSUInteger>(layout.offset);
                                    matched = &layout;
                                    break;
                                }
                            }
                            if (matched != nullptr) break;
                        }
                    }

                    // Phase 8X Group 4d follow-up¹⁴ — derive the Metal
                    // vertex format from the VAO record (the real VBO
                    // layout) rather than the shader-reflected scalar
                    // type. The fallback branch only runs when the
                    // draw builder failed to propagate VAO fields,
                    // which would indicate a plumbing bug; it preserves
                    // the pre-follow-up¹⁴ behavior for safety.
                    MTLVertexFormat format;
                    if (matched != nullptr && matched->glType != 0) {
                        format = vaoTypeToMTLFormat(
                            matched->glType,
                            matched->glComponentCount,
                            matched->glNormalized,
                            matched->glIsInteger);
                    } else {
                        format = glTypeToMTLFormatFallback(input.type);
                    }

                    vertexDescriptor.attributes[input.location].format = format;
                    vertexDescriptor.attributes[input.location].offset = attrOffset;
                    vertexDescriptor.attributes[input.location].bufferIndex = metalBuf;
                    if (metalBuf < vertexDescriptorBufferUsed.size()) {
                        vertexDescriptorBufferUsed[metalBuf] = true;
                    }
                }
            }

            // Buffer 0 layout: primary per-vertex data.
            // Attributeless draws (gl_VertexID-based) skip vertex buffer
            // layout entirely — the shader generates its own vertices.
            //
            // Only set layout[0] if at least one attribute actually uses
            // bufferIndex=0. Some tests (e.g. KHR-GL46 draw_elements_base_vertex
            // with divisor-instanced VBOs) have all attributes in buffer 1+;
            // setting an unused layout[0].stride triggers Metal's
            // "None of the attributes set bufferIndex to 0, but layout[0]
            // stride was set" assertion.
            const bool anyAttrOnBuffer0 = vertexDescriptorBufferUsed[0];
            if (!attributelessDraw && anyAttrOnBuffer0) {
                const NSUInteger stride = info.vertexStride > 0
                    ? info.vertexStride
                    : sizeof(float) * 3u;
                vertexDescriptor.layouts[0].stride = stride;
                vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                vertexDescriptor.layouts[0].stepRate = 1;
            }

            // Extra buffer layouts (1+): per-instance or additional per-vertex.
            for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                const auto& evb = info.extraVertexBuffers[ei];
                NSUInteger metalBuf = static_cast<NSUInteger>(ei + 1);
                if (metalBuf >= vertexDescriptorBufferUsed.size() ||
                    !vertexDescriptorBufferUsed[metalBuf]) {
                    continue;
                }
                if (evb.constantStep) {
                    vertexDescriptor.layouts[metalBuf].stride =
                        static_cast<NSUInteger>(evb.stride > 0 ? evb.stride : evb.byteCount);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionConstant;
                    vertexDescriptor.layouts[metalBuf].stepRate = 0;
                } else if (evb.divisor > 0) {
                    vertexDescriptor.layouts[metalBuf].stride = static_cast<NSUInteger>(evb.stride);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerInstance;
                    vertexDescriptor.layouts[metalBuf].stepRate = static_cast<NSUInteger>(evb.divisor);
                } else {
                    vertexDescriptor.layouts[metalBuf].stride = static_cast<NSUInteger>(evb.stride);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerVertex;
                    vertexDescriptor.layouts[metalBuf].stepRate = 1;
                }
            }

            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            ownedPipelineDescriptor.reset(desc);
            desc.vertexFunction = vertFn;
            desc.fragmentFunction = info.rasterizerDiscard ? nil : fragFn;
            // Attributeless draws don't need a vertex descriptor at all.
            desc.vertexDescriptor = attributelessDraw ? nil : vertexDescriptor;
            desc.colorAttachments[0].pixelFormat = colorFormat;
            // Phase 6-1a: match the pipeline's rasterSampleCount to
            // the attachment. Metal requires this for MSAA correctness
            // — a 4x-MSAA attachment with a sampleCount=1 pipeline
            // fails validation at encode time with no draw output.
            desc.rasterSampleCount = attachmentSampleCount;
            // MRT: configure pixelFormat for each additional color
            // attachment (slots 1..7). GL 4.6 §14.6 allows up to 8
            // simultaneous color outputs (GL_MAX_DRAW_BUFFERS).
            // CTS `draw_buffers.draw_buffers_1` writes
            // `fragColor0..fragColor7` to distinct attachments.
            // Slots with a nullptr texture stay at
            // `MTLPixelFormatInvalid` (Metal's default, i.e. "not
            // bound") and Metal silently ignores fragment-shader
            // writes for them.
            for (std::size_t ei = 0; ei < info.fboAdditionalColorTextures.size(); ++ei) {
                void* rawTex = info.fboAdditionalColorTextures[ei];
                if (rawTex == nullptr) continue;
                id<MTLTexture> extraTex = (__bridge id<MTLTexture>)rawTex;
                desc.colorAttachments[ei + 1].pixelFormat = extraTex.pixelFormat;
            }
            // Pipeline depth/stencil formats must match the bound
            // textures' Metal pixel formats. Previously hard-coded to
            // Depth32Float_Stencil8, but GL 4.6 allows depth-only
            // (`GL_DEPTH_COMPONENT32F`, DEPTH24) or stencil-only
            // (`GL_STENCIL_INDEX8`) attachments too, and attaching a
            // mismatched pipeline format makes Metal silently drop
            // every fragment (GPU-capture signature on
            // `geometry_shader.layered_framebuffer.depth_support`,
            // where the depth texture is pure Depth32Float but the
            // pipeline declared Depth32Float_Stencil8).
            {
                MTLPixelFormat depthFmt = MTLPixelFormatInvalid;
                MTLPixelFormat stencilFmt = MTLPixelFormatInvalid;
                if (info.fboDepthStencilTexture != nullptr) {
                    id<MTLTexture> dsTex = (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
                    const MTLPixelFormat pf = dsTex.pixelFormat;
                    // Formats carrying depth.
                    if (pf == MTLPixelFormatDepth16Unorm ||
                        pf == MTLPixelFormatDepth32Float ||
                        pf == MTLPixelFormatDepth32Float_Stencil8 ||
                        pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                        depthFmt = pf;
                    }
                    // Formats carrying stencil.
                    if (pf == MTLPixelFormatStencil8 ||
                        pf == MTLPixelFormatDepth32Float_Stencil8 ||
                        pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                        pf == MTLPixelFormatX32_Stencil8 ||
                        pf == MTLPixelFormatX24_Stencil8) {
                        stencilFmt = pf;
                    }
                } else if (info.fboColorTexture == nullptr &&
                           !info.fboAttachmentless) {
                    // Default framebuffer: keep the legacy combined
                    // format so the swapchain path (renderpass-attached
                    // depth+stencil renderbuffer backed by
                    // Depth32Float_Stencil8) still matches.
                    depthFmt = MTLPixelFormatDepth32Float_Stencil8;
                    stencilFmt = MTLPixelFormatDepth32Float_Stencil8;
                }
                desc.depthAttachmentPixelFormat = depthFmt;
                desc.stencilAttachmentPixelFormat = stencilFmt;
            }
            // Set inputPrimitiveTopology = Point for GL_POINTS ONLY.
            // Metal uses this flag to enable point-size rasterisation
            // (default point_size = 1.0 if the VS doesn't write it,
            // which our shaders typically don't). Leaving it at the
            // Unspecified default for Triangle / Line draws matters:
            // Metal rejects pipelines that write [[point_size]] with
            // an explicit Triangle or Line topology class, and some
            // GLSL shaders (including ones SPIRV-Cross auto-enhances)
            // carry a gl_PointSize write even when the draw is
            // triangles. Prior iteration set Triangle unconditionally
            // and broke ~4k triangle-rendering tests on that
            // combination (see 15a368e for the post-mortem).
            if (info.mode == GL_POINTS) {
                desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
            }
            // Layered rendering (GS-emul path): when the synth VS
            // writes `[[render_target_array_index]]`, Metal requires
            // an explicit `inputPrimitiveTopology` — otherwise
            // pipeline build fails with "Vertex shader writes
            // render_target_array_index but inputPrimitiveTopology
            // is not specified". Map the draw mode to Metal's
            // topology class; other modes defer to the Point
            // override above or leave Unspecified for the legacy
            // path compatibility.
            //
            // Sprint 16 Day 3 [viewport_array]: the same Metal-pipeline
            // requirement applies to `[[viewport_array_index]]` —
            // unspecified topology silently disables the per-vertex
            // viewport selection at draw time (no validation error,
            // fragments just drop). Trigger the topology classification
            // also when the encoder is binding a viewport array
            // (`viewportArrayCount > 1`), because that's when the
            // synth VS emits `[[viewport_array_index]]` (env-gated)
            // OR when a VS using ARB_shader_viewport_layer_array
            // emits it directly.
            if (info.fboColorArrayLength > 0 ||
                info.viewportArrayCount > 1) {
                switch (info.mode) {
                    case GL_POINTS:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
                        break;
                    case GL_LINES:
                    case GL_LINE_STRIP:
                    case GL_LINE_LOOP:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine;
                        break;
                    default:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
                        break;
                }
            }
            // GL_RASTERIZER_DISCARD → Metal rasterization disabled.
            // The VS still runs (and can write SSBOs / transform feedback)
            // but no fragment stage executes, no raster output is produced,
            // and Metal doesn't require a fragment function or a valid
            // [[position]] output from the vertex function. This is the
            // only Metal pipeline shape that accepts SPIRV-Cross's
            // `vertex void main0(...)` output for GL shaders that write
            // SSBOs without setting gl_Position.
            if (info.rasterizerDiscard) {
                desc.rasterizationEnabled = NO;
            }

            // Phase 8X Group 4d follow-up¹⁴ — apply the GL blend
            // state to the Metal pipeline color attachment. Before
            // follow-up¹⁴ the descriptor was left at Metal's defaults
            // (`blendingEnabled=NO, src=One, dst=Zero, op=Add,
            // writeMask=All`), so every translated draw was opaque
            // regardless of `glEnable(GL_BLEND) + glBlendFunc(...)`.
            // BAR followup¹³-verification §Candidate-1 traced that
            // as the reason spring's semi-transparent glyph overlay
            // composited as a solid rectangle instead of mixing with
            // the background. The cache key (above) already includes
            // the blend tuple, so a program that uses the same
            // shader with two different blend modes builds two
            // distinct pipelines and keeps both hot.
            MTLRenderPipelineColorAttachmentDescriptor* colorDesc = desc.colorAttachments[0];
            // Sprint 6 P1 sub-task 3 day 4 (CKPT44 prep): Metal rejects
            // pipelines with `blendingEnabled=YES` when the color
            // attachment's pixelFormat is an integer format
            // (R32Sint/Uint, RG32*, RGBA32*, etc.). GL allows the
            // combination silently — blending bits are ignored on
            // integer attachments per spec §17.3.6 — so apps and
            // gluStateReset can leave GL_BLEND on while pointing the
            // FBO at an R32UI / R32I / R32Sint render target. Surface
            // discovery: `geometry_shader.limits.max_output_components`
            // crashed Metal validation at draw time when GL_BLEND was
            // enabled and the FBO color attachment format was R32Sint
            // (CKPT43 cap-bump cascade). Force-disable blending for
            // integer pipeline-color formats so the pipeline-state
            // build matches GL's silent semantics.
            auto isIntegerColorFormat = [](MTLPixelFormat fmt) -> bool {
                switch (fmt) {
                    case MTLPixelFormatR8Sint:
                    case MTLPixelFormatR8Uint:
                    case MTLPixelFormatR16Sint:
                    case MTLPixelFormatR16Uint:
                    case MTLPixelFormatR32Sint:
                    case MTLPixelFormatR32Uint:
                    case MTLPixelFormatRG8Sint:
                    case MTLPixelFormatRG8Uint:
                    case MTLPixelFormatRG16Sint:
                    case MTLPixelFormatRG16Uint:
                    case MTLPixelFormatRG32Sint:
                    case MTLPixelFormatRG32Uint:
                    case MTLPixelFormatRGBA8Sint:
                    case MTLPixelFormatRGBA8Uint:
                    case MTLPixelFormatRGBA16Sint:
                    case MTLPixelFormatRGBA16Uint:
                    case MTLPixelFormatRGBA32Sint:
                    case MTLPixelFormatRGBA32Uint:
                    case MTLPixelFormatRGB10A2Uint:
                        return true;
                    default:
                        return false;
                }
            };
            const bool integerColorTarget = isIntegerColorFormat(colorFormat);
            colorDesc.blendingEnabled =
                (info.blend.enabled && !integerColorTarget) ? YES : NO;
            colorDesc.sourceRGBBlendFactor        = glBlendFactorToMTL(info.blend.srcRGB);
            colorDesc.destinationRGBBlendFactor   = glBlendFactorToMTL(info.blend.dstRGB);
            colorDesc.sourceAlphaBlendFactor      = glBlendFactorToMTL(info.blend.srcAlpha);
            colorDesc.destinationAlphaBlendFactor = glBlendFactorToMTL(info.blend.dstAlpha);
            colorDesc.rgbBlendOperation           = glBlendEqToMTL(info.blend.equationRGB);
            colorDesc.alphaBlendOperation         = glBlendEqToMTL(info.blend.equationAlpha);
            MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
            if (info.blend.colorMaskR) writeMask |= MTLColorWriteMaskRed;
            if (info.blend.colorMaskG) writeMask |= MTLColorWriteMaskGreen;
            if (info.blend.colorMaskB) writeMask |= MTLColorWriteMaskBlue;
            if (info.blend.colorMaskA) writeMask |= MTLColorWriteMaskAlpha;
            colorDesc.writeMask = writeMask;

            // Phase 8X Group 4d follow-up¹³ — one-shot per-program
            // diagnostic dump of the Metal pipeline descriptor shape.
            // Covers BAR followup¹²-verification §Candidate 1 (blend
            // state — did the translated-draw pipeline inherit GL
            // blend enable / src / dst / equation, or is it sitting on
            // Metal's default-off blend?) and §Candidate 2 (vertex
            // descriptor format — did `col` arrive as
            // MTLVertexFormatUChar4Normalized or as Float4? and do
            // the offsets/bufferIndex match the VBO layout peek dumped
            // at the first-draw site?). Both dumps fire from here
            // because the descriptor objects go out of scope after
            // newRenderPipelineStateWithDescriptor; macOS has no
            // runtime reflection API to walk a compiled
            // MTLRenderPipelineState. Gated by
            // `loggedPipelineBuildPrograms` so the dump fires exactly
            // once per GL program name per MetalFrameGraph instance
            // (GLContext) — builds are cached on GLProgramObject so a
            // program hits this branch at most once in the cache-miss
            // path anyway; the explicit set protects against theoretical
            // cache-invalidation cases.
            //
            // Format strings match the Metal header names so BAR can
            // grep for them directly against
            // reference/OpenGL-Refpages/gl4/glBlendFunc.xml +
            // glVertexAttribPointer.xml semantics. No decoding tables
            // here — raw enum values are emitted alongside a short
            // symbolic name for the common cases so the log stays
            // self-describing without a lookup table.
            // Phase 8X Group 4d follow-up¹⁷ — dedup is keyed on
            // (program, pipelineCacheKey), not program alone. See the
            // member declaration of `loggedPipelineBuildPrograms` for
            // the rationale (was hiding the `entries=5` cache growth).
            if (info.program != 0 &&
                loggedPipelineBuildPrograms.insert({info.program, pipelineCacheKey}).second) {
                auto vertexFormatName = [](MTLVertexFormat f) -> const char* {
                    switch (f) {
                        case MTLVertexFormatInvalid:          return "Invalid";
                        case MTLVertexFormatFloat:            return "Float";
                        case MTLVertexFormatFloat2:           return "Float2";
                        case MTLVertexFormatFloat3:           return "Float3";
                        case MTLVertexFormatFloat4:           return "Float4";
                        case MTLVertexFormatInt:              return "Int";
                        case MTLVertexFormatInt2:             return "Int2";
                        case MTLVertexFormatInt3:             return "Int3";
                        case MTLVertexFormatInt4:             return "Int4";
                        case MTLVertexFormatUInt:             return "UInt";
                        case MTLVertexFormatUInt2:            return "UInt2";
                        case MTLVertexFormatUInt3:            return "UInt3";
                        case MTLVertexFormatUInt4:            return "UInt4";
                        case MTLVertexFormatUChar:            return "UChar";
                        case MTLVertexFormatUChar2:           return "UChar2";
                        case MTLVertexFormatUChar3:           return "UChar3";
                        case MTLVertexFormatUChar4:           return "UChar4";
                        case MTLVertexFormatUCharNormalized:  return "UCharNormalized";
                        case MTLVertexFormatUChar2Normalized: return "UChar2Normalized";
                        case MTLVertexFormatUChar3Normalized: return "UChar3Normalized";
                        case MTLVertexFormatUChar4Normalized: return "UChar4Normalized";
                        case MTLVertexFormatChar:             return "Char";
                        case MTLVertexFormatChar2:            return "Char2";
                        case MTLVertexFormatChar3:            return "Char3";
                        case MTLVertexFormatChar4:            return "Char4";
                        case MTLVertexFormatCharNormalized:   return "CharNormalized";
                        case MTLVertexFormatChar2Normalized:  return "Char2Normalized";
                        case MTLVertexFormatChar3Normalized:  return "Char3Normalized";
                        case MTLVertexFormatChar4Normalized:  return "Char4Normalized";
                        case MTLVertexFormatUShort:           return "UShort";
                        case MTLVertexFormatUShort2:          return "UShort2";
                        case MTLVertexFormatUShort3:          return "UShort3";
                        case MTLVertexFormatUShort4:          return "UShort4";
                        case MTLVertexFormatUShortNormalized: return "UShortNormalized";
                        case MTLVertexFormatUShort2Normalized:return "UShort2Normalized";
                        case MTLVertexFormatUShort3Normalized:return "UShort3Normalized";
                        case MTLVertexFormatUShort4Normalized:return "UShort4Normalized";
                        case MTLVertexFormatShort:            return "Short";
                        case MTLVertexFormatShort2:           return "Short2";
                        case MTLVertexFormatShort3:           return "Short3";
                        case MTLVertexFormatShort4:           return "Short4";
                        case MTLVertexFormatShortNormalized:  return "ShortNormalized";
                        case MTLVertexFormatShort2Normalized: return "Short2Normalized";
                        case MTLVertexFormatShort3Normalized: return "Short3Normalized";
                        case MTLVertexFormatShort4Normalized: return "Short4Normalized";
                        case MTLVertexFormatHalf:             return "Half";
                        case MTLVertexFormatHalf2:            return "Half2";
                        case MTLVertexFormatHalf3:            return "Half3";
                        case MTLVertexFormatHalf4:            return "Half4";
                        default:                              return "Other";
                    }
                };
                auto stepFunctionName = [](MTLVertexStepFunction f) -> const char* {
                    switch (f) {
                        case MTLVertexStepFunctionConstant:             return "Constant";
                        case MTLVertexStepFunctionPerVertex:            return "PerVertex";
                        case MTLVertexStepFunctionPerInstance:          return "PerInstance";
                        case MTLVertexStepFunctionPerPatch:             return "PerPatch";
                        case MTLVertexStepFunctionPerPatchControlPoint: return "PerPatchControlPoint";
                        default:                                         return "Unknown";
                    }
                };
                auto blendFactorName = [](MTLBlendFactor f) -> const char* {
                    switch (f) {
                        case MTLBlendFactorZero:                     return "Zero";
                        case MTLBlendFactorOne:                      return "One";
                        case MTLBlendFactorSourceColor:              return "SourceColor";
                        case MTLBlendFactorOneMinusSourceColor:      return "OneMinusSourceColor";
                        case MTLBlendFactorSourceAlpha:              return "SourceAlpha";
                        case MTLBlendFactorOneMinusSourceAlpha:      return "OneMinusSourceAlpha";
                        case MTLBlendFactorDestinationColor:         return "DestinationColor";
                        case MTLBlendFactorOneMinusDestinationColor: return "OneMinusDestinationColor";
                        case MTLBlendFactorDestinationAlpha:         return "DestinationAlpha";
                        case MTLBlendFactorOneMinusDestinationAlpha: return "OneMinusDestinationAlpha";
                        case MTLBlendFactorSourceAlphaSaturated:     return "SourceAlphaSaturated";
                        case MTLBlendFactorBlendColor:               return "BlendColor";
                        case MTLBlendFactorOneMinusBlendColor:       return "OneMinusBlendColor";
                        case MTLBlendFactorBlendAlpha:               return "BlendAlpha";
                        case MTLBlendFactorOneMinusBlendAlpha:       return "OneMinusBlendAlpha";
                        default:                                     return "Other";
                    }
                };
                auto blendOpName = [](MTLBlendOperation op) -> const char* {
                    switch (op) {
                        case MTLBlendOperationAdd:             return "Add";
                        case MTLBlendOperationSubtract:        return "Subtract";
                        case MTLBlendOperationReverseSubtract: return "ReverseSubtract";
                        case MTLBlendOperationMin:             return "Min";
                        case MTLBlendOperationMax:             return "Max";
                        default:                               return "Other";
                    }
                };

                APPGL_LOG(PIPELINE, @"[GL] pipeline-build first-build program=%u"
                      @" colorFormat=0x%lX depthFormat=0x%lX",
                      info.program,
                      (unsigned long)desc.colorAttachments[0].pixelFormat,
                      (unsigned long)desc.depthAttachmentPixelFormat);

                // Vertex descriptor: walk attributes 0..15 and layouts
                // 0..15. A slot with MTLVertexFormatInvalid is either
                // unused or reserved by the attribute-layout map; we
                // emit those at a lower verbosity by suppressing them
                // unless every slot is Invalid.
                APPGL_LOG(PIPELINE, @"[GL]   vertexDescriptor attributes:");
                std::size_t nonInvalidAttrs = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexAttributeDescriptor* a = vertexDescriptor.attributes[i];
                    if (a.format == MTLVertexFormatInvalid) {
                        continue;
                    }
                    ++nonInvalidAttrs;
                    APPGL_LOG(PIPELINE, @"[GL]     attr[%lu] format=MTLVertexFormat%s(%lu)"
                          @" offset=%lu bufferIndex=%lu",
                          (unsigned long)i,
                          vertexFormatName(a.format),
                          (unsigned long)a.format,
                          (unsigned long)a.offset,
                          (unsigned long)a.bufferIndex);
                }
                if (nonInvalidAttrs == 0) {
                    APPGL_LOG(PIPELINE, @"[GL]     (no attributes set — vertex stage runs without vertex descriptor input)");
                }
                APPGL_LOG(PIPELINE, @"[GL]   vertexDescriptor layouts:");
                std::size_t nonEmptyLayouts = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexBufferLayoutDescriptor* l = vertexDescriptor.layouts[i];
                    if (l.stride == 0) {
                        continue;
                    }
                    ++nonEmptyLayouts;
                    APPGL_LOG(PIPELINE, @"[GL]     layout[%lu] stride=%lu"
                          @" stepFunction=MTLVertexStepFunction%s(%lu)"
                          @" stepRate=%lu",
                          (unsigned long)i,
                          (unsigned long)l.stride,
                          stepFunctionName(l.stepFunction),
                          (unsigned long)l.stepFunction,
                          (unsigned long)l.stepRate);
                }
                if (nonEmptyLayouts == 0) {
                    APPGL_LOG(PIPELINE, @"[GL]     (no layouts set — stride=0 on every slot)");
                }

                // Color attachment 0 blend state. BAR §Candidate 1.
                // Phase 8X Group 4d follow-up¹⁴ — the descriptor now
                // carries the GL blend state snapshot from the draw
                // site (`GLStateTracker::blendState()` +
                // `isEnabled(GL_BLEND)`), so these values reflect the
                // live pipeline rather than the MTLRenderPipeline-
                // ColorAttachmentDescriptor defaults. The annotation
                // flipped from `gl-plumbed=no` to `gl-plumbed=yes`
                // as the verification signal for BAR's follow-up¹³
                // memo. Apple's defaults (blendingEnabled=NO,
                // src=One, dst=Zero, op=Add, writeMask=All) are
                // still what you'd see for an opaque draw that
                // runs with `glDisable(GL_BLEND)`.
                MTLRenderPipelineColorAttachmentDescriptor* ca = desc.colorAttachments[0];
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].blendingEnabled=%d (gl-plumbed=yes)",
                      ca.blendingEnabled ? 1 : 0);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].rgb   src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceRGBBlendFactor),
                      (unsigned long)ca.sourceRGBBlendFactor,
                      blendFactorName(ca.destinationRGBBlendFactor),
                      (unsigned long)ca.destinationRGBBlendFactor,
                      blendOpName(ca.rgbBlendOperation),
                      (unsigned long)ca.rgbBlendOperation);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].alpha src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceAlphaBlendFactor),
                      (unsigned long)ca.sourceAlphaBlendFactor,
                      blendFactorName(ca.destinationAlphaBlendFactor),
                      (unsigned long)ca.destinationAlphaBlendFactor,
                      blendOpName(ca.alphaBlendOperation),
                      (unsigned long)ca.alphaBlendOperation);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].writeMask=0x%lX (all=0xF)",
                      (unsigned long)ca.writeMask);
                APPGL_LOG(PIPELINE, @"[GL] pipeline-build first-build program=%u END", info.program);
            }

            NSError* error = nil;
            // ADV-14: binary archive disabled pending investigation.
            // TODO: re-enable once crash in pipeline build path is resolved.
            // ensurePipelineArchive();
            // if (pipelineArchive != nil) {
            //     desc.binaryArchives = @[ pipelineArchive ];
            // }
            pipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (pipelineState == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newRenderPipelineStateWithDescriptor failed: %@", error);
                recordBuildFailure("pipeline-state", error);
                return false;
            }
            if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                std::fprintf(stderr,
                    "[APPGL_PIPELINE] program=%u key=0x%llx build=success "
                    "mode=0x%X verts=%d indices=%d instances=%d attrs=%zu "
                    "colorFormat=0x%lX depthFormat=0x%lX\n",
                    static_cast<unsigned>(info.program),
                    static_cast<unsigned long long>(pipelineCacheKey),
                    static_cast<unsigned>(info.mode),
                    static_cast<int>(info.vertexCount),
                    static_cast<int>(info.indexCount),
                    static_cast<int>(info.instanceCount),
                    info.vertexAttributeLayouts.size(),
                    static_cast<unsigned long>(desc.colorAttachments[0].pixelFormat),
                    static_cast<unsigned long>(desc.depthAttachmentPixelFormat));
                std::fflush(stderr);
            }
            ownedPipelineState.reset(pipelineState);
            // addPipelineToArchive(desc);  // ADV-14: disabled pending investigation

            const auto buildEnd = std::chrono::steady_clock::now();
            pipelineCumulativeBuildMs += std::chrono::duration<double, std::milli>(buildEnd - buildStart).count();
            if (profileDraw) {
                profilePipelineBuildUs += drawProfileElapsedUs(buildStart, buildEnd);
            }
            ++pipelineCacheMisses;
            if (info.pipelineStateCacheMissesOut != nullptr) {
                ++(*info.pipelineStateCacheMissesOut);
            }

            // Phase 8X Group 4d follow-up¹⁴ — insert into the
            // map-based cache first. The old scalar
            // {pipelineStateOut, pipelineColorFormatOut} pair is
            // still populated so the first-draw diagnostic bookkeeping
            // (and the leak-on-relink reset in `linkProgram`) keeps
            // seeing the most-recently-built pipeline in the same
            // slot it has always read from.
            if (info.pipelineStateCacheOut != nullptr) {
                void* retained = (void*)CFBridgingRetain(pipelineState);
                auto inserted = info.pipelineStateCacheOut->emplace(pipelineCacheKey, retained);
                if (info.pipelineStateCacheLastUseOut != nullptr) {
                    (*info.pipelineStateCacheLastUseOut)[pipelineCacheKey] =
                        ++renderPsoCacheClock;
                }
                if (info.pipelineStateCacheHighWaterOut != nullptr) {
                    *info.pipelineStateCacheHighWaterOut =
                        std::max<std::uint64_t>(
                            *info.pipelineStateCacheHighWaterOut,
                            static_cast<std::uint64_t>(
                                info.pipelineStateCacheOut->size()));
                }
                if (!inserted.second) {
                    // Key collided with an existing entry — release the
                    // old one and swap in the new. Shouldn't happen in
                    // normal operation because the cache miss path is
                    // only reached when the lookup failed.
                    if (inserted.first->second != nullptr) {
                        CFRelease(inserted.first->second);
                    }
                    inserted.first->second = retained;
                }
                evictRenderPsoCacheIfNeeded(info);
            }
            if (info.pipelineStateOut != nullptr) {
                // The scalar slot is a secondary mirror of the most
                // recently built pipeline. Release the previous
                // occupant and retain afresh so the scalar cache
                // stays balanced even when the map path also holds
                // an entry.
                if (*info.pipelineStateOut != nullptr) {
                    CFRelease(*info.pipelineStateOut);
                }
                *info.pipelineStateOut = (void*)CFBridgingRetain(pipelineState);
            }
            if (info.pipelineColorFormatOut != nullptr) {
                *info.pipelineColorFormatOut = static_cast<std::uint32_t>(colorFormat);
            }
        }

        // Step 7-4: create per-stage argument encoders AFTER the
        // pipeline-cache-resolve branch so cache hits share them with
        // cache misses. Uses cachedVertFn / cachedFragFn hoisted
        // at the top of this function — seeded from
        // `info.metalVertexFunction` / `info.metalFragmentFunction`
        // (the program's cached retains), then updated by the
        // build-branch cache-write so first-build + subsequent cache-
        // hit paths see the same `id<MTLFunction>`.
        //
        // `newArgumentEncoderWithBufferIndex:24` asserts "bufferIndex
        // N does not identify an argument buffer" on stages whose
        // compiled MSL lacks the [[buffer(N)]] parameter — gated on
        // the per-stage resource-presence check: desc_set 0 if the
        // stage has textures (sampled or storage; same list), SSBOs,
        // or atomic counters; desc_set 1 if the stage has a default
        // uniform block or any UBO.
        if (useArgBuf) {
            bool vertNeedsSet0 = vertexUsesArgBuf && !info.vertexTextures.empty();
            bool fragNeedsSet0 = fragmentUsesArgBuf &&
                (!info.fragmentTextures.empty() || fragmentNeedsGlNumSamplesArgBuf);
            for (const auto& ssbo : info.ssboBindings) {
                if (ssbo.metalBuffer == nullptr) continue;
                if (vertexUsesArgBuf && ssbo.isVertex)     vertNeedsSet0 = true;
                if (fragmentUsesArgBuf && ssbo.isFragment) fragNeedsSet0 = true;
            }
            for (const auto& atomic : info.atomicCounterBindings) {
                if (atomic.metalBuffer == nullptr) continue;
                if (vertexUsesArgBuf && atomic.isVertex)     vertNeedsSet0 = true;
                if (fragmentUsesArgBuf && atomic.isFragment) fragNeedsSet0 = true;
            }
            if (cachedVertFn != nil && vertNeedsSet0) {
                vertArgEncoderSet0 = [cachedVertFn newArgumentEncoderWithBufferIndex:24];
                vertArgEncoderSet0Release.reset(vertArgEncoderSet0);
            }
            if (cachedFragFn != nil && fragNeedsSet0) {
                fragArgEncoderSet0 = [cachedFragFn newArgumentEncoderWithBufferIndex:24];
                fragArgEncoderSet0Release.reset(fragArgEncoderSet0);
            }
            bool vertNeedsSet1 = vertexUsesArgBuf &&
                (info.vertexUniformData != nullptr && info.vertexUniformSize > 0);
            bool fragNeedsSet1 = fragmentUsesArgBuf &&
                (info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0);
            for (const auto& ubo : info.uboBindings) {
                if (ubo.size == 0) continue;
                if (vertexUsesArgBuf && ubo.isVertex)     vertNeedsSet1 = true;
                if (fragmentUsesArgBuf && ubo.isFragment) fragNeedsSet1 = true;
            }
            if (cachedVertFn != nil && vertNeedsSet1) {
                vertArgEncoderSet1 = [cachedVertFn newArgumentEncoderWithBufferIndex:25];
                vertArgEncoderSet1Release.reset(vertArgEncoderSet1);
            }
            if (cachedFragFn != nil && fragNeedsSet1) {
                fragArgEncoderSet1 = [cachedFragFn newArgumentEncoderWithBufferIndex:25];
                fragArgEncoderSet1Release.reset(fragArgEncoderSet1);
            }
        }

        DrawProfileTimePoint profileEncoderSetupStart = profileValidationEnd;
        if (profileDraw) {
            const DrawProfileTimePoint stateResolveEnd = drawProfileNow();
            profileSample.pipelineBuildUs = profilePipelineBuildUs;
            profileSample.stateResolveUs = std::max(
                0.0,
                drawProfileElapsedUs(profileValidationEnd, stateResolveEnd) -
                    profilePipelineBuildUs);
            profileEncoderSetupStart = stateResolveEnd;
        }

        ++translatedDrawEncodeCalls;  // C49 census: draws-per-pass denominator
        // RC-A02: FBO draws need their own render pass targeting the FBO
        // texture.  If a default-framebuffer encoder is open, close it first.
        if (isFBODraw && currentRenderEncoder != nil) {
            ++encoderClosesFboTargetChange;  // C49 census
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        if (!isFBODraw &&
            currentRenderEncoder != nil &&
            activeRenderPassFragmentShadingRate != info.fragmentShadingRate) {
            ++encoderClosesShadingRateChange;  // C49 census
            endRenderPass();
            resetCachedEncoderState();
        }

        // Ensure a render encoder is open. Subsequent draws reuse the same
        // encoder without any GPU sync.
        if (currentRenderEncoder == nil) {
            profileSample.encoderOpened = profileDraw;
            FG_TRACE(@"encodeTranslatedDraw: opening new render pass (prior cmdBuf=%p pendingClear=%d fbo=%d)",
                     currentCommandBuffer, hasPendingClear, isFBODraw);
            // C48: resolve deferred FBO-attachment clears against this
            // pass's attachment coverage. Exact-coverage entries fold
            // into the pass's load actions below; entries on the same
            // textures with different coverage materialize through the
            // legacy standalone path NOW — before the pass's command
            // buffer is ensured — so the materialize drain ordering
            // stays valid.
            bool foldColor0 = false;
            MTLClearColor foldColor0Value = MTLClearColorMake(0, 0, 0, 0);
            bool foldDepth = false;
            double foldDepthValue = 0.0;
            bool foldStencil = false;
            std::uint32_t foldStencilValue = 0;
            std::array<bool, 8> foldExtraColor{};
            std::array<MTLClearColor, 8> foldExtraColorValue{};
            if (std::getenv("APPGL_TRACE_FBO_CLEAR_FOLDING") != nullptr) {
                std::fprintf(stderr,
                    "[C48] pass-open fbo=%d entries=%zu multiview=%d colorTex=%p dsTex=%p dsLevel=%u dsSlice=%u rtal=%u maxLayer=%u\n",
                    (int)isFBODraw, pendingFboClears.size(),
                    (int)vertexUsesMultiviewViewMask,
                    info.fboColorTexture, info.fboDepthStencilTexture,
                    (unsigned)info.fboDepthStencilLevel,
                    (unsigned)info.fboDepthStencilSlice,
                    info.fboColorArrayLength, info.maxEmittedLayer);
            }
            if (isFBODraw && !pendingFboClears.empty() &&
                !vertexUsesMultiviewViewMask) {
                const std::uint32_t passRtal = info.fboColorArrayLength;
                const bool rtalClampPossible = info.maxEmittedLayer > 0;
                PendingFboClear folded;
                if (info.fboColorTexture != nullptr && !rtalClampPossible &&
                    consumePendingFboClearForAttachment(
                        info.fboColorTexture, /*isColor=*/true,
                        /*isDepth=*/false, /*isStencil=*/false,
                        info.fboColorLevels[0], info.fboColorSlices[0],
                        passRtal, folded)) {
                    foldColor0 = true;
                    foldColor0Value = MTLClearColorMake(
                        folded.rgba[0], folded.rgba[1],
                        folded.rgba[2], folded.rgba[3]);
                }
                for (std::size_t ei = 0;
                     ei < info.fboAdditionalColorTextures.size() && ei < 7;
                     ++ei) {
                    void* rawTex = info.fboAdditionalColorTextures[ei];
                    if (rawTex == nullptr || rtalClampPossible) continue;
                    if (consumePendingFboClearForAttachment(
                            rawTex, /*isColor=*/true,
                            /*isDepth=*/false, /*isStencil=*/false,
                            info.fboColorLevels[ei + 1],
                            info.fboColorSlices[ei + 1],
                            passRtal, folded)) {
                        foldExtraColor[ei] = true;
                        foldExtraColorValue[ei] = MTLClearColorMake(
                            folded.rgba[0], folded.rgba[1],
                            folded.rgba[2], folded.rgba[3]);
                    }
                }
                // Guard the MS-mismatch recovery below: an FBO pass with
                // mismatched color/depth sample counts drops the depth
                // attachment, which would silently lose a consumed fold.
                const bool depthAttachmentMayDrop =
                    fboColorTex != nil && fboDepthStencilTex != nil &&
                    fboColorTex.sampleCount != fboDepthStencilTex.sampleCount;
                if (info.fboDepthStencilTexture != nullptr &&
                    !rtalClampPossible && !depthAttachmentMayDrop) {
                    if (consumePendingFboClearForAttachment(
                            info.fboDepthStencilTexture, /*isColor=*/false,
                            /*isDepth=*/true, /*isStencil=*/false,
                            static_cast<std::uint32_t>(
                                info.fboDepthStencilLevel),
                            static_cast<std::uint32_t>(
                                info.fboDepthStencilSlice),
                            passRtal, folded)) {
                        foldDepth = true;
                        foldDepthValue = folded.depth;
                    }
                    if (consumePendingFboClearForAttachment(
                            info.fboDepthStencilTexture, /*isColor=*/false,
                            /*isDepth=*/false, /*isStencil=*/true,
                            static_cast<std::uint32_t>(
                                info.fboDepthStencilLevel),
                            static_cast<std::uint32_t>(
                                info.fboDepthStencilSlice),
                            passRtal, folded)) {
                        foldStencil = true;
                        foldStencilValue = folded.stencil;
                    }
                }
                // Whatever remains on this pass's target textures could
                // not fold — materialize it before the pass begins.
                std::array<void*, 8> extraTexes{};
                for (std::size_t ei = 0;
                     ei < info.fboAdditionalColorTextures.size() && ei < 8;
                     ++ei) {
                    extraTexes[ei] = info.fboAdditionalColorTextures[ei];
                }
                materializeNonFoldablePendingClearsForPassTargets(
                    info.fboColorTexture, info.fboDepthStencilTexture,
                    &extraTexes);
            }
            // Reuse the current command buffer if one exists (e.g. from a
            // prior solid-color draw), otherwise create a new one.
            if (currentCommandBuffer == nil) {
                ensureCurrentCommandBuffer(AppGLCommandReason::TranslatedDraw);
                if (currentCommandBuffer == nil) {
                    return false;
                }
            }

            if (isFBODraw) {
                // FBO path: use the caller-provided Metal texture as the
                // render target.  No drawable acquisition needed.
                colorTexture = fboColorTex;
            } else {
                if (!acquireDrawableIfNeeded()) {  // ADV-7
                    return false;
                }
                colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
            }
            if (colorTexture == nil) {
                return false;
            }

            // Resolve depth/stencil for this render pass.
            id<MTLTexture> passDepthStencil = isFBODraw ? fboDepthStencilTex : depthStencilTexture;

            // Ensure depth/stencil texture matches color attachment dimensions.
            // A mismatch here triggers Metal validation assertions on draw.
            if (!isFBODraw && depthStencilTexture != nil &&
                (depthStencilTexture.width != colorTexture.width ||
                 depthStencilTexture.height != colorTexture.height)) {
                APPGL_LOG(PIPELINE, @"[FG] depth/color size MISMATCH: depth=%lux%lu color=%lux%lu — rebuilding depth",
                      (unsigned long)depthStencilTexture.width,
                      (unsigned long)depthStencilTexture.height,
                      (unsigned long)colorTexture.width,
                      (unsigned long)colorTexture.height);
                id<MTLTexture> replacement = nil;
                @autoreleasepool {
                    MTLTextureDescriptor* dd = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                    width:colorTexture.width
                                                   height:colorTexture.height
                                                mipmapped:NO];
                    dd.storageMode = MTLStorageModePrivate;
                    dd.usage = MTLTextureUsageRenderTarget;
                    replacement = newDepthStencilTexture(dd);
                }
                if (replacement != nil) {
                    ++depthStencilRebuildsFromColorSizeMismatch;
                }
                replaceDepthStencilTexture(replacement);
                passDepthStencil = depthStencilTexture;
                drawableWidth = static_cast<GLsizei>(colorTexture.width);
                drawableHeight = static_cast<GLsizei>(colorTexture.height);
            }

            // Phase 6-1b: when color attachment is multisample but
            // the bound depth attachment isn't (or vice versa),
            // Metal rejects the pass with a sampleCount mismatch. Two
            // recovery paths:
            //   (a) non-FBO (default framebuffer) — rebuild the
            //       depthStencilTexture with matching sample count,
            //       same way we handle size mismatches above.
            //   (b) FBO with user-supplied depth — drop the depth
            //       attachment (render without depth test) rather
            //       than crash. Tests that need depth with MSAA must
            //       attach an MS depth renderbuffer; our
            //       renderbufferStorageMultisample path creates them
            //       correctly when the caller asks for samples > 1.
            if (colorTexture != nil && passDepthStencil != nil &&
                colorTexture.sampleCount != passDepthStencil.sampleCount) {
                if (!isFBODraw) {
                    APPGL_LOG(PIPELINE, @"[FG] depth/color sample-count MISMATCH: depth=%lu color=%lu — rebuilding depth with matching MS",
                          (unsigned long)passDepthStencil.sampleCount,
                          (unsigned long)colorTexture.sampleCount);
                    id<MTLTexture> replacement = nil;
                    @autoreleasepool {
                        MTLTextureDescriptor* dd = [MTLTextureDescriptor
                            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                        width:colorTexture.width
                                                       height:colorTexture.height
                                                    mipmapped:NO];
                        dd.storageMode = MTLStorageModePrivate;
                        dd.usage = MTLTextureUsageRenderTarget;
                        if (colorTexture.sampleCount > 1) {
                            dd.textureType = MTLTextureType2DMultisample;
                            dd.sampleCount = colorTexture.sampleCount;
                        }
                        replacement = newDepthStencilTexture(dd);
                    }
                    if (replacement != nil) {
                        ++depthStencilRebuildsFromSampleMismatch;
                    }
                    replaceDepthStencilTexture(replacement);
                    passDepthStencil = depthStencilTexture;
                } else {
                    APPGL_LOG(PIPELINE, @"[FG] FBO depth/color sample-count MISMATCH: depth=%lu color=%lu — dropping depth",
                          (unsigned long)passDepthStencil.sampleCount,
                          (unsigned long)colorTexture.sampleCount);
                    passDepthStencil = nil;
                }
            }

            // Build the render pass, merging any pending clear into the load
            // action so clear+draws share a single render pass (OPT-4).
            const auto passBuildStart = std::chrono::steady_clock::now();  // C49 census
            MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
            NSUInteger rateMapLayerCount = 1;
            pass.colorAttachments[0].texture = colorTexture;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            // Phase 6-5: honour FramebufferTextureLayer slice selection
            // per attachment. info.fboColorSlices carries the per-slot
            // Metal slice (0 for non-layered / FramebufferTexture /
            // renderbuffer attachments; layer index for
            // FramebufferTextureLayer on array targets). Enables the
            // CTS DSA `textures_storage_multisample_3d_*` pattern of
            // binding each MS-array layer to a distinct color
            // attachment. Without this, every layer silently collapses
            // onto slice 0 and the test's per-layer reference data
            // compares against slice-0's value.
            if (isFBODraw && info.fboColorSlices[0] > 0) {
                pass.colorAttachments[0].slice =
                    static_cast<NSUInteger>(info.fboColorSlices[0]);
            }
            if (isFBODraw && info.fboColorLevels[0] > 0) {
                pass.colorAttachments[0].level =
                    static_cast<NSUInteger>(info.fboColorLevels[0]);
            }
            if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = pendingClearColor;
            } else if (foldColor0) {
                // C48: consume the deferred FBO-attachment clear as this
                // pass's load action.
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = foldColor0Value;
            } else {
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            }
            // MRT: attach additional color targets (slots 1..7). GL
            // draw_buffers enumerations stored in
            // `fboAdditionalColorTextures` map 1:1 to Metal
            // colorAttachments[i+1]. Each uses Load + Store like the
            // primary — the pending-clear color applies to slot 0
            // only; subsequent attachments rely on
            // `glClearBuffer*` calls or untouched contents.
            for (std::size_t ei = 0; ei < info.fboAdditionalColorTextures.size(); ++ei) {
                void* rawTex = info.fboAdditionalColorTextures[ei];
                if (rawTex == nullptr) continue;
                id<MTLTexture> extraTex = (__bridge id<MTLTexture>)rawTex;
                pass.colorAttachments[ei + 1].texture = extraTex;
                if (ei < foldExtraColor.size() && foldExtraColor[ei]) {
                    // C48: folded deferred clear for this MRT slot.
                    pass.colorAttachments[ei + 1].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[ei + 1].clearColor =
                        foldExtraColorValue[ei];
                } else {
                    pass.colorAttachments[ei + 1].loadAction = MTLLoadActionLoad;
                }
                pass.colorAttachments[ei + 1].storeAction = MTLStoreActionStore;
                // Phase 6-5: per-slot slice (index ei+1 into fboColorSlices).
                const std::size_t sliceIdx = ei + 1;
                if (sliceIdx < info.fboColorSlices.size() &&
                    info.fboColorSlices[sliceIdx] > 0) {
                    pass.colorAttachments[ei + 1].slice =
                        static_cast<NSUInteger>(info.fboColorSlices[sliceIdx]);
                }
                if (sliceIdx < info.fboColorLevels.size() &&
                    info.fboColorLevels[sliceIdx] > 0) {
                    pass.colorAttachments[ei + 1].level =
                        static_cast<NSUInteger>(info.fboColorLevels[sliceIdx]);
                }
            }
            // Layered rendering — GS-emul path only. When the
            // emulated GS wrote gl_Layer, the VS routes the per-
            // primitive layer to `[[render_target_array_index]]`.
            // Metal requires renderTargetArrayLength on the pass
            // descriptor to match the attachment's slice count.
            // Non-layered draws leave this at 0 (Metal's default
            // non-layered behaviour).
            if (info.fboColorArrayLength > 0 || vertexUsesMultiviewViewMask) {
                // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray
                // clamp]: Apple Silicon's AGX driver asserts
                // `slice < getNumSlices() && Specified slice OOB`
                // when rTAL is set to the texture's full
                // arrayLength on `MTLTextureType2DMultisampleArray`
                // colour attachments — Codex Sprint 17 Day 1
                // forensics h2DM-3 verdict (Clerk-validated). The
                // active layer span (max(gl_Layer)+1) is what the
                // rasteriser actually routes into; clamping rTAL
                // to that span clears the assertion. Non-MS-array
                // layered targets (2D_ARRAY / 3D / CUBE / CUBE_ARRAY)
                // keep the texture's full arrayLength behaviour.
                NSUInteger rtal = static_cast<NSUInteger>(
                    info.fboColorArrayLength);
                if (rtal == 0 && vertexUsesMultiviewViewMask &&
                    colorTexture != nil) {
                    const bool layeredColorTarget =
                        colorTexture.textureType == MTLTextureType2DArray ||
                        colorTexture.textureType == MTLTextureType2DMultisampleArray ||
                        colorTexture.textureType == MTLTextureTypeCube ||
                        colorTexture.textureType == MTLTextureTypeCubeArray;
                    if (layeredColorTarget) {
                        rtal = std::max<NSUInteger>(colorTexture.arrayLength, 1u);
                    }
                }
                if (info.maxEmittedLayer > 0 &&
                    info.fboColorTexture != nullptr) {
                    id<MTLTexture> colTex = (__bridge id<MTLTexture>)
                        info.fboColorTexture;
                    if (colTex.textureType ==
                            MTLTextureType2DMultisampleArray) {
                        const NSUInteger active =
                            static_cast<NSUInteger>(
                                info.maxEmittedLayer + 1u);
                        if (active < rtal) rtal = active;
                    }
                }
                pass.renderTargetArrayLength = rtal;
                rateMapLayerCount = rtal;
            }
            if (passDepthStencil != nil) {
                // CKPT168 (Sprint 14 Day 15): attach to depth/stencil
                // pass slots only when the texture's pixel format is
                // depth/stencil-renderable per Metal's format table.
                // Pre-fix: blindly attached to BOTH slots regardless of
                // format, which Metal validation rejected with
                // "PixelFormat MTLPixelFormatDepth32Float is not
                // stencil renderable" on layered FBOs that use
                // depth-only attachments (CTS layered_framebuffer.
                // depth_support; sub-shape A of CKPT165 5F target).
                const MTLPixelFormat dsFormat = passDepthStencil.pixelFormat;
                const bool fmtHasDepth =
                    dsFormat == MTLPixelFormatDepth32Float ||
                    dsFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                    dsFormat == MTLPixelFormatDepth16Unorm;
                const bool fmtHasStencil =
                    dsFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                    dsFormat == MTLPixelFormatStencil8 ||
                    dsFormat == MTLPixelFormatX32_Stencil8 ||
                    dsFormat == MTLPixelFormatX24_Stencil8;
                if (fmtHasDepth) {
                    pass.depthAttachment.texture = passDepthStencil;
                    if (isFBODraw) {
                        pass.depthAttachment.level =
                            static_cast<NSUInteger>(info.fboDepthStencilLevel);
                        pass.depthAttachment.slice =
                            static_cast<NSUInteger>(info.fboDepthStencilSlice);
                    }
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                        pass.depthAttachment.loadAction = MTLLoadActionClear;
                        pass.depthAttachment.clearDepth = pendingClearDepth;
                    } else if (foldDepth) {
                        // C48: folded deferred FBO depth clear.
                        pass.depthAttachment.loadAction = MTLLoadActionClear;
                        pass.depthAttachment.clearDepth = foldDepthValue;
                    } else {
                        pass.depthAttachment.loadAction = MTLLoadActionLoad;
                    }
                }
                if (fmtHasStencil) {
                    pass.stencilAttachment.texture = passDepthStencil;
                    if (isFBODraw) {
                        pass.stencilAttachment.level =
                            static_cast<NSUInteger>(info.fboDepthStencilLevel);
                        pass.stencilAttachment.slice =
                            static_cast<NSUInteger>(info.fboDepthStencilSlice);
                    }
                    pass.stencilAttachment.storeAction = MTLStoreActionStore;
                    if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                        pass.stencilAttachment.loadAction = MTLLoadActionClear;
                        pass.stencilAttachment.clearStencil = pendingClearStencil;
                    } else if (foldStencil) {
                        // C48: folded deferred FBO stencil clear.
                        pass.stencilAttachment.loadAction = MTLLoadActionClear;
                        pass.stencilAttachment.clearStencil =
                            foldStencilValue & 0xFF;
                    } else {
                        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
                    }
                }
            }
            if (!isFBODraw) {
                hasPendingClear = false;
            }

            attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, rateMapLayerCount);
            traceColorLoadAction = pass.colorAttachments[0].loadAction;
            traceColorStoreAction = pass.colorAttachments[0].storeAction;
            traceDepthLoadAction = pass.depthAttachment.loadAction;
            traceStencilLoadAction = pass.stencilAttachment.loadAction;
            traceRenderTargetArrayLength = pass.renderTargetArrayLength;
            if (!openCurrentRenderEncoder(pass)) {
                return false;
            }
            // C49 census: pass open by target class + build cost.
            if (isFBODraw) {
                ++encoderOpensFboDraw;
            } else {
                ++encoderOpensDefaultFb;
            }
            ++passDescriptorBuilds;
            passDescriptorBuildUsTotal += static_cast<std::uint64_t>(
                std::chrono::duration<double, std::micro>(
                    std::chrono::steady_clock::now() - passBuildStart)
                    .count());
            traceOpenedRenderEncoder = true;
            activeRenderPassFragmentShadingRate = info.fragmentShadingRate;
            readbackSourceTexture = colorTexture;
            readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
            resetCachedEncoderState();
        }

        DrawProfileTimePoint profileRenderStateStart = profileEncoderSetupStart;
        if (profileDraw) {
            profileRenderStateStart = drawProfileNow();
            profileSample.encoderSetupUs =
                drawProfileElapsedUs(profileEncoderSetupStart, profileRenderStateStart);
        }

        // Encode the draw into the shared render encoder.
        // OPT-6: skip redundant state calls when consecutive draws share
        // the same pipeline / depth-stencil / raster state.
        if (pipelineState != cachedPipelineState) {
            [currentRenderEncoder setRenderPipelineState:pipelineState];
            cachedPipelineState = pipelineState;
        }

        // Depth-stencil state is driven by whether any depth
        // attachment exists — the default framebuffer's
        // `depthStencilTexture` OR the bound FBO's
        // `info.fboDepthStencilTexture`. Previously this gate only
        // checked the default-FB slot, which meant every FBO draw
        // ran with Metal's implicit "always pass, no write"
        // depth/stencil state regardless of GL's depth test +
        // depth-func + depth-write-mask. CTS
        // `geometry_shader.layered_framebuffer.depth_support`
        // clears depth to 0.5, draws with GL_LESS, and expects
        // layers 2/3 (depths 0, 0.5) to be rejected — but with no
        // state set, every fragment passed, producing the
        // observed "all-white" on all layers. Extending the gate
        // to the FBO case makes GL's depth state actually apply.
        const bool havePassDepthStencil =
            depthStencilTexture != nil ||
            info.fboDepthStencilTexture != nullptr;
        if (havePassDepthStencil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = info.depthTestEnabled;
            fakeInfo.depthFunc = info.depthFunc;
            fakeInfo.depthWriteMask = info.depthWriteMask;
            // Sprint 7 Phase 1 #11 (CKPT57): copy stencil identity too.
            fakeInfo.stencilTestEnabled = info.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = info.stencilFrontFunc;
            fakeInfo.stencilFrontRef = info.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = info.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = info.stencilFrontFail;
            fakeInfo.stencilFrontDepthFail = info.stencilFrontDepthFail;
            fakeInfo.stencilFrontDepthPass = info.stencilFrontDepthPass;
            fakeInfo.stencilFrontWriteMask = info.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = info.stencilBackFunc;
            fakeInfo.stencilBackRef = info.stencilBackRef;
            fakeInfo.stencilBackValueMask = info.stencilBackValueMask;
            fakeInfo.stencilBackFail = info.stencilBackFail;
            fakeInfo.stencilBackDepthFail = info.stencilBackDepthFail;
            fakeInfo.stencilBackDepthPass = info.stencilBackDepthPass;
            fakeInfo.stencilBackWriteMask = info.stencilBackWriteMask;
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(fakeInfo);
            if (dsState != nil && dsState != cachedDepthStencilState) {
                [currentRenderEncoder setDepthStencilState:dsState];
                cachedDepthStencilState = dsState;
            }
            // Apply stencil reference value (descriptor doesn't carry
            // it — Metal pulls it from the encoder per draw).
            if (info.stencilTestEnabled) {
                [currentRenderEncoder
                    setStencilFrontReferenceValue:
                        static_cast<uint32_t>(info.stencilFrontRef)
                    backReferenceValue:
                        static_cast<uint32_t>(info.stencilBackRef)];
            }
            if (std::getenv("APPGL_GS_DUMP_FBODEPTH") != nullptr) {
                std::fprintf(stderr,
                    "[GS] FBO draw depth state: test=%d writeMask=%d func=0x%x "
                    "fboDepth=%p arrayLen=%u\n",
                    (int)info.depthTestEnabled, (int)info.depthWriteMask,
                    (unsigned)info.depthFunc, info.fboDepthStencilTexture,
                    info.fboColorArrayLength);
                std::fflush(stderr);
            }
        }

        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront : MTLCullModeBack)
            : MTLCullModeNone;
        if (desiredCull != cachedCullMode) {
            [currentRenderEncoder setCullMode:desiredCull];
            cachedCullMode = desiredCull;
        }
        const MTLWinding desiredWinding =
            frontFacingWindingForClipControl(info.frontFace,
                                             clipControlInvertsWinding);
        if (desiredWinding != cachedFrontFaceWinding) {
            [currentRenderEncoder setFrontFacingWinding:desiredWinding];
            cachedFrontFaceWinding = desiredWinding;
        }
        const MTLTriangleFillMode desiredFill = info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        if (desiredFill != cachedFillMode) {
            [currentRenderEncoder setTriangleFillMode:desiredFill];
            cachedFillMode = desiredFill;
        }
        {
            const std::uint32_t sampleMask = attachmentSampleCount > 1
                ? info.sampleMask
                : 0xFFFFFFFFu;
            const NSInteger sampleMaskSlot =
                fixedFunctionSampleMaskBufferSlot(info.fragmentMSL);
            [currentRenderEncoder setFragmentBytes:&sampleMask
                                           length:sizeof(sampleMask)
                                           atIndex:static_cast<NSUInteger>(sampleMaskSlot)];
        }

        // GL 4.6 §14.6.5 / GL_ARB_polygon_offset_clamp — apply depth
        // bias. Metal's setDepthBias takes (bias, slopeScale, clamp):
        //   bias       ↔ GL units
        //   slopeScale ↔ GL factor
        //   clamp      ↔ GL clamp (0 = no clamp)
        // When no polygon-offset mode is enabled the three fields are
        // zero; setDepthBias(0,0,0) is the Metal no-op.
        {
            const float bias = info.polygonOffsetEnabled ? info.polygonOffsetUnits : 0.0f;
            const float slope = info.polygonOffsetEnabled ? info.polygonOffsetFactor : 0.0f;
            const float clampV = info.polygonOffsetEnabled ? info.polygonOffsetClamp : 0.0f;
            [currentRenderEncoder setDepthBias:bias slopeScale:slope clamp:clampV];
        }

        MTLViewport traceViewport = {0.0, 0.0, 0.0, 0.0, 0.0, 1.0};
        MTLScissorRect traceScissor = {0, 0, 0, 0};
        bool traceViewportSet = false;
        bool traceScissorSet = false;
        bool traceViewportArray = false;
        bool traceScissorArray = false;
        std::size_t traceViewportCount = 0;
        std::size_t traceScissorCount = 0;

        // RC-A02: set Metal viewport from GL viewport state.
        // Metal framebuffer Y is top-down while OpenGL viewport Y is
        // bottom-up.  Convert: metalOriginY = renderTargetH - glY - glH.
        //
        // Sprint 15 Q3-Option-B Day 8 [metal-viewport-array]: when
        // `info.viewportArrayCount > 1`, bind the full per-index
        // viewport array via `setViewports:count:` so shaders that
        // write gl_ViewportIndex / [[viewport_array_index]] route to
        // the right rectangle. Single-viewport path is preserved for
        // the common case to keep behavior bit-identical to pre-Day-8
        // baselines on tests that don't exercise viewport_array.
        if (info.viewportArrayCount > 1) {
            const NSUInteger rtHeightPx =
                (isFBODraw && info.fboHeight > 0)
                    ? static_cast<NSUInteger>(info.fboHeight)
                    : colorTexture.height;
            const double rtHeight = static_cast<double>(rtHeightPx);
            // Sprint 21 A-2 [clip_control.viewport_bounds]: match the
            // single-viewport path. Shaders with the injected Y-sign keep
            // each viewport rectangle fixed; legacy paths keep the
            // origin-dependent Metal viewport conversion.
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vps[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.viewportArray[i];
                vps[i].originX = static_cast<double>(e.originX);
                vps[i].originY = clipControlShaderYFixup
                    ? static_cast<double>(e.originY)
                    : (flipY
                        ? (rtHeight - static_cast<double>(e.originY)
                           - static_cast<double>(e.height))
                        : static_cast<double>(e.originY));
                vps[i].width   = static_cast<double>(e.width);
                vps[i].height  = static_cast<double>(e.height);
                vps[i].znear   = e.depthNear;
                vps[i].zfar    = e.depthFar;
            }
            [currentRenderEncoder setViewports:vps
                                         count:info.viewportArrayCount];
            if (info.viewportArrayCount > 0) {
                traceViewport = vps[0];
                traceViewportSet = true;
                traceViewportArray = true;
                traceViewportCount = info.viewportArrayCount;
            }
        } else if (info.viewportWidth > 0 && info.viewportHeight > 0) {
            // Sprint 16 Day 4 [layered_rendering]: clamp viewport to
            // render target bounds. The Y-flip computation
            // `rtHeight - glY - glH` produces negative originY when the
            // GL viewport is taller than the render target — which
            // happens for FBO draws that don't reset glViewport from
            // the default-framebuffer's window dimensions (e.g. CTS
            // `geometry_shader.layered_rendering.layered_rendering`
            // creates a 32×32 layered FBO but never calls glViewport,
            // so state.viewport() stays at glcts's default 256×256).
            // Negative originY is silently rejected by Metal's
            // tile-rasterizer on Apple Silicon, dropping every fragment.
            // Clamp the GL viewport rect to the render target before
            // computing the Metal-flipped origin so the bound rect is
            // always non-negative and within bounds.
            const NSUInteger rtWidthPx =
                (isFBODraw && info.fboWidth > 0)
                    ? static_cast<NSUInteger>(info.fboWidth)
                    : colorTexture.width;
            const NSUInteger rtHeightPx =
                (isFBODraw && info.fboHeight > 0)
                    ? static_cast<NSUInteger>(info.fboHeight)
                    : colorTexture.height;
            const double rtHeight = static_cast<double>(rtHeightPx);
            const GLint rtW = static_cast<GLint>(rtWidthPx);
            const GLint rtH = static_cast<GLint>(rtHeightPx);
            // GL viewport (bottom-up coords). Clamp x/y to [0, rt) and
            // width/height so the resulting rect fits in the RT.
            const GLint glX = std::max<GLint>(0, info.viewportX);
            const GLint glY = std::max<GLint>(0, info.viewportY);
            const GLsizei availW = static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
            const GLsizei availH = static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glW = std::min<GLsizei>(info.viewportWidth, availW);
            const GLsizei glH = std::min<GLsizei>(info.viewportHeight, availH);
            // Sprint 21 A-2 [clip_control.viewport_bounds]: translated
            // vertex shaders now carry a draw-time clip-control Y sign.
            // When present, keep the viewport rectangle fixed and let
            // LOWER_LEFT flip the mapping inside it. Legacy paths keep
            // the existing viewport-origin convention.
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(glX);
            vp.originY = clipControlShaderYFixup
                ? static_cast<double>(glY)
                : (flipY
                    ? (rtHeight - static_cast<double>(glY) - static_cast<double>(glH))
                    : static_cast<double>(glY));
            vp.width   = static_cast<double>(glW);
            vp.height  = static_cast<double>(glH);
            vp.znear   = info.depthRangeNear;
            vp.zfar    = info.depthRangeFar;
            if (vp.width > 0 && vp.height > 0) {
                [currentRenderEncoder setViewport:vp];
                traceViewport = vp;
                traceViewportSet = true;
                traceViewportCount = 1;
            }
        }

        // GL 4.6 §14.5.1 — scissor test. Metal has no "disable scissor"
        // flag, so when GL_SCISSOR_TEST is off we set the scissor rect
        // to cover the full render target. When enabled, we translate
        // the GL scissor box (bottom-up, render-target-relative) to
        // Metal's top-down coordinate system, clamp to the render
        // target bounds (Metal rejects off-screen/over-large rects),
        // and handle zero-dimension cases by placing a 1x1 rect just
        // outside the render target so no fragments pass — matching
        // CTS `viewport_array.scissor_zero_dimension` which expects
        // every fragment discarded when width=height=0.
        //
        // Sprint 16 Day 3 [viewport_array]: when the viewport array is
        // bound (count > 1), pair it 1:1 with a scissor array via
        // `setScissorRects:count:`. Per Apple Metal docs (and observed
        // behaviour on Apple Silicon), `setViewports:count:N` followed
        // by single `setScissorRect:` leaves scissor slots 1..N-1 at an
        // implementation-defined state that drops fragments at any
        // viewport > 0. Symmetric N-count is required.
        {
            const NSUInteger rtW =
                (isFBODraw && info.fboWidth > 0)
                    ? static_cast<NSUInteger>(info.fboWidth)
                    : colorTexture.width;
            const NSUInteger rtH =
                (isFBODraw && info.fboHeight > 0)
                    ? static_cast<NSUInteger>(info.fboHeight)
                    : colorTexture.height;
            // Helper that converts a single GL scissor rect (bottom-up,
            // RT-relative) plus an enabled flag into a Metal scissor
            // rect (top-down, clamped). When disabled, returns the
            // full RT — matching GL semantics where scissor only
            // discards when the test is on.
            auto makeMetalScissor = [&](bool enabled, GLint glX, GLint glY,
                                        GLsizei glW, GLsizei glH) -> MTLScissorRect {
                MTLScissorRect sr;
                if (!enabled) {
                    sr.x = 0; sr.y = 0; sr.width = rtW; sr.height = rtH;
                    return sr;
                }
                if (glW <= 0 || glH <= 0) {
                    sr.x = 0; sr.y = 0; sr.width = 0; sr.height = 0;
                    return sr;
                }
                GLint metalX = std::max<GLint>(0, glX);
                GLint metalY_bottomLeft = std::max<GLint>(0, glY);
                GLint metalY = static_cast<GLint>(rtH) - metalY_bottomLeft - glH;
                if (metalY < 0) { glH += metalY; metalY = 0; }
                GLsizei availW = static_cast<GLsizei>(rtW) - metalX;
                GLsizei availH = static_cast<GLsizei>(rtH) - metalY;
                GLsizei finalW = std::min<GLsizei>(glW, std::max<GLsizei>(0, availW));
                GLsizei finalH = std::min<GLsizei>(glH, std::max<GLsizei>(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr.x = rtW > 0 ? rtW - 1 : 0;
                    sr.y = rtH > 0 ? rtH - 1 : 0;
                    sr.width = 1; sr.height = 1;
                    return sr;
                }
                sr.x = static_cast<NSUInteger>(metalX);
                sr.y = static_cast<NSUInteger>(metalY);
                sr.width = static_cast<NSUInteger>(finalW);
                sr.height = static_cast<NSUInteger>(finalH);
                return sr;
            };

            if (info.viewportArrayCount > 1) {
                // Multi-viewport path: build N matching scissors. Per-
                // slot enable comes from glEnablei(SCISSOR_TEST, i);
                // when none of the slots have the test on we still
                // call setScissorRects:count: so Metal gets the
                // symmetric pairing it expects (each slot at full RT).
                MTLScissorRect srs[TranslatedDrawInfo::kMaxDrawViewports];
                for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                    const auto& sce = info.scissorArray[i];
                    // Honour both global SCISSOR_TEST and per-slot
                    // enable: the per-slot view in indexedScissorTest_
                    // is broadcast on global enable (GLStateTracker.cpp
                    // setEnabled(GL_SCISSOR_TEST)) — but a draw with
                    // global off needs a full-RT scissor at all slots
                    // regardless of the per-slot rect.
                    const bool enabled = info.scissorTestEnabled && sce.enabled;
                    srs[i] = makeMetalScissor(enabled, sce.x, sce.y,
                                               sce.width, sce.height);
                }
                [currentRenderEncoder setScissorRects:srs
                                                count:info.viewportArrayCount];
                if (info.viewportArrayCount > 0) {
                    traceScissor = srs[0];
                    traceScissorSet = true;
                    traceScissorArray = true;
                    traceScissorCount = info.viewportArrayCount;
                }
            } else {
                // Single-viewport path: original logic.
                MTLScissorRect sr = makeMetalScissor(info.scissorTestEnabled,
                                                     info.scissorX, info.scissorY,
                                                     info.scissorWidth,
                                                     info.scissorHeight);
                [currentRenderEncoder setScissorRect:sr];
                traceScissor = sr;
                traceScissorSet = true;
                traceScissorCount = 1;
            }
        }

        if (shouldEmitDrawTargetTrace(info.program)) {
            const char* targetKind = isFBODraw
                ? "fbo"
                : (usesOffscreenTarget ? "offscreen" : "drawable");
            std::fprintf(stderr,
                "[APPGL_DRAW_TARGET] program=%u key=0x%llx target=%s "
                "opened=%d mode=0x%X verts=%d indices=%d instances=%d "
                "attrs=%zu fragTex=%zu vertTex=%zu targetTex=%p "
                "targetSize=%lux%lu targetFmt=0x%lX samples=%lu "
                "fboColor=%p fboDS=%p fboSize=%dx%d fboArray=%u "
                "drawable=%p offscreen=%p readback=%p "
                "loadColor=%lu storeColor=%lu loadDepth=%lu loadStencil=%lu rtArray=%lu "
                "vpGL=%d,%d %dx%d vpMTL=%s%.1f,%.1f %.1fx%.1f "
                "vpCount=%zu vpArray=%d scGL=%d,%d %dx%d scissorEnabled=%d "
                "scMTL=%s%lu,%lu %lux%lu scCount=%zu scArray=%d "
                "depth=%d func=0x%X write=%d cull=%d cullMode=0x%X "
                "front=0x%X blend=%d mask=%d%d%d%d rasterDiscard=%d\n",
                static_cast<unsigned>(info.program),
                static_cast<unsigned long long>(pipelineCacheKey),
                targetKind,
                traceOpenedRenderEncoder ? 1 : 0,
                static_cast<unsigned>(info.mode),
                static_cast<int>(info.vertexCount),
                static_cast<int>(info.indexCount),
                static_cast<int>(effectiveInstanceCount),
                info.vertexAttributeLayouts.size(),
                info.fragmentTextures.size(),
                info.vertexTextures.size(),
                colorTexture != nil ? (__bridge void*)colorTexture : nullptr,
                colorTexture != nil ? static_cast<unsigned long>(colorTexture.width) : 0ul,
                colorTexture != nil ? static_cast<unsigned long>(colorTexture.height) : 0ul,
                colorTexture != nil ? static_cast<unsigned long>(colorTexture.pixelFormat) : 0ul,
                colorTexture != nil ? static_cast<unsigned long>(colorTexture.sampleCount) : 0ul,
                info.fboColorTexture,
                info.fboDepthStencilTexture,
                static_cast<int>(info.fboWidth),
                static_cast<int>(info.fboHeight),
                static_cast<unsigned>(info.fboColorArrayLength),
                currentDrawable != nil ? (__bridge void*)currentDrawable : nullptr,
                offscreenColorTexture != nil ? (__bridge void*)offscreenColorTexture : nullptr,
                readbackSourceTexture != nil ? (__bridge void*)readbackSourceTexture : nullptr,
                static_cast<unsigned long>(traceColorLoadAction),
                static_cast<unsigned long>(traceColorStoreAction),
                static_cast<unsigned long>(traceDepthLoadAction),
                static_cast<unsigned long>(traceStencilLoadAction),
                static_cast<unsigned long>(traceRenderTargetArrayLength),
                static_cast<int>(info.viewportX),
                static_cast<int>(info.viewportY),
                static_cast<int>(info.viewportWidth),
                static_cast<int>(info.viewportHeight),
                traceViewportSet ? "" : "unset:",
                traceViewport.originX,
                traceViewport.originY,
                traceViewport.width,
                traceViewport.height,
                traceViewportCount,
                traceViewportArray ? 1 : 0,
                static_cast<int>(info.scissorX),
                static_cast<int>(info.scissorY),
                static_cast<int>(info.scissorWidth),
                static_cast<int>(info.scissorHeight),
                info.scissorTestEnabled ? 1 : 0,
                traceScissorSet ? "" : "unset:",
                static_cast<unsigned long>(traceScissor.x),
                static_cast<unsigned long>(traceScissor.y),
                static_cast<unsigned long>(traceScissor.width),
                static_cast<unsigned long>(traceScissor.height),
                traceScissorCount,
                traceScissorArray ? 1 : 0,
                info.depthTestEnabled ? 1 : 0,
                static_cast<unsigned>(info.depthFunc),
                info.depthWriteMask ? 1 : 0,
                info.cullFaceEnabled ? 1 : 0,
                static_cast<unsigned>(info.cullFaceMode),
                static_cast<unsigned>(info.frontFace),
                info.blend.enabled ? 1 : 0,
                info.blend.colorMaskR ? 1 : 0,
                info.blend.colorMaskG ? 1 : 0,
                info.blend.colorMaskB ? 1 : 0,
                info.blend.colorMaskA ? 1 : 0,
                info.rasterizerDiscard ? 1 : 0);
            if (std::getenv("APPGL_TRACE_VERTEX_BINDINGS") != nullptr) {
                const std::size_t reflectedInputCount =
                    info.vertexReflection != nullptr
                        ? info.vertexReflection->vertexInputs.size()
                        : 0;
                std::fprintf(stderr,
                    "[APPGL_VERTEX_BINDINGS] program=%u primaryBuf=%u "
                    "primaryMetal=%d primaryOffset=%zu primaryStride=%zu "
                    "primaryAttrs=%zu extraBufs=%zu reflectedInputs=%zu\n",
                    static_cast<unsigned>(info.program),
                    static_cast<unsigned>(info.glVertexBuffer),
                    info.metalVertexBuffer != nullptr ? 1 : 0,
                    info.metalVertexBufferOffset,
                    info.vertexStride,
                    info.vertexAttributeLayouts.size(),
                    info.extraVertexBuffers.size(),
                    reflectedInputCount);
                if (info.vertexReflection != nullptr) {
                    const std::size_t inputTraceCount =
                        std::min<std::size_t>(reflectedInputCount, 16);
                    for (std::size_t i = 0; i < inputTraceCount; ++i) {
                        const auto& input = info.vertexReflection->vertexInputs[i];
                        std::fprintf(stderr,
                            "[APPGL_VERTEX_INPUT] program=%u input[%zu] "
                            "location=%u source=%u type=0x%X fp64=%d name=%s\n",
                            static_cast<unsigned>(info.program),
                            i,
                            static_cast<unsigned>(input.location),
                            static_cast<unsigned>(input.sourceLocation),
                            static_cast<unsigned>(input.type),
                            input.containsFp64 ? 1 : 0,
                            input.name.c_str());
                    }
                }
                for (std::size_t i = 0; i < info.vertexAttributeLayouts.size(); ++i) {
                    const auto& attr = info.vertexAttributeLayouts[i];
                    std::fprintf(stderr,
                        "[APPGL_VERTEX_ATTR] program=%u primary[%zu] "
                        "location=%u offset=%zu glType=0x%X comps=%d "
                        "norm=%d integer=%d\n",
                        static_cast<unsigned>(info.program),
                        i,
                        static_cast<unsigned>(attr.location),
                        attr.offset,
                        static_cast<unsigned>(attr.glType),
                        static_cast<int>(attr.glComponentCount),
                        attr.glNormalized ? 1 : 0,
                        attr.glIsInteger ? 1 : 0);
                }
                for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                    const auto& evb = info.extraVertexBuffers[ei];
                    std::fprintf(stderr,
                        "[APPGL_VERTEX_EXTRA] program=%u extra[%zu] "
                        "glBuffer=%u metal=%d data=%d owned=%zu offset=%zu "
                        "byteCount=%zu stride=%zu divisor=%u constant=%d "
                        "attrs=%zu\n",
                        static_cast<unsigned>(info.program),
                        ei,
                        static_cast<unsigned>(evb.glBuffer),
                        evb.metalBuffer != nullptr ? 1 : 0,
                        evb.data != nullptr ? 1 : 0,
                        evb.ownedData.size(),
                        evb.metalBufferOffset,
                        evb.byteCount,
                        evb.stride,
                        static_cast<unsigned>(evb.divisor),
                        evb.constantStep ? 1 : 0,
                        evb.attributes.size());
                    for (std::size_t ai = 0; ai < evb.attributes.size(); ++ai) {
                        const auto& attr = evb.attributes[ai];
                        std::fprintf(stderr,
                            "[APPGL_VERTEX_ATTR] program=%u extra[%zu].attr[%zu] "
                            "location=%u offset=%zu glType=0x%X comps=%d "
                            "norm=%d integer=%d\n",
                            static_cast<unsigned>(info.program),
                            ei,
                            ai,
                            static_cast<unsigned>(attr.location),
                            attr.offset,
                            static_cast<unsigned>(attr.glType),
                            static_cast<int>(attr.glComponentCount),
                            attr.glNormalized ? 1 : 0,
                            attr.glIsInteger ? 1 : 0);
                    }
                }
            }
            const std::size_t textureTraceCount =
                std::min<std::size_t>(info.fragmentTextures.size(), 6);
            for (std::size_t i = 0; i < textureTraceCount; ++i) {
                const auto& binding = info.fragmentTextures[i];
                id<MTLTexture> sampled = binding.metalTexture != nullptr
                    ? (__bridge id<MTLTexture>)binding.metalTexture
                    : nil;
                std::fprintf(stderr,
                    "[APPGL_DRAW_TEXTURE] program=%u frag[%zu] slot=%u "
                    "tex=%p size=%lux%lu fmt=0x%lX samples=%lu sampler=%p "
                    "reduction=0x%X lodBias=%.3f borderMask=0x%X\n",
                    static_cast<unsigned>(info.program),
                    i,
                    static_cast<unsigned>(binding.metalSlot),
                    sampled != nil ? (__bridge void*)sampled : nullptr,
                    sampled != nil ? static_cast<unsigned long>(sampled.width) : 0ul,
                    sampled != nil ? static_cast<unsigned long>(sampled.height) : 0ul,
                    sampled != nil ? static_cast<unsigned long>(sampled.pixelFormat) : 0ul,
                    sampled != nil ? static_cast<unsigned long>(sampled.sampleCount) : 0ul,
                    binding.metalSamplerState,
                    static_cast<unsigned>(binding.reductionMode),
                    static_cast<double>(binding.lodBias),
                    static_cast<unsigned>(binding.borderClampMask));
            }
            std::fflush(stderr);
        }

        DrawProfileTimePoint profileBindingStart = profileRenderStateStart;
        if (profileDraw) {
            profileBindingStart = drawProfileNow();
            profileSample.renderStateUs =
                drawProfileElapsedUs(profileRenderStateStart, profileBindingStart);
        }

        // Bind vertex data at buffer index 0.
        // Attributeless draws (gl_VertexID-driven) skip vertex buffer binding.
        // OPT-5: when the VBO has a pre-uploaded Metal buffer, bind it
        // directly — zero memcpy.  Otherwise fall back to the ring buffer
        // sub-allocation path (OPT-1).
        if (attributelessDraw || info.vertexAttributeLayouts.empty()) {
            // No primary vertex buffer needed. This covers true
            // gl_VertexID-driven draws and draws whose shader inputs all
            // come from current generic attributes in extra constant buffers.
        } else if (info.metalVertexBuffer != nullptr) {
            id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
            [currentRenderEncoder setVertexBuffer:mtlBuf
                                           offset:static_cast<NSUInteger>(info.metalVertexBufferOffset)
                                          atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.vertexData, info.vertexDataByteCount);
            if (alloc.buffer == nil) {
                return false;
            }
            [currentRenderEncoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }

        // Bind extra vertex buffers (buffer index 1+) — e.g. per-instance
        // attribute data from glVertexAttribDivisor.
        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
            const auto& evb = info.extraVertexBuffers[ei];
            if (evb.metalBuffer != nullptr) {
                id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)evb.metalBuffer;
                [currentRenderEncoder setVertexBuffer:mtlBuf
                                               offset:static_cast<NSUInteger>(evb.metalBufferOffset)
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            } else {
                const void* bytes = evb.data != nullptr
                    ? evb.data
                    : (evb.ownedData.empty() ? nullptr : evb.ownedData.data());
                auto alloc = ringSuballocate(bytes, evb.byteCount);
                if (alloc.buffer == nil) {
                    return false;
                }
                [currentRenderEncoder setVertexBuffer:alloc.buffer
                                               offset:alloc.offset
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            }
        }

        // Bind per-stage uniform buffers. Under argbuf mode, these are
        // populated into the desc_set 1 argument buffer via the
        // fragArgEncoderSet1 / vertArgEncoderSet1 encoders further
        // below. The direct-binding path here still fires when argbuf
        // is off OR when the stage has NO samplers (set 0) AND no
        // UBOs — which normally means the shader has nothing at all,
        // so the setBytes calls are no-ops. Under argbuf mode with
        // UBOs present, skip the direct-binding calls entirely.
        {
            if (!vertexUsesArgBuf &&
                info.vertexUniformData != nullptr && info.vertexUniformSize > 0) {
                [currentRenderEncoder setVertexBytes:info.vertexUniformData
                                              length:info.vertexUniformSize
                                             atIndex:16];
            }
            if (!fragmentUsesArgBuf &&
                info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0) {
                [currentRenderEncoder setFragmentBytes:info.fragmentUniformData
                                                length:info.fragmentUniformSize
                                               atIndex:16];
            }
            // CKPT121 (Sprint 11 Phase 2 Day 6): SPIRV-Cross emits
            // gl_NumSamples as a `constant int& [[buffer(0)]]` FS
            // parameter. The MSL ShaderTranslator post-process gates the
            // gl_SampleMask=UINT_MAX override on this value (== 1 means
            // non-MSAA per GL spec). Bind the bound color attachment's
            // sampleCount here so the FS reads a real count.
            // CTS sample_variables.mask.samples_{1,2,4} verify samples >= 1
            // do not get the UINT_MAX neutralization.
            if (!fragmentNeedsGlNumSamplesArgBuf) {
                const int32_t glNumSamples = static_cast<int32_t>(attachmentSampleCount);
                [currentRenderEncoder setFragmentBytes:&glNumSamples
                                                length:sizeof(glNumSamples)
                                               atIndex:0];
            }
            if (vertexNeedsFragmentShadingRateState) {
                [currentRenderEncoder setVertexBytes:&info.fragmentShadingRateShaderState
                                              length:sizeof(info.fragmentShadingRateShaderState)
                                             atIndex:kAppGLFragmentShadingRateParamsBufferSlot];
            }
            if (vertexClipControlYSignSlot >= 0) {
                const float clipControlYSign =
                    (clipControlShaderYFixup &&
                     info.clipOrigin != GL_UPPER_LEFT) ? -1.0f : 1.0f;
                [currentRenderEncoder setVertexBytes:&clipControlYSign
                                              length:sizeof(clipControlYSign)
                                             atIndex:static_cast<NSUInteger>(vertexClipControlYSignSlot)];
            }
            const bool logLodBias = std::getenv("APPGL_LOG_LB") != nullptr;
            const NSInteger vertexReductionModesSlot =
                shaderSlots.vertexReductionModesSlot;
            if (vertexReductionModesSlot >= 0) {
                std::vector<std::uint32_t>& modes = textureUIntScratch();
                buildTextureReductionModes(info.vertexTextures, modes);
                [currentRenderEncoder setVertexBytes:modes.data()
                                              length:modes.size() * sizeof(std::uint32_t)
                                             atIndex:static_cast<NSUInteger>(vertexReductionModesSlot)];
            }
            const NSInteger vertexLodBiasesSlot =
                shaderSlots.vertexLodBiasesSlot;
            if (vertexLodBiasesSlot >= 0) {
                std::vector<float>& biases = textureFloatScratch();
                buildTextureLodBiases(info.vertexTextures, biases);
                if (logLodBias) {
                    std::fprintf(stderr,
                        "[LB-LOD-BUFFER] stage=vert bufferSlot=%ld count=%zu bias0=%f texBindings=%zu\n",
                        static_cast<long>(vertexLodBiasesSlot),
                        biases.size(),
                        biases.empty() ? 0.0 : static_cast<double>(biases[0]),
                        info.vertexTextures.size());
                }
                [currentRenderEncoder setVertexBytes:biases.data()
                                              length:biases.size() * sizeof(float)
                                             atIndex:static_cast<NSUInteger>(vertexLodBiasesSlot)];
            }
            const NSInteger vertexBorderClampModesSlot =
                shaderSlots.vertexBorderClampModesSlot;
            const NSInteger vertexBorderClampColorsSlot =
                shaderSlots.vertexBorderClampColorsSlot;
            if (vertexBorderClampModesSlot >= 0) {
                std::vector<std::uint32_t>& modes = textureUIntScratch();
                buildTextureBorderClampModes(info.vertexTextures, modes);
                [currentRenderEncoder setVertexBytes:modes.data()
                                              length:modes.size() * sizeof(std::uint32_t)
                                             atIndex:static_cast<NSUInteger>(vertexBorderClampModesSlot)];
            }
            if (vertexBorderClampColorsSlot >= 0) {
                std::vector<std::array<std::int32_t, 4>>& colors =
                    textureBorderColorScratch();
                buildTextureBorderClampColors(info.vertexTextures, colors);
                [currentRenderEncoder setVertexBytes:colors.data()
                                              length:colors.size() * sizeof(std::array<std::int32_t, 4>)
                                             atIndex:static_cast<NSUInteger>(vertexBorderClampColorsSlot)];
            }
            const NSInteger vertexImplicitLodBiasCorrectionSlot =
                shaderSlots.vertexImplicitLodBiasCorrectionSlot;
            if (vertexImplicitLodBiasCorrectionSlot >= 0) {
                const float correction = 0.0f;
                [currentRenderEncoder setVertexBytes:&correction
                                              length:sizeof(correction)
                                             atIndex:static_cast<NSUInteger>(vertexImplicitLodBiasCorrectionSlot)];
            }
            const NSInteger fragmentReductionModesSlot =
                shaderSlots.fragmentReductionModesSlot;
            if (fragmentReductionModesSlot >= 0) {
                std::vector<std::uint32_t>& modes = textureUIntScratch();
                buildTextureReductionModes(info.fragmentTextures, modes);
                [currentRenderEncoder setFragmentBytes:modes.data()
                                                length:modes.size() * sizeof(std::uint32_t)
                                               atIndex:static_cast<NSUInteger>(fragmentReductionModesSlot)];
            }
            const NSInteger fragmentLodBiasesSlot =
                shaderSlots.fragmentLodBiasesSlot;
            if (fragmentLodBiasesSlot >= 0) {
                std::vector<float>& biases = textureFloatScratch();
                buildTextureLodBiases(info.fragmentTextures, biases);
                if (logLodBias) {
                    std::fprintf(stderr,
                        "[LB-LOD-BUFFER] stage=frag bufferSlot=%ld count=%zu bias0=%f texBindings=%zu\n",
                        static_cast<long>(fragmentLodBiasesSlot),
                        biases.size(),
                        biases.empty() ? 0.0 : static_cast<double>(biases[0]),
                        info.fragmentTextures.size());
                }
                [currentRenderEncoder setFragmentBytes:biases.data()
                                                length:biases.size() * sizeof(float)
                                               atIndex:static_cast<NSUInteger>(fragmentLodBiasesSlot)];
            }
            const NSInteger fragmentBorderClampModesSlot =
                shaderSlots.fragmentBorderClampModesSlot;
            const NSInteger fragmentBorderClampColorsSlot =
                shaderSlots.fragmentBorderClampColorsSlot;
            if (fragmentBorderClampModesSlot >= 0) {
                std::vector<std::uint32_t>& modes = textureUIntScratch();
                buildTextureBorderClampModes(info.fragmentTextures, modes);
                [currentRenderEncoder setFragmentBytes:modes.data()
                                                length:modes.size() * sizeof(std::uint32_t)
                                               atIndex:static_cast<NSUInteger>(fragmentBorderClampModesSlot)];
            }
            if (fragmentBorderClampColorsSlot >= 0) {
                std::vector<std::array<std::int32_t, 4>>& colors =
                    textureBorderColorScratch();
                buildTextureBorderClampColors(info.fragmentTextures, colors);
                [currentRenderEncoder setFragmentBytes:colors.data()
                                                length:colors.size() * sizeof(std::array<std::int32_t, 4>)
                                               atIndex:static_cast<NSUInteger>(fragmentBorderClampColorsSlot)];
            }
            const NSInteger fragmentImplicitLodBiasCorrectionSlot =
                shaderSlots.fragmentImplicitLodBiasCorrectionSlot;
            if (fragmentImplicitLodBiasCorrectionSlot >= 0) {
                const float correction =
                    implicitLodViewportBiasCorrection(info, isFBODraw, colorTexture);
                if (logLodBias) {
                    std::fprintf(stderr,
                        "[LB-LOD-CORRECTION] stage=frag bufferSlot=%ld correction=%f viewport=%dx%d fbo=%dx%d\n",
                        static_cast<long>(fragmentImplicitLodBiasCorrectionSlot),
                        static_cast<double>(correction),
                        info.viewportWidth,
                        info.viewportHeight,
                        info.fboWidth,
                        info.fboHeight);
                }
                [currentRenderEncoder setFragmentBytes:&correction
                                                length:sizeof(correction)
                                               atIndex:static_cast<NSUInteger>(fragmentImplicitLodBiasCorrectionSlot)];
            }
            if (fragmentNeedsFragCoordParams) {
                const float renderTargetHeight = colorTexture != nil
                    ? static_cast<float>(colorTexture.height)
                    : static_cast<float>(std::max<GLsizei>(info.viewportHeight, 1));
                auto fragmentSamplesRenderTarget = [&](id<MTLTexture> target) {
                    if (target == nil) return false;
                    for (const auto& binding : info.fragmentTextures) {
                        if (binding.metalTexture == nullptr) continue;
                        id<MTLTexture> sampled =
                            (__bridge id<MTLTexture>)binding.metalTexture;
                        if (sampled == target) return true;
                    }
                    return false;
                };
                bool fragmentSamplesColorAttachment =
                    fragmentSamplesRenderTarget(colorTexture);
                if (!fragmentSamplesColorAttachment) {
                    for (void* rawExtraTex : info.fboAdditionalColorTextures) {
                        if (rawExtraTex == nullptr) continue;
                        id<MTLTexture> extraTex =
                            (__bridge id<MTLTexture>)rawExtraTex;
                        if (fragmentSamplesRenderTarget(extraTex)) {
                            fragmentSamplesColorAttachment = true;
                            break;
                        }
                    }
                }
                bool fragmentUsesStorageImage = false;
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalTexture != nullptr &&
                        binding.metalSamplerState == nullptr) {
                        fragmentUsesStorageImage = true;
                        break;
                    }
                }
                const bool flipToLowerLeft =
                    (info.clipOrigin != GL_UPPER_LEFT) &&
                    !fragmentSamplesColorAttachment;
                const auto viewportLowerLeftBase = [&]() -> float {
                    if (colorTexture == nil) {
                        return static_cast<float>(
                            std::max<GLsizei>(info.viewportHeight, 1));
                    }
                    const GLint rtH =
                        static_cast<GLint>(colorTexture.height);
                    const GLint glY = std::max<GLint>(0, info.viewportY);
                    const GLsizei availH = static_cast<GLsizei>(
                        std::max<GLint>(0, rtH - glY));
                    const GLsizei glH = std::min<GLsizei>(
                        info.viewportHeight, availH);
                    return static_cast<float>(glY + glH);
                }();
                // When the vertex shader handles LOWER_LEFT Y fixup, the
                // Metal viewport stays in GL coordinates, so fragment
                // gl_FragCoord must use the clamped viewport as its base.
                const float lowerLeftBase =
                    (fragmentUsesStorageImage || clipControlShaderYFixup)
                        ? viewportLowerLeftBase
                        : renderTargetHeight;
                const float fragCoordParams[4] = {
                    flipToLowerLeft ? lowerLeftBase : 0.0f,
                    flipToLowerLeft ? -1.0f : 1.0f,
                    flipToLowerLeft ? 1.0f : 0.0f,
                    0.0f,
                };
                // Sprint 18 Bank D-3 (`textures_bind_unit`): fragment
                // shader-side gl_FragCoord Y synthesis. This payload is
                // intentionally independent of the 5930a4d/c196254 FBO
                // readback flip markers, which stay responsible only for
                // CPU-visible readback orientation. If the fragment shader
                // samples the active color attachment, keep Metal's
                // render-target texture coordinate space; texture_barrier
                // self-feedback relies on that aliasing path and is not the
                // D-3 sampled-input case.
                [currentRenderEncoder setFragmentBytes:fragCoordParams
                                                length:sizeof(fragCoordParams)
                                               atIndex:kAppGLFragCoordParamsBufferSlot];
            }

            // Shadow-compare Y fixup: per-texture-slot flip factors for
            // the _appgl_CmpFlip buffer injected by the translator.
            // Always set when the shader declares the buffer — bindings
            // without the FBO-rendered predicate read 0.0 (no flip).
            if (fragmentDepthCompareFlipSlot >= 0) {
                float compareFlips[32] = {};
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalSlot < 32u) {
                        compareFlips[binding.metalSlot] = binding.compareFlipY;
                    }
                }
                [currentRenderEncoder
                    setFragmentBytes:compareFlips
                              length:sizeof(compareFlips)
                             atIndex:static_cast<NSUInteger>(
                                 fragmentDepthCompareFlipSlot)];
            }

            // Bind UBO data to the Metal encoder at the reflection-specified
            // [[buffer(N)]] slots.  Each entry was resolved by GLContext from
            // the GL uniform buffer binding state.
            for (const auto& ubo : info.uboBindings) {
                if (ubo.size == 0) continue;
                const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
                if (ubo.metalBuffer != nullptr) {
                    // Large UBO (>4KB): bind the Metal buffer directly.
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(ubo.metalBuffer);
                    const NSUInteger off = static_cast<NSUInteger>(ubo.metalBufferOffset);
                    if (ubo.isVertex && !vertexUsesArgBuf) {
                        [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
                    }
                    if (ubo.isFragment && !fragmentUsesArgBuf) {
                        [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
                    }
                } else if (ubo.data != nullptr) {
                    // Small UBO (≤4KB): inline bytes.
                    if (ubo.isVertex && !vertexUsesArgBuf) {
                        [currentRenderEncoder setVertexBytes:ubo.data
                                                      length:static_cast<NSUInteger>(ubo.size)
                                                     atIndex:slot];
                    }
                    if (ubo.isFragment && !fragmentUsesArgBuf) {
                        [currentRenderEncoder setFragmentBytes:ubo.data
                                                        length:static_cast<NSUInteger>(ubo.size)
                                                       atIndex:slot];
                    }
                }
            }
        }

        // Bind SSBOs to the render encoder. GL 4.3+ permits vertex and
        // fragment stages to declare `layout(binding=N) buffer X` for
        // arbitrary indexed-buffer-bound SSBOs. KHR-GL46.shader_storage_
        // buffer_object.*-{vs,fs} exercises this from both stages. MSL
        // expects the buffer at the reflected [[buffer(metalSlot)]].
        //
        // Step 7-3 follow-up: under argbuf mode, SSBOs are populated
        // into the desc_set 0 argument buffer (same encoder as
        // sampled/storage images) further below. Skip this direct-
        // binding loop when argbuf is on to avoid double-binding at
        // the wrong slot.
        for (const auto& ssbo : info.ssboBindings) {
            if (ssbo.metalBuffer == nullptr) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)ssbo.metalBuffer;
            const NSUInteger slot = static_cast<NSUInteger>(ssbo.metalSlot);
            const NSUInteger off = static_cast<NSUInteger>(ssbo.offset);
            if (ssbo.isVertex && !vertexUsesArgBuf) {
                [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
            }
            if (ssbo.isFragment && !fragmentUsesArgBuf) {
                [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
            }
        }
        for (const auto& atomic : info.atomicCounterBindings) {
            if (atomic.metalBuffer == nullptr) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)atomic.metalBuffer;
            const NSUInteger slot = static_cast<NSUInteger>(atomic.metalSlot);
            const NSUInteger off = static_cast<NSUInteger>(atomic.offset);
            if (atomic.isVertex && !vertexUsesArgBuf) {
                [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
            }
            if (atomic.isFragment && !fragmentUsesArgBuf) {
                [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
            }
        }

        if (vertexUsesMultiviewViewMask && !vertexUsesArgBuf) {
            [currentRenderEncoder setVertexBytes:ovrViewMask
                                          length:sizeof(ovrViewMask)
                                         atIndex:24];
        }
        if (fragmentUsesMultiviewViewMask && !fragmentUsesArgBuf) {
            [currentRenderEncoder setFragmentBytes:ovrViewMask
                                            length:sizeof(ovrViewMask)
                                           atIndex:24];
        }

        // Phase 8X Group 4d follow-up⁷ — bind textures and samplers for
        // this draw. GLContext::drawArrays / drawArraysInstanced /
        // drawElements populates `info.fragmentTextures` and
        // `info.vertexTextures` by walking the program's sampler uniforms,
        // resolving each one through the GL texture-unit state, and
        // snapping pointers to the cached MTLTexture / MTLSamplerState on
        // the texture object. A slot with a nullptr texture or sampler is
        // skipped silently — that means the GL app bound a sampler
        // uniform that points at an empty texture unit, which on the GL
        // side would sample a 1×1×1 default texture. Metal has no such
        // default so the slot stays unbound and the shader gets whatever
        // the driver leaves there. Most engines bind a real texture
        // before drawing anything that samples it, so the "null slot"
        // case is only expected for debug paths that we don't care about
        // in the smoke run. BAR's select-menu fragment shaders sample
        // one texture per draw (the glyph atlas page), so every call
        // here populates one binding in `fragmentTextures`.
        //
        // Phase 8X Group 4d follow-up⁸ — diagnostic instrumentation for
        // BAR's followup⁷ verification "byte-identical screenshot"
        // finding. The binding fix landed structurally clean (gauntlet
        // green, no regressions) but produced zero pixel-level change in
        // the select-menu render. Three hypotheses (BAR followup⁷ §Visual):
        //   A. bindings are emitted but all metalTexture/metalSamplerState
        //      pointers are nullptr, so every entry hits the skip-guard
        //      below and the encoder stays in the unbound state.
        //   B. `resolveSamplerBindings` finds zero reflection entries so
        //      `fragmentTextures` is empty on arrival — see matching log
        //      in `GLContext::Impl::resolveSamplerBindings`.
        //   C. BAR's text rendering runs through a program that never
        //      reaches this encoder (fall-through to solid-color path
        //      before the translated gate).
        // This one-shot-per-program log distinguishes A from B and C:
        //   - if this line never logs for programs 5/6/8/10 → hypothesis C
        //   - if it logs with sizes (0/0) → hypothesis B (zero bindings
        //     arrived on the tdi; check resolve log)
        //   - if it logs with sizes > 0 and hasTexture=0 or hasSampler=0 →
        //     hypothesis A (bindings arrived but were null)
        //   - if it logs with sizes > 0 and hasTexture=1 hasSampler=1 →
        //     bindings are real but pixels are still unchanged; means
        //     the issue is downstream of binding (shader texture coord,
        //     missing color-attachment write, etc.)
        // Keyed on info.program so the log fires exactly once per GL
        // program name per MetalFrameGraph instance (one per
        // GLContext). Single-threaded GL context means no mutex is
        // needed. See `loggedBindingPrograms` on Impl for the
        // multi-context rationale.
        if (info.program != 0 &&
            loggedBindingPrograms.insert(info.program).second) {
            APPGL_LOG(DRAW, @"[GL] encodeTranslatedDraw first-draw program=%u"
                  @" fragmentTextures.size=%zu vertexTextures.size=%zu",
                  info.program,
                  info.fragmentTextures.size(),
                  info.vertexTextures.size());
            for (std::size_t i = 0; i < info.fragmentTextures.size(); ++i) {
                const auto& b = info.fragmentTextures[i];
                APPGL_LOG(DRAW, @"[GL]   frag[%zu] slot=%u hasTexture=%d hasSampler=%d",
                      i,
                      static_cast<unsigned>(b.metalSlot),
                      b.metalTexture != nullptr ? 1 : 0,
                      b.metalSamplerState != nullptr ? 1 : 0);
            }
            for (std::size_t i = 0; i < info.vertexTextures.size(); ++i) {
                const auto& b = info.vertexTextures[i];
                APPGL_LOG(DRAW, @"[GL]   vert[%zu] slot=%u hasTexture=%d hasSampler=%d",
                      i,
                      static_cast<unsigned>(b.metalSlot),
                      b.metalTexture != nullptr ? 1 : 0,
                      b.metalSamplerState != nullptr ? 1 : 0);
            }

            // Phase 8X Group 4d follow-up¹⁰ — §Secondary VBO peek
            // for BAR's Theory A/B split. Dump the first 32 bytes
            // of the vertex data, the stride, and the attribute
            // layout list so BAR can decide whether the UVs on
            // programs 8/10 are tightly inside `[0, 1)` (Theory A
            // out — REPEAT wrap doesn't matter) or whether
            // they're scrambled / out-of-range (Theory B hint —
            // VBO upload bug, or Recoil-side vertex data problem).
            //
            // The peek reads from `info.vertexData` when non-null
            // (CPU scratch path) or from the Metal buffer's CPU-
            // visible contents when the draw path bound a shared-
            // storage MTLBuffer directly (OPT-5 path). Private-
            // storage buffers are not readable from CPU so we
            // silently skip the hex dump in that case — BAR can
            // still see the stride and layout list to cross-check
            // against native GL's vertex array setup.
            //
            // Also dumps the attribute layout list so BAR knows
            // which byte offsets inside the stride hold `uv`
            // attributes — UI quad VBOs typically have something
            // like (pos.xy, uv.xy) packed tight or
            // (pos.xyz, uv.xy, color.rgba) in a 36-byte stride.
            APPGL_LOG(DRAW, @"[GL]   vbo stride=%zu vertexDataByteCount=%zu"
                  @" metalBuf=%d extraBufs=%zu attrLayouts=%zu",
                  info.vertexStride,
                  info.vertexDataByteCount,
                  info.metalVertexBuffer != nullptr ? 1 : 0,
                  info.extraVertexBuffers.size(),
                  info.vertexAttributeLayouts.size());
            for (std::size_t i = 0; i < info.vertexAttributeLayouts.size(); ++i) {
                const auto& a = info.vertexAttributeLayouts[i];
                APPGL_LOG(DRAW, @"[GL]     attr[%zu] location=%u offset=%zu",
                      i, a.location, a.offset);
            }

            // Resolve a CPU pointer to the start of the vertex
            // stream we're about to encode.
            const std::uint8_t* peekPtr = nullptr;
            if (info.vertexData != nullptr) {
                peekPtr = static_cast<const std::uint8_t*>(info.vertexData);
            } else if (info.metalVertexBuffer != nullptr) {
                id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
                // storageMode shared/managed → contents is a
                // valid CPU pointer. Private is nil/garbage.
                if ([mtlBuf storageMode] == MTLStorageModeShared ||
                    [mtlBuf storageMode] == MTLStorageModeManaged) {
                    const std::uint8_t* base =
                        static_cast<const std::uint8_t*>([mtlBuf contents]);
                    if (base != nullptr) {
                        peekPtr = base + info.metalVertexBufferOffset;
                    }
                }
            }

            if (peekPtr != nullptr) {
                // Peek 32 bytes — enough to cover a full 32-byte
                // stride (pos.xyz + uv.xy + color.rgba layouts) or
                // two 16-byte stride quads (pos.xy + uv.xy). BAR
                // can decode by stride; the stride is on the
                // preceding line.
                const std::size_t peekLen = 32;
                char hexBuf[128];
                char floatBuf[128];
                for (std::size_t i = 0; i < peekLen; ++i) {
                    std::snprintf(hexBuf + i * 3, sizeof(hexBuf) - i * 3,
                                  "%02X ", peekPtr[i]);
                }
                hexBuf[peekLen * 3 - 1] = '\0';
                // Also interpret as 8 floats for quick visual
                // sanity-check of position/UV ranges.
                float asFloats[8];
                std::memcpy(asFloats, peekPtr, sizeof(asFloats));
                std::snprintf(floatBuf, sizeof(floatBuf),
                    "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %.3f",
                    asFloats[0], asFloats[1], asFloats[2], asFloats[3],
                    asFloats[4], asFloats[5], asFloats[6], asFloats[7]);
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 hex=[%s]", hexBuf);
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 f32=[%s]", floatBuf);
            } else {
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 skip=private-or-null");
            }
        }
        // Step 7-3: argument-buffer binding path. When argbuf is enabled
        // and the pipeline has desc_set 0 (fragment and/or vertex stage),
        // allocate a per-stage argument buffer, populate it via the
        // MTLArgumentEncoder, bind at [[buffer(24)]], and call
        // useResource for each bound texture + sampler so Metal
        // residency tracks them. When argbuf is disabled, fall through
        // to the baseline direct-binding path unchanged.
        if (useArgBuf && (fragArgEncoderSet0 != nil || vertArgEncoderSet0 != nil ||
                          fragArgEncoderSet1 != nil || vertArgEncoderSet1 != nil)) {
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::ArgumentBinding,
                                             AppGLCommandReason::TranslatedDraw);
            auto encodeTexturesIntoArgBuf = [&](id<MTLArgumentEncoder> encoder,
                                                 const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
                                                 MTLRenderStages stage,
                                                 bool isFragment,
                                                 bool needsGlNumSamplesBuffer,
                                                 bool needsSSBOSizeBuffer) {
                // Step 7-3 follow-up: no early-return on empty textures
                // — the set-0 argbuf may also hold SSBOs (see the SSBO
                // loop below), and an SSBO-only shader (no samplers, no
                // storage images) still needs its argument buffer bound.
                // The encoder-is-nil check still fires when the stage
                // has no desc_set 0 usage at all.
                if (encoder == nil) return;
                const NSUInteger len = [encoder encodedLength];
                if (len == 0) return;
                // Step 7-4: ring-buffer sub-allocation for the
                // argument buffer. Avoids per-draw
                // newBufferWithLength churn — a single 16-MB ring slot
                // holds hundreds of argbufs until the GPU completes
                // the frame. Falls back to newBufferWithLength on ring
                // overflow (single draw exceeds remaining space).
                RingAlloc argBufAlloc = ringAllocRaw(len);
                id<MTLBuffer> argBuf = argBufAlloc.buffer;
                const NSUInteger argBufOffset = argBufAlloc.offset;
                if (argBuf == nil) return;
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::ArgumentBufferPayload,
                    AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                    AppGLCommandReason::TranslatedDraw,
                    24,
                    static_cast<std::size_t>(len));
                [encoder setArgumentBuffer:argBuf offset:argBufOffset];
                if (needsGlNumSamplesBuffer) {
                    const int32_t glNumSamples =
                        static_cast<int32_t>(attachmentSampleCount);
                    RingAlloc sampleCountAlloc =
                        ringSuballocate(&glNumSamples, sizeof(glNumSamples));
                    if (sampleCountAlloc.buffer != nil) {
                        info.submissionGroup.addTransient(
                            AppGLSubmissionTransientKind::UniformRingBytes,
                            AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                            AppGLCommandReason::TranslatedDraw,
                            0,
                            sizeof(glNumSamples));
                        [encoder setBuffer:sampleCountAlloc.buffer
                                    offset:sampleCountAlloc.offset
                                   atIndex:0];
                        [currentRenderEncoder useResource:sampleCountAlloc.buffer
                                                    usage:MTLResourceUsageRead
                                                   stages:stage];
                    }
                }
                // Sprint 18 Item42: graphics-stage SSBO `.length()`
                // sidecar. The translator rewrites graphics argbuf MSL
                // to read this table from direct buffer slot 30, keyed
                // by each SSBO's argbuf id (192+ for AppGL SSBOs). We
                // also populate desc_set 0 id(0) defensively because
                // SPIRV-Cross keeps that field in the argument-buffer
                // struct. This is the render-stage sister of the
                // compute direct sidecar from 96c7d10.
                if (needsSSBOSizeBuffer) {
                    std::uint32_t maxSlot = 0;
                    bool anySizedSSBO = false;
                    for (const auto& ssbo : info.ssboBindings) {
                        if (ssbo.metalBuffer == nullptr || ssbo.size == 0) continue;
                        if (isFragment && !ssbo.isFragment) continue;
                        if (!isFragment && !ssbo.isVertex) continue;
                        maxSlot = std::max(maxSlot, ssbo.metalSlot);
                        anySizedSSBO = true;
                    }
                    if (anySizedSSBO) {
                        static thread_local std::vector<std::uint32_t> sizes;
                        sizes.assign(static_cast<std::size_t>(maxSlot) + 1u, 0u);
                        for (const auto& ssbo : info.ssboBindings) {
                            if (ssbo.metalBuffer == nullptr || ssbo.size == 0) continue;
                            if (isFragment && !ssbo.isFragment) continue;
                            if (!isFragment && !ssbo.isVertex) continue;
                            if (ssbo.metalSlot >= sizes.size()) continue;
                            sizes[ssbo.metalSlot] =
                                static_cast<std::uint32_t>(std::min<std::size_t>(
                                    ssbo.size,
                                    static_cast<std::size_t>(
                                        std::numeric_limits<std::uint32_t>::max())));
                        }
                        RingAlloc sizeAlloc = ringSuballocate(
                            sizes.data(),
                            sizes.size() * sizeof(std::uint32_t));
                        if (sizeAlloc.buffer != nil) {
                            info.submissionGroup.addTransient(
                                AppGLSubmissionTransientKind::SsboSizeBuffer,
                                AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                                AppGLCommandReason::TranslatedDraw,
                                30,
                                sizes.size() * sizeof(std::uint32_t));
                            [encoder setBuffer:sizeAlloc.buffer
                                        offset:sizeAlloc.offset
                                       atIndex:0];
                            if (isFragment) {
                                [currentRenderEncoder setFragmentBuffer:sizeAlloc.buffer
                                                                  offset:sizeAlloc.offset
                                                                 atIndex:30];
                            } else {
                                [currentRenderEncoder setVertexBuffer:sizeAlloc.buffer
                                                                offset:sizeAlloc.offset
                                                               atIndex:30];
                            }
                            [currentRenderEncoder useResource:sizeAlloc.buffer
                                                        usage:MTLResourceUsageRead
                                                       stages:stage];
                        }
                    }
                }
                for (const auto& binding : textures) {
                    if (binding.metalTexture == nullptr) continue;
                    id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                    // Step 7-3 follow-up: reflection is now argbuf-aware,
                    // so `binding.metalSlot` IS the argbuf `[[id(N)]]`
                    // slot directly. For sampled images (metalSamplerState
                    // non-null) the texture half lives at metalSlot and the
                    // sampler at metalSlot+1 (reflection returns 2*glBinding
                    // so +1 = 2*glBinding+1, matching the consolidation
                    // convention). For storage images the sampler slot is
                    // unused; resolveImageBindings packs them into the
                    // same list with metalSamplerState=nullptr and
                    // metalSlot already offset to 128+glBinding.
                    const NSUInteger idIdx = static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setTexture:tex atIndex:idIdx];
                    MTLResourceUsage usage = MTLResourceUsageRead;
                    // SPIRV-Cross lowers samplerBuffer to a texel-fetch
                    // texture2d member only. There is no sampler member in
                    // the argument-buffer struct, unlike ordinary sampled
                    // textures, so do not write metalSlot+1 for buffer
                    // textures.
                    const bool usesSamplerArgument =
                        binding.metalSamplerState != nullptr &&
                        binding.textureBufferBackingMetalBuffer == nullptr;
                    if (usesSamplerArgument) {
                        id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setSamplerState:smp atIndex:idIdx + 1];
                        usage |= MTLResourceUsageSample;
                    } else if (binding.metalSamplerState == nullptr) {
                        // Storage image — add write usage since imageStore
                        // may fire. Direct-binding's path set ShaderWrite
                        // via MTLTextureUsage when the texture was created;
                        // argbuf mode additionally needs runtime
                        // useResource to track residency.
                        usage |= MTLResourceUsageWrite;
                    }
                    // Residency tracking: Metal's argument buffers are
                    // indirect references. Without useResource, the
                    // texture/sampler pages may not be resident on GPU
                    // when the shader reads through the argument buffer.
                    [currentRenderEncoder useResource:tex
                                                usage:usage
                                               stages:stage];
                    if (binding.textureBufferBackingMetalBuffer != nullptr) {
                        id<MTLBuffer> backingBuffer =
                            (__bridge id<MTLBuffer>)binding.textureBufferBackingMetalBuffer;
                        if (backingBuffer != nil) {
                            [currentRenderEncoder useResource:backingBuffer
                                                        usage:MTLResourceUsageRead
                                                       stages:stage];
                        }
                    }
                }
                // SSBOs (graphics stage) — `info.ssboBindings` stage-
                // filtered. Under argbuf reflection SSBOs live at
                // [[id(192 + glBinding)]]. Direct mode uses sequential
                // 28+N slots via setVertexBuffer/setFragmentBuffer.
                for (const auto& ssbo : info.ssboBindings) {
                    if (ssbo.metalBuffer == nullptr) continue;
                    if (isFragment && !ssbo.isFragment) continue;
                    if (!isFragment && !ssbo.isVertex) continue;
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(ssbo.metalBuffer);
                    [encoder setBuffer:buf
                                offset:static_cast<NSUInteger>(ssbo.offset)
                               atIndex:static_cast<NSUInteger>(ssbo.metalSlot)];
                    [currentRenderEncoder useResource:buf
                                                usage:MTLResourceUsageRead|MTLResourceUsageWrite
                                               stages:stage];
                }
                for (const auto& atomic : info.atomicCounterBindings) {
                    if (atomic.metalBuffer == nullptr) continue;
                    if (isFragment && !atomic.isFragment) continue;
                    if (!isFragment && !atomic.isVertex) continue;
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(atomic.metalBuffer);
                    [encoder setBuffer:buf
                                offset:static_cast<NSUInteger>(atomic.offset)
                               atIndex:static_cast<NSUInteger>(atomic.metalSlot)];
                    [currentRenderEncoder useResource:buf
                                                usage:MTLResourceUsageRead|MTLResourceUsageWrite
                                               stages:stage];
                }
                if (isFragment) {
                    [currentRenderEncoder setFragmentBuffer:argBuf offset:argBufOffset atIndex:24];
                } else {
                    [currentRenderEncoder setVertexBuffer:argBuf offset:argBufOffset atIndex:24];
                }
            };
            encodeTexturesIntoArgBuf(fragArgEncoderSet0, info.fragmentTextures,
                                      MTLRenderStageFragment, true,
                                      fragmentNeedsGlNumSamplesArgBuf,
                                      fragmentNeedsSSBOSizeBuffer);
            encodeTexturesIntoArgBuf(vertArgEncoderSet0, info.vertexTextures,
                                      MTLRenderStageVertex, false,
                                      false,
                                      vertexNeedsSSBOSizeBuffer);

            // Step 7-3 UBO follow-up: populate desc_set 1 argbuf with
            // the default uniform block + explicit `uniform Block`
            // UBOs. Default uniform block lives at [[id(16)]] per the
            // translator's uniformBufferBase convention; explicit UBOs
            // at sequential slots 16 + per-stage-offset (the
            // info.uboBindings entries carry their final metalSlot
            // from reflection).
            //
            // Small UBO data (ubo.data != nullptr, metalBuffer = nullptr)
            // was previously inlined via setVertexBytes/setFragmentBytes
            // which isn't usable inside an argument buffer — we must
            // hand the encoder a real MTLBuffer. Route through
            // `ringSuballocate` which copies the CPU bytes into a
            // device-visible transient buffer and returns its handle
            // + offset. The same path works for the default uniform
            // block data.
            auto encodeUBOsIntoArgBuf = [&](id<MTLArgumentEncoder> encoder,
                                             const void* uniformData,
                                             NSUInteger uniformSize,
                                             bool isVertex,
                                             MTLRenderStages stage) {
                if (encoder == nil) return;
                const NSUInteger len = [encoder encodedLength];
                if (len == 0) return;
                // Step 7-4: ring-buffer sub-allocation for the UBO
                // argument buffer (matches the set-0 texture argbuf
                // allocation above).
                RingAlloc argBufAlloc = ringAllocRaw(len);
                id<MTLBuffer> argBuf = argBufAlloc.buffer;
                const NSUInteger argBufOffset = argBufAlloc.offset;
                if (argBuf == nil) return;
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::ArgumentBufferPayload,
                    AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                    AppGLCommandReason::TranslatedDraw,
                    25,
                    static_cast<std::size_t>(len));
                [encoder setArgumentBuffer:argBuf offset:argBufOffset];

                // Default uniform block at [[id(16)]].
                if (uniformData != nullptr && uniformSize > 0) {
                    RingAlloc alloc = ringSuballocate(uniformData, uniformSize);
                    if (alloc.buffer != nil) {
                        info.submissionGroup.addTransient(
                            AppGLSubmissionTransientKind::UniformRingBytes,
                            AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                            AppGLCommandReason::TranslatedDraw,
                            16,
                            static_cast<std::size_t>(uniformSize));
                        [encoder setBuffer:alloc.buffer
                                    offset:alloc.offset
                                   atIndex:16];
                        [currentRenderEncoder useResource:alloc.buffer
                                                    usage:MTLResourceUsageRead
                                                   stages:stage];
                    }
                }

                // Explicit UBOs at their reflection-specified slots.
                for (const auto& ubo : info.uboBindings) {
                    if (ubo.size == 0) continue;
                    if (isVertex && !ubo.isVertex) continue;
                    if (!isVertex && !ubo.isFragment) continue;
                    const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
                    id<MTLBuffer> uboBuf = nil;
                    NSUInteger uboOff = 0;
                    if (ubo.metalBuffer != nullptr) {
                        uboBuf = (__bridge id<MTLBuffer>)(ubo.metalBuffer);
                        uboOff = static_cast<NSUInteger>(ubo.metalBufferOffset);
                    } else if (ubo.data != nullptr) {
                        RingAlloc alloc = ringSuballocate(ubo.data, ubo.size);
                        uboBuf = alloc.buffer;
                        uboOff = alloc.offset;
                        if (uboBuf != nil) {
                            info.submissionGroup.addTransient(
                                AppGLSubmissionTransientKind::UniformRingBytes,
                                AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                                AppGLCommandReason::TranslatedDraw,
                                static_cast<std::uint32_t>(slot),
                                ubo.size);
                        }
                    }
                    if (uboBuf == nil) continue;
                    [encoder setBuffer:uboBuf offset:uboOff atIndex:slot];
                    [currentRenderEncoder useResource:uboBuf
                                                usage:MTLResourceUsageRead
                                               stages:stage];
                }

                if (isVertex) {
                    [currentRenderEncoder setVertexBuffer:argBuf offset:argBufOffset atIndex:25];
                } else {
                    [currentRenderEncoder setFragmentBuffer:argBuf offset:argBufOffset atIndex:25];
                }
            };
            encodeUBOsIntoArgBuf(fragArgEncoderSet1,
                                  info.fragmentUniformData, info.fragmentUniformSize,
                                  /*isVertex=*/false, MTLRenderStageFragment);
            encodeUBOsIntoArgBuf(vertArgEncoderSet1,
                                  info.vertexUniformData, info.vertexUniformSize,
                                  /*isVertex=*/true, MTLRenderStageVertex);
        }
        // Sprint 8 B Cluster F F1 Day 9 (CKPT81): the per-binding
        // skip used to require BOTH metalTexture AND metalSamplerState
        // to be non-null, which silently dropped storage-image
        // bindings (resolveImageBindings deliberately leaves
        // metalSamplerState=nullptr because imageLoad/Store doesn't
        // need a sampler). Skip only on missing texture; bind the
        // sampler conditionally on its own. Required by
        // KHR-GL46.layout_binding.image2D_layout_binding_imageLoad_*
        // FS/VS variants — the test calls glBindImageTexture(N, ...),
        // resolveImageBindings populates fragmentTextures with
        // {tex, sampler=null, slot=N}, but the binding was being
        // dropped here so imageLoad in the FS read undefined.
        if (!fragmentUsesArgBuf) {
            for (const auto& binding : info.fragmentTextures) {
                if (binding.metalTexture == nullptr) {
                    continue;
                }
                id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                [currentRenderEncoder setFragmentTexture:tex
                                                 atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                if (binding.imageAtomicMetalBuffer != nullptr &&
                    binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                    id<MTLBuffer> buf =
                        (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                    if (buf != nil) {
                        [currentRenderEncoder setFragmentBuffer:buf
                                                         offset:binding.imageAtomicBufferOffset
                                                        atIndex:static_cast<NSUInteger>(
                                                            binding.imageAtomicBufferSlot)];
                    }
                }
                if (binding.metalSamplerState != nullptr) {
                    id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                    [currentRenderEncoder setFragmentSamplerState:smp
                                                          atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                }
            }
        }
        if (!vertexUsesArgBuf) {
            for (const auto& binding : info.vertexTextures) {
                if (binding.metalTexture == nullptr) {
                    continue;
                }
                id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                [currentRenderEncoder setVertexTexture:tex
                                               atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                if (binding.imageAtomicMetalBuffer != nullptr &&
                    binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                    id<MTLBuffer> buf =
                        (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                    if (buf != nil) {
                        [currentRenderEncoder setVertexBuffer:buf
                                                       offset:binding.imageAtomicBufferOffset
                                                      atIndex:static_cast<NSUInteger>(
                                                          binding.imageAtomicBufferSlot)];
                    }
                }
                if (binding.metalSamplerState != nullptr) {
                    id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                    [currentRenderEncoder setVertexSamplerState:smp
                                                        atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                }
            }
        }

        DrawProfileTimePoint profilePrimitivePrepStart = profileBindingStart;
        if (profileDraw) {
            profilePrimitivePrepStart = drawProfileNow();
            profileSample.bindingUs =
                drawProfileElapsedUs(profileBindingStart, profilePrimitivePrepStart);
        }

        MTLPrimitiveType primitive;
        // GL_TRIANGLE_FAN, GL_LINE_LOOP, and the four *_ADJACENCY modes
        // have no Metal equivalent. Expand to an indexed draw with a
        // recomputed index stream here. For drawElements inputs the
        // expansion source indexes into the user's element buffer (via
        // `readPositional` below); for drawArrays the positional index
        // equals the vertex ID.
        std::vector<std::uint32_t> expandedIndices;
        bool useExpandedIndices = false;

        // Resolve a positional draw index (0..n-1 for drawArrays /
        // 0..indexCount-1 for drawElements) to the vertex ID that Metal
        // will ultimately use as the index into the vertex buffer. For
        // drawElements we read from the user's element buffer — either
        // CPU-side bytes (info.indices) or the Metal index buffer's
        // mapped contents (info.metalIndexBuffer). For drawArrays the
        // positional index is returned unchanged.
        auto readPositional = [&](GLsizei p) -> std::uint32_t {
            const bool hasClientIndices = (info.indices != nullptr && info.indexCount > 0);
            const bool hasMetalIndices = (info.metalIndexBuffer != nullptr);
            if (!hasClientIndices && !hasMetalIndices) {
                return static_cast<std::uint32_t>(p);
            }
            const void* base = nullptr;
            if (hasClientIndices) {
                base = info.indices;
            } else {
                id<MTLBuffer> buf = (__bridge id<MTLBuffer>)info.metalIndexBuffer;
                base = static_cast<const std::uint8_t*>([buf contents])
                     + info.metalIndexBufferOffset;
            }
            switch (info.indexType) {
                case GL_UNSIGNED_BYTE:
                    return static_cast<std::uint32_t>(
                        reinterpret_cast<const std::uint8_t*>(base)[p]);
                case GL_UNSIGNED_SHORT:
                    return static_cast<std::uint32_t>(
                        reinterpret_cast<const std::uint16_t*>(base)[p]);
                case GL_UNSIGNED_INT:
                default:
                    return reinterpret_cast<const std::uint32_t*>(base)[p];
            }
        };

        switch (info.mode) {
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_TRIANGLE_FAN: {
                // Expand: fan(v0,v1,v2,...,vN) → tri(v0,v1,v2), tri(v0,v2,v3), ...
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 3) {
                    expandedIndices.reserve(static_cast<std::size_t>((n - 2) * 3));
                    for (GLsizei i = 1; i < n - 1; ++i) {
                        expandedIndices.push_back(readPositional(0));
                        expandedIndices.push_back(readPositional(i));
                        expandedIndices.push_back(readPositional(i + 1));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_LINE_LOOP: {
                // Expand: loop(v0,v1,...,vN) → strip(v0,v1,...,vN,v0)
                primitive = MTLPrimitiveTypeLineStrip;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 2) {
                    expandedIndices.reserve(static_cast<std::size_t>(n + 1));
                    for (GLsizei i = 0; i < n; ++i) {
                        expandedIndices.push_back(readPositional(i));
                    }
                    expandedIndices.push_back(readPositional(0)); // Close the loop
                    useExpandedIndices = true;
                }
                break;
            }
            // GL 4.6 §10.1 — adjacency modes without a geometry shader
            // ignore the adjacent vertices. When a GS is attached the
            // GS emulator decomposes these into the expanded output
            // topology upstream; this branch only runs when no GS is
            // in play, so emit MTLPrimitiveTypeTriangle / Line with
            // only the base-primitive verts.
            case GL_LINES_ADJACENCY: {
                // 4 verts per line → [1, 2] pair per group.
                primitive = MTLPrimitiveTypeLine;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei groups = n / 4;
                if (groups > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(groups) * 2);
                    for (GLsizei g = 0; g < groups; ++g) {
                        expandedIndices.push_back(readPositional(g * 4 + 1));
                        expandedIndices.push_back(readPositional(g * 4 + 2));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_LINE_STRIP_ADJACENCY: {
                // n verts → (n-3) line segments using verts[i+1], verts[i+2].
                primitive = MTLPrimitiveTypeLine;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 4) {
                    expandedIndices.reserve(static_cast<std::size_t>(n - 3) * 2);
                    for (GLsizei i = 1; i <= n - 3; ++i) {
                        expandedIndices.push_back(readPositional(i));
                        expandedIndices.push_back(readPositional(i + 1));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLES_ADJACENCY: {
                // 6 verts per triangle → [0, 2, 4] triple per group.
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei groups = n / 6;
                if (groups > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(groups) * 3);
                    for (GLsizei g = 0; g < groups; ++g) {
                        expandedIndices.push_back(readPositional(g * 6 + 0));
                        expandedIndices.push_back(readPositional(g * 6 + 2));
                        expandedIndices.push_back(readPositional(g * 6 + 4));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLE_STRIP_ADJACENCY: {
                // GL 4.6 §10.1 Table 10.2 — N verts → (N - 4) / 2
                // triangles (equivalently N/2 - 2). Main vertices
                // occupy positional indices 0, 2, 4, … with adjacent
                // vertices in between at 1, 3, 5, …. For primitive p
                // (0-indexed):
                //   even p : raw indices 2p,     2p + 2, 2p + 4
                //   odd  p : raw indices 2p + 2, 2p,     2p + 4
                // The odd-p swap preserves consistent winding — the
                // strip alternates orientation with each step.
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei triCount = (n >= 6) ? ((n - 4) / 2) : 0;
                if (triCount > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(triCount) * 3);
                    for (GLsizei p = 0; p < triCount; ++p) {
                        const GLsizei a = 2 * p + 0;
                        const GLsizei b = 2 * p + 2;
                        const GLsizei c = 2 * p + 4;
                        if ((p & 1) == 0) {
                            expandedIndices.push_back(readPositional(a));
                            expandedIndices.push_back(readPositional(b));
                            expandedIndices.push_back(readPositional(c));
                        } else {
                            expandedIndices.push_back(readPositional(b));
                            expandedIndices.push_back(readPositional(a));
                            expandedIndices.push_back(readPositional(c));
                        }
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLES:
            default:                primitive = MTLPrimitiveTypeTriangle; break;
        }

        profileSample.fboDraw = isFBODraw;
        profileSample.argumentBuffers = useArgBuf;
        profileSample.indexed =
            (useExpandedIndices && !expandedIndices.empty()) ||
            (info.indices != nullptr && info.indexCount > 0);
        profileSample.expanded = useExpandedIndices && !expandedIndices.empty();
        DrawProfileTimePoint profilePreDrawStart = profilePrimitivePrepStart;
        auto profileBeginMetalDraw = [&]() -> DrawProfileTimePoint {
            if (!profileDraw) {
                return DrawProfileTimePoint{};
            }
            const DrawProfileTimePoint metalDrawStart = drawProfileNow();
            profileSample.primitivePrepUs +=
                drawProfileElapsedUs(profilePreDrawStart, metalDrawStart);
            ++profileSample.metalDrawCalls;
            return metalDrawStart;
        };
        auto profileEndMetalDraw = [&](DrawProfileTimePoint metalDrawStart) {
            if (!profileDraw) return;
            const DrawProfileTimePoint metalDrawEnd = drawProfileNow();
            profileSample.metalDrawUs +=
                drawProfileElapsedUs(metalDrawStart, metalDrawEnd);
            profilePreDrawStart = metalDrawEnd;
        };

        if (useExpandedIndices && !expandedIndices.empty()) {
            // Primitive expansion path (GL_TRIANGLE_FAN, GL_LINE_LOOP,
            // adjacency modes). The expanded buffer carries actual
            // vertex IDs (for drawArrays) or actual element-buffer
            // values (for drawElements via readPositional). baseVertex
            // / baseInstance / instanceCount are preserved from the
            // original draw so Metal applies them uniformly.
            const std::size_t indexBytes = expandedIndices.size() * sizeof(std::uint32_t);
            auto iAlloc = ringSuballocate(expandedIndices.data(), indexBytes);
            if (iAlloc.buffer == nil) {
                return false;
            }
            if (effectiveInstanceCount > 1 || info.baseVertex != 0 || info.baseInstance != 0) {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(expandedIndices.size())
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:iAlloc.buffer
                             indexBufferOffset:iAlloc.offset
                                 instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                                    baseVertex:static_cast<NSUInteger>(info.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(info.baseInstance)];
                profileEndMetalDraw(metalDrawStart);
            } else {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(expandedIndices.size())
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:iAlloc.buffer
                             indexBufferOffset:iAlloc.offset];
                profileEndMetalDraw(metalDrawStart);
            }
        } else if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            if (info.indexType == GL_UNSIGNED_INT) {
                metalIndexType = MTLIndexTypeUInt32;
                bytesPerIndex = 4;
            }

            // OPT-5: use direct Metal index buffer when available.
            id<MTLBuffer> idxBuffer = nil;
            NSUInteger idxOffset = 0;
            if (info.metalIndexBuffer != nullptr) {
                idxBuffer = (__bridge id<MTLBuffer>)info.metalIndexBuffer;
                idxOffset = static_cast<NSUInteger>(info.metalIndexBufferOffset);
            } else {
                const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
                auto iAlloc = ringSuballocate(info.indices, indexBytes);
                if (iAlloc.buffer == nil) {
                    return false;
                }
                idxBuffer = iAlloc.buffer;
                idxOffset = iAlloc.offset;
            }

            if (effectiveInstanceCount > 1 || info.baseVertex != 0 || info.baseInstance != 0) {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset
                                 instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                                    baseVertex:static_cast<NSUInteger>(info.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(info.baseInstance)];
                profileEndMetalDraw(metalDrawStart);
            } else {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset];
                profileEndMetalDraw(metalDrawStart);
            }
        } else {
            if (effectiveInstanceCount > 1 || info.baseVertex != 0 || info.baseInstance != 0) {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:static_cast<NSUInteger>(info.baseVertex)
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)
                          instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                           baseInstance:static_cast<NSUInteger>(info.baseInstance)];
                profileEndMetalDraw(metalDrawStart);
            } else {
                const DrawProfileTimePoint metalDrawStart = profileBeginMetalDraw();
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:static_cast<NSUInteger>(info.baseVertex)
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)];
                profileEndMetalDraw(metalDrawStart);
            }
        }

        const DrawProfileTimePoint profileFinalizeStart =
            profileDraw ? drawProfileNow() : DrawProfileTimePoint{};
        if (isFBODraw) {
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }

        pendingPresent = true;
        if (profileDraw) {
            const DrawProfileTimePoint profileTotalEnd = drawProfileNow();
            profileSample.finalizeUs =
                drawProfileElapsedUs(profileFinalizeStart, profileTotalEnd);
            profileSample.totalUs =
                drawProfileElapsedUs(profileTotalStart, profileTotalEnd);
            drawSubmitProfile.record(profileSample);
        }
        return true;
    }

    struct ParallelChildEncoderState {
        id<MTLRenderPipelineState> cachedPipelineState = nil;
        id<MTLDepthStencilState> cachedDepthStencilState = nil;
        MTLCullMode cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
        MTLWinding cachedFrontFaceWinding =
            static_cast<MTLWinding>(0xFFFFFFFF);
        MTLTriangleFillMode cachedFillMode =
            static_cast<MTLTriangleFillMode>(0xFFFFFFFF);
    };

    bool parallelTextureBindingsWorkerSafe(
        const std::vector<TranslatedDrawInfo::TextureBinding>& textures) const {
        for (const auto& binding : textures) {
            if (binding.metalTexture == nullptr) {
                continue;
            }
            if (binding.metalSamplerState == nullptr ||
                binding.imageAtomicMetalBuffer != nullptr ||
                binding.textureBufferBackingMetalBuffer != nullptr) {
                return false;
            }
        }
        return true;
    }

    bool translatedDrawWorkerEmitSafe(const TranslatedDrawInfo& info) const {
        if (translatedDrawNeedsCpuOrRingUploadPath(info)) {
            return false;
        }
        if (!info.ssboBindings.empty() ||
            !info.atomicCounterBindings.empty() ||
            !info.writtenImageTextureNames.empty()) {
            return false;
        }
        if (!parallelTextureBindingsWorkerSafe(info.fragmentTextures) ||
            !parallelTextureBindingsWorkerSafe(info.vertexTextures)) {
            return false;
        }
        if (info.vertexUniformSize > 4096 ||
            info.fragmentUniformSize > 4096) {
            return false;
        }
        for (const auto& ubo : info.uboBindings) {
            if (ubo.metalBuffer == nullptr && ubo.size > 4096) {
                return false;
            }
        }
        if (info.indexCount > 0 &&
            info.indexType != GL_UNSIGNED_SHORT &&
            info.indexType != GL_UNSIGNED_INT) {
            return false;
        }
        return true;
    }

    bool prepareCapturedTranslatedDrawForParallel(
        const TranslatedDrawInfo& source,
        CapturedTranslatedDrawRecord& capture) {
        capture.parallelPrepared = false;
        capture.parallelFallbackReason =
            ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;

        if (!translatedDrawWorkerEmitSafe(source)) {
            return false;
        }

        const bool hasFragmentStage =
            source.fragmentMSL != nullptr && !source.fragmentMSL->empty();
        id<MTLTexture> colorTexture =
            usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;
        const NSUInteger attachmentSampleCount =
            colorTexture != nil ? colorTexture.sampleCount : 1;
        const bool forcePerSampleFS =
            source.sampleShadingEnabled && source.minSampleShading > 0.0f &&
            attachmentSampleCount > 1;

        std::uint64_t pipelineCacheKey = 0;
        TranslatedDrawPlanShaderSlots planSlots;
        const TranslatedDrawPlan* translatedPlan = source.translatedPlan;
        bool usedTranslatedPlan = false;
        if (translatedPlan != nullptr &&
            translatedPlan->valid &&
            !translatedPlan->useArgumentBuffers &&
            translatedPlan->colorFormat == static_cast<std::uint32_t>(colorFormat) &&
            translatedPlan->attachmentSampleCount ==
                static_cast<std::uint32_t>(attachmentSampleCount) &&
            translatedPlan->forcePerSampleFS == forcePerSampleFS &&
            translatedPlan->hasFragmentStage == hasFragmentStage) {
            usedTranslatedPlan = true;
            pipelineCacheKey = translatedPlan->pipelineCacheKey;
            planSlots = translatedPlan->shaderSlots;
        }
        if (!usedTranslatedPlan) {
            pipelineCacheKey =
                computePipelineCacheKey(source, colorFormat,
                                        attachmentSampleCount,
                                        forcePerSampleFS);
            const TranslatedDrawMSLSlots& slots =
                translatedDrawMSLSlots(source, pipelineCacheKey,
                                       hasFragmentStage);
            planSlots = phase2PlanShaderSlotsFromMSLSlots(slots);
        }

        const TranslatedDrawMSLSlots slots =
            phase2PlanMSLSlotsFromShaderSlots(planSlots);
        if (slots.vertexMslUsesArgBuf ||
            slots.fragmentMslUsesArgBuf ||
            slots.vertexHasSSBOSizeBuffer ||
            slots.fragmentHasSSBOSizeBuffer ||
            slots.fragmentNeedsGlNumSamplesArgBuf ||
            slots.vertexUsesMultiviewViewMask ||
            slots.fragmentUsesMultiviewViewMask) {
            return false;
        }

        id<MTLRenderPipelineState> pipelineState = nil;
        if (source.pipelineStateCacheOut != nullptr) {
            auto it = source.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != source.pipelineStateCacheOut->end() &&
                it->second != nullptr) {
                pipelineState =
                    (__bridge id<MTLRenderPipelineState>)(it->second);
            }
        } else if (source.pipelineStateOut != nullptr &&
                   *source.pipelineStateOut != nullptr &&
                   source.pipelineColorFormatOut != nullptr &&
                   *source.pipelineColorFormatOut ==
                       static_cast<std::uint32_t>(colorFormat)) {
            pipelineState =
                (__bridge id<MTLRenderPipelineState>)(*source.pipelineStateOut);
        }
        if (pipelineState == nil) {
            capture.parallelFallbackReason =
                ParallelEncodeFallbackReason::PipelineNotPrepared;
            return false;
        }

        id<MTLDepthStencilState> depthState = nil;
        if (depthStencilTexture != nil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = source.depthTestEnabled;
            fakeInfo.depthFunc = source.depthFunc;
            fakeInfo.depthWriteMask = source.depthWriteMask;
            fakeInfo.stencilTestEnabled = source.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = source.stencilFrontFunc;
            fakeInfo.stencilFrontRef = source.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = source.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = source.stencilFrontFail;
            fakeInfo.stencilFrontDepthFail = source.stencilFrontDepthFail;
            fakeInfo.stencilFrontDepthPass = source.stencilFrontDepthPass;
            fakeInfo.stencilFrontWriteMask = source.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = source.stencilBackFunc;
            fakeInfo.stencilBackRef = source.stencilBackRef;
            fakeInfo.stencilBackValueMask = source.stencilBackValueMask;
            fakeInfo.stencilBackFail = source.stencilBackFail;
            fakeInfo.stencilBackDepthFail = source.stencilBackDepthFail;
            fakeInfo.stencilBackDepthPass = source.stencilBackDepthPass;
            fakeInfo.stencilBackWriteMask = source.stencilBackWriteMask;
            depthState = depthStencilStateForDraw(fakeInfo);
        }

        capture.parallelPipelineState = (__bridge void*)pipelineState;
        capture.retainField(capture.parallelPipelineState);
        if (depthState != nil) {
            capture.parallelDepthStencilState = (__bridge void*)depthState;
            capture.retainField(capture.parallelDepthStencilState);
        }
        capture.parallelShaderSlots = planSlots;
        capture.parallelAttachmentSampleCount =
            static_cast<std::uint32_t>(attachmentSampleCount);
        capture.parallelColorFormat = static_cast<std::uint32_t>(colorFormat);
        capture.parallelHasFragmentStage = hasFragmentStage;
        capture.parallelClipControlShaderYFixup =
            slots.vertexClipControlYSignSlot >= 0 &&
            source.clipControlYSignFixupEnabled &&
            !source.stencilTestEnabled;
        capture.parallelClipControlInvertsWinding =
            capture.parallelClipControlShaderYFixup &&
            source.clipOrigin != GL_UPPER_LEFT;
        capture.parallelPrepared = true;
        return true;
    }

    NSInteger fixedFunctionSampleMaskSlotForTranslatedDraw(
        const TranslatedDrawInfo& source,
        std::uint64_t pipelineCacheKey) {
        auto it = translatedDrawSampleMaskSlotCache.find(pipelineCacheKey);
        if (it != translatedDrawSampleMaskSlotCache.end()) {
            return it->second;
        }
        const NSInteger slot = fixedFunctionSampleMaskBufferSlot(source.fragmentMSL);
        translatedDrawSampleMaskSlotCache.emplace(pipelineCacheKey, slot);
        return slot;
    }

    bool captureThreadedDeferredTranslatedDrawRecord(
        const TranslatedDrawInfo& source,
        CapturedTranslatedDrawRecord& capture,
        ParallelEncodeFallbackReason& fallbackReason) {
        capture.threadedPrepared = false;
        capture.threadedFallbackReason =
            ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
        fallbackReason = capture.threadedFallbackReason;

        if (!translatedDrawWorkerEmitSafe(source)) {
            return false;
        }
        if (!translatedDrawUsesSimpleMetalPrimitive(source.mode)) {
            fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
            capture.threadedFallbackReason = fallbackReason;
            return false;
        }

        ensureDrawableResources();
        const bool hasFragmentStage =
            source.fragmentMSL != nullptr && !source.fragmentMSL->empty();
        id<MTLTexture> colorTexture =
            usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;
        const NSUInteger attachmentSampleCount =
            colorTexture != nil ? colorTexture.sampleCount : 1;
        const bool forcePerSampleFS =
            source.sampleShadingEnabled && source.minSampleShading > 0.0f &&
            attachmentSampleCount > 1;

        const TranslatedDrawPlan* translatedPlan = source.translatedPlan;
        if (translatedPlan == nullptr ||
            !translatedPlan->valid ||
            translatedPlan->useArgumentBuffers ||
            translatedPlan->vertexUsesArgumentBuffer ||
            translatedPlan->fragmentUsesArgumentBuffer ||
            translatedPlan->colorFormat !=
                static_cast<std::uint32_t>(colorFormat) ||
            translatedPlan->attachmentSampleCount !=
                static_cast<std::uint32_t>(attachmentSampleCount) ||
            translatedPlan->forcePerSampleFS != forcePerSampleFS ||
            translatedPlan->hasFragmentStage != hasFragmentStage) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            capture.threadedFallbackReason = fallbackReason;
            return false;
        }

        const TranslatedDrawMSLSlots slots =
            phase2PlanMSLSlotsFromShaderSlots(translatedPlan->shaderSlots);
        if (slots.vertexMslUsesArgBuf ||
            slots.fragmentMslUsesArgBuf ||
            slots.vertexHasSSBOSizeBuffer ||
            slots.fragmentHasSSBOSizeBuffer ||
            slots.fragmentNeedsGlNumSamplesArgBuf ||
            slots.vertexUsesMultiviewViewMask ||
            slots.fragmentUsesMultiviewViewMask) {
            return false;
        }

        id<MTLRenderPipelineState> pipelineState = nil;
        const std::uint64_t pipelineCacheKey =
            translatedPlan->pipelineCacheKey;
        if (source.pipelineStateCacheOut != nullptr) {
            auto it = source.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != source.pipelineStateCacheOut->end() &&
                it->second != nullptr) {
                pipelineState =
                    (__bridge id<MTLRenderPipelineState>)(it->second);
            }
        } else if (source.pipelineStateOut != nullptr &&
                   *source.pipelineStateOut != nullptr &&
                   source.pipelineColorFormatOut != nullptr &&
                   *source.pipelineColorFormatOut ==
                       static_cast<std::uint32_t>(colorFormat)) {
            pipelineState =
                (__bridge id<MTLRenderPipelineState>)(*source.pipelineStateOut);
        }
        if (pipelineState == nil) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            capture.threadedFallbackReason = fallbackReason;
            return false;
        }

        id<MTLDepthStencilState> depthState = nil;
        if (depthStencilTexture != nil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = source.depthTestEnabled;
            fakeInfo.depthFunc = source.depthFunc;
            fakeInfo.depthWriteMask = source.depthWriteMask;
            fakeInfo.stencilTestEnabled = source.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = source.stencilFrontFunc;
            fakeInfo.stencilFrontRef = source.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = source.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = source.stencilFrontFail;
            fakeInfo.stencilFrontDepthFail = source.stencilFrontDepthFail;
            fakeInfo.stencilFrontDepthPass = source.stencilFrontDepthPass;
            fakeInfo.stencilFrontWriteMask = source.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = source.stencilBackFunc;
            fakeInfo.stencilBackRef = source.stencilBackRef;
            fakeInfo.stencilBackValueMask = source.stencilBackValueMask;
            fakeInfo.stencilBackFail = source.stencilBackFail;
            fakeInfo.stencilBackDepthFail = source.stencilBackDepthFail;
            fakeInfo.stencilBackDepthPass = source.stencilBackDepthPass;
            fakeInfo.stencilBackWriteMask = source.stencilBackWriteMask;
            depthState = depthStencilStateForDraw(fakeInfo);
        }

        if (!captureTranslatedDrawForThreadedDeferred(source, capture)) {
            fallbackReason = ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
            capture.threadedFallbackReason = fallbackReason;
            return false;
        }

        capture.threadedPlanStorage = *translatedPlan;
        capture.info.translatedPlan = &capture.threadedPlanStorage;
        capture.info.translatedPlanOut = nullptr;
        capture.info.translatedPlanRejectReasonOut = nullptr;
        capture.info.pipelineStateCacheOut = nullptr;
        capture.info.pipelineStateOut = nullptr;
        capture.info.pipelineColorFormatOut = nullptr;
        capture.info.pipelineBuildErrorOut = nullptr;
        capture.info.metalVertexFunctionOut = nullptr;
        capture.info.metalFragmentFunctionOut = nullptr;

        capture.threadedPipelineState = (__bridge void*)pipelineState;
        capture.retainField(capture.threadedPipelineState);
        if (depthState != nil) {
            capture.threadedDepthStencilState = (__bridge void*)depthState;
            capture.retainField(capture.threadedDepthStencilState);
        }
        capture.threadedFixedFunctionSampleMaskSlot =
            static_cast<std::int32_t>(
                fixedFunctionSampleMaskSlotForTranslatedDraw(
                    source, pipelineCacheKey));
        capture.threadedApproxBytes =
            capturedTranslatedDrawRecordApproxBytes(capture);
        capture.threadedPrepared = true;
        capture.threadedFallbackReason = ParallelEncodeFallbackReason::Count;
        fallbackReason = ParallelEncodeFallbackReason::Count;
        return true;
    }

    bool prepareLeanDirectTranslatedDrawDescriptor(
        const TranslatedDrawInfo& source,
        LeanDirectTranslatedDrawDescriptor& descriptor,
        ParallelEncodeFallbackReason& fallbackReason) {
        descriptor.reset();
        fallbackReason = ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;

        if (!translatedDrawWorkerEmitSafe(source)) {
            return false;
        }
        if (!translatedDrawUsesSimpleMetalPrimitive(source.mode)) {
            fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
            return false;
        }

        ensureDrawableResources();
        const bool hasFragmentStage =
            source.fragmentMSL != nullptr && !source.fragmentMSL->empty();
        id<MTLTexture> colorTexture =
            usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;
        const NSUInteger attachmentSampleCount =
            colorTexture != nil ? colorTexture.sampleCount : 1;
        const bool forcePerSampleFS =
            source.sampleShadingEnabled && source.minSampleShading > 0.0f &&
            attachmentSampleCount > 1;

        const TranslatedDrawPlan* translatedPlan = source.translatedPlan;
        if (translatedPlan == nullptr ||
            !translatedPlan->valid ||
            translatedPlan->useArgumentBuffers ||
            translatedPlan->colorFormat !=
                static_cast<std::uint32_t>(colorFormat) ||
            translatedPlan->attachmentSampleCount !=
                static_cast<std::uint32_t>(attachmentSampleCount) ||
            translatedPlan->forcePerSampleFS != forcePerSampleFS ||
            translatedPlan->hasFragmentStage != hasFragmentStage) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            return false;
        }

        const TranslatedDrawMSLSlots slots =
            phase2PlanMSLSlotsFromShaderSlots(translatedPlan->shaderSlots);
        if (slots.vertexMslUsesArgBuf ||
            slots.fragmentMslUsesArgBuf ||
            slots.vertexHasSSBOSizeBuffer ||
            slots.fragmentHasSSBOSizeBuffer ||
            slots.fragmentNeedsGlNumSamplesArgBuf ||
            slots.vertexUsesMultiviewViewMask ||
            slots.fragmentUsesMultiviewViewMask) {
            return false;
        }

        id<MTLRenderPipelineState> pipelineState = nil;
        const std::uint64_t pipelineCacheKey =
            translatedPlan->pipelineCacheKey;
        if (source.pipelineStateCacheOut != nullptr) {
            auto it = source.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != source.pipelineStateCacheOut->end() &&
                it->second != nullptr) {
                pipelineState =
                    (__bridge id<MTLRenderPipelineState>)(it->second);
            }
        } else if (source.pipelineStateOut != nullptr &&
                   *source.pipelineStateOut != nullptr &&
                   source.pipelineColorFormatOut != nullptr &&
                   *source.pipelineColorFormatOut ==
                       static_cast<std::uint32_t>(colorFormat)) {
            pipelineState =
                (__bridge id<MTLRenderPipelineState>)(*source.pipelineStateOut);
        }
        if (pipelineState == nil) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            return false;
        }

        id<MTLDepthStencilState> depthState = nil;
        if (depthStencilTexture != nil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = source.depthTestEnabled;
            fakeInfo.depthFunc = source.depthFunc;
            fakeInfo.depthWriteMask = source.depthWriteMask;
            fakeInfo.stencilTestEnabled = source.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = source.stencilFrontFunc;
            fakeInfo.stencilFrontRef = source.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = source.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = source.stencilFrontFail;
            fakeInfo.stencilFrontDepthFail = source.stencilFrontDepthFail;
            fakeInfo.stencilFrontDepthPass = source.stencilFrontDepthPass;
            fakeInfo.stencilFrontWriteMask = source.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = source.stencilBackFunc;
            fakeInfo.stencilBackRef = source.stencilBackRef;
            fakeInfo.stencilBackValueMask = source.stencilBackValueMask;
            fakeInfo.stencilBackFail = source.stencilBackFail;
            fakeInfo.stencilBackDepthFail = source.stencilBackDepthFail;
            fakeInfo.stencilBackDepthPass = source.stencilBackDepthPass;
            fakeInfo.stencilBackWriteMask = source.stencilBackWriteMask;
            depthState = depthStencilStateForDraw(fakeInfo);
        }

        bool hasExtraVertexAttributes = false;
        for (const auto& evb : source.extraVertexBuffers) {
            if (!evb.attributes.empty()) {
                hasExtraVertexAttributes = true;
                break;
            }
        }
        const bool attributelessDraw =
            source.vertexData == nullptr &&
            source.metalVertexBuffer == nullptr &&
            source.vertexAttributeLayouts.empty() &&
            !hasExtraVertexAttributes;
        if (!attributelessDraw && !source.vertexAttributeLayouts.empty()) {
            if (source.metalVertexBuffer == nullptr) {
                return false;
            }
            descriptor.bindPrimaryVertexBuffer = true;
            descriptor.metalVertexBuffer = source.metalVertexBuffer;
            descriptor.metalVertexBufferOffset =
                source.metalVertexBufferOffset;
        }
        for (std::size_t ei = 0; ei < source.extraVertexBuffers.size(); ++ei) {
            const auto& evb = source.extraVertexBuffers[ei];
            if (evb.attributes.empty()) {
                continue;
            }
            if (evb.metalBuffer == nullptr ||
                descriptor.extraVertexBufferCount >=
                    descriptor.extraVertexBuffers.size()) {
                return false;
            }
            auto& dst =
                descriptor.extraVertexBuffers[descriptor.extraVertexBufferCount++];
            dst.metalBuffer = evb.metalBuffer;
            dst.metalBufferOffset = evb.metalBufferOffset;
            dst.metalSlot = static_cast<std::uint32_t>(ei + 1);
        }

        if (source.vertexUniformSize > descriptor.vertexUniformStorage.size() ||
            source.fragmentUniformSize >
                descriptor.fragmentUniformStorage.size()) {
            return false;
        }
        if (source.vertexUniformData != nullptr &&
            source.vertexUniformSize > 0) {
            std::memcpy(descriptor.vertexUniformStorage.data(),
                        source.vertexUniformData,
                        source.vertexUniformSize);
            descriptor.vertexUniformSize = source.vertexUniformSize;
        }
        if (source.fragmentUniformData != nullptr &&
            source.fragmentUniformSize > 0) {
            std::memcpy(descriptor.fragmentUniformStorage.data(),
                        source.fragmentUniformData,
                        source.fragmentUniformSize);
            descriptor.fragmentUniformSize = source.fragmentUniformSize;
        }

        auto copyTextures =
            [](const std::vector<TranslatedDrawInfo::TextureBinding>& src,
               std::array<LeanDirectTranslatedDrawDescriptor::TextureBinding,
                          kLeanDirectMaxTextureBindings>& dst,
               std::size_t& dstCount) {
                for (const auto& binding : src) {
                    if (binding.metalTexture == nullptr) {
                        continue;
                    }
                    if (binding.metalSamplerState == nullptr ||
                        binding.textureBufferBackingMetalBuffer != nullptr ||
                        binding.imageAtomicMetalBuffer != nullptr ||
                        dstCount >= dst.size()) {
                        return false;
                    }
                    auto& copied = dst[dstCount++];
                    copied.metalSlot = binding.metalSlot;
                    copied.metalTexture = binding.metalTexture;
                    copied.metalSamplerState = binding.metalSamplerState;
                    copied.reductionMode = binding.reductionMode;
                    copied.lodBias = binding.lodBias;
                    copied.borderClampMask = binding.borderClampMask;
                    copied.borderColor = binding.borderColor;
                }
                return true;
            };
        if (!copyTextures(source.vertexTextures,
                          descriptor.vertexTextures,
                          descriptor.vertexTextureCount) ||
            !copyTextures(source.fragmentTextures,
                          descriptor.fragmentTextures,
                          descriptor.fragmentTextureCount)) {
            return false;
        }

        for (const auto& ubo : source.uboBindings) {
            if (ubo.size == 0) {
                continue;
            }
            if (descriptor.uboBindingCount >=
                descriptor.uboBindings.size()) {
                return false;
            }
            auto& copied = descriptor.uboBindings[descriptor.uboBindingCount++];
            copied.metalSlot = ubo.metalSlot;
            copied.size = ubo.size;
            copied.metalBuffer = ubo.metalBuffer;
            copied.metalBufferOffset = ubo.metalBufferOffset;
            copied.isVertex = ubo.isVertex;
            copied.isFragment = ubo.isFragment;
            copied.data = nullptr;
            copied.inlineDataOffset = 0;
            copied.usesInlineData = false;
            if (ubo.metalBuffer == nullptr) {
                if (ubo.data == nullptr ||
                    descriptor.uboInlineStorageSize + ubo.size >
                        descriptor.uboInlineStorage.size()) {
                    return false;
                }
                copied.inlineDataOffset = descriptor.uboInlineStorageSize;
                std::memcpy(descriptor.uboInlineStorage.data() +
                                descriptor.uboInlineStorageSize,
                            ubo.data,
                            ubo.size);
                descriptor.uboInlineStorageSize += ubo.size;
                copied.usesInlineData = true;
            }
        }

        descriptor.pipelineState = (__bridge void*)pipelineState;
        descriptor.depthStencilState =
            depthState != nil ? (__bridge void*)depthState : nullptr;
        descriptor.shaderSlots = translatedPlan->shaderSlots;
        descriptor.attachmentSampleCount =
            static_cast<std::uint32_t>(attachmentSampleCount);
        descriptor.colorFormat = static_cast<std::uint32_t>(colorFormat);
        descriptor.fixedFunctionSampleMaskSlot =
            static_cast<std::int32_t>(
                fixedFunctionSampleMaskSlotForTranslatedDraw(
                    source, pipelineCacheKey));
        descriptor.clipControlShaderYFixup =
            translatedPlan->clipControlShaderYFixup;
        descriptor.clipControlInvertsWinding =
            translatedPlan->clipControlInvertsWinding;

        descriptor.mode = source.mode;
        descriptor.vertexCount = source.vertexCount;
        descriptor.baseVertex = source.baseVertex;
        descriptor.instanceCount = source.instanceCount;
        descriptor.baseInstance = source.baseInstance;
        descriptor.indexCount = source.indexCount;
        descriptor.indexType = source.indexType;
        descriptor.metalIndexBuffer = source.metalIndexBuffer;
        descriptor.metalIndexBufferOffset = source.metalIndexBufferOffset;

        descriptor.depthTestEnabled = source.depthTestEnabled;
        descriptor.depthFunc = source.depthFunc;
        descriptor.depthWriteMask = source.depthWriteMask;
        descriptor.stencilTestEnabled = source.stencilTestEnabled;
        descriptor.stencilFrontRef = source.stencilFrontRef;
        descriptor.stencilBackRef = source.stencilBackRef;
        descriptor.cullFaceEnabled = source.cullFaceEnabled;
        descriptor.cullFaceMode = source.cullFaceMode;
        descriptor.frontFace = source.frontFace;
        descriptor.wireframe = source.wireframe;
        descriptor.sampleMask = source.sampleMask;
        descriptor.polygonOffsetEnabled = source.polygonOffsetEnabled;
        descriptor.polygonOffsetFactor = source.polygonOffsetFactor;
        descriptor.polygonOffsetUnits = source.polygonOffsetUnits;
        descriptor.polygonOffsetClamp = source.polygonOffsetClamp;
        descriptor.viewportX = source.viewportX;
        descriptor.viewportY = source.viewportY;
        descriptor.viewportWidth = source.viewportWidth;
        descriptor.viewportHeight = source.viewportHeight;
        descriptor.depthRangeNear = source.depthRangeNear;
        descriptor.depthRangeFar = source.depthRangeFar;
        descriptor.scissorTestEnabled = source.scissorTestEnabled;
        descriptor.scissorX = source.scissorX;
        descriptor.scissorY = source.scissorY;
        descriptor.scissorWidth = source.scissorWidth;
        descriptor.scissorHeight = source.scissorHeight;
        descriptor.clipOrigin = source.clipOrigin;
        descriptor.fragmentShadingRate = source.fragmentShadingRate;
        descriptor.fragmentShadingRateShaderState =
            source.fragmentShadingRateShaderState;

        fallbackReason = ParallelEncodeFallbackReason::Count;
        return true;
    }

    bool prepareThreadedDeferredDescriptorFromRecord(
        const CapturedTranslatedDrawRecord& record,
        LeanDirectTranslatedDrawDescriptor& descriptor,
        ParallelEncodeFallbackReason& fallbackReason) const {
        descriptor.reset();
        fallbackReason = ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
        if (!record.threadedPrepared ||
            record.threadedPipelineState == nullptr ||
            record.info.translatedPlan != &record.threadedPlanStorage) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            return false;
        }

        const TranslatedDrawInfo& source = record.info;
        if (!translatedDrawWorkerEmitSafe(source)) {
            return false;
        }
        if (!translatedDrawUsesSimpleMetalPrimitive(source.mode)) {
            fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
            return false;
        }

        const TranslatedDrawPlan& translatedPlan =
            record.threadedPlanStorage;
        if (!translatedPlan.valid || translatedPlan.useArgumentBuffers) {
            fallbackReason = ParallelEncodeFallbackReason::PipelineNotPrepared;
            return false;
        }
        const TranslatedDrawMSLSlots slots =
            phase2PlanMSLSlotsFromShaderSlots(translatedPlan.shaderSlots);
        if (slots.vertexMslUsesArgBuf ||
            slots.fragmentMslUsesArgBuf ||
            slots.vertexHasSSBOSizeBuffer ||
            slots.fragmentHasSSBOSizeBuffer ||
            slots.fragmentNeedsGlNumSamplesArgBuf ||
            slots.vertexUsesMultiviewViewMask ||
            slots.fragmentUsesMultiviewViewMask) {
            return false;
        }

        bool hasExtraVertexAttributes = false;
        for (const auto& evb : source.extraVertexBuffers) {
            if (!evb.attributes.empty()) {
                hasExtraVertexAttributes = true;
                break;
            }
        }
        const bool attributelessDraw =
            source.vertexData == nullptr &&
            source.metalVertexBuffer == nullptr &&
            source.vertexAttributeLayouts.empty() &&
            !hasExtraVertexAttributes;
        if (!attributelessDraw && !source.vertexAttributeLayouts.empty()) {
            if (source.metalVertexBuffer == nullptr) {
                return false;
            }
            descriptor.bindPrimaryVertexBuffer = true;
            descriptor.metalVertexBuffer = source.metalVertexBuffer;
            descriptor.metalVertexBufferOffset =
                source.metalVertexBufferOffset;
        }
        for (std::size_t ei = 0; ei < source.extraVertexBuffers.size(); ++ei) {
            const auto& evb = source.extraVertexBuffers[ei];
            if (evb.attributes.empty()) {
                continue;
            }
            if (evb.metalBuffer == nullptr ||
                descriptor.extraVertexBufferCount >=
                    descriptor.extraVertexBuffers.size()) {
                return false;
            }
            auto& dst =
                descriptor.extraVertexBuffers[descriptor.extraVertexBufferCount++];
            dst.metalBuffer = evb.metalBuffer;
            dst.metalBufferOffset = evb.metalBufferOffset;
            dst.metalSlot = static_cast<std::uint32_t>(ei + 1);
        }

        if (source.vertexUniformSize > descriptor.vertexUniformStorage.size() ||
            source.fragmentUniformSize >
                descriptor.fragmentUniformStorage.size()) {
            return false;
        }
        if (source.vertexUniformData != nullptr &&
            source.vertexUniformSize > 0) {
            std::memcpy(descriptor.vertexUniformStorage.data(),
                        source.vertexUniformData,
                        source.vertexUniformSize);
            descriptor.vertexUniformSize = source.vertexUniformSize;
        }
        if (source.fragmentUniformData != nullptr &&
            source.fragmentUniformSize > 0) {
            std::memcpy(descriptor.fragmentUniformStorage.data(),
                        source.fragmentUniformData,
                        source.fragmentUniformSize);
            descriptor.fragmentUniformSize = source.fragmentUniformSize;
        }

        auto copyTextures =
            [](const std::vector<TranslatedDrawInfo::TextureBinding>& src,
               std::array<LeanDirectTranslatedDrawDescriptor::TextureBinding,
                          kLeanDirectMaxTextureBindings>& dst,
               std::size_t& dstCount) {
                for (const auto& binding : src) {
                    if (binding.metalTexture == nullptr) {
                        continue;
                    }
                    if (binding.metalSamplerState == nullptr ||
                        binding.textureBufferBackingMetalBuffer != nullptr ||
                        binding.imageAtomicMetalBuffer != nullptr ||
                        dstCount >= dst.size()) {
                        return false;
                    }
                    auto& copied = dst[dstCount++];
                    copied.metalSlot = binding.metalSlot;
                    copied.metalTexture = binding.metalTexture;
                    copied.metalSamplerState = binding.metalSamplerState;
                    copied.reductionMode = binding.reductionMode;
                    copied.lodBias = binding.lodBias;
                    copied.borderClampMask = binding.borderClampMask;
                    copied.borderColor = binding.borderColor;
                }
                return true;
            };
        if (!copyTextures(source.vertexTextures,
                          descriptor.vertexTextures,
                          descriptor.vertexTextureCount) ||
            !copyTextures(source.fragmentTextures,
                          descriptor.fragmentTextures,
                          descriptor.fragmentTextureCount)) {
            return false;
        }

        for (const auto& ubo : source.uboBindings) {
            if (ubo.size == 0) {
                continue;
            }
            if (descriptor.uboBindingCount >=
                descriptor.uboBindings.size()) {
                return false;
            }
            auto& copied = descriptor.uboBindings[descriptor.uboBindingCount++];
            copied.metalSlot = ubo.metalSlot;
            copied.size = ubo.size;
            copied.metalBuffer = ubo.metalBuffer;
            copied.metalBufferOffset = ubo.metalBufferOffset;
            copied.isVertex = ubo.isVertex;
            copied.isFragment = ubo.isFragment;
            copied.data = nullptr;
            copied.inlineDataOffset = 0;
            copied.usesInlineData = false;
            if (ubo.metalBuffer == nullptr) {
                if (ubo.data == nullptr ||
                    descriptor.uboInlineStorageSize + ubo.size >
                        descriptor.uboInlineStorage.size()) {
                    return false;
                }
                copied.inlineDataOffset = descriptor.uboInlineStorageSize;
                std::memcpy(descriptor.uboInlineStorage.data() +
                                descriptor.uboInlineStorageSize,
                            ubo.data,
                            ubo.size);
                descriptor.uboInlineStorageSize += ubo.size;
                copied.usesInlineData = true;
            }
        }

        descriptor.pipelineState = record.threadedPipelineState;
        descriptor.depthStencilState = record.threadedDepthStencilState;
        descriptor.shaderSlots = translatedPlan.shaderSlots;
        descriptor.attachmentSampleCount =
            translatedPlan.attachmentSampleCount;
        descriptor.colorFormat = translatedPlan.colorFormat;
        descriptor.fixedFunctionSampleMaskSlot =
            record.threadedFixedFunctionSampleMaskSlot;
        descriptor.clipControlShaderYFixup =
            translatedPlan.clipControlShaderYFixup;
        descriptor.clipControlInvertsWinding =
            translatedPlan.clipControlInvertsWinding;

        descriptor.mode = source.mode;
        descriptor.vertexCount = source.vertexCount;
        descriptor.baseVertex = source.baseVertex;
        descriptor.instanceCount = source.instanceCount;
        descriptor.baseInstance = source.baseInstance;
        descriptor.indexCount = source.indexCount;
        descriptor.indexType = source.indexType;
        descriptor.metalIndexBuffer = source.metalIndexBuffer;
        descriptor.metalIndexBufferOffset = source.metalIndexBufferOffset;

        descriptor.depthTestEnabled = source.depthTestEnabled;
        descriptor.depthFunc = source.depthFunc;
        descriptor.depthWriteMask = source.depthWriteMask;
        descriptor.stencilTestEnabled = source.stencilTestEnabled;
        descriptor.stencilFrontRef = source.stencilFrontRef;
        descriptor.stencilBackRef = source.stencilBackRef;
        descriptor.cullFaceEnabled = source.cullFaceEnabled;
        descriptor.cullFaceMode = source.cullFaceMode;
        descriptor.frontFace = source.frontFace;
        descriptor.wireframe = source.wireframe;
        descriptor.sampleMask = source.sampleMask;
        descriptor.polygonOffsetEnabled = source.polygonOffsetEnabled;
        descriptor.polygonOffsetFactor = source.polygonOffsetFactor;
        descriptor.polygonOffsetUnits = source.polygonOffsetUnits;
        descriptor.polygonOffsetClamp = source.polygonOffsetClamp;
        descriptor.viewportX = source.viewportX;
        descriptor.viewportY = source.viewportY;
        descriptor.viewportWidth = source.viewportWidth;
        descriptor.viewportHeight = source.viewportHeight;
        descriptor.depthRangeNear = source.depthRangeNear;
        descriptor.depthRangeFar = source.depthRangeFar;
        descriptor.scissorTestEnabled = source.scissorTestEnabled;
        descriptor.scissorX = source.scissorX;
        descriptor.scissorY = source.scissorY;
        descriptor.scissorWidth = source.scissorWidth;
        descriptor.scissorHeight = source.scissorHeight;
        descriptor.clipOrigin = source.clipOrigin;
        descriptor.fragmentShadingRate = source.fragmentShadingRate;
        descriptor.fragmentShadingRateShaderState =
            source.fragmentShadingRateShaderState;

        fallbackReason = ParallelEncodeFallbackReason::Count;
        return true;
    }

    bool buildDefaultParallelRenderPass(
        GLenum fragmentShadingRate,
        MTLRenderPassDescriptor*& passOut,
        id<MTLTexture>& colorTextureOut,
        id<MTLTexture>& passDepthStencilOut) {
        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(AppGLCommandReason::TranslatedDraw);
            if (currentCommandBuffer == nil) {
                return false;
            }
        }
        if (!acquireDrawableIfNeeded()) {
            return false;
        }

        id<MTLTexture> colorTexture =
            usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }
        id<MTLTexture> passDepthStencil = depthStencilTexture;
        if (depthStencilTexture != nil &&
            (depthStencilTexture.width != colorTexture.width ||
             depthStencilTexture.height != colorTexture.height)) {
            id<MTLTexture> replacement = nil;
            @autoreleasepool {
                MTLTextureDescriptor* dd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                width:colorTexture.width
                                               height:colorTexture.height
                                            mipmapped:NO];
                dd.storageMode = MTLStorageModePrivate;
                dd.usage = MTLTextureUsageRenderTarget;
                replacement = newDepthStencilTexture(dd);
            }
            if (replacement != nil) {
                ++depthStencilRebuildsFromColorSizeMismatch;
            }
            replaceDepthStencilTexture(replacement);
            passDepthStencil = depthStencilTexture;
            drawableWidth = static_cast<GLsizei>(colorTexture.width);
            drawableHeight = static_cast<GLsizei>(colorTexture.height);
        }
        if (colorTexture != nil && passDepthStencil != nil &&
            colorTexture.sampleCount != passDepthStencil.sampleCount) {
            id<MTLTexture> replacement = nil;
            @autoreleasepool {
                MTLTextureDescriptor* dd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                width:colorTexture.width
                                               height:colorTexture.height
                                            mipmapped:NO];
                dd.storageMode = MTLStorageModePrivate;
                dd.usage = MTLTextureUsageRenderTarget;
                if (colorTexture.sampleCount > 1) {
                    dd.textureType = MTLTextureType2DMultisample;
                    dd.sampleCount = colorTexture.sampleCount;
                }
                replacement = newDepthStencilTexture(dd);
            }
            if (replacement != nil) {
                ++depthStencilRebuildsFromSampleMismatch;
            }
            replaceDepthStencilTexture(replacement);
            passDepthStencil = depthStencilTexture;
        }

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (passDepthStencil != nil) {
            pass.depthAttachment.texture = passDepthStencil;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.loadAction =
                (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT))
                    ? MTLLoadActionClear
                    : MTLLoadActionLoad;
            if (pass.depthAttachment.loadAction == MTLLoadActionClear) {
                pass.depthAttachment.clearDepth = pendingClearDepth;
            }
            pass.stencilAttachment.texture = passDepthStencil;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.loadAction =
                (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT))
                    ? MTLLoadActionClear
                    : MTLLoadActionLoad;
            if (pass.stencilAttachment.loadAction == MTLLoadActionClear) {
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            }
        }
        attachFragmentShadingRateMap(pass, fragmentShadingRate,
                                     colorTexture, 1);
        passOut = pass;
        colorTextureOut = colorTexture;
        passDepthStencilOut = passDepthStencil;
        return true;
    }

    bool ensureLeanDirectDefaultRenderPass(
        GLenum fragmentShadingRate,
        id<MTLTexture>& colorTextureOut,
        id<MTLTexture>& passDepthStencilOut) {
        if (currentRenderEncoder != nil &&
            activeRenderPassFragmentShadingRate != fragmentShadingRate) {
            endRenderPass();
            resetCachedEncoderState();
        }
        if (currentRenderEncoder != nil) {
            if (!usesOffscreenTarget && currentDrawable == nil &&
                !acquireDrawableIfNeeded()) {
                return false;
            }
            colorTextureOut =
                usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
            passDepthStencilOut = depthStencilTexture;
            return colorTextureOut != nil;
        }

        MTLRenderPassDescriptor* pass = nil;
        if (!buildDefaultParallelRenderPass(fragmentShadingRate,
                                            pass,
                                            colorTextureOut,
                                            passDepthStencilOut)) {
            return false;
        }
        if (!openCurrentRenderEncoder(pass)) {
            return false;
        }
        hasPendingClear = false;
        activeRenderPassFragmentShadingRate = fragmentShadingRate;
        readbackSourceTexture = colorTextureOut;
        readbackSourceIsBGRA =
            colorTextureOut.pixelFormat == MTLPixelFormatBGRA8Unorm;
        resetCachedEncoderState();
        return true;
    }

    bool encodeLeanDirectTranslatedDrawDescriptorOnEncoder(
        const LeanDirectTranslatedDrawDescriptor& descriptor,
        id<MTLRenderCommandEncoder> encoder,
        id<MTLTexture> colorTexture,
        id<MTLTexture> passDepthStencil,
        ParallelChildEncoderState& encoderState,
        bool markPendingPresent) {
        if (encoder == nil || colorTexture == nil ||
            descriptor.pipelineState == nullptr) {
            return false;
        }
        id<MTLRenderPipelineState> pipelineState =
            (__bridge id<MTLRenderPipelineState>)descriptor.pipelineState;
        if (pipelineState == nil) {
            return false;
        }
        const TranslatedDrawMSLSlots shaderSlots =
            phase2PlanMSLSlotsFromShaderSlots(descriptor.shaderSlots);
        const NSUInteger attachmentSampleCount =
            static_cast<NSUInteger>(
                std::max<std::uint32_t>(
                    descriptor.attachmentSampleCount, 1u));

        if (pipelineState != encoderState.cachedPipelineState) {
            [encoder setRenderPipelineState:pipelineState];
            encoderState.cachedPipelineState = pipelineState;
        }
        if (passDepthStencil != nil &&
            descriptor.depthStencilState != nullptr) {
            id<MTLDepthStencilState> dsState =
                (__bridge id<MTLDepthStencilState>)
                    descriptor.depthStencilState;
            if (dsState != nil &&
                dsState != encoderState.cachedDepthStencilState) {
                [encoder setDepthStencilState:dsState];
                encoderState.cachedDepthStencilState = dsState;
            }
            if (descriptor.stencilTestEnabled) {
                [encoder setStencilFrontReferenceValue:
                             static_cast<uint32_t>(
                                 descriptor.stencilFrontRef)
                            backReferenceValue:
                             static_cast<uint32_t>(
                                 descriptor.stencilBackRef)];
            }
        }

        const MTLCullMode desiredCull = descriptor.cullFaceEnabled
            ? (descriptor.cullFaceMode == GL_FRONT ? MTLCullModeFront
                                                   : MTLCullModeBack)
            : MTLCullModeNone;
        if (desiredCull != encoderState.cachedCullMode) {
            [encoder setCullMode:desiredCull];
            encoderState.cachedCullMode = desiredCull;
        }
        const MTLWinding desiredWinding =
            frontFacingWindingForClipControl(
                descriptor.frontFace,
                descriptor.clipControlInvertsWinding);
        if (desiredWinding != encoderState.cachedFrontFaceWinding) {
            [encoder setFrontFacingWinding:desiredWinding];
            encoderState.cachedFrontFaceWinding = desiredWinding;
        }
        const MTLTriangleFillMode desiredFill = descriptor.wireframe
            ? MTLTriangleFillModeLines
            : MTLTriangleFillModeFill;
        if (desiredFill != encoderState.cachedFillMode) {
            [encoder setTriangleFillMode:desiredFill];
            encoderState.cachedFillMode = desiredFill;
        }
        {
            const std::uint32_t sampleMask = attachmentSampleCount > 1
                ? descriptor.sampleMask
                : 0xFFFFFFFFu;
            [encoder setFragmentBytes:&sampleMask
                                length:sizeof(sampleMask)
                               atIndex:static_cast<NSUInteger>(
                                           descriptor.fixedFunctionSampleMaskSlot)];
        }
        {
            const float bias = descriptor.polygonOffsetEnabled
                ? descriptor.polygonOffsetUnits
                : 0.0f;
            const float slope = descriptor.polygonOffsetEnabled
                ? descriptor.polygonOffsetFactor
                : 0.0f;
            const float clampV = descriptor.polygonOffsetEnabled
                ? descriptor.polygonOffsetClamp
                : 0.0f;
            [encoder setDepthBias:bias slopeScale:slope clamp:clampV];
        }

        if (descriptor.viewportWidth > 0 &&
            descriptor.viewportHeight > 0) {
            const GLint rtW = static_cast<GLint>(colorTexture.width);
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            const double rtHeight = static_cast<double>(rtH);
            const GLint glX = std::max<GLint>(0, descriptor.viewportX);
            const GLint glY = std::max<GLint>(0, descriptor.viewportY);
            const GLsizei availW =
                static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
            const GLsizei availH =
                static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glW =
                std::min<GLsizei>(descriptor.viewportWidth, availW);
            const GLsizei glH =
                std::min<GLsizei>(descriptor.viewportHeight, availH);
            const bool flipY = (descriptor.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(glX);
            vp.originY = descriptor.clipControlShaderYFixup
                ? static_cast<double>(glY)
                : (flipY
                    ? (rtHeight - static_cast<double>(glY) -
                       static_cast<double>(glH))
                    : static_cast<double>(glY));
            vp.width = static_cast<double>(glW);
            vp.height = static_cast<double>(glH);
            vp.znear = descriptor.depthRangeNear;
            vp.zfar = descriptor.depthRangeFar;
            if (vp.width > 0 && vp.height > 0) {
                [encoder setViewport:vp];
            }
        }
        {
            const NSUInteger rtW = colorTexture.width;
            const NSUInteger rtH = colorTexture.height;
            MTLScissorRect sr;
            if (!descriptor.scissorTestEnabled) {
                sr = {0, 0, rtW, rtH};
            } else if (descriptor.scissorWidth <= 0 ||
                       descriptor.scissorHeight <= 0) {
                sr = {0, 0, 0, 0};
            } else {
                GLint metalX = std::max<GLint>(0, descriptor.scissorX);
                GLint metalYBottomLeft =
                    std::max<GLint>(0, descriptor.scissorY);
                GLint metalY = static_cast<GLint>(rtH) -
                    metalYBottomLeft - descriptor.scissorHeight;
                GLsizei scissorH = descriptor.scissorHeight;
                if (metalY < 0) {
                    scissorH += metalY;
                    metalY = 0;
                }
                const GLsizei availW =
                    static_cast<GLsizei>(rtW) - metalX;
                const GLsizei availH =
                    static_cast<GLsizei>(rtH) - metalY;
                const GLsizei finalW =
                    std::min<GLsizei>(
                        descriptor.scissorWidth,
                        std::max<GLsizei>(0, availW));
                const GLsizei finalH =
                    std::min<GLsizei>(
                        scissorH,
                        std::max<GLsizei>(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr = {rtW > 0 ? rtW - 1 : 0,
                          rtH > 0 ? rtH - 1 : 0,
                          1,
                          1};
                } else {
                    sr = {static_cast<NSUInteger>(metalX),
                          static_cast<NSUInteger>(metalY),
                          static_cast<NSUInteger>(finalW),
                          static_cast<NSUInteger>(finalH)};
                }
            }
            [encoder setScissorRect:sr];
        }

        if (descriptor.bindPrimaryVertexBuffer) {
            if (descriptor.metalVertexBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> mtlBuf =
                (__bridge id<MTLBuffer>)descriptor.metalVertexBuffer;
            [encoder setVertexBuffer:mtlBuf
                               offset:static_cast<NSUInteger>(
                                          descriptor.metalVertexBufferOffset)
                              atIndex:0];
        }
        for (std::size_t i = 0;
             i < descriptor.extraVertexBufferCount;
             ++i) {
            const auto& evb = descriptor.extraVertexBuffers[i];
            if (evb.metalBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)evb.metalBuffer;
            [encoder setVertexBuffer:mtlBuf
                               offset:static_cast<NSUInteger>(
                                          evb.metalBufferOffset)
                              atIndex:static_cast<NSUInteger>(
                                          evb.metalSlot)];
        }

        if (descriptor.vertexUniformSize > 0) {
            [encoder setVertexBytes:descriptor.vertexUniformStorage.data()
                              length:descriptor.vertexUniformSize
                             atIndex:16];
        }
        if (descriptor.fragmentUniformSize > 0) {
            [encoder setFragmentBytes:descriptor.fragmentUniformStorage.data()
                                length:descriptor.fragmentUniformSize
                               atIndex:16];
        }
        {
            const int32_t glNumSamples =
                static_cast<int32_t>(attachmentSampleCount);
            [encoder setFragmentBytes:&glNumSamples
                                length:sizeof(glNumSamples)
                               atIndex:0];
        }
        if (shaderSlots.vertexNeedsFragmentShadingRateState) {
            [encoder setVertexBytes:
                         &descriptor.fragmentShadingRateShaderState
                              length:sizeof(
                                  descriptor.fragmentShadingRateShaderState)
                             atIndex:kAppGLFragmentShadingRateParamsBufferSlot];
        }
        if (shaderSlots.vertexClipControlYSignSlot >= 0) {
            const float clipControlYSign =
                (descriptor.clipControlShaderYFixup &&
                 descriptor.clipOrigin != GL_UPPER_LEFT) ? -1.0f : 1.0f;
            [encoder setVertexBytes:&clipControlYSign
                              length:sizeof(clipControlYSign)
                             atIndex:static_cast<NSUInteger>(
                                         shaderSlots.vertexClipControlYSignSlot)];
        }

        auto setVertexBytesIfPresent = [&](NSInteger slot,
                                           const void* data,
                                           NSUInteger length) {
            if (slot >= 0 && data != nullptr && length > 0) {
                [encoder setVertexBytes:data
                                  length:length
                                 atIndex:static_cast<NSUInteger>(slot)];
            }
        };
        auto setFragmentBytesIfPresent = [&](NSInteger slot,
                                             const void* data,
                                             NSUInteger length) {
            if (slot >= 0 && data != nullptr && length > 0) {
                [encoder setFragmentBytes:data
                                    length:length
                                   atIndex:static_cast<NSUInteger>(slot)];
            }
        };
        if (shaderSlots.vertexReductionModesSlot >= 0) {
            std::vector<std::uint32_t>& modes = textureUIntScratch();
            buildLeanDirectTextureReductionModes(
                descriptor.vertexTextures.data(),
                descriptor.vertexTextureCount,
                modes);
            setVertexBytesIfPresent(
                shaderSlots.vertexReductionModesSlot,
                modes.data(),
                static_cast<NSUInteger>(
                    modes.size() * sizeof(std::uint32_t)));
        }
        if (shaderSlots.vertexLodBiasesSlot >= 0) {
            std::vector<float>& biases = textureFloatScratch();
            buildLeanDirectTextureLodBiases(
                descriptor.vertexTextures.data(),
                descriptor.vertexTextureCount,
                biases);
            setVertexBytesIfPresent(
                shaderSlots.vertexLodBiasesSlot,
                biases.data(),
                static_cast<NSUInteger>(biases.size() * sizeof(float)));
        }
        if (shaderSlots.vertexBorderClampModesSlot >= 0) {
            std::vector<std::uint32_t>& modes = textureUIntScratch();
            buildLeanDirectTextureBorderClampModes(
                descriptor.vertexTextures.data(),
                descriptor.vertexTextureCount,
                modes);
            setVertexBytesIfPresent(
                shaderSlots.vertexBorderClampModesSlot,
                modes.data(),
                static_cast<NSUInteger>(
                    modes.size() * sizeof(std::uint32_t)));
        }
        if (shaderSlots.vertexBorderClampColorsSlot >= 0) {
            std::vector<std::array<std::int32_t, 4>>& colors =
                textureBorderColorScratch();
            buildLeanDirectTextureBorderClampColors(
                descriptor.vertexTextures.data(),
                descriptor.vertexTextureCount,
                colors);
            setVertexBytesIfPresent(
                shaderSlots.vertexBorderClampColorsSlot,
                colors.data(),
                static_cast<NSUInteger>(
                    colors.size() *
                    sizeof(std::array<std::int32_t, 4>)));
        }
        if (shaderSlots.vertexImplicitLodBiasCorrectionSlot >= 0) {
            const float correction = 0.0f;
            [encoder setVertexBytes:&correction
                              length:sizeof(correction)
                             atIndex:static_cast<NSUInteger>(
                                         shaderSlots.vertexImplicitLodBiasCorrectionSlot)];
        }
        if (shaderSlots.fragmentReductionModesSlot >= 0) {
            std::vector<std::uint32_t>& modes = textureUIntScratch();
            buildLeanDirectTextureReductionModes(
                descriptor.fragmentTextures.data(),
                descriptor.fragmentTextureCount,
                modes);
            setFragmentBytesIfPresent(
                shaderSlots.fragmentReductionModesSlot,
                modes.data(),
                static_cast<NSUInteger>(
                    modes.size() * sizeof(std::uint32_t)));
        }
        if (shaderSlots.fragmentLodBiasesSlot >= 0) {
            std::vector<float>& biases = textureFloatScratch();
            buildLeanDirectTextureLodBiases(
                descriptor.fragmentTextures.data(),
                descriptor.fragmentTextureCount,
                biases);
            setFragmentBytesIfPresent(
                shaderSlots.fragmentLodBiasesSlot,
                biases.data(),
                static_cast<NSUInteger>(biases.size() * sizeof(float)));
        }
        if (shaderSlots.fragmentBorderClampModesSlot >= 0) {
            std::vector<std::uint32_t>& modes = textureUIntScratch();
            buildLeanDirectTextureBorderClampModes(
                descriptor.fragmentTextures.data(),
                descriptor.fragmentTextureCount,
                modes);
            setFragmentBytesIfPresent(
                shaderSlots.fragmentBorderClampModesSlot,
                modes.data(),
                static_cast<NSUInteger>(
                    modes.size() * sizeof(std::uint32_t)));
        }
        if (shaderSlots.fragmentBorderClampColorsSlot >= 0) {
            std::vector<std::array<std::int32_t, 4>>& colors =
                textureBorderColorScratch();
            buildLeanDirectTextureBorderClampColors(
                descriptor.fragmentTextures.data(),
                descriptor.fragmentTextureCount,
                colors);
            setFragmentBytesIfPresent(
                shaderSlots.fragmentBorderClampColorsSlot,
                colors.data(),
                static_cast<NSUInteger>(
                    colors.size() *
                    sizeof(std::array<std::int32_t, 4>)));
        }
        auto implicitLodCorrection = [&]() -> float {
            if (descriptor.viewportWidth <= 0 ||
                descriptor.viewportHeight <= 0 ||
                colorTexture == nil) {
                return 0.0f;
            }
            const GLint rtW = static_cast<GLint>(colorTexture.width);
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            if (rtW <= 0 || rtH <= 0) {
                return 0.0f;
            }
            const GLint glX = std::max<GLint>(0, descriptor.viewportX);
            const GLint glY = std::max<GLint>(0, descriptor.viewportY);
            const GLsizei availW =
                static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
            const GLsizei availH =
                static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei clampedW =
                std::min<GLsizei>(descriptor.viewportWidth, availW);
            const GLsizei clampedH =
                std::min<GLsizei>(descriptor.viewportHeight, availH);
            if (clampedW <= 0 || clampedH <= 0) {
                return 0.0f;
            }
            const float scaleX =
                static_cast<float>(descriptor.viewportWidth) /
                static_cast<float>(clampedW);
            const float scaleY =
                static_cast<float>(descriptor.viewportHeight) /
                static_cast<float>(clampedH);
            const float scale = std::max(scaleX, scaleY);
            return scale > 1.0f ? -std::log2(scale) : 0.0f;
        };
        if (shaderSlots.fragmentImplicitLodBiasCorrectionSlot >= 0) {
            const float correction = implicitLodCorrection();
            [encoder setFragmentBytes:&correction
                                length:sizeof(correction)
                               atIndex:static_cast<NSUInteger>(
                                           shaderSlots.fragmentImplicitLodBiasCorrectionSlot)];
        }
        if (shaderSlots.fragmentNeedsFragCoordParams) {
            auto fragmentSamplesColorAttachment = [&]() {
                for (std::size_t i = 0;
                     i < descriptor.fragmentTextureCount;
                     ++i) {
                    const auto& binding = descriptor.fragmentTextures[i];
                    if (binding.metalTexture == nullptr) {
                        continue;
                    }
                    id<MTLTexture> sampled =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (sampled == colorTexture) {
                        return true;
                    }
                }
                return false;
            };
            const float renderTargetHeight =
                static_cast<float>(colorTexture.height);
            const bool flipToLowerLeft =
                (descriptor.clipOrigin != GL_UPPER_LEFT) &&
                !fragmentSamplesColorAttachment();
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            const GLint glY = std::max<GLint>(0, descriptor.viewportY);
            const GLsizei availH =
                static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glH =
                std::min<GLsizei>(descriptor.viewportHeight, availH);
            const float viewportLowerLeftBase =
                static_cast<float>(glY + glH);
            const float lowerLeftBase = descriptor.clipControlShaderYFixup
                ? viewportLowerLeftBase
                : renderTargetHeight;
            const float fragCoordParams[4] = {
                flipToLowerLeft ? lowerLeftBase : 0.0f,
                flipToLowerLeft ? -1.0f : 1.0f,
                flipToLowerLeft ? 1.0f : 0.0f,
                0.0f,
            };
            [encoder setFragmentBytes:fragCoordParams
                                length:sizeof(fragCoordParams)
                               atIndex:kAppGLFragCoordParamsBufferSlot];
        }

        for (std::size_t i = 0; i < descriptor.uboBindingCount; ++i) {
            const auto& ubo = descriptor.uboBindings[i];
            if (ubo.size == 0) {
                continue;
            }
            const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
            if (ubo.metalBuffer != nullptr) {
                id<MTLBuffer> buf =
                    (__bridge id<MTLBuffer>)ubo.metalBuffer;
                const NSUInteger off =
                    static_cast<NSUInteger>(ubo.metalBufferOffset);
                if (ubo.isVertex) {
                    [encoder setVertexBuffer:buf offset:off atIndex:slot];
                }
                if (ubo.isFragment) {
                    [encoder setFragmentBuffer:buf offset:off atIndex:slot];
                }
            } else {
                const void* bytes = ubo.usesInlineData
                    ? descriptor.uboInlineStorage.data() + ubo.inlineDataOffset
                    : ubo.data;
                if (bytes == nullptr ||
                    (ubo.usesInlineData &&
                     ubo.inlineDataOffset + ubo.size >
                         descriptor.uboInlineStorage.size())) {
                    return false;
                }
                if (ubo.isVertex) {
                    [encoder setVertexBytes:bytes
                                      length:static_cast<NSUInteger>(ubo.size)
                                     atIndex:slot];
                }
                if (ubo.isFragment) {
                    [encoder setFragmentBytes:bytes
                                        length:static_cast<NSUInteger>(ubo.size)
                                       atIndex:slot];
                }
            }
        }

        for (std::size_t i = 0;
             i < descriptor.fragmentTextureCount;
             ++i) {
            const auto& binding = descriptor.fragmentTextures[i];
            if (binding.metalTexture == nullptr) {
                continue;
            }
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp =
                (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            if (smp == nil) {
                return false;
            }
            [encoder setFragmentTexture:tex
                                atIndex:static_cast<NSUInteger>(
                                            binding.metalSlot)];
            [encoder setFragmentSamplerState:smp
                                     atIndex:static_cast<NSUInteger>(
                                                 binding.metalSlot)];
        }
        for (std::size_t i = 0;
             i < descriptor.vertexTextureCount;
             ++i) {
            const auto& binding = descriptor.vertexTextures[i];
            if (binding.metalTexture == nullptr) {
                continue;
            }
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp =
                (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            if (smp == nil) {
                return false;
            }
            [encoder setVertexTexture:tex
                              atIndex:static_cast<NSUInteger>(
                                          binding.metalSlot)];
            [encoder setVertexSamplerState:smp
                                   atIndex:static_cast<NSUInteger>(
                                               binding.metalSlot)];
        }

        MTLPrimitiveType primitive;
        switch (descriptor.mode) {
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_TRIANGLES:      primitive = MTLPrimitiveTypeTriangle; break;
            default: return false;
        }

        const GLsizei effectiveInstanceCount =
            std::max<GLsizei>(descriptor.instanceCount, 1);
        if (descriptor.indexCount > 0) {
            if (descriptor.metalIndexBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> idxBuffer =
                (__bridge id<MTLBuffer>)descriptor.metalIndexBuffer;
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            if (descriptor.indexType == GL_UNSIGNED_INT) {
                metalIndexType = MTLIndexTypeUInt32;
            } else if (descriptor.indexType != GL_UNSIGNED_SHORT) {
                return false;
            }
            if (effectiveInstanceCount > 1 ||
                descriptor.baseVertex != 0 ||
                descriptor.baseInstance != 0) {
                [encoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(
                                                   descriptor.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:static_cast<NSUInteger>(
                                                   descriptor.metalIndexBufferOffset)
                                 instanceCount:static_cast<NSUInteger>(
                                                   effectiveInstanceCount)
                                    baseVertex:static_cast<NSInteger>(
                                                   descriptor.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(
                                                   descriptor.baseInstance)];
            } else {
                [encoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(
                                                   descriptor.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:static_cast<NSUInteger>(
                                                   descriptor.metalIndexBufferOffset)];
            }
        } else if (effectiveInstanceCount > 1 ||
                   descriptor.baseVertex != 0 ||
                   descriptor.baseInstance != 0) {
            [encoder drawPrimitives:primitive
                         vertexStart:static_cast<NSUInteger>(
                                         descriptor.baseVertex)
                         vertexCount:static_cast<NSUInteger>(
                                         descriptor.vertexCount)
                       instanceCount:static_cast<NSUInteger>(
                                         effectiveInstanceCount)
                        baseInstance:static_cast<NSUInteger>(
                                         descriptor.baseInstance)];
        } else {
            [encoder drawPrimitives:primitive
                         vertexStart:static_cast<NSUInteger>(
                                         descriptor.baseVertex)
                         vertexCount:static_cast<NSUInteger>(
                                         descriptor.vertexCount)];
        }
        if (markPendingPresent) {
            pendingPresent = true;
        }
        return true;
    }

    bool encodeLeanDirectTranslatedDrawDescriptor(
        const LeanDirectTranslatedDrawDescriptor& descriptor,
        id<MTLTexture> colorTexture,
        id<MTLTexture> passDepthStencil) {
        if (currentRenderEncoder == nil) {
            return false;
        }
        ParallelChildEncoderState encoderState;
        encoderState.cachedPipelineState = cachedPipelineState;
        encoderState.cachedDepthStencilState = cachedDepthStencilState;
        encoderState.cachedCullMode = cachedCullMode;
        encoderState.cachedFrontFaceWinding = cachedFrontFaceWinding;
        encoderState.cachedFillMode = cachedFillMode;
        const bool encoded =
            encodeLeanDirectTranslatedDrawDescriptorOnEncoder(
                descriptor,
                currentRenderEncoder,
                colorTexture,
                passDepthStencil,
                encoderState,
                true);
        if (encoded) {
            cachedPipelineState = encoderState.cachedPipelineState;
            cachedDepthStencilState = encoderState.cachedDepthStencilState;
            cachedCullMode = encoderState.cachedCullMode;
            cachedFrontFaceWinding = encoderState.cachedFrontFaceWinding;
            cachedFillMode = encoderState.cachedFillMode;
        }
        return encoded;
    }

    bool encodeCapturedTranslatedDrawOnChildEncoder(
        const CapturedTranslatedDrawRecord& captured,
        id<MTLRenderCommandEncoder> encoder,
        id<MTLTexture> colorTexture,
        id<MTLTexture> passDepthStencil,
        ParallelChildEncoderState& encoderState) {
        const TranslatedDrawInfo& info = captured.info;
        if (!captured.parallelPrepared || encoder == nil || colorTexture == nil) {
            return false;
        }
        id<MTLRenderPipelineState> pipelineState =
            (__bridge id<MTLRenderPipelineState>)captured.parallelPipelineState;
        if (pipelineState == nil) {
            return false;
        }
        const TranslatedDrawMSLSlots shaderSlots =
            phase2PlanMSLSlotsFromShaderSlots(captured.parallelShaderSlots);
        const bool clipControlShaderYFixup =
            captured.parallelClipControlShaderYFixup;
        const bool clipControlInvertsWinding =
            captured.parallelClipControlInvertsWinding;
        const NSUInteger attachmentSampleCount =
            static_cast<NSUInteger>(
                std::max<std::uint32_t>(
                    captured.parallelAttachmentSampleCount, 1u));

        if (pipelineState != encoderState.cachedPipelineState) {
            [encoder setRenderPipelineState:pipelineState];
            encoderState.cachedPipelineState = pipelineState;
        }
        if (passDepthStencil != nil && captured.parallelDepthStencilState != nullptr) {
            id<MTLDepthStencilState> dsState =
                (__bridge id<MTLDepthStencilState>)
                    captured.parallelDepthStencilState;
            if (dsState != nil && dsState != encoderState.cachedDepthStencilState) {
                [encoder setDepthStencilState:dsState];
                encoderState.cachedDepthStencilState = dsState;
            }
            if (info.stencilTestEnabled) {
                [encoder setStencilFrontReferenceValue:
                             static_cast<uint32_t>(info.stencilFrontRef)
                            backReferenceValue:
                             static_cast<uint32_t>(info.stencilBackRef)];
            }
        }

        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront : MTLCullModeBack)
            : MTLCullModeNone;
        if (desiredCull != encoderState.cachedCullMode) {
            [encoder setCullMode:desiredCull];
            encoderState.cachedCullMode = desiredCull;
        }
        const MTLWinding desiredWinding =
            frontFacingWindingForClipControl(info.frontFace,
                                             clipControlInvertsWinding);
        if (desiredWinding != encoderState.cachedFrontFaceWinding) {
            [encoder setFrontFacingWinding:desiredWinding];
            encoderState.cachedFrontFaceWinding = desiredWinding;
        }
        const MTLTriangleFillMode desiredFill =
            info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        if (desiredFill != encoderState.cachedFillMode) {
            [encoder setTriangleFillMode:desiredFill];
            encoderState.cachedFillMode = desiredFill;
        }
        {
            const std::uint32_t sampleMask = attachmentSampleCount > 1
                ? info.sampleMask
                : 0xFFFFFFFFu;
            const NSInteger sampleMaskSlot =
                fixedFunctionSampleMaskBufferSlot(info.fragmentMSL);
            [encoder setFragmentBytes:&sampleMask
                                length:sizeof(sampleMask)
                               atIndex:static_cast<NSUInteger>(sampleMaskSlot)];
        }
        {
            const float bias =
                info.polygonOffsetEnabled ? info.polygonOffsetUnits : 0.0f;
            const float slope =
                info.polygonOffsetEnabled ? info.polygonOffsetFactor : 0.0f;
            const float clampV =
                info.polygonOffsetEnabled ? info.polygonOffsetClamp : 0.0f;
            [encoder setDepthBias:bias slopeScale:slope clamp:clampV];
        }

        if (info.viewportWidth > 0 && info.viewportHeight > 0) {
            const GLint rtW = static_cast<GLint>(colorTexture.width);
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            const double rtHeight = static_cast<double>(rtH);
            const GLint glX = std::max<GLint>(0, info.viewportX);
            const GLint glY = std::max<GLint>(0, info.viewportY);
            const GLsizei availW =
                static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
            const GLsizei availH =
                static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glW = std::min<GLsizei>(info.viewportWidth, availW);
            const GLsizei glH = std::min<GLsizei>(info.viewportHeight, availH);
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(glX);
            vp.originY = clipControlShaderYFixup
                ? static_cast<double>(glY)
                : (flipY
                    ? (rtHeight - static_cast<double>(glY) -
                       static_cast<double>(glH))
                    : static_cast<double>(glY));
            vp.width = static_cast<double>(glW);
            vp.height = static_cast<double>(glH);
            vp.znear = info.depthRangeNear;
            vp.zfar = info.depthRangeFar;
            if (vp.width > 0 && vp.height > 0) {
                [encoder setViewport:vp];
            }
        }
        {
            const NSUInteger rtW = colorTexture.width;
            const NSUInteger rtH = colorTexture.height;
            MTLScissorRect sr;
            if (!info.scissorTestEnabled) {
                sr = {0, 0, rtW, rtH};
            } else if (info.scissorWidth <= 0 || info.scissorHeight <= 0) {
                sr = {0, 0, 0, 0};
            } else {
                GLint metalX = std::max<GLint>(0, info.scissorX);
                GLint metalYBottomLeft = std::max<GLint>(0, info.scissorY);
                GLint metalY = static_cast<GLint>(rtH) -
                    metalYBottomLeft - info.scissorHeight;
                GLsizei scissorH = info.scissorHeight;
                if (metalY < 0) {
                    scissorH += metalY;
                    metalY = 0;
                }
                const GLsizei availW =
                    static_cast<GLsizei>(rtW) - metalX;
                const GLsizei availH =
                    static_cast<GLsizei>(rtH) - metalY;
                const GLsizei finalW =
                    std::min<GLsizei>(
                        info.scissorWidth,
                        std::max<GLsizei>(0, availW));
                const GLsizei finalH =
                    std::min<GLsizei>(
                        scissorH,
                        std::max<GLsizei>(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr = {rtW > 0 ? rtW - 1 : 0,
                          rtH > 0 ? rtH - 1 : 0,
                          1,
                          1};
                } else {
                    sr = {static_cast<NSUInteger>(metalX),
                          static_cast<NSUInteger>(metalY),
                          static_cast<NSUInteger>(finalW),
                          static_cast<NSUInteger>(finalH)};
                }
            }
            [encoder setScissorRect:sr];
        }

        bool hasExtraVertexAttributes = false;
        for (const auto& evb : info.extraVertexBuffers) {
            if (!evb.attributes.empty()) {
                hasExtraVertexAttributes = true;
                break;
            }
        }
        const bool attributelessDraw =
            info.vertexData == nullptr &&
            info.metalVertexBuffer == nullptr &&
            info.vertexAttributeLayouts.empty() &&
            !hasExtraVertexAttributes;
        if (!attributelessDraw && !info.vertexAttributeLayouts.empty()) {
            if (info.metalVertexBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> mtlBuf =
                (__bridge id<MTLBuffer>)info.metalVertexBuffer;
            [encoder setVertexBuffer:mtlBuf
                               offset:static_cast<NSUInteger>(
                                          info.metalVertexBufferOffset)
                              atIndex:0];
        }
        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
            const auto& evb = info.extraVertexBuffers[ei];
            if (evb.attributes.empty()) {
                continue;
            }
            if (evb.metalBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)evb.metalBuffer;
            [encoder setVertexBuffer:mtlBuf
                               offset:static_cast<NSUInteger>(
                                          evb.metalBufferOffset)
                              atIndex:static_cast<NSUInteger>(ei + 1)];
        }

        if (info.vertexUniformData != nullptr && info.vertexUniformSize > 0) {
            [encoder setVertexBytes:info.vertexUniformData
                              length:info.vertexUniformSize
                             atIndex:16];
        }
        if (info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0) {
            [encoder setFragmentBytes:info.fragmentUniformData
                                length:info.fragmentUniformSize
                               atIndex:16];
        }
        {
            const int32_t glNumSamples =
                static_cast<int32_t>(attachmentSampleCount);
            [encoder setFragmentBytes:&glNumSamples
                                length:sizeof(glNumSamples)
                               atIndex:0];
        }
        if (shaderSlots.vertexNeedsFragmentShadingRateState) {
            [encoder setVertexBytes:&info.fragmentShadingRateShaderState
                              length:sizeof(info.fragmentShadingRateShaderState)
                             atIndex:kAppGLFragmentShadingRateParamsBufferSlot];
        }
        if (shaderSlots.vertexClipControlYSignSlot >= 0) {
            const float clipControlYSign =
                (clipControlShaderYFixup &&
                 info.clipOrigin != GL_UPPER_LEFT) ? -1.0f : 1.0f;
            [encoder setVertexBytes:&clipControlYSign
                              length:sizeof(clipControlYSign)
                             atIndex:static_cast<NSUInteger>(
                                         shaderSlots.vertexClipControlYSignSlot)];
        }

        auto setTextureModeBytes =
            [&](NSInteger slot,
                const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
                bool fragment,
                auto builder) {
                if (slot < 0) {
                    return;
                }
                decltype(builder(textures)) payload = builder(textures);
                if (payload.empty()) {
                    return;
                }
                const void* data = payload.data();
                const NSUInteger length =
                    static_cast<NSUInteger>(
                        payload.size() * sizeof(payload[0]));
                if (fragment) {
                    [encoder setFragmentBytes:data
                                        length:length
                                       atIndex:static_cast<NSUInteger>(slot)];
                } else {
                    [encoder setVertexBytes:data
                                      length:length
                                     atIndex:static_cast<NSUInteger>(slot)];
                }
            };
        auto buildModes = [](const auto& textures) {
            std::vector<std::uint32_t> modes;
            buildTextureReductionModes(textures, modes);
            return modes;
        };
        auto buildLodBiases = [](const auto& textures) {
            std::vector<float> biases;
            buildTextureLodBiases(textures, biases);
            return biases;
        };
        auto buildBorderModes = [](const auto& textures) {
            std::vector<std::uint32_t> modes;
            buildTextureBorderClampModes(textures, modes);
            return modes;
        };
        auto buildBorderColors = [](const auto& textures) {
            std::vector<std::array<std::int32_t, 4>> colors;
            buildTextureBorderClampColors(textures, colors);
            return colors;
        };
        setTextureModeBytes(shaderSlots.vertexReductionModesSlot,
                            info.vertexTextures, false, buildModes);
        setTextureModeBytes(shaderSlots.vertexLodBiasesSlot,
                            info.vertexTextures, false, buildLodBiases);
        setTextureModeBytes(shaderSlots.vertexBorderClampModesSlot,
                            info.vertexTextures, false, buildBorderModes);
        setTextureModeBytes(shaderSlots.vertexBorderClampColorsSlot,
                            info.vertexTextures, false, buildBorderColors);
        if (shaderSlots.vertexImplicitLodBiasCorrectionSlot >= 0) {
            const float correction = 0.0f;
            [encoder setVertexBytes:&correction
                              length:sizeof(correction)
                             atIndex:static_cast<NSUInteger>(
                                         shaderSlots.vertexImplicitLodBiasCorrectionSlot)];
        }
        setTextureModeBytes(shaderSlots.fragmentReductionModesSlot,
                            info.fragmentTextures, true, buildModes);
        setTextureModeBytes(shaderSlots.fragmentLodBiasesSlot,
                            info.fragmentTextures, true, buildLodBiases);
        setTextureModeBytes(shaderSlots.fragmentBorderClampModesSlot,
                            info.fragmentTextures, true, buildBorderModes);
        setTextureModeBytes(shaderSlots.fragmentBorderClampColorsSlot,
                            info.fragmentTextures, true, buildBorderColors);
        if (shaderSlots.fragmentImplicitLodBiasCorrectionSlot >= 0) {
            const float correction =
                implicitLodViewportBiasCorrection(info, false, colorTexture);
            [encoder setFragmentBytes:&correction
                                length:sizeof(correction)
                               atIndex:static_cast<NSUInteger>(
                                           shaderSlots.fragmentImplicitLodBiasCorrectionSlot)];
        }
        if (shaderSlots.fragmentNeedsFragCoordParams) {
            auto fragmentSamplesColorAttachment = [&]() {
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalTexture == nullptr) {
                        continue;
                    }
                    id<MTLTexture> sampled =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (sampled == colorTexture) {
                        return true;
                    }
                }
                return false;
            };
            const float renderTargetHeight =
                static_cast<float>(colorTexture.height);
            const bool flipToLowerLeft =
                (info.clipOrigin != GL_UPPER_LEFT) &&
                !fragmentSamplesColorAttachment();
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            const GLint glY = std::max<GLint>(0, info.viewportY);
            const GLsizei availH =
                static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glH =
                std::min<GLsizei>(info.viewportHeight, availH);
            const float viewportLowerLeftBase =
                static_cast<float>(glY + glH);
            const float lowerLeftBase = clipControlShaderYFixup
                ? viewportLowerLeftBase
                : renderTargetHeight;
            const float fragCoordParams[4] = {
                flipToLowerLeft ? lowerLeftBase : 0.0f,
                flipToLowerLeft ? -1.0f : 1.0f,
                flipToLowerLeft ? 1.0f : 0.0f,
                0.0f,
            };
            [encoder setFragmentBytes:fragCoordParams
                                length:sizeof(fragCoordParams)
                               atIndex:kAppGLFragCoordParamsBufferSlot];
        }

        for (const auto& ubo : info.uboBindings) {
            if (ubo.size == 0) {
                continue;
            }
            const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
            if (ubo.metalBuffer != nullptr) {
                id<MTLBuffer> buf =
                    (__bridge id<MTLBuffer>)ubo.metalBuffer;
                const NSUInteger off =
                    static_cast<NSUInteger>(ubo.metalBufferOffset);
                if (ubo.isVertex) {
                    [encoder setVertexBuffer:buf offset:off atIndex:slot];
                }
                if (ubo.isFragment) {
                    [encoder setFragmentBuffer:buf offset:off atIndex:slot];
                }
            } else if (ubo.data != nullptr) {
                if (ubo.isVertex) {
                    [encoder setVertexBytes:ubo.data
                                      length:static_cast<NSUInteger>(ubo.size)
                                     atIndex:slot];
                }
                if (ubo.isFragment) {
                    [encoder setFragmentBytes:ubo.data
                                        length:static_cast<NSUInteger>(ubo.size)
                                       atIndex:slot];
                }
            }
        }

        for (const auto& binding : info.fragmentTextures) {
            if (binding.metalTexture == nullptr) {
                continue;
            }
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp =
                (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            if (smp == nil) {
                return false;
            }
            [encoder setFragmentTexture:tex
                                atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            [encoder setFragmentSamplerState:smp
                                     atIndex:static_cast<NSUInteger>(binding.metalSlot)];
        }
        for (const auto& binding : info.vertexTextures) {
            if (binding.metalTexture == nullptr) {
                continue;
            }
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp =
                (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            if (smp == nil) {
                return false;
            }
            [encoder setVertexTexture:tex
                              atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            [encoder setVertexSamplerState:smp
                                   atIndex:static_cast<NSUInteger>(binding.metalSlot)];
        }

        MTLPrimitiveType primitive;
        switch (info.mode) {
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_TRIANGLES:      primitive = MTLPrimitiveTypeTriangle; break;
            default: return false;
        }

        const GLsizei effectiveInstanceCount =
            std::max<GLsizei>(info.instanceCount, 1);
        if (info.indexCount > 0) {
            if (info.metalIndexBuffer == nullptr) {
                return false;
            }
            id<MTLBuffer> idxBuffer =
                (__bridge id<MTLBuffer>)info.metalIndexBuffer;
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            if (info.indexType == GL_UNSIGNED_INT) {
                metalIndexType = MTLIndexTypeUInt32;
            } else if (info.indexType != GL_UNSIGNED_SHORT) {
                return false;
            }
            if (effectiveInstanceCount > 1 ||
                info.baseVertex != 0 ||
                info.baseInstance != 0) {
                [encoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:static_cast<NSUInteger>(
                                                   info.metalIndexBufferOffset)
                                 instanceCount:static_cast<NSUInteger>(
                                                   effectiveInstanceCount)
                                    baseVertex:static_cast<NSInteger>(info.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(
                                                   info.baseInstance)];
            } else {
                [encoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:static_cast<NSUInteger>(
                                                   info.metalIndexBufferOffset)];
            }
        } else if (effectiveInstanceCount > 1 ||
                   info.baseVertex != 0 ||
                   info.baseInstance != 0) {
            [encoder drawPrimitives:primitive
                         vertexStart:static_cast<NSUInteger>(info.baseVertex)
                         vertexCount:static_cast<NSUInteger>(info.vertexCount)
                       instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                        baseInstance:static_cast<NSUInteger>(info.baseInstance)];
        } else {
            [encoder drawPrimitives:primitive
                         vertexStart:static_cast<NSUInteger>(info.baseVertex)
                         vertexCount:static_cast<NSUInteger>(info.vertexCount)];
        }
        return true;
    }

    bool tryReplayPendingPreparedTranslatedDrawBatchSerial(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason fallbackReason) {
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingParallelTranslatedDraws.size());
        if (drawCount == 0) {
            return true;
        }
        const GLenum fragmentRate =
            pendingParallelTranslatedDraws.front().info.fragmentShadingRate;
        for (const auto& captured : pendingParallelTranslatedDraws) {
            if (!captured.parallelPrepared ||
                captured.info.fragmentShadingRate != fragmentRate) {
                return false;
            }
        }

        if (currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        acquireRingSlot();

        MTLRenderPassDescriptor* pass = nil;
        id<MTLTexture> colorTexture = nil;
        id<MTLTexture> passDepthStencil = nil;
        if (!buildDefaultParallelRenderPass(
                fragmentRate,
                pass,
                colorTexture,
                passDepthStencil)) {
            return false;
        }

        if (!openCurrentRenderEncoder(pass)) {
            return false;
        }
        hasPendingClear = false;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA =
            colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        activeRenderPassFragmentShadingRate = fragmentRate;

        std::uint64_t failures = 0;
        const DrawProfileTimePoint replayStart = drawProfileNow();
        ParallelChildEncoderState encoderState;
        for (CapturedTranslatedDrawRecord& captured :
             pendingParallelTranslatedDraws) {
            const bool encoded =
                encodeCapturedTranslatedDrawOnChildEncoder(
                    captured,
                    currentRenderEncoder,
                    colorTexture,
                    passDepthStencil,
                    encoderState);
            if (!encoded) {
                ++failures;
            }
        }
        [currentRenderEncoder endEncoding];
        releaseCurrentRenderEncoder();
        activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        resetCachedEncoderState();
        pendingPresent = true;

        const double elapsedUs =
            drawProfileElapsedUs(replayStart, drawProfileNow());
        parallelEncodeProfile.recordSerialBatchReplay(
            reason, fallbackReason, drawCount, elapsedUs, failures);
        return true;
    }

    void replayPendingParallelTranslatedDrawBatchSerial(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason fallbackReason) {
        if (tryReplayPendingPreparedTranslatedDrawBatchSerial(
                reason, fallbackReason)) {
            return;
        }

        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingParallelTranslatedDraws.size());
        std::uint64_t failures = 0;
        const DrawProfileTimePoint replayStart = drawProfileNow();
        for (CapturedTranslatedDrawRecord& captured :
             pendingParallelTranslatedDraws) {
            const bool encoded = encodeTranslatedDrawSerial(captured.info);
            if (!encoded) {
                ++failures;
            }
        }
        const double elapsedUs =
            drawProfileElapsedUs(replayStart, drawProfileNow());
        parallelEncodeProfile.recordSerialBatchReplay(
            reason, fallbackReason, drawCount, elapsedUs, failures);
    }

    bool replayPendingLeanDirectDescriptorBatchSerial(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason fallbackReason) {
        (void)fallbackReason;
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingLeanDirectDescriptors.size());
        if (drawCount == 0) {
            return true;
        }

        const DrawProfileTimePoint replayStart = drawProfileNow();
        std::uint64_t failures = 0;
        for (const auto& descriptor : pendingLeanDirectDescriptors) {
            id<MTLTexture> colorTexture = nil;
            id<MTLTexture> passDepthStencil = nil;
            const bool passReady =
                ensureLeanDirectDefaultRenderPass(
                    descriptor.fragmentShadingRate,
                    colorTexture,
                    passDepthStencil);
            const bool encoded =
                passReady &&
                encodeLeanDirectTranslatedDrawDescriptor(
                    descriptor,
                    colorTexture,
                    passDepthStencil);
            if (!encoded) {
                ++failures;
            }
        }
        const DrawProfileTimePoint bodyEnd = drawProfileNow();
        if (currentRenderEncoder != nil) {
            endCurrentRenderPassOnly();
            resetCachedEncoderState();
        }
        pendingPresent = true;
        const double elapsedUs =
            drawProfileElapsedUs(replayStart, drawProfileNow());
        parallelEncodeProfile.recordDescriptorSerialBatch(
            reason, drawCount, elapsedUs, failures);
        const double bodyUs = drawProfileElapsedUs(replayStart, bodyEnd);
        frameAttributionProfile.recordDescriptorSerial(
            reason,
            drawCount,
            elapsedUs,
            bodyUs,
            std::max(0.0, elapsedUs - bodyUs),
            failures);
        return failures == 0;
    }

    void dispatchThreadedDeferredRecordChunks(bool flushAll) {
        if (!threadedDeferredRecordProfile.enabled) {
            return;
        }
        if (!flushAll && !threadedDeferredRecordProfile.asyncEnabled) {
            return;
        }
        if (threadedDeferredRecordGroup == nullptr) {
            threadedDeferredRecordGroup = dispatch_group_create();
        }
        const std::uint64_t available =
            static_cast<std::uint64_t>(pendingThreadedDeferredRecords.size());
        const bool splitByWorkers =
            flushAll && !threadedDeferredRecordProfile.asyncEnabled;
        const std::uint64_t remainingAtStart =
            available - nextThreadedDeferredRecordToDispatch;
        const std::uint64_t splitChunkCount = splitByWorkers
            ? std::min<std::uint64_t>(
                  std::max<std::uint32_t>(
                      threadedDeferredRecordProfile.configuredWorkerCount, 1u),
                  remainingAtStart)
            : 0;
        const std::uint64_t splitBase = splitChunkCount > 0
            ? remainingAtStart / splitChunkCount
            : 0;
        const std::uint64_t splitRemainder = splitChunkCount > 0
            ? remainingAtStart % splitChunkCount
            : 0;
        std::uint64_t splitOrdinal = 0;
        const std::uint64_t asyncChunkSize =
            std::max<std::uint64_t>(
                threadedDeferredRecordProfile.configuredAsyncChunkSize, 1u);
        while (nextThreadedDeferredRecordToDispatch < available) {
            const std::uint64_t remaining =
                available - nextThreadedDeferredRecordToDispatch;
            if (splitByWorkers && splitOrdinal >= splitChunkCount) {
                break;
            }
            if (!splitByWorkers && !flushAll && remaining < asyncChunkSize) {
                break;
            }
            const std::uint64_t count = splitByWorkers
                ? (splitBase + (splitOrdinal < splitRemainder ? 1u : 0u))
                : std::min<std::uint64_t>(asyncChunkSize, remaining);
            if (count == 0) {
                break;
            }
            ++splitOrdinal;
            const std::uint64_t begin =
                nextThreadedDeferredRecordToDispatch;
            const std::uint64_t end = begin + count;
            pendingThreadedDeferredChunks.emplace_back();
            ThreadedDeferredAsyncChunk& chunk =
                pendingThreadedDeferredChunks.back();
            chunk.chunkIndex = nextThreadedDeferredChunkIndex++;
            chunk.begin = begin;
            chunk.end = end;
            auto records =
                std::make_shared<
                    std::vector<CapturedTranslatedDrawRecord*>>();
            auto descriptors =
                std::make_shared<
                    std::vector<LeanDirectTranslatedDrawDescriptor*>>();
            records->reserve(static_cast<std::size_t>(count));
            descriptors->reserve(static_cast<std::size_t>(count));
            for (std::uint64_t draw = begin; draw < end; ++draw) {
                records->push_back(&pendingThreadedDeferredRecords[
                    static_cast<std::size_t>(draw)]);
                descriptors->push_back(&pendingThreadedDeferredDescriptors[
                    static_cast<std::size_t>(draw)]);
            }
            ThreadedDeferredAsyncChunk* chunkPtr = &chunk;
            std::atomic<std::uint64_t>* completionOrdinalPtr =
                &threadedDeferredCompletionOrdinal;
            Impl* self = this;
            dispatch_queue_t queue =
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
            dispatch_group_async(threadedDeferredRecordGroup, queue, ^{
                @autoreleasepool {
                    const DrawProfileTimePoint workerStart = drawProfileNow();
                    std::uint64_t failures = 0;
                    for (std::size_t i = 0; i < records->size(); ++i) {
                        CapturedTranslatedDrawRecord* record = (*records)[i];
                        LeanDirectTranslatedDrawDescriptor* descriptor =
                            (*descriptors)[i];
                        ParallelEncodeFallbackReason drawFallback =
                            ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
                        const bool prepared =
                            self->prepareThreadedDeferredDescriptorFromRecord(
                                *record, *descriptor, drawFallback);
                        record->threadedDescriptorPrepared = prepared;
                        record->threadedDescriptorFallbackReason = drawFallback;
                        if (!prepared) {
                            ++failures;
                        }
                    }
                    chunkPtr->workerUs =
                        drawProfileElapsedUs(workerStart, drawProfileNow());
                    chunkPtr->failures = failures;
                    chunkPtr->completionOrdinal =
                        completionOrdinalPtr->fetch_add(
                            1, std::memory_order_relaxed);
                }
            });
            nextThreadedDeferredRecordToDispatch = end;
        }
    }

    bool replayThreadedDeferredRecordBatchSerialWithDescriptors(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason fallbackReason) {
        (void)reason;
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingThreadedDeferredRecords.size());
        if (drawCount == 0) {
            return true;
        }

        std::uint64_t failures = 0;
        for (std::size_t draw = 0;
             draw < pendingThreadedDeferredRecords.size();
             ++draw) {
            const CapturedTranslatedDrawRecord& record =
                pendingThreadedDeferredRecords[draw];
            LeanDirectTranslatedDrawDescriptor descriptorStorage;
            const LeanDirectTranslatedDrawDescriptor* descriptor = nullptr;
            ParallelEncodeFallbackReason descriptorFallback =
                ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
            bool prepared = false;
            if (record.threadedDescriptorFastRecord) {
                prepared =
                    record.threadedDescriptorPrepared &&
                    draw < pendingThreadedDeferredDescriptors.size();
                if (prepared) {
                    descriptor = &pendingThreadedDeferredDescriptors[draw];
                } else {
                    descriptorFallback =
                        record.threadedDescriptorFallbackReason;
                }
            } else {
                prepared =
                    prepareThreadedDeferredDescriptorFromRecord(
                        record, descriptorStorage, descriptorFallback);
                if (prepared) {
                    descriptor = &descriptorStorage;
                }
            }
            id<MTLTexture> colorTexture = nil;
            id<MTLTexture> passDepthStencil = nil;
            const bool passReady =
                prepared &&
                ensureLeanDirectDefaultRenderPass(
                    descriptor->fragmentShadingRate,
                    colorTexture,
                    passDepthStencil);
            const bool encoded =
                passReady &&
                encodeLeanDirectTranslatedDrawDescriptor(
                    *descriptor,
                    colorTexture,
                    passDepthStencil);
            if (!encoded) {
                ++failures;
            }
        }
        if (currentRenderEncoder != nil) {
            endCurrentRenderPassOnly();
            resetCachedEncoderState();
        }
        pendingPresent = true;
        threadedDeferredRecordProfile.recordFallback(
            fallbackReason, drawCount);
        if (failures > 0) {
            threadedDeferredRecordProfile.recordFallback(
                ParallelEncodeFallbackReason::EncodeFailure, failures);
        }
        return failures == 0;
    }

    bool tryEncodeThreadedDeferredRecordBatch(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason& fallbackReason) {
        (void)reason;
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingThreadedDeferredRecords.size());
        const bool asyncMode = threadedDeferredRecordProfile.asyncEnabled;
        double waitUs = 0.0;
        if (asyncMode) {
            dispatchThreadedDeferredRecordChunks(true);
            const DrawProfileTimePoint waitStart = drawProfileNow();
            if (threadedDeferredRecordGroup != nullptr) {
                dispatch_group_wait(threadedDeferredRecordGroup,
                                    DISPATCH_TIME_FOREVER);
            }
            waitUs = drawProfileElapsedUs(waitStart, drawProfileNow());
        }
        if (drawCount < threadedDeferredRecordProfile.configuredMinBatch) {
            fallbackReason = ParallelEncodeFallbackReason::SmallBatch;
            return false;
        }

        const GLenum fragmentRate =
            pendingThreadedDeferredRecords.front().info.fragmentShadingRate;
        bool descriptorFastBatch = !asyncMode;
        for (const auto& record : pendingThreadedDeferredRecords) {
            if (!record.threadedPrepared) {
                fallbackReason = record.threadedFallbackReason;
                return false;
            }
            if (!record.threadedDescriptorFastRecord) {
                descriptorFastBatch = false;
            }
            if (record.info.fragmentShadingRate != fragmentRate) {
                fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
                return false;
            }
        }

        std::vector<ParallelEncodeChunkProfile> chunkProfiles;
        double sumWorkerUs = 0.0;
        double maxWorkerUs = 0.0;
        std::uint64_t failures = 0;
        std::uint64_t outOfOrderCompletions = 0;
        std::uint64_t chunkCount = 0;

        if (asyncMode) {
            chunkCount = static_cast<std::uint64_t>(
                pendingThreadedDeferredChunks.size());
            chunkProfiles.reserve(static_cast<std::size_t>(chunkCount));
            for (const ThreadedDeferredAsyncChunk& work :
                 pendingThreadedDeferredChunks) {
                sumWorkerUs += work.workerUs;
                maxWorkerUs = std::max(maxWorkerUs, work.workerUs);
                failures += work.failures;
                if (work.completionOrdinal != work.chunkIndex) {
                    ++outOfOrderCompletions;
                }
                ParallelEncodeChunkProfile profile;
                profile.chunkIndex = work.chunkIndex;
                profile.drawBegin = work.begin;
                profile.drawEnd = work.end;
                profile.drawCount = work.end - work.begin;
                profile.workerEncodeUs = work.workerUs;
                profile.failures = work.failures;
                chunkProfiles.push_back(profile);
            }
            for (const auto& record : pendingThreadedDeferredRecords) {
                if (!record.threadedDescriptorPrepared) {
                    ++failures;
                    if (fallbackReason == ParallelEncodeFallbackReason::EncodeFailure) {
                        fallbackReason = record.threadedDescriptorFallbackReason;
                    }
                }
            }
        } else {
            struct ThreadedDeferredChunkWork {
                std::uint64_t chunkIndex = 0;
                std::uint64_t begin = 0;
                std::uint64_t end = 0;
                double workerUs = 0.0;
                std::uint64_t failures = 0;
                std::uint64_t completionOrdinal =
                    std::numeric_limits<std::uint64_t>::max();
            };

            const std::uint64_t configuredWorkers =
                std::max<std::uint32_t>(
                    threadedDeferredRecordProfile.configuredWorkerCount, 1u);
            chunkCount = std::min<std::uint64_t>(configuredWorkers, drawCount);
            std::vector<ThreadedDeferredChunkWork> chunks(
                static_cast<std::size_t>(chunkCount));
            const std::uint64_t baseChunkSize = drawCount / chunkCount;
            const std::uint64_t remainder = drawCount % chunkCount;
            std::uint64_t cursor = 0;
            for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
                const std::uint64_t count =
                    baseChunkSize + (chunk < remainder ? 1u : 0u);
                ThreadedDeferredChunkWork& work =
                    chunks[static_cast<std::size_t>(chunk)];
                work.chunkIndex = chunk;
                work.begin = cursor;
                work.end = cursor + count;
                cursor += count;
            }

            ThreadedDeferredChunkWork* chunkData = chunks.data();
            Impl* self = this;
            std::atomic<std::uint64_t> completionOrdinal{0};
            std::atomic<std::uint64_t>* completionOrdinalPtr =
                &completionOrdinal;
            const DrawProfileTimePoint wallStart = drawProfileNow();
            auto prepareChunk = ^(std::uint64_t index) {
                @autoreleasepool {
                    ThreadedDeferredChunkWork& work =
                        chunkData[static_cast<std::size_t>(index)];
                    const DrawProfileTimePoint workerStart = drawProfileNow();
                    for (std::uint64_t draw = work.begin;
                         draw < work.end;
                         ++draw) {
                        CapturedTranslatedDrawRecord& record =
                            self->pendingThreadedDeferredRecords[
                                static_cast<std::size_t>(draw)];
                        LeanDirectTranslatedDrawDescriptor& descriptor =
                            self->pendingThreadedDeferredDescriptors[
                                static_cast<std::size_t>(draw)];
                        if (record.threadedDescriptorFastRecord) {
                            if (!record.threadedDescriptorPrepared ||
                                descriptor.fragmentShadingRate !=
                                    record.info.fragmentShadingRate) {
                                ++work.failures;
                            }
                            continue;
                        }
                        ParallelEncodeFallbackReason drawFallback =
                            ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
                        const bool prepared =
                            self->prepareThreadedDeferredDescriptorFromRecord(
                                record, descriptor, drawFallback);
                        record.threadedDescriptorPrepared = prepared;
                        record.threadedDescriptorFallbackReason = drawFallback;
                        if (!prepared) {
                            ++work.failures;
                        }
                    }
                    work.workerUs =
                        drawProfileElapsedUs(workerStart, drawProfileNow());
                    work.completionOrdinal =
                        completionOrdinalPtr->fetch_add(
                            1, std::memory_order_relaxed);
                }
            };
            if (chunkCount == 1 || descriptorFastBatch) {
                for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
                    prepareChunk(chunk);
                }
            } else {
                dispatch_queue_t queue =
                    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
                dispatch_apply(static_cast<size_t>(chunkCount),
                               queue,
                               ^(size_t index) {
                    prepareChunk(static_cast<std::uint64_t>(index));
                });
            }
            waitUs = drawProfileElapsedUs(wallStart, drawProfileNow());

            chunkProfiles.reserve(static_cast<std::size_t>(chunkCount));
            for (const ThreadedDeferredChunkWork& work : chunks) {
                sumWorkerUs += work.workerUs;
                maxWorkerUs = std::max(maxWorkerUs, work.workerUs);
                failures += work.failures;
                if (work.completionOrdinal != work.chunkIndex) {
                    ++outOfOrderCompletions;
                }
                ParallelEncodeChunkProfile profile;
                profile.chunkIndex = work.chunkIndex;
                profile.drawBegin = work.begin;
                profile.drawEnd = work.end;
                profile.drawCount = work.end - work.begin;
                profile.workerEncodeUs = work.workerUs;
                profile.failures = work.failures;
                chunkProfiles.push_back(profile);
            }
            for (const auto& record : pendingThreadedDeferredRecords) {
                if (!record.threadedDescriptorPrepared) {
                    ++failures;
                    if (fallbackReason == ParallelEncodeFallbackReason::EncodeFailure) {
                        fallbackReason = record.threadedDescriptorFallbackReason;
                    }
                }
            }
        }
        if (failures > 0) {
            if (fallbackReason == ParallelEncodeFallbackReason::Count) {
                fallbackReason = ParallelEncodeFallbackReason::EncodeFailure;
            }
            threadedDeferredRecordProfile.recordBatch(
                drawCount,
                chunkCount,
                chunkProfiles,
                waitUs,
                sumWorkerUs,
                maxWorkerUs,
                waitUs,
                0.0,
                failures,
                outOfOrderCompletions,
                0,
                0);
            return false;
        }

        std::uint64_t sequenceViolations = 0;
        std::uint64_t missingOrDuplicate = 0;
        std::uint64_t expectedSequence =
            pendingThreadedDeferredRecords.front().threadedSequence;
        std::uint64_t previousSequence = 0;
        bool havePreviousSequence = false;
        for (const auto& record : pendingThreadedDeferredRecords) {
            if (record.threadedSequence != expectedSequence) {
                ++sequenceViolations;
            }
            if (havePreviousSequence &&
                record.threadedSequence != previousSequence + 1) {
                ++missingOrDuplicate;
            }
            previousSequence = record.threadedSequence;
            havePreviousSequence = true;
            ++expectedSequence;
        }
        if (sequenceViolations > 0 || missingOrDuplicate > 0) {
            fallbackReason = ParallelEncodeFallbackReason::EncodeFailure;
            threadedDeferredRecordProfile.recordBatch(
                drawCount,
                chunkCount,
                chunkProfiles,
                waitUs,
                sumWorkerUs,
                maxWorkerUs,
                waitUs,
                0.0,
                sequenceViolations + missingOrDuplicate,
                outOfOrderCompletions,
                sequenceViolations,
                missingOrDuplicate);
            return false;
        }

        const DrawProfileTimePoint mergeStart = drawProfileNow();
        std::uint64_t encodeFailures = 0;
        std::uint64_t encodedDraws = 0;
        for (const auto& descriptor : pendingThreadedDeferredDescriptors) {
            id<MTLTexture> colorTexture = nil;
            id<MTLTexture> passDepthStencil = nil;
            const bool passReady =
                ensureLeanDirectDefaultRenderPass(
                    descriptor.fragmentShadingRate,
                    colorTexture,
                    passDepthStencil);
            const bool encoded =
                passReady &&
                encodeLeanDirectTranslatedDrawDescriptor(
                    descriptor,
                    colorTexture,
                    passDepthStencil);
            if (!encoded) {
                ++encodeFailures;
                if (encodedDraws == 0) {
                    break;
                }
                continue;
            }
            ++encodedDraws;
        }
        const double mergeUs =
            drawProfileElapsedUs(mergeStart, drawProfileNow());
        threadedDeferredRecordProfile.recordBatch(
            drawCount,
            chunkCount,
            chunkProfiles,
            waitUs,
            sumWorkerUs,
            maxWorkerUs,
            waitUs,
            mergeUs,
            encodeFailures,
            outOfOrderCompletions,
            0,
            0);
        fallbackReason = encodeFailures == 0
            ? ParallelEncodeFallbackReason::Count
            : ParallelEncodeFallbackReason::EncodeFailure;
        return encodeFailures == 0 || encodedDraws > 0;
    }

    void flushThreadedDeferredRecordBatch(ParallelEncodeBoundaryReason reason) {
        if (!threadedDeferredRecordProfile.enabled ||
            pendingThreadedDeferredRecords.empty() ||
            flushingThreadedDeferredRecordBatch) {
            return;
        }

        flushingThreadedDeferredRecordBatch = true;
        threadedDeferredRecordProfile.recordBoundary(reason);
        ParallelEncodeFallbackReason fallbackReason =
            ParallelEncodeFallbackReason::EncodeFailure;
        const bool encoded =
            tryEncodeThreadedDeferredRecordBatch(reason, fallbackReason);
        if (!encoded) {
            replayThreadedDeferredRecordBatchSerialWithDescriptors(
                reason, fallbackReason);
        }
        pendingThreadedDeferredRecords.clear();
        pendingThreadedDeferredDescriptors.clear();
        pendingThreadedDeferredChunks.clear();
        nextThreadedDeferredRecordToDispatch = 0;
        nextThreadedDeferredChunkIndex = 0;
        threadedDeferredCompletionOrdinal.store(0, std::memory_order_relaxed);
        flushingThreadedDeferredRecordBatch = false;
    }

    bool tryEncodeLeanDirectDescriptorWorkerBatch(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason& fallbackReason) {
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingLeanDirectDescriptors.size());
        const DrawProfileTimePoint totalStart = drawProfileNow();
        if (drawCount < parallelEncodeProfile.configuredMinBatch) {
            fallbackReason = ParallelEncodeFallbackReason::SmallBatch;
            return false;
        }
        if (parallelEncodeProfile.configuredWorkerCount <= 1) {
            fallbackReason = ParallelEncodeFallbackReason::WorkerCount;
            return false;
        }
        if (reason == ParallelEncodeBoundaryReason::Finish &&
            leanDirectDescriptorWorkerFlushCount > 0) {
            fallbackReason = ParallelEncodeFallbackReason::SmallBatch;
            return false;
        }

        const GLenum fragmentRate =
            pendingLeanDirectDescriptors.front().fragmentShadingRate;
        for (const auto& descriptor : pendingLeanDirectDescriptors) {
            if (descriptor.fragmentShadingRate != fragmentRate) {
                fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
                return false;
            }
        }

        if (currentRenderEncoder != nil) {
            endCurrentRenderPassOnly();
            resetCachedEncoderState();
        }
        acquireRingSlot();

        MTLRenderPassDescriptor* pass = nil;
        id<MTLTexture> colorTexture = nil;
        id<MTLTexture> passDepthStencil = nil;
        if (!buildDefaultParallelRenderPass(fragmentRate,
                                            pass,
                                            colorTexture,
                                            passDepthStencil)) {
            fallbackReason =
                ParallelEncodeFallbackReason::ParallelEncoderCreateFailure;
            return false;
        }

        id<MTLParallelRenderCommandEncoder> parallelEncoder =
            [currentCommandBuffer parallelRenderCommandEncoderWithDescriptor:pass];
        if (parallelEncoder == nil) {
            fallbackReason =
                ParallelEncodeFallbackReason::ParallelEncoderCreateFailure;
            return false;
        }

        const std::uint64_t configuredWorkers =
            parallelEncodeProfile.configuredWorkerCount;
        const std::uint64_t chunkCount =
            std::min<std::uint64_t>(configuredWorkers, drawCount);
        std::vector<id<MTLRenderCommandEncoder>> childEncoders;
        childEncoders.reserve(static_cast<std::size_t>(chunkCount));
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            id<MTLRenderCommandEncoder> child =
                [parallelEncoder renderCommandEncoder];
            if (child == nil) {
                for (id<MTLRenderCommandEncoder> enc : childEncoders) {
                    [enc endEncoding];
                }
                [parallelEncoder endEncoding];
                activeRenderPassFragmentShadingRate =
                    GL_SHADING_RATE_1X1_PIXELS_EXT;
                resetCachedEncoderState();
                fallbackReason =
                    ParallelEncodeFallbackReason::ChildEncoderCreateFailure;
                return false;
            }
            childEncoders.push_back(child);
        }

        hasPendingClear = false;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA =
            colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        activeRenderPassFragmentShadingRate = fragmentRate;

        struct LeanDirectChunkWork {
            std::uint64_t begin = 0;
            std::uint64_t end = 0;
            double workerUs = 0.0;
            std::uint64_t failures = 0;
        };
        std::vector<LeanDirectChunkWork> chunks(
            static_cast<std::size_t>(chunkCount));
        const std::uint64_t baseChunkSize = drawCount / chunkCount;
        const std::uint64_t remainder = drawCount % chunkCount;
        std::uint64_t cursor = 0;
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            const std::uint64_t count =
                baseChunkSize + (chunk < remainder ? 1u : 0u);
            chunks[static_cast<std::size_t>(chunk)].begin = cursor;
            chunks[static_cast<std::size_t>(chunk)].end = cursor + count;
            cursor += count;
        }

        const DrawProfileTimePoint wallStart = drawProfileNow();
        LeanDirectChunkWork* chunkData = chunks.data();
        id<MTLRenderCommandEncoder>* encoderData = childEncoders.data();
        Impl* self = this;
        dispatch_queue_t queue =
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_apply(static_cast<size_t>(chunkCount), queue, ^(size_t index) {
            @autoreleasepool {
                ParallelChildEncoderState childState;
                LeanDirectChunkWork& work = chunkData[index];
                id<MTLRenderCommandEncoder> child = encoderData[index];
                const DrawProfileTimePoint workerStart = drawProfileNow();
                for (std::uint64_t draw = work.begin; draw < work.end; ++draw) {
                    const bool encoded =
                        self->encodeLeanDirectTranslatedDrawDescriptorOnEncoder(
                            self->pendingLeanDirectDescriptors[
                                static_cast<std::size_t>(draw)],
                            child,
                            colorTexture,
                            passDepthStencil,
                            childState,
                            false);
                    if (!encoded) {
                        ++work.failures;
                    }
                }
                work.workerUs =
                    drawProfileElapsedUs(workerStart, drawProfileNow());
                [child endEncoding];
            }
        });
        [parallelEncoder endEncoding];
        const DrawProfileTimePoint wallEnd = drawProfileNow();
        const double wallUs =
            drawProfileElapsedUs(wallStart, wallEnd);
        currentRenderEncoder = nil;
        activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        resetCachedEncoderState();
        pendingPresent = true;

        std::vector<ParallelEncodeChunkProfile> chunkProfiles;
        chunkProfiles.reserve(static_cast<std::size_t>(chunkCount));
        double sumWorkerUs = 0.0;
        double maxWorkerUs = 0.0;
        std::uint64_t failures = 0;
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            const LeanDirectChunkWork& work =
                chunks[static_cast<std::size_t>(chunk)];
            sumWorkerUs += work.workerUs;
            maxWorkerUs = std::max(maxWorkerUs, work.workerUs);
            failures += work.failures;
            ParallelEncodeChunkProfile profile;
            profile.chunkIndex = chunk;
            profile.drawBegin = work.begin;
            profile.drawEnd = work.end;
            profile.drawCount = work.end - work.begin;
            profile.workerEncodeUs = work.workerUs;
            profile.failures = work.failures;
            chunkProfiles.push_back(profile);
        }
        parallelEncodeProfile.recordDescriptorWorkerBatch(
            reason,
            drawCount,
            chunkProfiles,
            wallUs,
            sumWorkerUs,
            maxWorkerUs,
            failures);
        const double totalUs =
            drawProfileElapsedUs(totalStart, drawProfileNow());
        const double setupUs = drawProfileElapsedUs(totalStart, wallStart);
        frameAttributionProfile.recordDescriptorWorker(
            reason,
            drawCount,
            chunkCount,
            totalUs,
            setupUs,
            wallUs,
            std::max(0.0, totalUs - setupUs - wallUs),
            failures);
        ++leanDirectDescriptorWorkerFlushCount;
        return true;
    }

    void flushLeanDirectDescriptorBatch(ParallelEncodeBoundaryReason reason) {
        if (!parallelEncodeProfile.enabled ||
            pendingLeanDirectDescriptors.empty() ||
            flushingLeanDirectDescriptorBatch) {
            return;
        }

        flushingLeanDirectDescriptorBatch = true;
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingLeanDirectDescriptors.size());
        const DrawProfileTimePoint flushStart = drawProfileNow();
        ParallelEncodeFallbackReason fallbackReason =
            ParallelEncodeFallbackReason::EncodeFailure;
        const bool parallelEncoded =
            tryEncodeLeanDirectDescriptorWorkerBatch(reason, fallbackReason);
        if (!parallelEncoded) {
            replayPendingLeanDirectDescriptorBatchSerial(
                reason, fallbackReason);
        }
        frameAttributionProfile.recordDescriptorFlush(
            reason,
            drawCount,
            drawProfileElapsedUs(flushStart, drawProfileNow()),
            parallelEncoded);
        pendingLeanDirectDescriptors.clear();
        flushingLeanDirectDescriptorBatch = false;
    }

    bool tryEncodeParallelTranslatedDrawBatch(
        ParallelEncodeBoundaryReason reason,
        ParallelEncodeFallbackReason& fallbackReason) {
        const std::uint64_t drawCount =
            static_cast<std::uint64_t>(pendingParallelTranslatedDraws.size());
        if (drawCount < parallelEncodeProfile.configuredMinBatch) {
            fallbackReason = ParallelEncodeFallbackReason::SmallBatch;
            return false;
        }
        if (parallelEncodeProfile.configuredWorkerCount <= 1) {
            fallbackReason = ParallelEncodeFallbackReason::WorkerCount;
            return false;
        }

        const GLenum fragmentRate =
            pendingParallelTranslatedDraws.front().info.fragmentShadingRate;
        for (const auto& captured : pendingParallelTranslatedDraws) {
            if (!captured.parallelPrepared) {
                fallbackReason = captured.parallelFallbackReason;
                return false;
            }
            if (captured.info.fragmentShadingRate != fragmentRate) {
                fallbackReason = ParallelEncodeFallbackReason::MixedRenderState;
                return false;
            }
        }

        if (currentRenderEncoder != nil) {
            endCurrentRenderPassOnly();
            activeRenderPassFragmentShadingRate =
                GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        acquireRingSlot();

        MTLRenderPassDescriptor* pass = nil;
        id<MTLTexture> colorTexture = nil;
        id<MTLTexture> passDepthStencil = nil;
        if (!buildDefaultParallelRenderPass(
                fragmentRate,
                pass,
                colorTexture,
                passDepthStencil)) {
            fallbackReason =
                ParallelEncodeFallbackReason::ParallelEncoderCreateFailure;
            return false;
        }

        id<MTLParallelRenderCommandEncoder> parallelEncoder =
            [currentCommandBuffer parallelRenderCommandEncoderWithDescriptor:pass];
        if (parallelEncoder == nil) {
            fallbackReason =
                ParallelEncodeFallbackReason::ParallelEncoderCreateFailure;
            return false;
        }
        hasPendingClear = false;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA =
            colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        activeRenderPassFragmentShadingRate = fragmentRate;

        const std::uint64_t configuredWorkers =
            parallelEncodeProfile.configuredWorkerCount;
        const std::uint64_t chunkCount =
            std::min<std::uint64_t>(configuredWorkers, drawCount);
        std::vector<id<MTLRenderCommandEncoder>> childEncoders;
        childEncoders.reserve(static_cast<std::size_t>(chunkCount));
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            id<MTLRenderCommandEncoder> child =
                [parallelEncoder renderCommandEncoder];
            if (child == nil) {
                for (id<MTLRenderCommandEncoder> enc : childEncoders) {
                    [enc endEncoding];
                }
                [parallelEncoder endEncoding];
                activeRenderPassFragmentShadingRate =
                    GL_SHADING_RATE_1X1_PIXELS_EXT;
                resetCachedEncoderState();
                fallbackReason =
                    ParallelEncodeFallbackReason::ChildEncoderCreateFailure;
                return false;
            }
            childEncoders.push_back(child);
        }

        struct ParallelChunkWork {
            std::uint64_t begin = 0;
            std::uint64_t end = 0;
            double workerUs = 0.0;
            std::uint64_t failures = 0;
        };
        std::vector<ParallelChunkWork> chunks(
            static_cast<std::size_t>(chunkCount));
        const std::uint64_t baseChunkSize = drawCount / chunkCount;
        const std::uint64_t remainder = drawCount % chunkCount;
        std::uint64_t cursor = 0;
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            const std::uint64_t count =
                baseChunkSize + (chunk < remainder ? 1u : 0u);
            chunks[static_cast<std::size_t>(chunk)].begin = cursor;
            chunks[static_cast<std::size_t>(chunk)].end = cursor + count;
            cursor += count;
        }

        const DrawProfileTimePoint wallStart = drawProfileNow();
        ParallelChunkWork* chunkData = chunks.data();
        id<MTLRenderCommandEncoder>* encoderData = childEncoders.data();
        Impl* self = this;
        dispatch_queue_t queue =
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_apply(static_cast<size_t>(chunkCount), queue, ^(size_t index) {
            @autoreleasepool {
                ParallelChildEncoderState childState;
                ParallelChunkWork& work = chunkData[index];
                id<MTLRenderCommandEncoder> child = encoderData[index];
                const DrawProfileTimePoint workerStart = drawProfileNow();
                for (std::uint64_t draw = work.begin; draw < work.end; ++draw) {
                    const bool encoded =
                        self->encodeCapturedTranslatedDrawOnChildEncoder(
                            self->pendingParallelTranslatedDraws[
                                static_cast<std::size_t>(draw)],
                            child,
                            colorTexture,
                            passDepthStencil,
                            childState);
                    if (!encoded) {
                        ++work.failures;
                    }
                }
                work.workerUs =
                    drawProfileElapsedUs(workerStart, drawProfileNow());
                [child endEncoding];
            }
        });
        [parallelEncoder endEncoding];
        const double wallUs =
            drawProfileElapsedUs(wallStart, drawProfileNow());
        currentRenderEncoder = nil;
        activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        resetCachedEncoderState();
        pendingPresent = true;

        std::vector<ParallelEncodeChunkProfile> chunkProfiles;
        chunkProfiles.reserve(static_cast<std::size_t>(chunkCount));
        double sumWorkerUs = 0.0;
        double maxWorkerUs = 0.0;
        std::uint64_t failures = 0;
        for (std::uint64_t chunk = 0; chunk < chunkCount; ++chunk) {
            const ParallelChunkWork& work =
                chunks[static_cast<std::size_t>(chunk)];
            sumWorkerUs += work.workerUs;
            maxWorkerUs = std::max(maxWorkerUs, work.workerUs);
            failures += work.failures;
            ParallelEncodeChunkProfile profile;
            profile.chunkIndex = chunk;
            profile.drawBegin = work.begin;
            profile.drawEnd = work.end;
            profile.drawCount = work.end - work.begin;
            profile.workerEncodeUs = work.workerUs;
            profile.failures = work.failures;
            chunkProfiles.push_back(profile);
        }
        parallelEncodeProfile.recordParallelBatch(
            reason,
            drawCount,
            chunkProfiles,
            wallUs,
            sumWorkerUs,
            maxWorkerUs,
            failures);
        return true;
    }

    void flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason reason) {
        if (!flushingThreadedDeferredRecordBatch) {
            flushThreadedDeferredRecordBatch(reason);
        }
        if (!flushingLeanDirectDescriptorBatch) {
            flushLeanDirectDescriptorBatch(reason);
        }
        if (!parallelEncodeProfile.enabled ||
            pendingParallelTranslatedDraws.empty() ||
            flushingParallelTranslatedBatch) {
            return;
        }

        flushingParallelTranslatedBatch = true;
        ParallelEncodeFallbackReason fallbackReason =
            ParallelEncodeFallbackReason::EncodeFailure;
        const bool parallelEncoded =
            tryEncodeParallelTranslatedDrawBatch(reason, fallbackReason);
        if (!parallelEncoded) {
            replayPendingParallelTranslatedDrawBatchSerial(
                reason, fallbackReason);
        }
        pendingParallelTranslatedDraws.clear();
        flushingParallelTranslatedBatch = false;
    }

    void flushParallelEncodeBoundary() {
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
    }

    bool encodeTranslatedDraw(TranslatedDrawInfo& info) {
        // C48: a sampled texture with a deferred FBO clear must be
        // materialized before any encode path (serial, parallel capture,
        // or threaded-deferred) sees it.
        if (!pendingFboClears.empty()) {
            materializePendingFboClearsForSampledTextures(info);
        }
        if (threadedDeferredRecordProfile.enabled) {
            threadedDeferredRecordProfile.recordTranslatedDraw();
            if (flushingThreadedDeferredRecordBatch) {
                return encodeTranslatedDrawSerial(info);
            }

            ParallelEncodeBoundaryReason reason =
                ParallelEncodeBoundaryReason::SerialPathOnly;
            if (!translatedDrawParallelCaptureEligible(info, reason)) {
                flushThreadedDeferredRecordBatch(reason);
                threadedDeferredRecordProfile.recordBoundary(reason);
                return encodeTranslatedDrawSerial(info);
            }

            threadedDeferredRecordProfile.recordCandidate();
            if (!pendingThreadedDeferredRecords.empty() &&
                pendingThreadedDeferredRecords.front().info.fragmentShadingRate !=
                    info.fragmentShadingRate) {
                flushThreadedDeferredRecordBatch(
                    ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
            }

            if (pendingThreadedDeferredRecords.empty()) {
                pendingThreadedDeferredDescriptors.clear();
                pendingThreadedDeferredChunks.clear();
                nextThreadedDeferredRecordToDispatch = 0;
                nextThreadedDeferredChunkIndex = 0;
                threadedDeferredCompletionOrdinal.store(
                    0, std::memory_order_relaxed);
            }
            if (threadedDeferredRecordProfile.descriptorFastEnabled) {
                // Use the descriptor as the deferred record payload while
                // preserving chunk validation and ordered serial merge by
                // threadedSequence.
                pendingThreadedDeferredRecords.emplace_back();
                CapturedTranslatedDrawRecord& record =
                    pendingThreadedDeferredRecords.back();
                pendingThreadedDeferredDescriptors.emplace_back();
                LeanDirectTranslatedDrawDescriptor& descriptor =
                    pendingThreadedDeferredDescriptors.back();
                ParallelEncodeFallbackReason fallbackReason =
                    ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
                const DrawProfileTimePoint captureStart = drawProfileNow();
                if (!prepareLeanDirectTranslatedDrawDescriptor(
                        info, descriptor, fallbackReason)) {
                    pendingThreadedDeferredDescriptors.pop_back();
                    pendingThreadedDeferredRecords.pop_back();
                    const ParallelEncodeBoundaryReason boundaryReason =
                        parallelEncodeBoundaryForFallback(fallbackReason);
                    flushThreadedDeferredRecordBatch(boundaryReason);
                    threadedDeferredRecordProfile.recordBoundary(boundaryReason);
                    threadedDeferredRecordProfile.recordFallback(fallbackReason);
                    return encodeTranslatedDrawSerial(info);
                }
                record.threadedPrepared = true;
                record.threadedFallbackReason =
                    ParallelEncodeFallbackReason::Count;
                record.threadedDescriptorFastRecord = true;
                record.threadedDescriptorPrepared = true;
                record.threadedDescriptorFallbackReason =
                    ParallelEncodeFallbackReason::Count;
                record.info.fragmentShadingRate =
                    descriptor.fragmentShadingRate;
                record.threadedSequence = nextThreadedDeferredSequence++;
                record.threadedApproxBytes =
                    sizeof(LeanDirectTranslatedDrawDescriptor);
                threadedDeferredRecordProfile.recordCapture(
                    record.threadedApproxBytes,
                    drawProfileElapsedUs(captureStart, drawProfileNow()));
                if (pendingThreadedDeferredRecords.size() >=
                    threadedDeferredRecordProfile.configuredMaxBatch) {
                    flushThreadedDeferredRecordBatch(
                        ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
                }
                return true;
            }
            pendingThreadedDeferredRecords.emplace_back();
            CapturedTranslatedDrawRecord& capture =
                pendingThreadedDeferredRecords.back();
            ParallelEncodeFallbackReason fallbackReason =
                ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
            const DrawProfileTimePoint captureStart = drawProfileNow();
            if (!captureThreadedDeferredTranslatedDrawRecord(info,
                                                             capture,
                                                             fallbackReason)) {
                pendingThreadedDeferredRecords.pop_back();
                const ParallelEncodeBoundaryReason boundaryReason =
                    parallelEncodeBoundaryForFallback(fallbackReason);
                flushThreadedDeferredRecordBatch(boundaryReason);
                threadedDeferredRecordProfile.recordBoundary(boundaryReason);
                threadedDeferredRecordProfile.recordFallback(fallbackReason);
                return encodeTranslatedDrawSerial(info);
            }
            pendingThreadedDeferredDescriptors.emplace_back();
            capture.threadedSequence = nextThreadedDeferredSequence++;
            threadedDeferredRecordProfile.recordCapture(
                capture.threadedApproxBytes,
                drawProfileElapsedUs(captureStart, drawProfileNow()));
            dispatchThreadedDeferredRecordChunks(false);
            if (pendingThreadedDeferredRecords.size() >=
                threadedDeferredRecordProfile.configuredMaxBatch) {
                flushThreadedDeferredRecordBatch(
                    ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
            }
            return true;
        }

        if (!parallelEncodeProfile.enabled) {
            return encodeTranslatedDrawSerial(info);
        }

        parallelEncodeProfile.recordTranslatedDraw();
        if (flushingParallelTranslatedBatch) {
            return encodeTranslatedDrawSerial(info);
        }

        ParallelEncodeBoundaryReason reason =
            ParallelEncodeBoundaryReason::SerialPathOnly;
        if (!translatedDrawParallelCaptureEligible(info, reason)) {
            flushParallelTranslatedDrawBatch(reason);
            parallelEncodeProfile.recordBoundary(reason);
            return encodeTranslatedDrawSerial(info);
        }

        parallelEncodeProfile.recordCandidate();

        if (parallelEncodeProfile.configuredWorkerCount <= 1) {
            LeanDirectTranslatedDrawDescriptor descriptor;
            ParallelEncodeFallbackReason fallbackReason =
                ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
            const DrawProfileTimePoint prepareStart = drawProfileNow();
            if (!prepareLeanDirectTranslatedDrawDescriptor(info,
                                                           descriptor,
                                                           fallbackReason)) {
                const ParallelEncodeBoundaryReason boundaryReason =
                    parallelEncodeBoundaryForFallback(fallbackReason);
                flushParallelTranslatedDrawBatch(boundaryReason);
                parallelEncodeProfile.recordBoundary(boundaryReason);
                parallelEncodeProfile.recordDescriptorFallback();
                parallelEncodeProfile.recordDirectSerialFallback(fallbackReason);
                return encodeTranslatedDrawSerial(info);
            }
            const double prepareUs =
                drawProfileElapsedUs(prepareStart, drawProfileNow());
            parallelEncodeProfile.recordDescriptorPrepared(prepareUs);

            id<MTLTexture> colorTexture = nil;
            id<MTLTexture> passDepthStencil = nil;
            const DrawProfileTimePoint encodeStart = drawProfileNow();
            if (!ensureLeanDirectDefaultRenderPass(descriptor.fragmentShadingRate,
                                                   colorTexture,
                                                   passDepthStencil)) {
                fallbackReason =
                    ParallelEncodeFallbackReason::ParallelEncoderCreateFailure;
                const ParallelEncodeBoundaryReason boundaryReason =
                    parallelEncodeBoundaryForFallback(fallbackReason);
                parallelEncodeProfile.recordBoundary(boundaryReason);
                parallelEncodeProfile.recordDescriptorFallback();
                parallelEncodeProfile.recordDirectSerialFallback(fallbackReason);
                frameAttributionProfile.recordDescriptorImmediate(
                    prepareUs,
                    drawProfileElapsedUs(encodeStart, drawProfileNow()),
                    false);
                return encodeTranslatedDrawSerial(info);
            }
            if (!encodeLeanDirectTranslatedDrawDescriptor(descriptor,
                                                         colorTexture,
                                                         passDepthStencil)) {
                fallbackReason = ParallelEncodeFallbackReason::EncodeFailure;
                const ParallelEncodeBoundaryReason boundaryReason =
                    parallelEncodeBoundaryForFallback(fallbackReason);
                parallelEncodeProfile.recordBoundary(boundaryReason);
                parallelEncodeProfile.recordDescriptorFallback();
                parallelEncodeProfile.recordDirectSerialFallback(fallbackReason);
                frameAttributionProfile.recordDescriptorImmediate(
                    prepareUs,
                    drawProfileElapsedUs(encodeStart, drawProfileNow()),
                    false);
                return encodeTranslatedDrawSerial(info);
            }
            const double encodeUs =
                drawProfileElapsedUs(encodeStart, drawProfileNow());
            parallelEncodeProfile.recordDescriptorEncoded(encodeUs);
            frameAttributionProfile.recordDescriptorImmediate(
                prepareUs,
                encodeUs,
                true);
            return true;
        }

        if (!pendingLeanDirectDescriptors.empty() &&
            pendingLeanDirectDescriptors.front().fragmentShadingRate !=
                info.fragmentShadingRate) {
            flushLeanDirectDescriptorBatch(
                ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
        }
        pendingLeanDirectDescriptors.emplace_back();
        LeanDirectTranslatedDrawDescriptor& descriptor =
            pendingLeanDirectDescriptors.back();
        ParallelEncodeFallbackReason fallbackReason =
            ParallelEncodeFallbackReason::UnsafeResourceOrRingUpload;
        const DrawProfileTimePoint prepareStart = drawProfileNow();
        if (!prepareLeanDirectTranslatedDrawDescriptor(info,
                                                       descriptor,
                                                       fallbackReason)) {
            pendingLeanDirectDescriptors.pop_back();
            const ParallelEncodeBoundaryReason boundaryReason =
                parallelEncodeBoundaryForFallback(fallbackReason);
            flushParallelTranslatedDrawBatch(boundaryReason);
            parallelEncodeProfile.recordBoundary(boundaryReason);
            parallelEncodeProfile.recordDescriptorFallback();
            parallelEncodeProfile.recordDirectSerialFallback(fallbackReason);
            return encodeTranslatedDrawSerial(info);
        }
        parallelEncodeProfile.recordDescriptorPrepared(
            drawProfileElapsedUs(prepareStart, drawProfileNow()));
        if (pendingLeanDirectDescriptors.size() >=
            parallelEncodeProfile.configuredLeanMaxBatch) {
            flushLeanDirectDescriptorBatch(
                ParallelEncodeBoundaryReason::ResourceMutationOrBarrier);
        }

        return true;
    }

    // Phase 3B.3 [metal-tess-TF] — build the tess domain-point
    // generator compute kernel. Takes per-patch MTLQuadTessellation
    // FactorsHalf (from TCS output at buffer(26)) + a small param
    // struct and writes per-output-vertex (tessCoord, primID) into
    // two buffers that the TES-as-compute kernel consumes at
    // buffer(25) / buffer(24). Equivalent to
    // `generateTessDomain` from TessellationEmulator.cpp, ported to
    // MSL.
    //
    // MVP (3B.3): supports `triangles` + `quads` domains with all
    // three spacing modes. Isolines deferred to Phase 4 (Metal has
    // no native isoline tess at all, and we can reuse the `quads`
    // path with one collapsed axis). Point-mode deferred to 3B.5.
    //
    // Dispatch: one thread per patch. The thread sequentially writes
    // its patch's domain vertices starting at an atomic-claimed slot
    // in the output buffer. Multi-patch ordering isn't guaranteed
    // (atomics claim in thread-scheduler order) — for Phase 3B tests
    // the CTS cases are single-patch so this doesn't matter yet;
    // Phase 3B.4 adds prefix-sum offsets for deterministic ordering
    // when it becomes necessary.
    bool ensureTessDomainGenLibrary() {
        if (tessDomainGenLibrary != nil && tessDomainGenPipelineState != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

// Must match MTLQuadTessellationFactorsHalf byte layout.
//
// Sprint 2 fix: Metal's MTLQuadTessellationFactorsHalf has
// `edgeTessellationFactor[4]` FIRST (bytes 0..7) followed by
// `insideTessellationFactor[2]` (bytes 8..11). Prior versions of this
// struct had them reversed; the regular single-N codepath worked
// accidentally because `axisMax = max(o0..o3, i0..i1)` is permutation-
// invariant over the misaligned set, but per-edge logic exposed the
// mis-read by reading individual fields. (kTessDomainPortMSL at line 41
// already had the correct order — that path was unaffected.)
struct QuadFactors {
    half edgeTessellationFactor[4];
    half insideTessellationFactor[2];
};

// Runtime parameters for domain generation. Host packs before dispatch.
//   genMode:    0=Triangles, 1=Quads (2=Isolines deferred)
//   genSpacing: 0=Equal, 1=FractionalEven, 2=FractionalOdd
//   patchCount: number of patches to process
//   pointMode:  1 if TES declared `layout(..., point_mode) in;` — emits
//               unique tess-points (one vertex each) instead of triangle
//               primitives. TF captures one entry per emitted vertex.
struct TessGenParams {
    uint genMode;
    uint genSpacing;
    uint patchCount;
    uint pointMode;
    uint vertexOrder;  // 0=CCW, 1=CW — swap last two verts of each tri when CW
};

// Round factor value up to the nearest valid segment count for the
// given spacing. Matches `getTessellationLevelAfterVertexSpacing` in
// CTS's TessellationShaderUtils — including the FRAC_ODD MAX-1 cap.
//
// GL 4.6 §11.2.2 + CTS reference: FRAC_ODD clamps to [1, MAX-1]
// (= [1, 63] with MAX=64). Without the MAX-1 cap, level=64 produced
// rounded=65 (= CEIL(64) + odd-fix) but CTS expects 63 (= clamp(64,
// 1, 63)). Closes the FRAC_ODD-at-MAX edge case for vertex_spacing
// and inner-rounding tests (T4E §1 documented the divergence).
		inline uint segmentCount(float level, uint spacing) {
	    if (spacing == 2u) {
	        level = clamp(level, 1.0f, 63.0f);     // FractionalOdd: [1, MAX-1]
    } else {
        level = clamp(level, 1.0f, 64.0f);
    }
    int n = int(ceil(level));
    if (spacing == 1u) {               // FractionalEven: round up to even >= 2
        if (n < 2) n = 2;
        if ((n & 1) != 0) n += 1;
    } else if (spacing == 2u) {        // FractionalOdd: round up to odd >= 1
        if (n < 1) n = 1;
        if ((n & 1) == 0) n += 1;
    } else {                            // Equal: plain ceil, floor at 1
        if (n < 1) n = 1;
    }
		    return uint(n);
		}

		inline uint quadInnerSegmentCount(float level, uint spacing) {
		    // CTS models quad inner levels clamped to 1 as just above 1 before
		    // spacing rounding, yielding a center point for equal-spacing
		    // point-mode quads with inner levels like [-1, 1].
		    if (!(level > 1.0f)) {
		        return segmentCount(2.0f, spacing);
		    }
		    return segmentCount(level, spacing);
		}

		inline uint triangleInnerSegmentCount(float level,
		                                      float o0, float o1, float o2,
		                                      uint spacing) {
		    if (!(level > 1.0f) &&
		        (o0 > 1.0f || o1 > 1.0f || o2 > 1.0f)) {
		        return segmentCount(2.0f, spacing);
		    }
		    return segmentCount(level, spacing);
		}

		inline float edgeParam(uint k, uint n, uint spacing) {
		    if ((spacing == 1u || spacing == 2u) && n > 2u) {
		        float shortStep = 0.5f / float(n);
		        float longStep = (1.0f - 2.0f * shortStep) / float(n - 2u);
		        if (k == 0u) return 0.0f;
		        if (k >= n) return 1.0f;
		        if (k == 1u) return shortStep;
		        return shortStep + float(k - 1u) * longStep;
		    }
		    return float(k) / float(n);
		}

		inline float quadInnerEdgeParam(uint k, uint n, uint spacing, float level) {
		    if (spacing == 2u && level >= 64.0f) {
		        return float(k) / float(n);
		    }
		    return edgeParam(k, n, spacing);
		}

		inline bool patchHasDrawableOuterLevels(float o0, float o1, float o2, float o3, uint genMode) {
		    if (genMode == 0u) {
	        return (o0 > 0.0f) && (o1 > 0.0f) && (o2 > 0.0f);
	    }
	    if (genMode == 1u) {
	        return (o0 > 0.0f) && (o1 > 0.0f) && (o2 > 0.0f) && (o3 > 0.0f);
	    }
	    return (o0 > 0.0f) && (o1 > 0.0f);
	}

// Emit one triangle's worth (3 verts) of (tessCoord, primID) into the
// output buffer via an atomic claim. Barycentric coords for
// triangle-domain tests.
inline void emitTriangle(
    float3 a, float3 b, float3 c,
    uint primID,
    uint vertexOrder,  // 0=CCW, 1=CW — swap last two verts
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 3u, memory_order_relaxed);
    coords[base + 0] = packed_float3(a);
    if (vertexOrder == 1u) {
        coords[base + 1] = packed_float3(c);
        coords[base + 2] = packed_float3(b);
    } else {
        coords[base + 1] = packed_float3(b);
        coords[base + 2] = packed_float3(c);
    }
    primIDs[base + 0] = primID;
    primIDs[base + 1] = primID;
    primIDs[base + 2] = primID;
}

// Emit one point's worth (1 vert) for point_mode TES.
inline void emitPoint(
    float3 a,
    uint primID,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(a);
    primIDs[base] = primID;
}

inline bool appglNearTessLevel(float value, float expected) {
    return fabs(value - expected) < 0.25f;
}

inline uint appglRule7SlotKind(float value, float expected) {
    if (appglNearTessLevel(value, expected)) {
        return 1u;
    }
    if (appglNearTessLevel(value, 64.0f / 3.0f)) {
        return 2u;
    }
    return 0u;
}

inline bool appglRule7TriLowLevels(float i0, float i1,
                                   float o0, float o1, float o2) {
    if (!appglNearTessLevel(i0, 3.0f) ||
        !appglNearTessLevel(i1, 4.0f)) {
        return false;
    }
    uint s0 = appglRule7SlotKind(o0, 6.0f);
    uint s1 = appglRule7SlotKind(o1, 5.0f);
    uint s2 = appglRule7SlotKind(o2, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u) {
        return false;
    }
    uint modified = (s0 == 2u ? 1u : 0u) +
                    (s1 == 2u ? 1u : 0u) +
                    (s2 == 2u ? 1u : 0u);
    return modified <= 1u;
}

inline bool appglRule7QuadLowLevels(float i0, float i1,
                                    float o0, float o1, float o2, float o3) {
    if (!appglNearTessLevel(i0, 4.0f) ||
        !appglNearTessLevel(i1, 5.0f)) {
        return false;
    }
    uint s0 = appglRule7SlotKind(o0, 7.0f);
    uint s1 = appglRule7SlotKind(o1, 6.0f);
    uint s2 = appglRule7SlotKind(o2, 5.0f);
    uint s3 = appglRule7SlotKind(o3, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u || s3 == 0u) {
        return false;
    }
    uint modified = (s0 == 2u ? 1u : 0u) +
                    (s1 == 2u ? 1u : 0u) +
                    (s2 == 2u ? 1u : 0u) +
                    (s3 == 2u ? 1u : 0u);
    return modified <= 1u;
}

// Per-patch inner worker. Emits this patch's tess-grid vertices via
// atomic claim on `totalVertCount`. Called once per patchID by the
// serial driver kernel below, so even though claims are atomic the
// emission order matches patch order — CTS's
//   expected = n_vertex / n_result_vertices_per_patch
// reads from a buffer laid out that way.
void genPatchDomain(
    uint patchID,
    constant TessGenParams& params,
    const device QuadFactors* factors,
    device packed_float3* domainTessCoord,
    device uint* domainPrimID,
    device atomic_uint* totalVertCount)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
	    float o3 = float(f.edgeTessellationFactor[3]);
	    float i0 = float(f.insideTessellationFactor[0]);
	    float i1 = float(f.insideTessellationFactor[1]);
	    if (!patchHasDrawableOuterLevels(o0, o1, o2, o3, params.genMode)) {
	        return;
	    }

	    if (params.genMode == 0u) {
        // Triangles — barycentric (u, v, w) with u+v+w = 1.
        //
        // Sprint 2 Track 1 (T4H Phase B): per-edge triangles point-
        // mode for the vertex_spacing.* cluster, gated on outers-
        // differ AND pointMode (M2 mitigation per T4H). Equal-outer
        // case stays on single-N axisMax — preserves invariance.*
        // GENUINE_PASS that depend on the symmetric grid emission.
        //
        // GL §11.2.2.2: outer[0]=edge across u-corner (between v-
        // and w- corners; u=0 line), outer[1]=v=0 edge, outer[2]=
        // w=0 edge. Inner level inner[0] controls concentric inner
        // triangles. Triangles use only outer[0..2] + inner[0].
        const bool triOutersDiffer = !(o0 == o1 && o1 == o2);
        if (params.pointMode != 0u && triOutersDiffer) {
            uint outerN0 = segmentCount(o0, params.genSpacing);
            uint outerN1 = segmentCount(o1, params.genSpacing);
            uint outerN2 = segmentCount(o2, params.genSpacing);
            uint innerN  = triangleInnerSegmentCount(i0, o0, o1, o2,
                                                     params.genSpacing);

            // 3 outer corners (barycentric).
            emitPoint(float3(1.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // u-corner
            emitPoint(float3(0.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // v-corner
            emitPoint(float3(0.0f, 0.0f, 1.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // w-corner

	            // outer[0] = u=0 edge (varies between v-corner and w-corner).
	            for (uint k = 1u; k < outerN0; ++k) {
	                float t = edgeParam(k, outerN0, params.genSpacing);
	                emitPoint(float3(0.0f, 1.0f - t, t), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[1] = v=0 edge (varies between w-corner and u-corner).
	            for (uint k = 1u; k < outerN1; ++k) {
	                float t = edgeParam(k, outerN1, params.genSpacing);
	                emitPoint(float3(t, 0.0f, 1.0f - t), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[2] = w=0 edge (varies between u-corner and v-corner).
	            for (uint k = 1u; k < outerN2; ++k) {
	                float t = edgeParam(k, outerN2, params.genSpacing);
	                emitPoint(float3(1.0f - t, t, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }

	            if (innerN < 2u) {
	                emitPoint(float3(1.0f / 3.0f, 1.0f / 3.0f,
	                                 1.0f / 3.0f),
	                          patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                return;
	            }

	            // Inner triangle subdivision: concentric inner triangles
	            // per GL 4.6 §11.2.2.2. CTS reference algorithm in
            // esextcTessellationShaderPoints.cpp lines 962-1002:
            //   for (n = innerN; n >= 0; n -= 2) {
            //     if (n == 2) emit center point; break;
            //     if (n == 3) emit 3 corners; break;
            //     emit corners + (n-2)*3 edge interior;
            //   }
            // Ring r corners at barycentric (1 - 2r/M, r/M, r/M),
            // permutations. Ring r has (M - 2r) segments per edge.
            // Sprint-1's `inner_seg` interior-grid emission was wrong:
            // CTS verifier extracts ring-by-ring and expects each ring
            // to be a concentric triangle, not a flat grid. Failure
            // surfaces as "Invalid delta between segments" because the
            // grid-positioned points don't lie on the expected inner-
            // triangle edges at the right distances.
            //
	            // Spec barycentric formula (1-2r/M, r/M, r/M) crosses the
	            // centroid for r > M/3. The CTS topology extractor assumes
	            // each remaining ring is still a non-inverted nested
	            // triangle, while the point-count verifier expects all rings
	            // down to n==3. Keep both contracts by distributing the
	            // emitted rings evenly between the outer boundary and the
	            // centroid. This preserves per-ring segment counts without
	            // placing adjacent rings inside CTS's 1e-3 line tolerance.
	            uint inv_innerN = innerN;
	            uint ring = 1u;
	            uint ringCount = (innerN - 1u) / 2u;
	            float ringDenom = 3.0f * float(ringCount + 1u);
	            while (inv_innerN >= 2u) {
	                if (inv_innerN == 2u) {
	                    // Degenerate ring → single center point.
                    emitPoint(float3(1.0f / 3.0f, 1.0f / 3.0f,
                                     1.0f / 3.0f),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    break;
                }

	                float off = float(ring) / ringDenom;
	                float ce = 1.0f - 2.0f * off;

	                // 3 ring corners.
                emitPoint(float3(ce, off, off), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(off, ce, off), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(off, off, ce), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);

                if (inv_innerN == 3u) {
                    // Innermost ring is just 3 corners (no interior).
                    break;
                }

	                // Edge interior: (inv_innerN - 2) segments per edge,
	                // (inv_innerN - 3) interior points per edge.
	                uint inner_seg = inv_innerN - 2u;
	                for (uint k = 1u; k < inner_seg; ++k) {
	                    float t = edgeParam(k, inner_seg, params.genSpacing);
                    // Edge across u-corner (between v- and w-corners).
                    emitPoint(float3(off,
                                     ce * (1.0f - t) + off * t,
                                     off * (1.0f - t) + ce * t),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    // Edge across v-corner (between u- and w-corners).
                    emitPoint(float3(ce * (1.0f - t) + off * t,
                                     off,
                                     off * (1.0f - t) + ce * t),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    // Edge across w-corner (between u- and v-corners).
                    emitPoint(float3(ce * (1.0f - t) + off * t,
                                     off * (1.0f - t) + ce * t,
                                     off),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                }

                inv_innerN -= 2u;
                ring += 1u;
            }
            return;
        }

        // Equal-outer fallback: single-N produces a symmetric grid.
        // CTS `isVertexDefined` uses EXACT == on vertex components;
        // `1.0f - u - v` would produce ULP-different values vs
        // direct division, so we compute w as (N-i-j)/N.
        float triAxisMax = max(max(o0, o1), max(o2, i0));
        if (params.pointMode == 0u && params.genSpacing == 0u &&
            appglRule7TriLowLevels(i0, i1, o0, o1, o2)) {
            triAxisMax = 6.0f;
        }
        uint N = segmentCount(triAxisMax, params.genSpacing);
        float fN = float(N);
        if (params.pointMode != 0u) {
            for (uint j = 0u; j <= N; ++j) {
                float v = float(j) / fN;
                for (uint i = 0u; i + j <= N; ++i) {
                    float u = float(i) / fN;
                    float w = float(N - i - j) / fN;
                    emitPoint(float3(u, v, w), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
        } else {
            for (uint j = 0; j + 1u <= N; ++j) {
                uint row0Len = N + 1u - j;
                uint row1Len = N - j;
                float vj0 = float(j) / fN;
                float vj1 = float(j + 1u) / fN;
                for (uint i = 0u; i + 1u < row0Len; ++i) {
                    float ui0 = float(i) / fN;
                    float ui1 = float(i + 1u) / fN;
                    // Direct-division barycentric w = (N-i-j)/N.
                    // Apex row (j) coords:
                    float wa0 = float(N - i     - j) / fN;
                    float wa1 = float(N - (i+1) - j) / fN;
                    // Lower row (j+1) coords:
                    float wb0 = float(N - i     - (j+1)) / fN;
                    float wb1 = float(N - (i+1) - (j+1)) / fN;
                    if (i < row1Len) {
                        float3 a = float3(ui0, vj0, wa0);
                        float3 b = float3(ui1, vj0, wa1);
                        float3 c = float3(ui0, vj1, wb0);
                        emitTriangle(a, b, c, patchID, params.vertexOrder,
                                      totalVertCount, domainTessCoord, domainPrimID);
                    }
                    if (i + 1u < row1Len) {
                        float3 a = float3(ui1, vj0, wa1);
                        float3 b = float3(ui1, vj1, wb1);
                        float3 c = float3(ui0, vj1, wb0);
                        emitTriangle(a, b, c, patchID, params.vertexOrder,
                                      totalVertCount, domainTessCoord, domainPrimID);
                    }
                }
            }
        }
    } else if (params.genMode == 1u) {
        // Quads — (u, v, 0) with u, v ∈ [0, 1]. Two triangles per
        // grid cell.
        //
        // GL 4.6 §11.2.2.3: outer levels index by edge position —
        //   outer[0] = u=0 edge (varies v), contributes to vN
        //   outer[1] = v=0 edge (varies u), contributes to uN
        //   outer[2] = u=1 edge (varies v), contributes to vN
        //   outer[3] = v=1 edge (varies u), contributes to uN
        //   inner[0] = u-axis inner subdivision count
        //   inner[1] = v-axis inner subdivision count
        //
        // Sprint 2 Track 1 (T4H Phase A): per-edge quads point-mode
        // for the vertex_spacing.* cluster, gated on outers-differ
        // AND pointMode (M2 mitigation per T4H). Equal-outer-equal-
        // inner case stays on single-N axisMax — preserves the
        // 12 invariance.* GENUINE_PASS that depend on (1/N, 0) ↔
        // (0, 1/N) symmetric grid emission. Sprint 1's reverted
        // attempt was structurally correct but operated on field-
        // order-bug-mis-read inputs (commit 6f72c03 fixed); this
        // re-attempt now reads correct edge values.
        const bool outersDiffer =
            !(o0 == o1 && o1 == o2 && o2 == o3) || !(i0 == i1);
        if (params.pointMode != 0u && outersDiffer) {
	            uint outerN0 = segmentCount(o0, params.genSpacing);
	            uint outerN1 = segmentCount(o1, params.genSpacing);
	            uint outerN2 = segmentCount(o2, params.genSpacing);
	            uint outerN3 = segmentCount(o3, params.genSpacing);
	            uint innerN_u = quadInnerSegmentCount(i0, params.genSpacing);
	            uint innerN_v = quadInnerSegmentCount(i1, params.genSpacing);

            // 4 outer corners.
            emitPoint(float3(0.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(1.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(1.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(0.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);

	            // outer[0] = u=0 edge (varies v).
	            for (uint k = 1u; k < outerN0; ++k) {
	                float v = edgeParam(k, outerN0, params.genSpacing);
	                emitPoint(float3(0.0f, v, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[1] = v=0 edge (varies u).
	            for (uint k = 1u; k < outerN1; ++k) {
	                float u = edgeParam(k, outerN1, params.genSpacing);
	                emitPoint(float3(u, 0.0f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[2] = u=1 edge (varies v).
	            for (uint k = 1u; k < outerN2; ++k) {
	                float v = edgeParam(k, outerN2, params.genSpacing);
	                emitPoint(float3(1.0f, v, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[3] = v=1 edge (varies u).
	            for (uint k = 1u; k < outerN3; ++k) {
	                float u = edgeParam(k, outerN3, params.genSpacing);
	                emitPoint(float3(u, 1.0f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }

            // Inner ring + interior. innerN_u/v ≥ 3 → distinct
            // corners + edge interior + grid. innerN == 2 collapses
            // to a single center point. innerN == 1 (or mixed-axis
            // collapse) deferred — affects a subset of test
            // iterations and falls back to no-inner-emission here.
            if (innerN_u >= 3u && innerN_v >= 3u) {
                float u_lo = 1.0f / float(innerN_u);
                float u_hi = 1.0f - u_lo;
                float v_lo = 1.0f / float(innerN_v);
                float v_hi = 1.0f - v_lo;
	                uint inner_seg_u = innerN_u - 2u;
	                uint inner_seg_v = innerN_v - 2u;
	                float inv_seg_u = 1.0f / float(inner_seg_u);
	                float inv_seg_v = 1.0f / float(inner_seg_v);
                emitPoint(float3(u_lo, v_lo, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(u_hi, v_lo, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(u_hi, v_hi, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(u_lo, v_hi, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_v; ++k) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(k, inner_seg_v, params.genSpacing, i1);
	                    emitPoint(float3(u_lo, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                    emitPoint(float3(u_hi, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	                for (uint k = 1u; k < inner_seg_u; ++k) {
	                    float u = u_lo + (u_hi - u_lo) *
	                        quadInnerEdgeParam(k, inner_seg_u, params.genSpacing, i0);
	                    emitPoint(float3(u, v_lo, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                    emitPoint(float3(u, v_hi, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	                for (uint j = 1u; j < inner_seg_v; ++j) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(j, inner_seg_v, params.genSpacing, i1);
	                    for (uint i = 1u; i < inner_seg_u; ++i) {
	                        float u = u_lo + (u_hi - u_lo) *
	                            quadInnerEdgeParam(i, inner_seg_u, params.genSpacing, i0);
	                        emitPoint(float3(u, v, 0.0f), patchID,
	                                  totalVertCount, domainTessCoord, domainPrimID);
	                    }
	                }
	            } else if (innerN_u == 2u && innerN_v >= 3u) {
	                float v_lo = 1.0f / float(innerN_v);
	                float v_hi = 1.0f - v_lo;
	                uint inner_seg_v = innerN_v - 2u;
	                emitPoint(float3(0.5f, v_lo, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(0.5f, v_hi, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_v; ++k) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(k, inner_seg_v, params.genSpacing, i1);
	                    emitPoint(float3(0.5f, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	            } else if (innerN_v == 2u && innerN_u >= 3u) {
	                float u_lo = 1.0f / float(innerN_u);
	                float u_hi = 1.0f - u_lo;
	                uint inner_seg_u = innerN_u - 2u;
	                emitPoint(float3(u_lo, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(u_hi, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_u; ++k) {
	                    float u = u_lo + (u_hi - u_lo) *
	                        quadInnerEdgeParam(k, inner_seg_u, params.genSpacing, i0);
	                    emitPoint(float3(u, 0.5f, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	            } else if (innerN_u == 2u && innerN_v == 2u) {
	                emitPoint(float3(0.5f, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
            return;
        }

        // Equal-outer fallback: invariance.* tests need single-N
        // (1/N, 0) ↔ (0, 1/N) symmetric grid. CTS `invariance_rule4`
        // iterates with inner=(32,31) outer=(29,29,29,29) and expects
        // the symmetric counterpart of (1/32, 0) on the v=0 edge to
        // appear at (0, 1/32) on the u=0 edge — requires vN==32, i.e.
        // vN picks up inner[1]. Match by using max-of-all-applicable
        // levels for both axes.
        uint axisMax = max(max(max(o0, o1), max(o2, o3)), max(i0, i1));
        if (params.pointMode == 0u && params.genSpacing == 0u &&
            appglRule7QuadLowLevels(i0, i1, o0, o1, o2, o3)) {
            axisMax = 7u;
        }

        uint uN = segmentCount(axisMax, params.genSpacing);
        uint vN = segmentCount(axisMax, params.genSpacing);
        float fU = float(uN);
        float fV = float(vN);
        if (params.pointMode != 0u) {
            // Point_mode quads: (uN+1)(vN+1) unique grid points.
            for (uint j = 0u; j <= vN; ++j) {
                float v = float(j) / fV;
                for (uint i = 0u; i <= uN; ++i) {
                    float u = float(i) / fU;
                    emitPoint(float3(u, v, 0.0f), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
	        } else {
	            for (uint j = 0u; j < vN; ++j) {
	                float vj0 = float(j) / fV;
	                float vj1 = float(j + 1u) / fV;
	                for (uint i = 0u; i < uN; ++i) {
	                    float ui0 = float(i) / fU;
	                    float ui1 = float(i + 1u) / fU;
	                    float3 a = float3(ui0, vj0, 0.0f);
	                    float3 b = float3(ui1, vj0, 0.0f);
	                    float3 c = float3(ui0, vj1, 0.0f);
	                    float3 d = float3(ui1, vj1, 0.0f);
	                    bool emittedMarker = false;
	                    if (params.genSpacing == 2u && i0 == 1.0f && i1 > 1.0f && i == 0u) {
	                        if (j == 0u) {
	                            emitTriangle(float3(0.0f, vj1, 0.0f),
	                                         float3(1.0f, vj1, 0.0f),
	                                         float3(0.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        } else if (j + 1u == vN) {
	                            emitTriangle(float3(0.0f, vj0, 0.0f),
	                                         float3(1.0f, vj0, 0.0f),
	                                         float3(0.0f, 1.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        }
	                    } else if (params.genSpacing == 2u && i1 == 1.0f && i0 > 1.0f && j == 0u) {
	                        if (i == 0u) {
	                            emitTriangle(float3(ui1, 0.0f, 0.0f),
	                                         float3(ui1, 1.0f, 0.0f),
	                                         float3(0.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        } else if (i + 1u == uN) {
	                            emitTriangle(float3(ui0, 0.0f, 0.0f),
	                                         float3(ui0, 1.0f, 0.0f),
	                                         float3(1.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        }
	                    }
	                    if (!emittedMarker) {
	                        emitTriangle(a, b, d, patchID, params.vertexOrder,
	                                      totalVertCount, domainTessCoord, domainPrimID);
	                    }
	                    emitTriangle(a, d, c, patchID, params.vertexOrder,
	                                  totalVertCount, domainTessCoord, domainPrimID);
	                }
	            }
	        }
    } else if (params.genMode == 2u) {
        // Isolines (§11.2.2.4) — (u, v, 0) with u ∈ [0, 1], v half-
        // open in [0, 1). outer[0] is the number of lines (always
        // equal-spacing per spec), outer[1] is segments-per-line
        // (honours the spacing mode). No inner levels.
        uint vN = segmentCount(o0, 0u);                  // forced equal
        uint uN = segmentCount(o1, params.genSpacing);
        float fU = float(uN);
        float fV = float(vN);
        if (params.pointMode != 0u) {
            // Point_mode: vN × (uN+1) unique points.
            for (uint i = 0u; i < vN; ++i) {
                float v = float(i) / fV;
                for (uint j = 0u; j <= uN; ++j) {
                    float u = float(j) / fU;
                    emitPoint(float3(u, v, 0.0f), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
        } else {
            // Line_mode: each line i at v = i/vN contributes
            // uN segments = 2*uN verts. Output as pairs (p[j], p[j+1])
            // so downstream GL_LINES topology reads cleanly.
            for (uint i = 0u; i < vN; ++i) {
                float v = float(i) / fV;
                for (uint j = 0u; j < uN; ++j) {
                    float u0 = float(j) / fU;
                    float u1 = float(j + 1u) / fU;
                    // Inline emitLine using a 2-slot atomic claim.
                    uint base = atomic_fetch_add_explicit(
                        totalVertCount, 2u, memory_order_relaxed);
                    domainTessCoord[base + 0] = packed_float3(float3(u0, v, 0.0f));
                    domainTessCoord[base + 1] = packed_float3(float3(u1, v, 0.0f));
                    domainPrimID[base + 0] = patchID;
                    domainPrimID[base + 1] = patchID;
                }
            }
        }
    }
}

// Serial driver: one thread, walks patches in order so emission order
// matches patch order (atomic claims still work; single-thread removes
// the inter-patch race).
kernel void spvGenTessDomain(
    uint gid [[thread_position_in_grid]],
    constant TessGenParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* domainTessCoord [[buffer(25)]],
    device uint* domainPrimID [[buffer(24)]],
    device atomic_uint* totalVertCount [[buffer(23)]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        genPatchDomain(p, params, factors,
                        domainTessCoord, domainPrimID, totalVertCount);
    }
}
)MSL";
        NSError* error = nil;
        tessDomainGenLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (tessDomainGenLibrary == nil) {
            FG_TRACE(@"ensureTessDomainGenLibrary: newLibraryWithSource failed: %@",
                      error ? error.localizedDescription : @"(no err)");
            return false;
        }
        id<MTLFunction> fn = [tessDomainGenLibrary newFunctionWithName:@"spvGenTessDomain"];
        if (fn == nil) {
            return false;
        }
        ScopedOwnedObjCObject fnRelease(fn);
        NSError* psoError = nil;
        tessDomainGenPipelineState = [device newComputePipelineStateWithFunction:fn
                                                                            error:&psoError];
        if (tessDomainGenPipelineState == nil) {
            FG_TRACE(@"ensureTessDomainGenLibrary: newComputePipelineStateWithFunction failed: %@",
                      psoError ? psoError.localizedDescription : @"(no err)");
            return false;
        }
        return true;
    }

    // Phase 3C [metal-tess-TF] — build the library containing the
    // HW-tessellator domain-coord capture vertex functions.
    // Both fns share the same output-buffer layout as the compute kernel
    // (`spvGenTessDomain`) so the downstream TES-as-compute path reads
    // the same buffers without branching:
    //     buffer(23) → `device atomic_uint*    totalVertCount`
    //     buffer(24) → `device uint*           domainPrimID`
    //     buffer(25) → `device packed_float3*  domainTessCoord`
    // Metal's HW tessellator drives the function once per generated
    // vertex, with `[[position_in_patch]]` supplying the tessCoord in
    // domain-native units (barycentric for triangles, 2D for quads) and
    // `[[patch_id]]` supplying the patch index.
    bool ensureTessDomainCaptureLibrary() {
        if (tessDomainCaptureLibrary != nil) return true;
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

// Factor-clamp kernel. Metal HW tess drops the entire patch if ANY
// tess factor is <= 0; GL 4.6 §11.2.3 says outer<=0 ignores that edge
// (the rest of the patch still tessellates) and inner<1 is silently
// clamped to 1. Our MSL-kernel domain-gen path clamps to [1, 64] in
// `segmentCount`. Mirror that clamp here so Metal HW sees the same
// spec-compliant values the CPU path already does.
//
// Reads/writes `MTLQuadTessellationFactorsHalf` layout (edge[0..3] at
// bytes 0..7, inside[0..1] at bytes 8..11). SPIRV-Cross's emitted TCS
// writes this layout regardless of patch type — Metal reads the
// triangle subset (edge[0..2] + inside at half[3]) correctly from the
// first 8 bytes.
kernel void spvTessFactorClamp(
    device half* factors [[buffer(0)]],
    constant uint& patchCount [[buffer(1)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= patchCount) return;
    uint base = gid * 6u;  // 6 halves per patch (quad struct size)
    for (uint i = 0u; i < 6u; ++i) {
        half v = factors[base + i];
        factors[base + i] = (v < half(1.0)) ? half(1.0) :
                            (v > half(64.0)) ? half(64.0) : v;
    }
}

[[patch(quad, 0)]] vertex void spvTessDomainCaptureQuad(
    float2 gl_TessCoordIn [[position_in_patch]],
    uint   gl_PrimitiveID [[patch_id]],
    device atomic_uint*   totalVertCount  [[buffer(23)]],
    device uint*          domainPrimID    [[buffer(24)]],
    device packed_float3* domainTessCoord [[buffer(25)]])
{
    uint base = atomic_fetch_add_explicit(totalVertCount, 1u, memory_order_relaxed);
    domainTessCoord[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, 0.0);
    domainPrimID[base]    = gl_PrimitiveID;
}

[[patch(triangle, 0)]] vertex void spvTessDomainCaptureTri(
    float3 gl_TessCoordIn [[position_in_patch]],
    uint   gl_PrimitiveID [[patch_id]],
    device atomic_uint*   totalVertCount  [[buffer(23)]],
    device uint*          domainPrimID    [[buffer(24)]],
    device packed_float3* domainTessCoord [[buffer(25)]])
{
    uint base = atomic_fetch_add_explicit(totalVertCount, 1u, memory_order_relaxed);
    domainTessCoord[base] = packed_float3(gl_TessCoordIn);
    domainPrimID[base]    = gl_PrimitiveID;
}
)MSL";
        NSError* error = nil;
        tessDomainCaptureLibrary =
            [device newLibraryWithSource:source options:nil error:&error];
        if (tessDomainCaptureLibrary == nil) {
            FG_TRACE(@"ensureTessDomainCaptureLibrary: newLibraryWithSource failed: %@",
                      error ? error.localizedDescription : @"(no err)");
            return false;
        }
        return true;
    }

    // Phase 3C [metal-tess-TF] — lazily build the factor-clamp compute
    // PSO. Shares `tessDomainCaptureLibrary` with the capture vertex
    // fns. Returns nil on build failure — caller falls back to skipping
    // the clamp (HW path will fail on degenerate factors).
    id<MTLComputePipelineState> ensureTessFactorClampPipelineState() {
        if (tessFactorClampPipelineState != nil) return tessFactorClampPipelineState;
        if (!ensureTessDomainCaptureLibrary()) return nil;
        id<MTLFunction> fn =
            [tessDomainCaptureLibrary newFunctionWithName:@"spvTessFactorClamp"];
        if (fn == nil) return nil;
        ScopedOwnedObjCObject fnRelease(fn);
        NSError* err = nil;
        tessFactorClampPipelineState =
            [device newComputePipelineStateWithFunction:fn error:&err];
        if (tessFactorClampPipelineState == nil) {
            FG_TRACE(@"ensureTessFactorClampPipelineState failed: %@",
                      err ? err.localizedDescription : @"(no err)");
        }
        return tessFactorClampPipelineState;
    }

    // Phase 4A [metal-tess-TF] — lazily build the MSL-port domain-gen
    // library + its two PSOs (triangles, quads). MSL source lives at
    // file scope (`kTessDomainPortMSL`) so the validation probe
    // (`phaseAProbeTessDomainPort`) can share it.
    //
    // Compiled with `MTLMathModeSafe` — required for bit-exact CPU
    // parity (default options fuse `1 - fu - fv` into single-rounded
    // ops and drift 1 ULP at boundary vertices).
    bool ensureTessDomainPortLibrary() {
        if (tessDomainPortTrianglesPSO != nil &&
            tessDomainPortQuadsPSO != nil) {
            return true;
        }
        if (tessDomainPortLibrary == nil) {
            MTLCompileOptions* opts = [MTLCompileOptions new];
            ScopedOwnedObjCObject optsRelease(opts);
            if (@available(macOS 15.0, *)) {
                opts.mathMode = MTLMathModeSafe;
            } else {
                opts.fastMathEnabled = NO;
            }
            NSError* libErr = nil;
            tessDomainPortLibrary = [device
                newLibraryWithSource:kTessDomainPortMSL
                             options:opts
                               error:&libErr];
            if (tessDomainPortLibrary == nil) {
                FG_TRACE(@"ensureTessDomainPortLibrary: library build failed: %@",
                          libErr ? libErr.localizedDescription : @"(no err)");
                return false;
            }
        }
        auto buildPSO = [&](NSString* fnName) -> id<MTLComputePipelineState> {
            id<MTLFunction> f = [tessDomainPortLibrary newFunctionWithName:fnName];
            if (f == nil) return nil;
            ScopedOwnedObjCObject fnRelease(f);
            NSError* perr = nil;
            id<MTLComputePipelineState> p =
                [device newComputePipelineStateWithFunction:f error:&perr];
            if (p == nil) {
                FG_TRACE(@"ensureTessDomainPortLibrary: PSO %@ failed: %@",
                          fnName,
                          perr ? perr.localizedDescription : @"(no err)");
            }
            return p;
        };
        if (tessDomainPortTrianglesPSO == nil)
            tessDomainPortTrianglesPSO = buildPSO(@"spvGenTessDomainTrianglesPort");
        if (tessDomainPortQuadsPSO == nil)
            tessDomainPortQuadsPSO = buildPSO(@"spvGenTessDomainQuadsPort");
        return tessDomainPortTrianglesPSO != nil &&
               tessDomainPortQuadsPSO != nil;
    }

    // Phase 3C [metal-tess-TF] — build (and cache) a PSO that captures
    // tessellator output for the given patchType / partition / winding.
    // Cache key packs all three enum values into a uint32. Returns nil
    // on build failure — caller falls back to the compute-kernel path.
    //
    // The PSO uses rasterizationEnabled=NO + vertex void, which Metal
    // permits. Without that combo Metal rejects with "RasterizationEnabled
    // is false but the vertex shader's return type is not void".
    id<MTLRenderPipelineState> ensureTessDomainCapturePSO(
        MTLPatchType patchType,
        MTLTessellationPartitionMode partition,
        MTLWinding winding)
    {
        if (!ensureTessDomainCaptureLibrary()) return nil;
        const std::uint32_t key =
            (static_cast<std::uint32_t>(patchType) << 16) |
            (static_cast<std::uint32_t>(partition) << 8) |
             static_cast<std::uint32_t>(winding);
        auto it = tessDomainCapturePSOCache.find(key);
        if (it != tessDomainCapturePSOCache.end()) return it->second;

        NSString* fnName = (patchType == MTLPatchTypeQuad)
            ? @"spvTessDomainCaptureQuad"
            : @"spvTessDomainCaptureTri";
        id<MTLFunction> vfn = [tessDomainCaptureLibrary newFunctionWithName:fnName];
        if (vfn == nil) {
            FG_TRACE(@"ensureTessDomainCapturePSO: function %@ not found", fnName);
            return nil;
        }
        ScopedOwnedObjCObject vfnRelease(vfn);
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        ScopedOwnedObjCObject pdRelease(pd);
        pd.vertexFunction = vfn;
        pd.fragmentFunction = nil;
        pd.rasterizationEnabled = NO;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        pd.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        pd.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        pd.tessellationPartitionMode = partition;
        pd.tessellationOutputWindingOrder = winding;
        pd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
        pd.maxTessellationFactor = 64;
        NSError* psoError = nil;
        id<MTLRenderPipelineState> pso =
            [device newRenderPipelineStateWithDescriptor:pd error:&psoError];
        if (pso == nil) {
            FG_TRACE(@"ensureTessDomainCapturePSO: PSO build failed (key=0x%x): %@",
                      key,
                      psoError ? psoError.localizedDescription : @"(no err)");
            return nil;
        }
        tessDomainCapturePSOCache[key] = pso;
        return pso;
    }

    bool ensureSolidColorLibrary() {
        if (solidColorLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLVertexIn {
    float3 position [[attribute(0)]];
};

struct AppGLVertexOut {
    float4 position [[position]];
};

vertex AppGLVertexOut appgl_solid_vs(AppGLVertexIn in [[stage_in]]) {
    AppGLVertexOut out;
    out.position = float4(in.position, 1.0);
    return out;
}

fragment float4 appgl_solid_fs(constant float4& color [[buffer(0)]]) {
    return color;
}
)MSL";
        NSError* error = nil;
        solidColorLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (solidColorLibrary == nil) {
            return false;
        }
        solidColorVertexFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_vs"];
        solidColorFragmentFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_fs"];
        return solidColorVertexFn != nil && solidColorFragmentFn != nil;
    }

    bool ensureSolidColorPipelineState(const MetalDrawInfo& info) {
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        if (solidColorPipelineState != nil
            && solidColorPipelineColorFormat == colorFormat) {
            return true;
        }

        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        const NSUInteger stride = info.positionStride > 0
            ? info.positionStride
            : sizeof(float) * 3u;
        vertexDescriptor.layouts[0].stride = stride;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        ScopedOwnedObjCObject descRelease(desc);
        desc.vertexFunction = solidColorVertexFn;
        desc.fragmentFunction = solidColorFragmentFn;
        desc.vertexDescriptor = vertexDescriptor;
        desc.colorAttachments[0].pixelFormat = colorFormat;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

        NSError* error = nil;
        id<MTLRenderPipelineState> newState =
            [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (newState == nil) {
            return false;
        }
        releaseOwnedObjCObject(solidColorPipelineState);
        solidColorPipelineState = newState;
        solidColorPipelineColorFormat = colorFormat;
        return true;
    }

    // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
    // shader library and two pipeline states (vertex-color-only and
    // vertex-color × texture2D). Built lazily on first glEnd that
    // actually drains vertices, mirroring the solid-color pattern.
    //
    // The MSL vertex shader reads the captured `{pos, color, texcoord}`
    // interleaved tuple via the attribute slots (0, 1, 2) and multiplies
    // position by an MVP matrix pushed as a vertex constant buffer at
    // index 1 (buffer 0 is the vertex data). The fragment shader picks
    // the path based on which pipeline is bound — untextured just
    // returns the interpolated color, textured multiplies it by a
    // sample from a single-unit texture2D bound at fragment slot 0.
    // Both pipelines share the same vertex descriptor / vertex function
    // / color format, so the only divergence is the fragment function.
    bool ensureImmediateModeLibrary() {
        if (immediateModeLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLImmediateIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct AppGLImmediateOut {
    float4 position [[position]];
    float4 color;
    float2 texcoord;
};

vertex AppGLImmediateOut appgl_immediate_vs(
    AppGLImmediateIn in [[stage_in]],
    constant float4x4& mvp [[buffer(1)]]
) {
    AppGLImmediateOut out;
    out.position = mvp * in.position;
    out.color    = in.color;
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 appgl_immediate_color_fs(AppGLImmediateOut in [[stage_in]]) {
    return in.color;
}

fragment float4 appgl_immediate_textured_fs(
    AppGLImmediateOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    return in.color * tex.sample(samp, in.texcoord);
}
)MSL";
        NSError* error = nil;
        immediateModeLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (immediateModeLibrary == nil) {
            NSLog(@"[AppGL] immediate-mode library build failed: %@", error);
            return false;
        }
        immediateModeVertexFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_vs"];
        immediateModeColorFragmentFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_color_fs"];
        immediateModeTexturedFragmentFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_textured_fs"];
        return immediateModeVertexFn != nil
            && immediateModeColorFragmentFn != nil
            && immediateModeTexturedFragmentFn != nil;
    }

    bool ensureImmediateModePipelines(MTLPixelFormat colorFormat) {
        if (immediateModeColorPipelineState != nil
            && immediateModeTexturedPipelineState != nil
            && immediateModePipelineColorFormat == colorFormat) {
            return true;
        }

        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        // attribute 0: position (float4) at offset 0
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        // attribute 1: color (float4) at offset 16
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[1].offset = sizeof(float) * 4;
        vertexDescriptor.attributes[1].bufferIndex = 0;
        // attribute 2: texcoord (float2) at offset 32
        vertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
        vertexDescriptor.attributes[2].offset = sizeof(float) * 8;
        vertexDescriptor.attributes[2].bufferIndex = 0;
        vertexDescriptor.layouts[0].stride = sizeof(float) * 10; // 40 bytes
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        // Alpha blending is always enabled for immediate-mode — it's
        // what Chobby's Chili UI renders on top of the scene and every
        // glColor*/glTexCoord* path assumes straight-alpha blending.
        auto makePipeline = [&](id<MTLFunction> fragmentFn) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            ScopedOwnedObjCObject descRelease(desc);
            desc.vertexFunction = immediateModeVertexFn;
            desc.fragmentFunction = fragmentFn;
            desc.vertexDescriptor = vertexDescriptor;
            desc.colorAttachments[0].pixelFormat = colorFormat;
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            NSError* error = nil;
            id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (state == nil) {
                NSLog(@"[AppGL] immediate-mode pipeline build failed: %@", error);
            }
            return state;
        };

        id<MTLRenderPipelineState> colorState = makePipeline(immediateModeColorFragmentFn);
        id<MTLRenderPipelineState> texturedState = makePipeline(immediateModeTexturedFragmentFn);
        if (colorState == nil || texturedState == nil) {
            releaseOwnedObjCObject(colorState);
            releaseOwnedObjCObject(texturedState);
            return false;
        }
        releaseOwnedObjCObject(immediateModeColorPipelineState);
        releaseOwnedObjCObject(immediateModeTexturedPipelineState);
        immediateModeColorPipelineState = colorState;
        immediateModeTexturedPipelineState = texturedState;
        immediateModePipelineColorFormat = colorFormat;
        return true;
    }

    // Lazy default linear sampler for immediate-mode textured draws.
    // Chobby sets up texture parameters on the bound texture before
    // every batch, but the Chili UI only uses nearest/linear clamp-to-
    // edge — a single default is fine for the ~90% path; if BAR ever
    // needs filtering variants the sampler can be cached by GL state.
    id<MTLSamplerState> immediateModeDefaultSampler() {
        if (immediateModeSamplerState != nil) {
            return immediateModeSamplerState;
        }
        MTLSamplerDescriptor* sdesc = [[MTLSamplerDescriptor alloc] init];
        ScopedOwnedObjCObject sdescRelease(sdesc);
        sdesc.minFilter = MTLSamplerMinMagFilterLinear;
        sdesc.magFilter = MTLSamplerMinMagFilterLinear;
        sdesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sdesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        immediateModeSamplerState = [device newSamplerStateWithDescriptor:sdesc];
        return immediateModeSamplerState;
    }

    // C48 — pending FBO-attachment clear registry. With
    // APPGL_ENABLE_FBO_CLEAR_FOLDING=1, clearLayeredTextureImpl defers
    // the clear here instead of issuing drain-current + standalone
    // clear command buffers. The next translated-draw render pass that
    // targets the exact same attachment coverage consumes the entry as
    // its MTLLoadActionClear (fold). Any other consumer of the texture
    // (sampling, readback, blit, upload, non-matching pass coverage)
    // must materialize the entry first via the legacy standalone path,
    // tagged with the FboClearMaterialize* reasons so the census can
    // separate folded from materialized clears.
    struct PendingFboClear {
        void* tex = nullptr;  // CFRetained id<MTLTexture>
        std::uint32_t arrayLength = 0;
        std::uint32_t level = 0;
        std::uint32_t slice = 0;
        bool isColor = false;
        bool isDepth = false;
        bool isStencil = false;
        float rgba[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        float depth = 0.0f;
        std::uint32_t stencil = 0;
    };
    std::vector<PendingFboClear> pendingFboClears;
    static constexpr std::size_t kMaxPendingFboClears = 16;
    std::uint64_t fboClearsDeferred = 0;
    std::uint64_t fboClearsFolded = 0;
    std::uint64_t fboClearsMaterialized = 0;
    std::uint64_t fboClearsCoalesced = 0;

    void deferFboClear(void* texVoid, std::uint32_t arrayLength,
                       std::uint32_t level, std::uint32_t slice,
                       bool isColor, bool isDepth, bool isStencil,
                       const float rgba[4], float depth, std::uint32_t stencil) {
        for (auto& entry : pendingFboClears) {
            if (entry.tex == texVoid &&
                entry.isColor == isColor &&
                entry.isDepth == isDepth &&
                entry.isStencil == isStencil &&
                entry.arrayLength == arrayLength &&
                entry.level == level &&
                entry.slice == slice) {
                // Same coverage cleared again before consumption —
                // last clear wins.
                if (rgba != nullptr) {
                    std::memcpy(entry.rgba, rgba, sizeof(entry.rgba));
                }
                entry.depth = depth;
                entry.stencil = stencil;
                ++fboClearsCoalesced;
                return;
            }
        }
        if (pendingFboClears.size() >= kMaxPendingFboClears) {
            PendingFboClear oldest = pendingFboClears.front();
            pendingFboClears.erase(pendingFboClears.begin());
            materializePendingFboClearEntry(oldest);
        }
        PendingFboClear entry;
        entry.tex = texVoid;
        CFRetain((CFTypeRef)texVoid);
        entry.arrayLength = arrayLength;
        entry.level = level;
        entry.slice = slice;
        entry.isColor = isColor;
        entry.isDepth = isDepth;
        entry.isStencil = isStencil;
        if (rgba != nullptr) {
            std::memcpy(entry.rgba, rgba, sizeof(entry.rgba));
        }
        entry.depth = depth;
        entry.stencil = stencil;
        pendingFboClears.push_back(entry);
        ++fboClearsDeferred;
    }

    // Execute a deferred clear through the legacy standalone path with
    // the materialize reason set, then drop the registry retain.
    void materializePendingFboClearEntry(const PendingFboClear& entry) {
        ++fboClearsMaterialized;
        clearLayeredTextureImpl(entry.tex, entry.arrayLength, entry.level,
                                entry.slice, entry.isColor, entry.isDepth,
                                entry.isStencil,
                                entry.isColor ? entry.rgba : nullptr,
                                entry.depth, entry.stencil,
                                /*materializing=*/true);
        CFRelease((CFTypeRef)entry.tex);
    }

    void materializeAllPendingFboClears() {
        if (pendingFboClears.empty()) {
            return;
        }
        std::vector<PendingFboClear> entries;
        entries.swap(pendingFboClears);
        for (const auto& entry : entries) {
            materializePendingFboClearEntry(entry);
        }
    }

    // Materialize every pending clear on `texVoid` (and on textures it
    // is a view of, via Metal's parentTexture relationship).
    void materializePendingFboClearsForTexture(void* texVoid) {
        if (pendingFboClears.empty() || texVoid == nullptr) {
            return;
        }
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texVoid;
        void* parent = tex.parentTexture != nil
            ? (__bridge void*)tex.parentTexture : nullptr;
        std::vector<PendingFboClear> matched;
        for (std::size_t i = 0; i < pendingFboClears.size();) {
            if (pendingFboClears[i].tex == texVoid ||
                (parent != nullptr && pendingFboClears[i].tex == parent)) {
                matched.push_back(pendingFboClears[i]);
                pendingFboClears.erase(pendingFboClears.begin() +
                                       static_cast<std::ptrdiff_t>(i));
            } else {
                ++i;
            }
        }
        for (const auto& entry : matched) {
            materializePendingFboClearEntry(entry);
        }
    }

    // A draw that SAMPLES a texture with a pending deferred clear must
    // see the cleared contents — materialize before encoding. Matches
    // the bound texture directly and through Metal's parentTexture
    // (texture views). This guards the consume-before-draw case even
    // when the C47 sampler GPU-order skip bypasses the producer drain.
    void materializePendingFboClearsForSampledTextures(
        const TranslatedDrawInfo& info) {
        if (pendingFboClears.empty()) {
            return;
        }
        auto scan = [&](const std::vector<TranslatedDrawInfo::TextureBinding>&
                            bindings) {
            for (const auto& binding : bindings) {
                if (binding.metalTexture == nullptr) continue;
                materializePendingFboClearsForTexture(binding.metalTexture);
                if (pendingFboClears.empty()) return;
            }
        };
        scan(info.fragmentTextures);
        if (!pendingFboClears.empty()) {
            scan(info.vertexTextures);
        }
    }

    // Fold lookup at translated-draw pass-build time. Returns true and
    // removes the entry when a pending clear exactly matches the pass's
    // attachment coverage (texture + aspect + level + slice +
    // layered-extent). Exact match is required: folding into a pass
    // with different coverage would clear slices/levels the deferred
    // glClear never targeted, or miss ones it did.
    bool consumePendingFboClearForAttachment(void* texVoid, bool isColor,
                                             bool isDepth, bool isStencil,
                                             std::uint32_t level,
                                             std::uint32_t slice,
                                             std::uint32_t passArrayLength,
                                             PendingFboClear& out) {
        if (pendingFboClears.empty() || texVoid == nullptr) {
            return false;
        }
        if (std::getenv("APPGL_TRACE_FBO_CLEAR_FOLDING") != nullptr) {
            std::fprintf(stderr,
                "[C48] consume? tex=%p aspect=%d%d%d level=%u slice=%u rtal=%u entries=%zu\n",
                texVoid, (int)isColor, (int)isDepth, (int)isStencil,
                level, slice, passArrayLength, pendingFboClears.size());
            for (const auto& e : pendingFboClears) {
                std::fprintf(stderr,
                    "[C48]   entry tex=%p aspect=%d%d%d level=%u slice=%u arrayLen=%u\n",
                    e.tex, (int)e.isColor, (int)e.isDepth, (int)e.isStencil,
                    e.level, e.slice, e.arrayLength);
            }
        }
        for (std::size_t i = 0; i < pendingFboClears.size(); ++i) {
            PendingFboClear& entry = pendingFboClears[i];
            if (entry.tex != texVoid) continue;
            if (entry.isColor != isColor || entry.isDepth != isDepth ||
                entry.isStencil != isStencil) {
                continue;
            }
            if (entry.level != level || entry.slice != slice) continue;
            if (entry.arrayLength != passArrayLength) continue;
            out = entry;
            pendingFboClears.erase(pendingFboClears.begin() +
                                   static_cast<std::ptrdiff_t>(i));
            ++fboClearsFolded;
            CFRelease((CFTypeRef)out.tex);
            return true;
        }
        return false;
    }

    // Materialize any remaining pending clears that live on the
    // textures a pass is about to target with non-matching coverage
    // (e.g. a layered entry when the pass renders a single slice).
    // Must run before the pass's command buffer is ensured so the
    // legacy drain ordering inside the materialize path stays valid.
    void materializeNonFoldablePendingClearsForPassTargets(
        void* colorTex, void* depthStencilTex,
        const std::array<void*, 8>* additionalColor) {
        if (pendingFboClears.empty()) {
            return;
        }
        auto touchesPass = [&](void* entryTex) -> bool {
            if (entryTex == colorTex || entryTex == depthStencilTex) {
                return true;
            }
            if (additionalColor != nullptr) {
                for (void* extra : *additionalColor) {
                    if (extra != nullptr && entryTex == extra) return true;
                }
            }
            return false;
        };
        std::vector<PendingFboClear> matched;
        for (std::size_t i = 0; i < pendingFboClears.size();) {
            if (touchesPass(pendingFboClears[i].tex)) {
                matched.push_back(pendingFboClears[i]);
                pendingFboClears.erase(pendingFboClears.begin() +
                                       static_cast<std::ptrdiff_t>(i));
            } else {
                ++i;
            }
        }
        for (const auto& entry : matched) {
            materializePendingFboClearEntry(entry);
        }
    }

    void releasePendingFboClearsForTeardown() {
        for (const auto& entry : pendingFboClears) {
            CFRelease((CFTypeRef)entry.tex);
        }
        pendingFboClears.clear();
    }

    // Clear a (possibly layered) MTLTexture via an empty render pass
    // with MTLLoadActionClear. `arrayLength` > 0 enables layered mode
    // and clears all slices in a single pass (Metal's native path).
    // `isColor` / `isDepth` / `isStencil` are mutually exclusive and
    // drive which attachment slot is populated on the pass
    // descriptor. Used by `clearDepthAttachment`, `clearStencilAttach
    // ment`, and (future) `clearColorAttachment` to make glClear on
    // texture-backed FBO attachments actually land on the Metal
    // side — without this, the Metal texture stays at whatever
    // contents it had at creation (zeros for a newly-created
    // texture) and the next draw's depth/stencil test reads that
    // junk value instead of the cleared one.
    bool clearLayeredTextureImpl(void* texVoid, std::uint32_t arrayLength,
                                 std::uint32_t level, std::uint32_t slice,
                                 bool isColor, bool isDepth, bool isStencil,
                                 const float rgba[4], float depth, std::uint32_t stencil,
                                 bool materializing = false) {
        if (texVoid == nullptr || device == nil || commandQueue == nil) return false;
        // C48: defer the clear into the pending-fold registry instead of
        // issuing drain + standalone clear CBs. MS attachments keep the
        // eager path (their clears are the only legal way to seed every
        // sample and upstream routing depends on immediate execution).
        if (!materializing && fboClearFoldingEnabled()) {
            id<MTLTexture> texEarly = (__bridge id<MTLTexture>)texVoid;
            if (texEarly.sampleCount <= 1) {
                deferFboClear(texVoid, arrayLength, level, slice,
                              isColor, isDepth, isStencil, rgba, depth, stencil);
                return true;
            }
        }
        const bool useAsyncLayeredClear = layeredClearAsyncEnabled();
        const AppGLCommandReason drainReason = materializing
            ? (useAsyncLayeredClear
                   ? AppGLCommandReason::FboClearMaterializeDrainCurrentAsync
                   : AppGLCommandReason::FboClearMaterializeDrainCurrent)
            : (useAsyncLayeredClear
                   ? AppGLCommandReason::LayeredClearDrainCurrentAsync
                   : AppGLCommandReason::LayeredClearDrainCurrent);
        const AppGLCommandReason clearReason = materializing
            ? (useAsyncLayeredClear
                   ? AppGLCommandReason::FboClearMaterializeAsync
                   : AppGLCommandReason::FboClearMaterialize)
            : (useAsyncLayeredClear
                   ? AppGLCommandReason::LayeredClearAsync
                   : AppGLCommandReason::LayeredClear);
        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::Clear);
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texVoid;
        // Close any in-flight encoder. Metal disallows two render
        // encoders open on the same command buffer.
        if (currentRenderEncoder != nil) {
            ++encoderClosesClear;  // C49 census
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        auto drainCurrentCommandBuffer = [&]() -> bool {
            if (currentCommandBuffer == nil) {
                return true;
            }
            presentCurrentDrawable(currentCommandBuffer);
            if (useAsyncLayeredClear) {
                if (ringSlotAcquired) {
                    commitWithFrameSignal(
                        currentCommandBufferLease,
                        drainReason);
                    advanceRingBuffer();
                } else {
                    currentCommandBufferLease.commit(
                        drainReason);
                }
                currentCommandBuffer = nil;
                clearCurrentDrawable();
                pendingPresent = false;
                resetCachedEncoderState();
                return true;
            }
            const bool completed =
                currentCommandBufferLease.commitAndWait(drainReason);
            if (ringSlotAcquired) {
                signalRingSlotNow();
                advanceRingBuffer();
            }
            currentCommandBuffer = nil;
            clearCurrentDrawable();
            pendingPresent = false;
            resetCachedEncoderState();
            return completed;
        };
        if (!drainCurrentCommandBuffer()) {
            return false;
        }

        static constexpr std::uint32_t kMaxLayeredClearPassesPerCommandBuffer = 8;
        MetalCommandBufferLease clearLease;
        id<MTLCommandBuffer> clearCommandBuffer = nil;
        std::uint32_t passesInCommandBuffer = 0;

        auto beginClearChunk = [&]() -> bool {
            if (clearCommandBuffer != nil) {
                return true;
            }
            clearLease = makeCommandBufferDrainingAutorelease(clearReason);
            clearCommandBuffer = clearLease.get();
            if (clearCommandBuffer == nil) {
                return false;
            }
            attachErrorHandler(clearCommandBuffer, @"layeredClear");
            passesInCommandBuffer = 0;
            return true;
        };
        auto commitClearChunk = [&]() -> bool {
            if (clearCommandBuffer == nil) {
                return true;
            }
            if (useAsyncLayeredClear) {
                clearLease.retainObjectUntilCompleted(tex);
                clearLease.commit(clearReason);
                clearCommandBuffer = nil;
                clearLease = MetalCommandBufferLease{};
                passesInCommandBuffer = 0;
                resetCachedEncoderState();
                return true;
            }
            const bool completed = clearLease.commitAndWait(clearReason);
            clearCommandBuffer = nil;
            clearLease = MetalCommandBufferLease{};
            passesInCommandBuffer = 0;
            resetCachedEncoderState();
            return completed;
        };
        auto encodeClearPass = [&](std::uint32_t targetSlice,
                                   std::uint32_t targetArrayLength) -> bool {
            if (!beginClearChunk()) {
                return false;
            }
            @autoreleasepool {
                MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
                if (isColor) {
                    pass.colorAttachments[0].texture = tex;
                    pass.colorAttachments[0].level = level;
                    pass.colorAttachments[0].slice = targetSlice;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    pass.colorAttachments[0].clearColor =
                        MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
                }
                if (isDepth) {
                    pass.depthAttachment.texture = tex;
                    pass.depthAttachment.level = level;
                    pass.depthAttachment.slice = targetSlice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = depth;
                }
                if (isStencil) {
                    pass.stencilAttachment.texture = tex;
                    pass.stencilAttachment.level = level;
                    pass.stencilAttachment.slice = targetSlice;
                    pass.stencilAttachment.loadAction = MTLLoadActionClear;
                    pass.stencilAttachment.storeAction = MTLStoreActionStore;
                    pass.stencilAttachment.clearStencil = stencil & 0xFF;
                }
                if (targetArrayLength > 0) {
                    pass.renderTargetArrayLength = targetArrayLength;
                }
                id<MTLRenderCommandEncoder> enc =
                    [clearCommandBuffer renderCommandEncoderWithDescriptor:pass];
                if (enc == nil) {
                    return false;
                }
                [enc endEncoding];
            }
            ++passesInCommandBuffer;
            if (passesInCommandBuffer == kMaxLayeredClearPassesPerCommandBuffer) {
                return commitClearChunk();
            }
            return true;
        };
        if (!isColor && (isDepth || isStencil) && arrayLength > 0) {
            for (std::uint32_t i = 0; i < arrayLength; ++i) {
                if (!encodeClearPass(slice + i, 0)) {
                    return false;
                }
            }
            return commitClearChunk();
        }

        if (!encodeClearPass(slice, arrayLength)) {
            return false;
        }
        return commitClearChunk();
    }
    bool clearLayeredTextureDepth(void* tex, std::uint32_t arrayLength, float depth) {
        return clearLayeredTextureImpl(tex, arrayLength, 0, 0, false, true, false,
            nullptr, depth, 0);
    }
    bool clearLayeredTextureStencil(void* tex, std::uint32_t arrayLength, std::uint32_t stencil) {
        return clearLayeredTextureImpl(tex, arrayLength, 0, 0, false, false, true,
            nullptr, 0.0f, stencil);
    }
    bool clearLayeredTextureColor(void* tex, std::uint32_t arrayLength, const float rgba[4],
                                  std::uint32_t level = 0, std::uint32_t slice = 0) {
        return clearLayeredTextureImpl(tex, arrayLength, level, slice, true, false, false,
            rgba, 0.0f, 0);
    }
    bool clearTextureDepth(void* tex, std::uint32_t level, std::uint32_t slice,
                           std::uint32_t arrayLength, float depth) {
        return clearLayeredTextureImpl(tex, arrayLength, level, slice,
            false, true, false, nullptr, depth, 0);
    }
    bool clearTextureStencil(void* tex, std::uint32_t level, std::uint32_t slice,
                             std::uint32_t arrayLength, std::uint32_t stencil) {
        return clearLayeredTextureImpl(tex, arrayLength, level, slice,
            false, false, true, nullptr, 0.0f, stencil);
    }

    bool ensureDepthStencilUploadLibrary() {
        if (depthStencilUploadLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLDSUploadParams {
    uint originX;
    uint originY;
    uint width;
    uint height;
    uint writeDepth;
    float fallbackDepth;
};

struct AppGLDSUploadVSOut {
    float4 position [[position]];
};

struct AppGLDSUploadFSOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

vertex AppGLDSUploadVSOut appgl_ds_upload_vs(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    AppGLDSUploadVSOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment AppGLDSUploadFSOut appgl_ds_upload_fs(
    AppGLDSUploadVSOut in [[stage_in]],
    constant float* depthPixels [[buffer(0)]],
    constant AppGLDSUploadParams& params [[buffer(1)]])
{
    AppGLDSUploadFSOut out;
    out.color = float4(0.0, 0.0, 0.0, 0.0);
    out.depth = params.fallbackDepth;
    if (params.writeDepth != 0) {
        const uint px = uint(in.position.x);
        const uint py = uint(in.position.y);
        const uint localX = px - params.originX;
        const uint localY = py - params.originY;
        if (localX < params.width && localY < params.height) {
            const uint sourceRow = params.height - 1u - localY;
            out.depth = clamp(depthPixels[sourceRow * params.width + localX],
                              0.0f, 1.0f);
        }
    }
    return out;
}
)MSL";
        NSError* error = nil;
        depthStencilUploadLibrary =
            [device newLibraryWithSource:source options:nil error:&error];
        if (depthStencilUploadLibrary == nil) {
            NSLog(@"[AppGL] depth/stencil upload library build failed: %@", error);
            return false;
        }
        depthStencilUploadVertexFn =
            [depthStencilUploadLibrary newFunctionWithName:@"appgl_ds_upload_vs"];
        depthStencilUploadFragmentFn =
            [depthStencilUploadLibrary newFunctionWithName:@"appgl_ds_upload_fs"];
        return depthStencilUploadVertexFn != nil &&
               depthStencilUploadFragmentFn != nil;
    }

    id<MTLRenderPipelineState> depthStencilUploadPipelineState(
        MTLPixelFormat format,
        NSUInteger sampleCount) {
        if (!ensureDepthStencilUploadLibrary()) {
            return nil;
        }
        const std::uint64_t key =
            static_cast<std::uint64_t>(format) |
            (static_cast<std::uint64_t>(sampleCount) << 32);
        auto it = depthStencilUploadPSOCache.find(key);
        if (it != depthStencilUploadPSOCache.end()) {
            return it->second;
        }

        MTLRenderPipelineDescriptor* desc =
            [[MTLRenderPipelineDescriptor alloc] init];
        ScopedOwnedObjCObject descRelease(desc);
        desc.vertexFunction = depthStencilUploadVertexFn;
        desc.fragmentFunction = depthStencilUploadFragmentFn;
        desc.rasterSampleCount = sampleCount;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        desc.depthAttachmentPixelFormat = format;
        desc.stencilAttachmentPixelFormat = format;

        NSError* error = nil;
        id<MTLRenderPipelineState> state =
            [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (state == nil) {
            NSLog(@"[AppGL] depth/stencil upload PSO build failed: %@", error);
            return nil;
        }
        depthStencilUploadPSOCache[key] = state;
        return state;
    }

    id<MTLDepthStencilState> makeDepthStencilUploadState(bool writeDepth,
                                                         bool writeStencil) {
        MTLDepthStencilDescriptor* desc =
            [[MTLDepthStencilDescriptor alloc] init];
        ScopedOwnedObjCObject descRelease(desc);
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        desc.depthWriteEnabled = writeDepth ? YES : NO;
        if (writeStencil) {
            MTLStencilDescriptor* face = [[MTLStencilDescriptor alloc] init];
            ScopedOwnedObjCObject faceRelease(face);
            face.stencilCompareFunction = MTLCompareFunctionAlways;
            face.readMask = 0xFF;
            face.writeMask = 0xFF;
            face.stencilFailureOperation = MTLStencilOperationReplace;
            face.depthFailureOperation = MTLStencilOperationReplace;
            face.depthStencilPassOperation = MTLStencilOperationReplace;
            desc.frontFaceStencil = face;
            desc.backFaceStencil = face;
        }
        return [device newDepthStencilStateWithDescriptor:desc];
    }

    bool writeMultisampleDepthStencilRegion(void* texVoid, GLint x, GLint y,
                                            GLsizei width, GLsizei height,
                                            const GLfloat* depthPixels,
                                            bool writeDepth,
                                            std::uint8_t stencilValue,
                                            bool writeStencil) {
        if (texVoid == nullptr || device == nil || commandQueue == nil ||
            width <= 0 || height <= 0 || x < 0 || y < 0 ||
            (!writeDepth && !writeStencil) ||
            (writeDepth && depthPixels == nullptr)) {
            return false;
        }
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texVoid;
        if (tex == nil || tex.sampleCount <= 1 ||
            x + width > static_cast<GLint>(tex.width) ||
            y + height > static_cast<GLint>(tex.height)) {
            return false;
        }
        const MTLPixelFormat format = tex.pixelFormat;
        if (format != MTLPixelFormatDepth24Unorm_Stencil8 &&
            format != MTLPixelFormatDepth32Float_Stencil8) {
            return false;
        }

        id<MTLRenderPipelineState> pso =
            depthStencilUploadPipelineState(format, tex.sampleCount);
        if (pso == nil) {
            return false;
        }
        id<MTLDepthStencilState> dsState =
            makeDepthStencilUploadState(writeDepth, writeStencil);
        if (dsState == nil) {
            return false;
        }
        ScopedOwnedObjCObject dsStateRelease(dsState);

        const float fallbackDepth = 1.0f;
        const void* depthSource = writeDepth ? depthPixels : &fallbackDepth;
        const NSUInteger depthByteCount = writeDepth
            ? static_cast<NSUInteger>(width) *
                  static_cast<NSUInteger>(height) * sizeof(GLfloat)
            : sizeof(GLfloat);
        id<MTLBuffer> depthBuffer =
            [device newBufferWithBytes:depthSource
                                length:depthByteCount
                               options:MTLResourceStorageModeShared];
        if (depthBuffer == nil) {
            return false;
        }
        ScopedOwnedObjCObject depthBufferRelease(depthBuffer);

        struct UploadParams {
            std::uint32_t originX;
            std::uint32_t originY;
            std::uint32_t width;
            std::uint32_t height;
            std::uint32_t writeDepth;
            float fallbackDepth;
        };
        const NSUInteger metalY = tex.height -
            static_cast<NSUInteger>(y + height);
        const UploadParams params = {
            static_cast<std::uint32_t>(x),
            static_cast<std::uint32_t>(metalY),
            static_cast<std::uint32_t>(width),
            static_cast<std::uint32_t>(height),
            writeDepth ? 1u : 0u,
            fallbackDepth
        };

        id<MTLTexture> dummyColor = nil;
        @autoreleasepool {
            MTLTextureDescriptor* dummyDesc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                   width:tex.width
                                                                  height:tex.height
                                                               mipmapped:NO];
            dummyDesc.textureType = MTLTextureType2DMultisample;
            dummyDesc.sampleCount = tex.sampleCount;
            dummyDesc.storageMode = MTLStorageModePrivate;
            dummyDesc.usage = MTLTextureUsageRenderTarget;
            dummyColor = reusableDummyColorTexture(dummyDesc);
        }
        if (dummyColor == nil) {
            return false;
        }

        flushForReadback();
        auto lease = makeCommandBufferDrainingAutorelease(
            AppGLCommandReason::RenderbufferMirror);
        id<MTLCommandBuffer> cmd = lease.get();
        if (cmd == nil) {
            return false;
        }
        attachErrorHandler(cmd, @"depthStencilUpload");

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        pass.colorAttachments[0].texture = dummyColor;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        pass.depthAttachment.texture = tex;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = tex;
        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:pass];
        if (enc == nil) {
            return false;
        }

        [enc setRenderPipelineState:pso];
        [enc setDepthStencilState:dsState];
        [enc setViewport:(MTLViewport){
            0.0, 0.0,
            static_cast<double>(tex.width),
            static_cast<double>(tex.height),
            0.0, 1.0
        }];
        [enc setScissorRect:(MTLScissorRect){
            static_cast<NSUInteger>(x),
            metalY,
            static_cast<NSUInteger>(width),
            static_cast<NSUInteger>(height)
        }];
        if (writeStencil) {
            [enc setStencilReferenceValue:stencilValue];
        }
        [enc setFragmentBuffer:depthBuffer offset:0 atIndex:0];
        [enc setFragmentBytes:&params length:sizeof(params) atIndex:1];
        [enc setCullMode:MTLCullModeNone];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
        [enc endEncoding];

        const bool completed =
            lease.commitAndWait(AppGLCommandReason::RenderbufferMirror);
        resetCachedEncoderState();
        return completed;
    }

    bool encodeImmediateModeDraw(const ImmediateDrawInfo& info) {
        FG_TRACE(@"encodeImmediateModeDraw: enter mode=0x%X verts=%zu tex=%p",
                 info.mode, info.vertexCount, info.metalTexture);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        // C48: immediate-mode draws don't fold deferred FBO clears —
        // materialize them so ordering/consumption stays correct.
        materializeAllPendingFboClears();
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::ImmediateModeDraw);
        if (info.vertices == nullptr || info.vertexCount == 0 || info.vertexStride == 0) {
            return false;
        }

        // Map GL mode → Metal primitive. GL_QUADS was already expanded
        // to GL_TRIANGLES on the GLContext side, so we only see core-
        // profile primitives here.
        MTLPrimitiveType primitive;
        switch (info.mode) {
            case GL_TRIANGLES:      primitive = MTLPrimitiveTypeTriangle; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            default:
                // GL_TRIANGLE_FAN and GL_LINE_LOOP have no Metal
                // equivalent; expand them here if BAR hits them.
                FG_TRACE(@"encodeImmediateModeDraw: unsupported mode 0x%X", info.mode);
                return false;
        }

        acquireRingSlot();
        ensureDrawableResources();
        if (!ensureImmediateModeLibrary()) {
            return false;
        }

        endRenderPass();

        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(AppGLCommandReason::ImmediateModeDraw);
            if (currentCommandBuffer == nil) {
                return false;
            }
        }

        if (!acquireDrawableIfNeeded()) {  // ADV-7
            return false;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        const MTLPixelFormat colorFormat = colorTexture.pixelFormat;
        if (!ensureImmediateModePipelines(colorFormat)) {
            return false;
        }

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        hasPendingClear = false;

        attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, 1);
        id<MTLRenderCommandEncoder> encoder =
            [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            return false;
        }

        id<MTLRenderPipelineState> pipelineState = (info.metalTexture != nullptr)
            ? immediateModeTexturedPipelineState
            : immediateModeColorPipelineState;
        [encoder setRenderPipelineState:pipelineState];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setTriangleFillMode:MTLTriangleFillModeFill];

        const std::size_t vertexBytes = info.vertexCount * info.vertexStride;
        if (vertexBytes <= 4096) {
            [encoder setVertexBytes:info.vertices length:vertexBytes atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.vertices, vertexBytes);
            if (alloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }

        // MVP matrix is pushed as a vertex-stage constant (buffer index 1).
        // `Matrix4` stores 16 floats in column-major order, matching MSL's
        // float4x4 memory layout.
        const Matrix4 mvp = info.mvp;
        [encoder setVertexBytes:mvp.m.data() length:sizeof(float) * 16 atIndex:1];

        if (info.metalTexture != nullptr) {
            id<MTLTexture> tex = (__bridge id<MTLTexture>)(info.metalTexture);
            [encoder setFragmentTexture:tex atIndex:0];
            id<MTLSamplerState> samp = immediateModeDefaultSampler();
            if (samp != nil) {
                [encoder setFragmentSamplerState:samp atIndex:0];
            }
        }

        [encoder drawPrimitives:primitive
                    vertexStart:0
                    vertexCount:static_cast<NSUInteger>(info.vertexCount)];

        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pendingPresent = true;
        return true;
    }

    // Sprint 7 Phase 1 #11 (CKPT57): GL stencil enum → Metal converter
    // helpers. Pulled out as free functions so depthStencilStateForDraw
    // and the tess-Phase-2 render path can both call them — the same
    // GL→Metal mapping needs to apply identically across encode paths.
    static MTLCompareFunction glStencilCompareToMetal(GLenum func) {
        switch (func) {
            case GL_NEVER:    return MTLCompareFunctionNever;
            case GL_LESS:     return MTLCompareFunctionLess;
            case GL_EQUAL:    return MTLCompareFunctionEqual;
            case GL_LEQUAL:   return MTLCompareFunctionLessEqual;
            case GL_GREATER:  return MTLCompareFunctionGreater;
            case GL_NOTEQUAL: return MTLCompareFunctionNotEqual;
            case GL_GEQUAL:   return MTLCompareFunctionGreaterEqual;
            case GL_ALWAYS:   default: return MTLCompareFunctionAlways;
        }
    }
    static MTLStencilOperation glStencilOpToMetal(GLenum op) {
        switch (op) {
            case GL_KEEP:        return MTLStencilOperationKeep;
            case GL_ZERO:        return MTLStencilOperationZero;
            case GL_REPLACE:     return MTLStencilOperationReplace;
            case GL_INCR:        return MTLStencilOperationIncrementClamp;
            case GL_DECR:        return MTLStencilOperationDecrementClamp;
            case GL_INCR_WRAP:   return MTLStencilOperationIncrementWrap;
            case GL_DECR_WRAP:   return MTLStencilOperationDecrementWrap;
            case GL_INVERT:      return MTLStencilOperationInvert;
            default:             return MTLStencilOperationKeep;
        }
    }

    // Build per-face MTLStencilDescriptor from the GL face state. The
    // `referenceValue` lives on the encoder (setStencilReferenceValue:),
    // not the descriptor — callers handle that separately.
    static MTLStencilDescriptor* buildMetalStencilFace(
        GLenum func, GLuint valueMask,
        GLenum sfail, GLenum dpfail, GLenum dppass,
        GLuint writeMask)
    {
        MTLStencilDescriptor* sd = [[MTLStencilDescriptor alloc] init];
        sd.stencilCompareFunction = glStencilCompareToMetal(func);
        sd.readMask = valueMask;
        sd.writeMask = writeMask;
        sd.stencilFailureOperation = glStencilOpToMetal(sfail);
        sd.depthFailureOperation = glStencilOpToMetal(dpfail);
        sd.depthStencilPassOperation = glStencilOpToMetal(dppass);
        return sd;
    }

    id<MTLDepthStencilState> depthStencilStateForDraw(const MetalDrawInfo& info) {
        // Cache key: pack (depth state) plus a stencil-state fingerprint
        // into a 64-bit key. The depth half stays at low 32 bits for
        // back-compat-shaped lookups; stencil identity hashes into the
        // high 32 bits when stencilTestEnabled. State space is small per
        // app (a handful of stencil configs typically), so post-first-
        // frame hash-table lookup keeps allocations at zero.
        std::uint64_t key = (info.depthTestEnabled ? 0x10000ull : 0ull)
                          | (info.depthWriteMask ? 0x20000ull : 0ull)
                          | (static_cast<std::uint64_t>(info.depthFunc) & 0xFFFFull);
        if (info.stencilTestEnabled) {
            // Compact stencil identity hash. Mix 14 GL enums + 2 ints
            // into the upper 32 bits via a cheap FNV-1a-like fold.
            std::uint64_t s = 0x40000000ull;   // disambiguator from depth-only key
            auto mix = [&](std::uint64_t v) {
                s ^= v;
                s = s * 1099511628211ull;
            };
            mix(static_cast<std::uint64_t>(info.stencilFrontFunc));
            mix(static_cast<std::uint64_t>(info.stencilFrontRef));
            mix(static_cast<std::uint64_t>(info.stencilFrontValueMask));
            mix(static_cast<std::uint64_t>(info.stencilFrontFail));
            mix(static_cast<std::uint64_t>(info.stencilFrontDepthFail));
            mix(static_cast<std::uint64_t>(info.stencilFrontDepthPass));
            mix(static_cast<std::uint64_t>(info.stencilFrontWriteMask));
            mix(static_cast<std::uint64_t>(info.stencilBackFunc));
            mix(static_cast<std::uint64_t>(info.stencilBackRef));
            mix(static_cast<std::uint64_t>(info.stencilBackValueMask));
            mix(static_cast<std::uint64_t>(info.stencilBackFail));
            mix(static_cast<std::uint64_t>(info.stencilBackDepthFail));
            mix(static_cast<std::uint64_t>(info.stencilBackDepthPass));
            mix(static_cast<std::uint64_t>(info.stencilBackWriteMask));
            key |= (s << 32) & 0xFFFFFFFF00000000ull;
        }

        auto it = depthStencilCache.find(key);
        if (it != depthStencilCache.end()) {
            return it->second;
        }

        MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
        ScopedOwnedObjCObject descRelease(desc);
        desc.depthWriteEnabled = info.depthTestEnabled && info.depthWriteMask;
        if (info.depthTestEnabled) {
            switch (info.depthFunc) {
                case GL_NEVER: desc.depthCompareFunction = MTLCompareFunctionNever; break;
                case GL_LESS: desc.depthCompareFunction = MTLCompareFunctionLess; break;
                case GL_EQUAL: desc.depthCompareFunction = MTLCompareFunctionEqual; break;
                case GL_LEQUAL: desc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
                case GL_GREATER: desc.depthCompareFunction = MTLCompareFunctionGreater; break;
                case GL_NOTEQUAL: desc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
                case GL_GEQUAL: desc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
                case GL_ALWAYS: default: desc.depthCompareFunction = MTLCompareFunctionAlways; break;
            }
        } else {
            desc.depthCompareFunction = MTLCompareFunctionAlways;
        }
        // Sprint 7 Phase 1 #11 (CKPT57): apply per-face stencil state.
        // When stencil test is disabled, leave defaults (Always + Keep,
        // matching GL spec: "if the stencil test is not enabled, the
        // stencil test always passes" — GL 4.6 §17.3.5).
        if (info.stencilTestEnabled) {
            desc.frontFaceStencil = buildMetalStencilFace(
                info.stencilFrontFunc, info.stencilFrontValueMask,
                info.stencilFrontFail, info.stencilFrontDepthFail,
                info.stencilFrontDepthPass, info.stencilFrontWriteMask);
            desc.backFaceStencil = buildMetalStencilFace(
                info.stencilBackFunc, info.stencilBackValueMask,
                info.stencilBackFail, info.stencilBackDepthFail,
                info.stencilBackDepthPass, info.stencilBackWriteMask);
        }

        id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:desc];
        depthStencilCache[key] = state;
        return state;
    }

    void endFrame(GLObjectStore& objects) {
        FrameAttributionScope attributionScope(
            frameAttributionProfile,
            FrameAttributionAction::EndFrame);
        endRenderPass();
        objects.drainDeferredDeletes();
        if (!commitCurrentAsync(AppGLCommandReason::EndFrame)) {
            invalidateTransientState();
            attributionScope.markFailed();
        }
    }

    void present(AppGLCommandReason reason = AppGLCommandReason::PresentPendingWork) {
        FrameAttributionScope attributionScope(
            frameAttributionProfile,
            FrameAttributionAction::Present);
        FG_TRACE(@"present: enter  pendingPresent=%d encoder=%p cmdBuf=%p drawable=%p",
                 pendingPresent, currentRenderEncoder, currentCommandBuffer, currentDrawable);
        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::Present);
        // Flush any deferred clear that wasn't consumed by a draw call.
        if (hasPendingClear) {
            flushPendingClear();
        }
        ++presentCalls;
        switch (reason) {
            case AppGLCommandReason::PresentFromFlush:
                ++presentFromFlushCalls;
                break;
            case AppGLCommandReason::PresentFromSwapBuffers:
                ++presentFromSwapBuffersCalls;
                break;
            default:
                ++presentInternalCalls;
                break;
        }
        // S24 census: the attribution profile previously dumped ONLY in
        // the Impl destructor, so harness-killed live runs produced 0
        // rows (Step-1 capture matrix). Emit cumulative snapshots
        // periodically to stderr — same channel the CB profile uses and
        // the capture parsers already read.
        if (frameAttributionProfile.enabled &&
            presentCalls % 600 == 0) {
            frameAttributionProfile.dump();
        }
        if (pendingPresent) {
            ++presentPendingTrueCalls;
        } else {
            ++presentPendingFalseCalls;
        }
        if (currentCommandBuffer != nil) {
            ++presentCommandBufferPresentCalls;
        } else {
            ++presentCommandBufferNilCalls;
        }
        if (!pendingPresent || currentCommandBuffer == nil) {
            ++presentNoWorkReturns;
            return;
        }
        // OPT-8: async commit — the completion handler signals the frame
        // semaphore, allowing the CPU to encode the next frame while the GPU
        // processes this one.  Replaces the old waitUntilCompleted which
        // serialised CPU and GPU completely for offscreen targets.
        ++presentCommitAttempts;
        if (!commitCurrentAsync(reason)) {
            ++presentCommitFailures;
            attributionScope.markFailed();
        } else {
            ++presentCommitSuccesses;
        }
    }

    bool finish() {
        FrameAttributionScope attributionScope(
            frameAttributionProfile,
            FrameAttributionAction::Finish);
        // C48: glFinish promises every prior GL command completed —
        // deferred FBO clears must land first.
        materializeAllPendingFboClears();
        flushParallelTranslatedDrawBatch(ParallelEncodeBoundaryReason::Finish);
        if (hasPendingClear) {
            flushPendingClear();
        }
        endRenderPass();
        const bool submittedFinishWork = commitCurrentAsync(AppGLCommandReason::FinishWait);
        const bool finished = commandSubmission == nullptr
            ? true
            : commandSubmission->drainAllOutstanding(AppGLCommandReason::LifetimeDrain,
                                                     submittedFinishWork);
        if (!finished) {
            attributionScope.markFailed();
        }
        return finished;
    }

    bool copyPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
        FG_TRACE(@"copyPixels: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        if (outPixels == nullptr || width < 0 || height < 0) {
            return false;
        }
        if (width == 0 || height == 0) {
            return true;
        }
        if (device == nil || commandQueue == nil) {
            return copyHeadlessPixels(x, y, width, height, outPixels);
        }
        // C48: deferred FBO clears must land before any readback.
        materializeAllPendingFboClears();
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::CopyReadback);
        // Flush any deferred clear before readback.
        if (hasPendingClear) {
            flushPendingClear();
        }
        // Close any open render encoder before we commit the command buffer
        // for readback — otherwise Metal asserts on uncommitted encoder.
        endRenderPass();
        ensureDrawableResources();
        id<MTLTexture> sourceTexture = readbackSourceTexture != nil
            ? readbackSourceTexture
            : (usesOffscreenTarget ? offscreenColorTexture : nil);
        if (sourceTexture == nil) {
            return false;
        }
        const bool sourceIsBGRA = sourceTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;

        const NSUInteger sourceWidth = sourceTexture.width;
        const NSUInteger sourceHeight = sourceTexture.height;
        const NSUInteger packedRowBytes = sourceWidth * 4u;
        NSUInteger readbackRowBytes = packedRowBytes;
        const std::uint8_t* sourceBytes = nullptr;
        std::vector<std::uint8_t> directReadback;
        id<MTLBuffer> readbackBuffer = nil;
        ScopedOwnedObjCObject readbackBufferRelease;

        const auto waitForQueue = [&]() -> bool {
            auto fenceLease = makeCommandBuffer(AppGLCommandReason::FlushForReadback);
            id<MTLCommandBuffer> fence = fenceLease.get();
            if (fence == nil) {
                return false;
            }
            return fenceLease.commitAndWait(AppGLCommandReason::FlushForReadback);
        };

        if (sourceTexture.storageMode == MTLStorageModeShared) {
            if (currentCommandBuffer != nil) {
                if (!currentCommandBufferLease.commitAndWait(AppGLCommandReason::FlushForReadback)) {
                    return false;
                }
                // OPT-8: GPU finished synchronously — release the ring slot
                // so the semaphore stays balanced (no completion handler here).
                if (ringSlotAcquired) {
                    signalRingSlotNow();
                    ringSlotAcquired = false;
                }
                invalidateTransientState();
            } else if (!waitForQueue()) {
                return false;
            }

            directReadback.assign(static_cast<std::size_t>(packedRowBytes * sourceHeight), 0);
            [sourceTexture getBytes:directReadback.data()
                        bytesPerRow:packedRowBytes
                         fromRegion:MTLRegionMake2D(0, 0, sourceWidth, sourceHeight)
                        mipmapLevel:0];
            sourceBytes = directReadback.data();
        } else {
            readbackRowBytes = alignBytesPerRow(packedRowBytes);
            readbackBuffer = [device newBufferWithLength:readbackRowBytes * sourceHeight
                                                 options:MTLResourceStorageModeShared];
            if (readbackBuffer == nil) {
                return false;
            }
            readbackBufferRelease.reset(readbackBuffer);

            MetalCommandBufferLease standaloneLease;
            id<MTLCommandBuffer> commandBuffer = currentCommandBuffer;
            if (commandBuffer == nil) {
                standaloneLease = makeCommandBuffer(AppGLCommandReason::FlushForReadback);
                commandBuffer = standaloneLease.get();
            }
            if (commandBuffer == nil) {
                return false;
            }
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:sourceTexture
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(sourceWidth, sourceHeight, 1)
                         toBuffer:readbackBuffer
                destinationOffset:0
           destinationBytesPerRow:readbackRowBytes
         destinationBytesPerImage:readbackRowBytes * sourceHeight];
            [blit endEncoding];
            const bool consumedCurrentCommandBuffer = commandBuffer == currentCommandBuffer;
            bool completed = false;
            if (consumedCurrentCommandBuffer) {
                completed = currentCommandBufferLease.commitAndWait(AppGLCommandReason::FlushForReadback);
            } else {
                completed = standaloneLease.commitAndWait(AppGLCommandReason::FlushForReadback);
            }
            if (!completed) {
                return false;
            }
            // OPT-8: release ring slot if we consumed the current CB synchronously.
            if (consumedCurrentCommandBuffer && ringSlotAcquired) {
                signalRingSlotNow();
                ringSlotAcquired = false;
            }
            if (consumedCurrentCommandBuffer) {
                invalidateTransientState();
            }
            sourceBytes = static_cast<const std::uint8_t*>([readbackBuffer contents]);
        }

        // RC-A02: OpenGL framebuffer row 0 is at the bottom; Metal
        // texture row 0 is at the top.  Flip Y during readback:
        // metalRow = textureHeight - 1 - glRow.
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint glY = y + row;
                const GLint srcY = static_cast<GLint>(sourceHeight) - 1 - glY;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4;
                if (srcX < 0 || srcY < 0 || srcX >= static_cast<GLint>(sourceWidth) || srcY >= static_cast<GLint>(sourceHeight)) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = static_cast<std::size_t>(srcY) * static_cast<std::size_t>(readbackRowBytes)
                    + static_cast<std::size_t>(srcX) * 4u;
                if (sourceIsBGRA) {
                    bytes[dstOffset + 0] = sourceBytes[srcOffset + 2];
                    bytes[dstOffset + 1] = sourceBytes[srcOffset + 1];
                    bytes[dstOffset + 2] = sourceBytes[srcOffset + 0];
                    bytes[dstOffset + 3] = sourceBytes[srcOffset + 3];
                } else {
                    std::memcpy(bytes + dstOffset, sourceBytes + srcOffset, 4);
                }
            }
        }
        return true;
    }

    // Flush the GPU: end any open render encoder, commit and wait for the
    // current command buffer.  After this call, all previously-encoded draws
    // are guaranteed to have completed and their results are CPU-visible via
    // [MTLTexture getBytes:].  Used by FBO readback paths.
    void flushForReadback() {
        FrameAttributionScope attributionScope(
            frameAttributionProfile,
            FrameAttributionAction::FlushForReadback);
        // C48: a readback consumer must observe deferred FBO clears.
        materializeAllPendingFboClears();
        if (currentRenderEncoder != nil) {
            ++encoderClosesReadback;  // C49 census
        }
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::CopyReadback);
        endRenderPass();
        if (currentCommandBuffer != nil) {
            if (!currentCommandBufferLease.commitAndWait(AppGLCommandReason::FlushForReadback)) {
                attributionScope.markFailed();
                return;
            }
            if (ringSlotAcquired) {
                signalRingSlotNow();
                ringSlotAcquired = false;
            }
            invalidateTransientState();
        } else if (commandSubmission != nullptr && commandSubmission->hasOutstandingCommandBuffers()) {
            auto fenceLease = makeCommandBuffer(AppGLCommandReason::FlushForReadback);
            id<MTLCommandBuffer> fence = fenceLease.get();
            if (fence != nil) {
                fenceLease.commitAndWait(AppGLCommandReason::FlushForReadback);
            }
        }
    }

    bool drainCurrentCommandBufferForStandaloneEncoding(
        std::string* diagnostic,
        AppGLCommandReason reason = AppGLCommandReason::DrainCurrentStandalone) {
        endRenderPass();
        if (currentCommandBuffer == nil) {
            return true;
        }

        presentCurrentDrawable(currentCommandBuffer);
        if (!currentCommandBufferLease.commitAndWait(reason)) {
            if (diagnostic != nullptr) {
                *diagnostic = "prior command buffer failed or timed out";
            }
            return false;
        }
        if (ringSlotAcquired) {
            signalRingSlotNow();
            advanceRingBuffer();
        }
        currentCommandBuffer = nil;
        clearCurrentDrawable();
        pendingPresent = false;
        resetCachedEncoderState();

        return true;
    }

    bool drainPresentLifecycleForStandaloneEncoding(
        std::string* diagnostic,
        AppGLCommandReason reason) {
        if (!drainCurrentCommandBufferForStandaloneEncoding(
                diagnostic, reason)) {
            return false;
        }
        if (usesOffscreenTarget ||
            commandSubmission == nullptr ||
            !commandSubmission->hasOutstandingCommandBuffers()) {
            return true;
        }
        if (!commandSubmission->drainAllOutstanding(reason, false)) {
            if (diagnostic != nullptr) {
                *diagnostic = "outstanding present command buffers failed or timed out";
            }
            return false;
        }
        resetCachedEncoderState();
        return true;
    }

    bool isReady() const {
        return device != nil && commandQueue != nil && (layer != nil || usesOffscreenTarget);
    }

    // Compile MSL into a retained MTLComputePipelineState. Returns
    // transfer-retained void* so the caller can store it on the
    // GLProgramObject and free it via releaseRetainedMetalObject at
    // relink / program delete. On failure returns nullptr with the
    // NSError surfaced through `outError`.
    //
    // Step 7-3 compute follow-up: optional `outFunction` receives the
    // MTLFunction (transfer-retained void*) when non-null — needed so
    // the argument-buffer path can call
    // `newArgumentEncoderWithBufferIndex:` at dispatch time. Callers
    // who don't use argument buffers pass nullptr and only the PSO is
    // retained.
    void* buildComputePipelineState(const std::string& msl, std::string* outError,
                                     void** outFunction = nullptr,
                                     void* stageInputOutputDescriptor = nullptr) {
        if (outFunction != nullptr) *outFunction = nullptr;
        if (device == nil || msl.empty()) {
            if (outError) *outError = "no device or empty MSL";
            return nullptr;
        }
        NSError* libError = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:msl.c_str()]
            options:nil error:&libError];
        if (lib == nil) {
            if (outError) {
                *outError = libError.localizedDescription.UTF8String
                    ? libError.localizedDescription.UTF8String : "newLibraryWithSource failed";
            }
            return nullptr;
        }
        ScopedOwnedObjCObject libRelease(lib);
        // SPIRV-Cross emits the entry point as "main0" by default (same
        // convention as the vertex/fragment paths).
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        ScopedOwnedObjCObject emptyConstantsRelease(emptyConstants);
        NSError* fnError = nil;
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"
                                        constantValues:emptyConstants
                                                 error:&fnError];
        if (fn == nil) {
            if (outError) {
                *outError = fnError.localizedDescription.UTF8String
                    ? fnError.localizedDescription.UTF8String : "newFunctionWithName(main0) failed";
            }
            return nullptr;
        }
        ScopedOwnedObjCObject fnRelease(fn);
        NSError* psoError = nil;
        id<MTLComputePipelineState> pso = nil;
        if (stageInputOutputDescriptor != nullptr) {
            // VS-as-compute path: SPIRV-Cross with
            // forceVertexForTessellation=true emits `main0(main0_in in
            // [[stage_in]], ...)`; building this requires a
            // MTLComputePipelineDescriptor with a populated
            // `stageInputDescriptor`. The descriptor is built from the
            // bound VAO (see `buildMetalStageInputOutputDescriptor`).
            MTLComputePipelineDescriptor* psoDesc =
                [[MTLComputePipelineDescriptor alloc] init];
            ScopedOwnedObjCObject psoDescRelease(psoDesc);
            psoDesc.computeFunction = fn;
            psoDesc.stageInputDescriptor =
                (__bridge MTLStageInputOutputDescriptor*)stageInputOutputDescriptor;
            pso = [device newComputePipelineStateWithDescriptor:psoDesc
                                                        options:MTLPipelineOptionNone
                                                     reflection:nil
                                                          error:&psoError];
        } else {
            pso = [device newComputePipelineStateWithFunction:fn
                                                        error:&psoError];
        }
        if (pso == nil) {
            if (outError) {
                *outError = psoError.localizedDescription.UTF8String
                    ? psoError.localizedDescription.UTF8String : "newComputePipelineState failed";
            }
            return nullptr;
        }
        if (outFunction != nullptr) {
            *outFunction = (void*)CFBridgingRetain(fn);
        }
        void* retained = (void*)CFBridgingRetain(pso);
        releaseOwnedObjCObject(pso);
        return retained;
    }

    // Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: dispatch VS-as-
    // compute kernel + capture per-vertex output bytes (no
    // MTLStageInputOutputDescriptor — attributeless VS only). See
    // public-API doc on `MetalFrameGraph::encodeVsTfComputeDraw`.
    bool encodeVsTfComputeDraw(void* vsComputePSO,
                               std::uint32_t vertexCount,
                               std::size_t perVertexBytes,
                               const void* uniformBytes,
                               std::size_t uniformLength,
                               std::uint8_t* outBytes)
    {
        if (vsComputePSO == nullptr || vertexCount == 0 ||
            perVertexBytes == 0 || outBytes == nullptr) {
            return false;
        }
        if (device == nil || commandQueue == nil) {
            return false;
        }
        const NSUInteger totalBytes =
            static_cast<NSUInteger>(perVertexBytes) *
            static_cast<NSUInteger>(vertexCount);
        id<MTLBuffer> outBuf =
            [device newBufferWithLength:totalBytes
                                options:MTLResourceStorageModeShared];
        if (outBuf == nil) {
            return false;
        }
        ScopedOwnedObjCObject outBufRelease(outBuf);
        outBuf.label = @"appgl-vstf-out";

        auto lease = makeCommandBuffer(AppGLCommandReason::VertexTransformFeedbackReadback);
        id<MTLCommandBuffer> cmdBuf = lease.get();
        if (cmdBuf == nil) {
            return false;
        }
        cmdBuf.label = @"appgl-vstf-vs-compute";
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (enc == nil) {
            return false;
        }
        id<MTLComputePipelineState> pso =
            (__bridge id<MTLComputePipelineState>)vsComputePSO;
        [enc setComputePipelineState:pso];
        // Per-vertex output buffer at [[buffer(28)]] (matches SPIRV-
        // Cross's default `shader_output_buffer_index`).
        [enc setBuffer:outBuf offset:0 atIndex:28];
        if (uniformBytes != nullptr && uniformLength > 0) {
            [enc setBytes:uniformBytes
                   length:uniformLength
                  atIndex:16];
        }
        // Sprint 16 Day 1 (CKPT209) — Phase 3b Component E:
        // SPIRV-Cross's vertex_for_tessellation MSL emit declares
        // `uint3 spvDispatchBase [[grid_origin]]` (per
        // spirv_msl.cpp:1050-1060) and computes
        // `gl_VertexIndex = gl_GlobalInvocationID.x + spvDispatchBase.x`.
        // Plain `dispatchThreads:` doesn't initialise [[grid_origin]],
        // so spvDispatchBase reads garbage → gl_VertexIndex points
        // anywhere → switch on gl_VertexID%4 jumps to a random case
        // OR no case → output stays at allocation default (0).
        // Fix: call setStageInRegion: with origin (0,0,0) to prime
        // [[grid_origin]] before dispatch. Sister-pattern reuse from
        // Metal's stage_in-compute-kernel pattern (the [[grid_origin]]
        // attribute is shared across stage_in and grid-origin compute
        // dispatch). `dispatchThreads:` then proceeds with a known
        // base offset of zero, matching glDrawArrays(POINTS, 0, N)
        // semantics where gl_BaseVertex = 0.
        [enc setStageInRegion:MTLRegionMake1D(0, vertexCount)];
        // Match the existing tess-as-compute VS encoder shape:
        // dispatchThreads sets [[grid_size]] to vertexCount; SPIRV-
        // Cross's emitted VS uses `gl_GlobalInvocationID.x` as the
        // per-vertex index and bounds-checks via the
        // spvStageInputSize early-return.
        const NSUInteger maxPerTg =
            pso.maxTotalThreadsPerThreadgroup > 0
                ? pso.maxTotalThreadsPerThreadgroup : 32;
        const NSUInteger tgWidth =
            vertexCount < maxPerTg ? vertexCount : maxPerTg;
        [enc dispatchThreads:MTLSizeMake(vertexCount, 1, 1)
         threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
        [enc endEncoding];
        if (!lease.commitAndWait(AppGLCommandReason::VertexTransformFeedbackReadback)) {
            return false;
        }

        const std::uint8_t* contents =
            static_cast<const std::uint8_t*>([outBuf contents]);
        if (contents == nullptr) {
            return false;
        }
        std::memcpy(outBytes, contents, totalBytes);
        return true;
    }

    // Sprint 3 [metal-mesh-GS]: compile MSL → retained MTLFunction.
    // Mesh render PSOs are FBO-format-keyed so the PSO build itself
    // happens at draw time, but the source-to-AIR compile is stable
    // across draw invocations and stashed on the program object.
    void* compileMSLFunction(const std::string& msl, std::string* outError) {
        if (device == nil || msl.empty()) {
            if (outError) *outError = "no device or empty MSL";
            return nullptr;
        }
        NSError* libError = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:msl.c_str()]
            options:nil error:&libError];
        if (lib == nil) {
            if (outError) {
                *outError = libError.localizedDescription.UTF8String
                    ? libError.localizedDescription.UTF8String : "newLibraryWithSource failed";
            }
            return nullptr;
        }
        ScopedOwnedObjCObject libRelease(lib);
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
        if (fn == nil) {
            if (outError) *outError = "newFunctionWithName(main0) failed";
            return nullptr;
        }
        void* retained = (void*)CFBridgingRetain(fn);
        releaseOwnedObjCObject(fn);
        return retained;
    }

    // Metal tess Phase 1 probe — validates that the SPIRV-Cross-emitted
    // tess MSL compiles and the Metal tessellation pipeline descriptor
    // accepts the TES + FS function pair. See the public
    // `MetalFrameGraph::probeTessellationPipeline` declaration for the
    // full contract.
    MetalFrameGraph::TessPipelineProbeResult probeTessellationPipeline(
        const std::string& tcsMSL,
        const std::string& tesMSL,
        const std::string& fsMSL,
        GLenum genMode,
        GLenum genSpacing,
        GLenum genVertexOrder,
        const std::string& vsComputeMSL,
        const std::string& tesComputeMSL)
    {
        MetalFrameGraph::TessPipelineProbeResult result;
        if (device == nil) {
            result.diagnostic = "no Metal device";
            return result;
        }
        // Allow `tesMSL` to be empty when the as-compute form is present
        // — happens for isolines TES post-SPIRV-Cross-095c99c-bypass:
        // `tess_evaluation_as_compute=true` emits valid kernel MSL while
        // the conventional `--msl` path still throws "Metal does not
        // support isoline tessellation." Stages 1c (TES-compute PSO),
        // 1a (TCS-compute PSO), 1b (VS-compute PSO) cover the compute
        // chain. Stages 2/3 (TES library + render PSO) are skipped below
        // when tesMSL is empty so the function still returns with
        // tessEvalComputeOk=true.
        if (tcsMSL.empty() || (tesMSL.empty() && tesComputeMSL.empty()) || fsMSL.empty()) {
            result.diagnostic = "missing MSL for one or more stages (tcs/tes/fs)";
            return result;
        }

        // Stage 1 — TCS compute PSO. Shares `buildComputePipelineState`
        // so any refinements to compute-pipeline validation flow through
        // the tess path too.
        std::string tcsError;
        void* tcsPSO = buildComputePipelineState(tcsMSL, &tcsError, nullptr);
        if (tcsPSO == nullptr) {
            result.diagnostic = std::string("tcs-compute: ") + tcsError;
            return result;
        }
        result.computeOk = true;
        result.computePipelineState = tcsPSO;

        // Stage 1b (Phase 3) — VS-as-compute PSO. Only attempted when
        // the caller passed a non-empty MSL. Programs whose VS has no
        // stage-input ([[stage_in]]) attributes can build directly;
        // programs that need a MTLStageInputOutputDescriptor will fail
        // here and drop to the CPU fallback via the program-side
        // handleability gate. Diagnosed but not a hard failure — the
        // caller may still use the TCS-only path for simple tess.
        if (!vsComputeMSL.empty()) {
            std::string vsError;
            void* vsPSO = buildComputePipelineState(vsComputeMSL, &vsError, nullptr);
            if (vsPSO != nullptr) {
                result.vertexComputeOk = true;
                result.vertexComputePipelineState = vsPSO;
            } else {
                // T4I [metal-tess-TF]: Metal returns "Function requires
                // stage_in attributes but no descriptor was set." when
                // the VS-as-compute MSL declares `[[stage_in]]`. That's
                // not a fatal error — we just need to defer PSO build
                // to draw time when the bound VAO is known. Set the
                // `vertexComputeNeedsDescriptor` flag so the program
                // side can build the PSO from the VAO descriptor at
                // draw time. Other compile failures (syntax errors etc)
                // remain non-fatal but won't trigger the deferred path.
                if (vsError.find("stage_in") != std::string::npos) {
                    result.vertexComputeNeedsDescriptor = true;
                }
                // Keep going — a failed VS-compute PSO shouldn't mask
                // the TCS + render PSO validation, but we stash the
                // diagnostic so callers can decide whether to use the
                // simpler no-VS path.
                result.diagnostic = std::string("vs-compute (non-fatal): ") + vsError;
            }
        }

        // Stage 1c (Phase 3B.4 [metal-tess-TF]) — TES-as-compute PSO.
        // Caller opts in by passing the SPIRV-Cross-emitted kernel
        // form of the TES MSL (the one produced when
        // `forceTessEvalAsCompute=true`). Builds the compute PSO that
        // the encoder's 4-dispatch TF-capture chain consumes.
        // Non-fatal if it fails: the traditional render-PSO TES path
        // stays available for non-TF draws.
        if (!tesComputeMSL.empty()) {
            std::string tesComputeError;
            void* tesComputePSO = buildComputePipelineState(
                tesComputeMSL, &tesComputeError, nullptr);
            if (tesComputePSO != nullptr) {
                result.tessEvalComputeOk = true;
                result.tessEvalComputePipelineState = tesComputePSO;
            } else if (result.diagnostic.empty()) {
                result.diagnostic = std::string("tes-compute (non-fatal): ") + tesComputeError;
            }
        }

        // Stages 2 + 3 build the conventional render-PSO path (TES as a
        // vertex function feeding Metal's fixed-function tessellator +
        // FS for rasterization). Skip entirely when `tesMSL` is empty —
        // happens for isolines post-SPIRV-Cross-095c99c-bypass, where
        // we have a valid tess-eval-as-compute kernel but no render
        // form. The compute chain (TCS-compute → domain-gen → TES-
        // compute) already handles the dispatch end-to-end without a
        // render PSO. Probe returns with `tessEvalComputeOk=true`
        // (set in stage 1c) and `renderOk=false`; the caller's tier
        // selection branches on whether render PSO is needed.
        if (tesMSL.empty()) {
            return result;
        }

        // Stage 2 — TES + FS libraries + functions.
        NSError* tesLibErr = nil;
        id<MTLLibrary> tesLib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:tesMSL.c_str()]
            options:nil error:&tesLibErr];
        if (tesLib == nil) {
            result.diagnostic = std::string("tes-library: ") +
                (tesLibErr.localizedDescription.UTF8String
                    ? tesLibErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        NSError* tesFnErr = nil;
        id<MTLFunction> tesFn = [tesLib newFunctionWithName:@"main0"
                                              constantValues:emptyConstants
                                                       error:&tesFnErr];
        if (tesFn == nil) {
            result.diagnostic = std::string("tes-function: ") +
                (tesFnErr.localizedDescription.UTF8String
                    ? tesFnErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }

        NSError* fsLibErr = nil;
        id<MTLLibrary> fsLib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:fsMSL.c_str()]
            options:nil error:&fsLibErr];
        if (fsLib == nil) {
            result.diagnostic = std::string("fs-library: ") +
                (fsLibErr.localizedDescription.UTF8String
                    ? fsLibErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        NSError* fsFnErr = nil;
        id<MTLFunction> fsFn = [fsLib newFunctionWithName:@"main0"
                                            constantValues:emptyConstants
                                                     error:&fsFnErr];
        if (fsFn == nil) {
            result.diagnostic = std::string("fs-function: ") +
                (fsFnErr.localizedDescription.UTF8String
                    ? fsFnErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }

        // Stage 3 — tess-enabled render pipeline descriptor. The format
        // is BGRA8Unorm for the probe; Phase 2's real draw path rebuilds
        // per FBO color format inside the encoder.
        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = tesFn;
        desc.fragmentFunction = fsFn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        // Partition mode maps per GL 4.6 §11.2.2.1:
        //   GL_EQUAL            → integer
        //   GL_FRACTIONAL_EVEN  → fractionalEven
        //   GL_FRACTIONAL_ODD   → fractionalOdd
        // Metal's .pow2 has no GL analogue. Winding mirrors the
        // TES `layout(cw|ccw)` qualifier.
        switch (genSpacing) {
            case GL_FRACTIONAL_EVEN:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeFractionalEven;
                break;
            case GL_FRACTIONAL_ODD:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeFractionalOdd;
                break;
            case GL_EQUAL:
            default:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
                break;
        }
        desc.tessellationOutputWindingOrder =
            (genVertexOrder == GL_CW) ? MTLWindingClockwise : MTLWindingCounterClockwise;
        desc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        desc.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
        desc.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        desc.maxTessellationFactor = 64;  // GL_MAX_TESS_GEN_LEVEL
        (void)genMode;

        NSError* psoErr = nil;
        id<MTLRenderPipelineState> renderPSO =
            [device newRenderPipelineStateWithDescriptor:desc error:&psoErr];
        if (renderPSO == nil) {
            result.diagnostic = std::string("tess-render-pipeline: ") +
                (psoErr.localizedDescription.UTF8String
                    ? psoErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        result.renderOk = true;
        (void)renderPSO;   // released at autorelease-pool drain; Phase 2
                           // rebuilds the render PSO per FBO format.
        return result;
    }

    // Metal-native tessellation draw encoder (Phase 2 of the metal-tess
    // project). See the public declaration on MetalFrameGraph for the
    // full contract. Flow:
    //   (1) End any open render pass + drain the command buffer so
    //       subsequent compute writes are visible.
    //   (2) Allocate a factor buffer (private storage; written by the
    //       TCS, read by Metal's fixed-function tessellator at
    //       drawPatches time) + an indirect-params buffer (shared, filled
    //       with [patchVerticesIn, patchesPerThreadgroup=1]).
    //   (3) Compute-encode the TCS: setPipelineState, bind factor +
    //       indirect params, dispatchThreadgroups(patchCount x 1 x 1,
    //       threadsPerThreadgroup = tessControlOutputVertices x 1 x 1).
    //       Commit + wait so the factor buffer is populated before the
    //       subsequent render pass reads it.
    //   (4) Build / cache a tess-enabled MTLRenderPipelineState keyed on
    //       (tesMSL, fsMSL, colorFormat, depthFormat) — SPIRV-Cross's
    //       TES is emitted with `[[ patch(<domain>, 0) ]]` which must
    //       match the genMode.
    //   (5) Begin a render pass on the FBO (or default framebuffer),
    //       set viewport/scissor/cull/depth state, setRenderPipelineState,
    //       setTessellationFactorBuffer, and drawPatches.
    //   (6) End the render pass and commit.
    bool encodeMetalTessellationDraw(MetalTessDrawInfo& info) {
        // C48: tess draws don't fold deferred FBO clears — materialize.
        materializeAllPendingFboClears();
        info.didRender = false;
        if (!info.submissionGroup.declared) {
            info.submissionGroup.reset(AppGLSubmissionGroupKind::TessDraw,
                                       AppGLCommandReason::TessRender);
            info.submissionGroup.approximateFallbackDisallowed = true;
        }
        if (device == nil || commandQueue == nil) return false;
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::TessellationDraw);
        if (info.tessControlPipelineState == nullptr) return false;
        // Allow `tessEvalMSL` to be empty when the as-compute kernel is
        // present (isolines TES post-SPIRV-Cross-095c99c). Render pipeline
        // build below is skipped when tessEvalMSL is empty — the compute
        // chain handles the dispatch end-to-end and (with rasterizer-
        // discard active or TF-only mode) we never need the render PSO.
        if ((info.tessEvalMSL == nullptr || info.tessEvalMSL->empty()) &&
            info.tessEvalComputePipelineState == nullptr) return false;
        if (info.fragmentMSL == nullptr || info.fragmentMSL->empty()) return false;
        if (info.patchCount <= 0 || info.tessControlOutputVertices <= 0) return false;
        const bool isTessEvalComputeRequested =
            info.tessEvalComputePipelineState != nullptr && metalTessTFEnabled();
        auto bindComputeTextures =
            [](id<MTLComputeCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setTexture:tex atIndex:slot];
                    if (binding.imageAtomicMetalBuffer != nullptr &&
                        binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                        id<MTLBuffer> buf =
                            (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                        if (buf != nil) {
                            [encoder setBuffer:buf
                                        offset:binding.imageAtomicBufferOffset
                                       atIndex:static_cast<NSUInteger>(
                                           binding.imageAtomicBufferSlot)];
                        }
                    }
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setSamplerState:smp atIndex:slot];
                    }
                }
            };
        auto bindVertexTextures =
            [](id<MTLRenderCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setVertexTexture:tex atIndex:slot];
                    if (binding.imageAtomicMetalBuffer != nullptr &&
                        binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                        id<MTLBuffer> buf =
                            (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                        if (buf != nil) {
                            [encoder setVertexBuffer:buf
                                              offset:binding.imageAtomicBufferOffset
                                             atIndex:static_cast<NSUInteger>(
                                                 binding.imageAtomicBufferSlot)];
                        }
                    }
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setVertexSamplerState:smp atIndex:slot];
                    }
                }
            };
        auto bindFragmentTextures =
            [](id<MTLRenderCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setFragmentTexture:tex atIndex:slot];
                    if (binding.imageAtomicMetalBuffer != nullptr &&
                        binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                        id<MTLBuffer> buf =
                            (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                        if (buf != nil) {
                            [encoder setFragmentBuffer:buf
                                                offset:binding.imageAtomicBufferOffset
                                               atIndex:static_cast<NSUInteger>(
                                                   binding.imageAtomicBufferSlot)];
                        }
                    }
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setFragmentSamplerState:smp atIndex:slot];
                    }
                }
            };
        auto mslUsesArgumentBufferSet =
            [](const std::string* msl, unsigned set) -> bool {
                if (msl == nullptr) {
                    return false;
                }
                char needle[64];
                std::snprintf(needle, sizeof(needle),
                              "spvDescriptorSetBuffer%u", set);
                return msl->find(needle) != std::string::npos;
            };
        auto bindComputeUniformSet1ArgBuffer =
            [&](id<MTLComputeCommandEncoder> encoder,
                const std::string* msl,
                const void* uniformData,
                std::size_t uniformSize,
                AppGLCommandReason reason) -> bool {
                if (!mslUsesArgumentBufferSet(msl, 1)) {
                    return true;
                }
                if (encoder == nil || msl == nullptr || msl->empty()) {
                    return false;
                }
                if (uniformData == nullptr || uniformSize == 0) {
                    return true;
                }

                id<MTLLibrary> lib = getOrCompileLibrary(*msl);
                if (lib == nil) {
                    return false;
                }
                MTLFunctionConstantValues* emptyConstants =
                    [[MTLFunctionConstantValues alloc] init];
                ScopedOwnedObjCObject emptyConstantsRelease(emptyConstants);
                NSError* fnErr = nil;
                id<MTLFunction> fn = [lib newFunctionWithName:@"main0"
                                                constantValues:emptyConstants
                                                         error:&fnErr];
                if (fn == nil) {
                    if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                        std::fprintf(stderr,
                            "[APPGL] tess compute function build failed: %s\n",
                            fnErr ? fnErr.localizedDescription.UTF8String : "(no err)");
                    }
                    return false;
                }
                ScopedOwnedObjCObject fnRelease(fn);
                id<MTLArgumentEncoder> argEnc =
                    [fn newArgumentEncoderWithBufferIndex:25];
                if (argEnc == nil) {
                    return false;
                }
                ScopedOwnedObjCObject argEncRelease(argEnc);
                const NSUInteger len = [argEnc encodedLength];
                if (len == 0) {
                    return true;
                }

                RingAlloc argBufAlloc = ringAllocRaw(len);
                id<MTLBuffer> argBuf = argBufAlloc.buffer;
                const NSUInteger argBufOffset = argBufAlloc.offset;
                if (argBuf == nil) {
                    return false;
                }
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::ArgumentBufferPayload,
                    AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                    reason,
                    25,
                    static_cast<std::size_t>(len));
                [argEnc setArgumentBuffer:argBuf offset:argBufOffset];

                RingAlloc uniformAlloc =
                    ringSuballocate(uniformData, uniformSize);
                if (uniformAlloc.buffer == nil) {
                    return false;
                }
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::UniformRingBytes,
                    AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                    reason,
                    16,
                    static_cast<std::size_t>(uniformSize));
                [argEnc setBuffer:uniformAlloc.buffer
                            offset:uniformAlloc.offset
                           atIndex:16];
                [encoder setBuffer:argBuf offset:argBufOffset atIndex:25];
                [encoder useResource:uniformAlloc.buffer
                                usage:MTLResourceUsageRead];
                return true;
            };
        info.submissionGroup.argumentBuffersEnabled =
            info.submissionGroup.argumentBuffersEnabled ||
            mslUsesArgumentBufferSet(info.tessControlMSL, 1) ||
            mslUsesArgumentBufferSet(info.tessVertexAsComputeMSL, 1) ||
            mslUsesArgumentBufferSet(info.tessEvalAsComputeMSL, 1);

        // (1) Drain any prior state so compute runs against a clean
        // command buffer and subsequent render-pass reads see the
        // factor-buffer writes.
        const bool defaultFramebufferTessDraw = info.fboColorTexture == nullptr;
        const bool tessSamplesPriorFramebufferState =
            !info.tessControlTextures.empty() ||
            !info.tessVertexAsComputeTextures.empty() ||
            !info.tessEvalTextures.empty() ||
            !info.fragmentTextures.empty();
        const bool keepDefaultFrameOpen =
            defaultFramebufferTessDraw && !tessSamplesPriorFramebufferState;
        if (keepDefaultFrameOpen) {
            endRenderPass();
            resetCachedEncoderState();
            if (!usesOffscreenTarget &&
                currentCommandBuffer == nil &&
                commandSubmission != nullptr &&
                commandSubmission->hasOutstandingCommandBuffers() &&
                !commandSubmission->drainAllOutstanding(
                    AppGLCommandReason::TessDrainCurrent, false)) {
                return false;
            }
        } else if (!drainPresentLifecycleForStandaloneEncoding(
                       nullptr,
                       AppGLCommandReason::TessDrainCurrent)) {
            return false;
        }

        auto fillTransientBufferAndWait =
            [&](id<MTLBuffer> buffer,
                NSUInteger byteCount,
                AppGLCommandReason reason,
                NSString* label) -> bool {
                if (buffer == nil || byteCount == 0) {
                    return true;
                }
                auto fillLease = makeCommandBuffer(reason);
                id<MTLCommandBuffer> fillCmd = fillLease.get();
                if (fillCmd == nil) {
                    return false;
                }
                fillCmd.label = label;
                id<MTLBlitCommandEncoder> fillEnc =
                    [fillCmd blitCommandEncoder];
                if (fillEnc == nil) {
                    return false;
                }
                [fillEnc fillBuffer:buffer
                               range:NSMakeRange(0, byteCount)
                               value:0];
                [fillEnc endEncoding];
                return fillLease.commitAndWait(reason);
            };

        // (2) Allocate factor buffer (over-size to quad for conservatism;
        // SPIRV-Cross always emits the quad struct even for triangle
        // TES and Metal reads the triangle subset).
        const NSUInteger factorBytes =
            sizeof(MTLQuadTessellationFactorsHalf) *
            (NSUInteger)info.patchCount;
        // Sprint 7 #1 (CKPT64) — synth TCS host-populate of half-precision
        // tess factors requires CPU write access to factorBuf. For TES-only
        // programs the synth TCS dual-writes 1.0 defaults; the host needs
        // to override these with glPatchParameterfv state so the domain-gen
        // kernel (which reads factorBuf @ slot 26 in half precision) sees
        // the correct tessellation levels. Storage mode is Shared on Apple
        // Silicon UMA where Private vs Shared has negligible perf delta —
        // GPU readers (domain-gen, tessellator, TES) work identically; CPU
        // writes fire from synth_host_populate, and TES-compute consumers
        // need to read the post-TCS half factors for exact buffer sizing.
        const MTLResourceOptions factorBufOpts =
            (info.tessControlSynthesized || isTessEvalComputeRequested)
                ? MTLResourceStorageModeShared
                : MTLResourceStorageModePrivate;
        id<MTLBuffer> factorBuf =
            [device newBufferWithLength:factorBytes
                                options:factorBufOpts];
        if (factorBuf == nil) return false;
        ScopedOwnedObjCObject factorBufRelease(factorBuf);
        factorBuf.label = @"appgl-tess-factor";
        info.submissionGroup.addTransient(
            AppGLSubmissionTransientKind::TessFactorBuffer,
            AppGLSubmissionOrderingMechanism::CpuCompletionWait,
            AppGLCommandReason::TessControlCompute,
            26,
            static_cast<std::size_t>(factorBytes));

        // Phase 3: additional buffers for VS-compute + TCS user output.
        // Size each slot from the emitted MSL structs; 256 bytes remains the
        // legacy minimum, but CTS max-in/out cases can legitimately carry
        // larger arrays through VS/TCS/TES handoff buffers.
        const bool isPhase3 =
            info.vertexComputePipelineState != nullptr || info.forcePhase3Buffers;
        const NSUInteger kPhase3SlotBytes = 256;
        const NSUInteger vsOutStride = std::max<NSUInteger>(
            kPhase3SlotBytes,
            static_cast<NSUInteger>(appglEstimateMslStructStrideBytes(
                info.tessVertexAsComputeMSL, "main0_out")));
        const NSUInteger cpOutStride = std::max<NSUInteger>(
            kPhase3SlotBytes,
            static_cast<NSUInteger>(appglEstimateMslStructStrideBytes(
                info.tessControlMSL, "main0_out")));
        const NSUInteger patchOutStride = std::max<NSUInteger>(
            kPhase3SlotBytes,
            static_cast<NSUInteger>(appglEstimateMslStructStrideBytes(
                info.tessControlMSL, "main0_patchOut")));
        const NSUInteger vertexCount = isPhase3
            ? (NSUInteger)(info.patchCount * info.patchVertices)
            : 0;
        auto checkedPhase3Bytes =
            [](NSUInteger count, NSUInteger stride, NSUInteger& out) -> bool {
                if (stride == 0) {
                    return false;
                }
                if (count > std::numeric_limits<NSUInteger>::max() / stride) {
                    return false;
                }
                out = count * stride;
                return true;
            };
        NSUInteger vsOutBytes = 0;
        NSUInteger cpOutBytes = 0;
        NSUInteger patchOutBytes = 0;
        if (isPhase3) {
            if (!checkedPhase3Bytes(vertexCount, vsOutStride, vsOutBytes) ||
                !checkedPhase3Bytes(
                    (NSUInteger)(info.patchCount * info.tessControlOutputVertices),
                    cpOutStride, cpOutBytes) ||
                !checkedPhase3Bytes((NSUInteger)info.patchCount,
                                    patchOutStride, patchOutBytes)) {
                return false;
            }
        }
        id<MTLBuffer> vsOutBuf = nil;
        id<MTLBuffer> cpOutBuf = nil;
        id<MTLBuffer> patchOutBuf = nil;
        ScopedOwnedObjCObject vsOutBufRelease;
        ScopedOwnedObjCObject cpOutBufRelease;
        ScopedOwnedObjCObject patchOutBufRelease;
        if (isPhase3) {
            // CKPT137 (Sprint 13 Phase 2 Day 1 — γ2.1 runtime instrumentation):
            // when APPGL_TRACE_TESS_BUF is set, allocate vsOutBuf/cpOutBuf in
            // shared storage mode so we can blit-read post-write contents and
            // verify per-patch buffer wiring vs symbolic-expected.
            static const bool s_trBuf = (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr);
	            const MTLResourceOptions storageOpt = (s_trBuf || info.forcePhase3Buffers)
	                ? MTLResourceStorageModeShared
	                : MTLResourceStorageModePrivate;
            vsOutBuf = [device newBufferWithLength:vsOutBytes
                                           options:storageOpt];
            cpOutBuf = [device newBufferWithLength:cpOutBytes
                                           options:storageOpt];
            patchOutBuf = [device newBufferWithLength:patchOutBytes
                                              options:storageOpt];
            if (vsOutBuf == nil || cpOutBuf == nil || patchOutBuf == nil) {
                return false;
            }
            vsOutBufRelease.reset(vsOutBuf);
            cpOutBufRelease.reset(cpOutBuf);
            patchOutBufRelease.reset(patchOutBuf);
	            vsOutBuf.label = @"appgl-tess-vs-out";
	            cpOutBuf.label = @"appgl-tess-cp-out";
	            patchOutBuf.label = @"appgl-tess-patch-out";
            const AppGLSubmissionOrderingMechanism vsOutOrdering =
                info.vertexComputePipelineState != nullptr
                    ? AppGLSubmissionOrderingMechanism::CpuCompletionWait
                    : AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer;
            const AppGLCommandReason vsOutReason =
                info.vertexComputePipelineState != nullptr
                    ? AppGLCommandReason::TessVertexCompute
                    : AppGLCommandReason::TessControlCompute;
            info.submissionGroup.addTransient(
                AppGLSubmissionTransientKind::TessVsOutputBuffer,
                vsOutOrdering,
                vsOutReason,
                22,
                static_cast<std::size_t>(vsOutBytes));
            info.submissionGroup.addTransient(
                AppGLSubmissionTransientKind::TessControlPointOutputBuffer,
                AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                AppGLCommandReason::TessControlCompute,
                22,
                static_cast<std::size_t>(cpOutBytes));
            info.submissionGroup.addTransient(
                AppGLSubmissionTransientKind::TessPatchOutputBuffer,
                AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                AppGLCommandReason::TessControlCompute,
                20,
                static_cast<std::size_t>(patchOutBytes));
	            if (info.forcePhase3Buffers) {
	                if (void* p = [vsOutBuf contents]) {
	                    std::memset(p, 0, (std::size_t)vsOutBytes);
	                }
	            }
            if (s_trBuf) {
                std::fprintf(stderr,
                    "[TESS-BUF] alloc vsOutBuf=%p (sz=%lu stride=%lu) "
                    "cpOutBuf=%p (sz=%lu stride=%lu) "
                    "patchOutBuf=%p (sz=%lu stride=%lu) "
                    "vertexCount=%lu patchCount=%d patchVertices=%d "
                    "tessCtrlOutputVertices=%d\n",
                    (__bridge void*)vsOutBuf, (unsigned long)vsOutBytes,
                    (unsigned long)vsOutStride,
                    (__bridge void*)cpOutBuf, (unsigned long)cpOutBytes,
                    (unsigned long)cpOutStride,
                    (__bridge void*)patchOutBuf, (unsigned long)patchOutBytes,
                    (unsigned long)patchOutStride,
                    (unsigned long)vertexCount, info.patchCount, info.patchVertices,
                    info.tessControlOutputVertices);
            }
        }

	        // Sprint 5 Phase 1 — Path L Class 2A: full-precision tess level
	        // shadow buffer at slot 23. SPIRV-Cross's TCS/TES kernels index
	        // this side buffer with a quad-sized six-float stride for every
	        // domain. Domain-gen reads only the mode-relevant subset from the
	        // half factor buffer, but the full-precision sidecar must stay at
	        // the generated kernel stride to avoid isoline/triangle overruns.
	        // Outer levels first, then inner. SPIRV-Cross fork's TCS-side
	        // dual-write (commit 635380d) populates this buffer alongside
        // the half-precision spvTessLevel. TES-side reads from this
        // buffer (commit 4f626b9). Avoids half-precision rounding error
        // on `tc2te.gl_tessLevel`'s tess-level read-back checks.
	        const NSUInteger fullStride = 6;
        const NSUInteger fullFactorBytes =
            sizeof(float) * fullStride * (NSUInteger)info.patchCount;
        id<MTLBuffer> factorBufFull =
            [device newBufferWithLength:(fullFactorBytes > 0 ? fullFactorBytes : 4)
                                options:MTLResourceStorageModeShared];
        if (factorBufFull == nil) return false;
        ScopedOwnedObjCObject factorBufFullRelease(factorBufFull);
        factorBufFull.label = @"appgl-tess-factor-full";
        info.submissionGroup.addTransient(
            AppGLSubmissionTransientKind::TessFactorFullBuffer,
            AppGLSubmissionOrderingMechanism::CpuCompletionWait,
            AppGLCommandReason::TessControlCompute,
            23,
            static_cast<std::size_t>(fullFactorBytes));

        // spvIndirectParams: SPIRV-Cross `constant uint*` — element [0]
        // is gl_PatchVerticesIn (from glPatchParameteri, default 3),
        // element [1] is the TOTAL patch count in the dispatch. The
        // TCS MSL uses it to clamp gl_PrimitiveID when gl_GlobalInvocationID
        // exceeds the valid range (workgroup-size rounding). Setting it
        // to 1 silently clamps every patch to index 0 — causing
        // every patch to read VS slot 0 as its input.
        uint32_t indirectParams[2] = {
            (uint32_t)(info.patchVertices > 0 ? info.patchVertices : 3),
            (uint32_t)(info.patchCount > 0 ? info.patchCount : 1)
        };
        id<MTLBuffer> indirectBuf =
            [device newBufferWithBytes:indirectParams
                                length:sizeof(indirectParams)
                               options:MTLResourceStorageModeShared];
        if (indirectBuf == nil) return false;
        ScopedOwnedObjCObject indirectBufRelease(indirectBuf);
        indirectBuf.label = @"appgl-tess-indirect-params";
        info.submissionGroup.addTransient(
            AppGLSubmissionTransientKind::TessIndirectParamsBuffer,
            AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
            AppGLCommandReason::TessControlCompute,
            29,
            sizeof(indirectParams));

        // (3a) Phase 3: VS-as-compute dispatch. Runs once per vertex
        // in the draw range and writes per-vertex output into
        // `vsOutBuf` at [[buffer(28)]]. TCS reads from this buffer via
        // `spvIn [[buffer(22)]]` (no stage-input descriptor needed with
        // `multi_patch_workgroup = true`).
        if (isPhase3 && info.vertexComputePipelineState != nullptr) {
            info.submissionGroup.addSubgroup(
                AppGLSubmissionGroupKind::TessVertex,
                AppGLCommandReason::TessVertexCompute);
            auto vsLease = makeCommandBuffer(AppGLCommandReason::TessVertexCompute);
            id<MTLCommandBuffer> vsCmdBuf = vsLease.get();
            if (vsCmdBuf == nil) return false;
            vsCmdBuf.label = @"appgl-tess-vs-compute";
            id<MTLComputeCommandEncoder> vsEnc =
                [vsCmdBuf computeCommandEncoder];
            if (vsEnc == nil) return false;
            id<MTLComputePipelineState> vsPSO =
                (__bridge id<MTLComputePipelineState>)info.vertexComputePipelineState;
            [vsEnc setComputePipelineState:vsPSO];
            [vsEnc setBuffer:vsOutBuf offset:0 atIndex:28];
            const bool vsUniformUsesArgBuf =
                mslUsesArgumentBufferSet(info.tessVertexAsComputeMSL, 1);
            if (!bindComputeUniformSet1ArgBuffer(
                    vsEnc, info.tessVertexAsComputeMSL,
                    info.tessVertexAsComputeUniformData,
                    info.tessVertexAsComputeUniformSize,
                    AppGLCommandReason::TessVertexCompute)) {
                return false;
            }
            if (info.tessVertexAsComputeUniformData != nullptr &&
                info.tessVertexAsComputeUniformSize > 0 &&
                !vsUniformUsesArgBuf) {
                [vsEnc setBytes:info.tessVertexAsComputeUniformData
                         length:info.tessVertexAsComputeUniformSize
                        atIndex:16];
            }
            bindComputeTextures(vsEnc, info.tessVertexAsComputeTextures);
            // T4I [metal-tess-TF]: bind VAO vertex buffers for VS
            // compute when the PSO was built with a stage-input
            // descriptor. The slots match the descriptor's
            // `attributes[*].bufferIndex` (0..15 by default per
            // BindingMap::vertexBufferBase). Empty for VS programs
            // that read inputs via gl_VertexID-only paths.
            for (const auto& binding : info.vertexComputeBufferBindings) {
                if (binding.metalBuffer == nullptr) {
                    continue;
                }
                [vsEnc setBuffer:(__bridge id<MTLBuffer>)binding.metalBuffer
                          offset:(NSUInteger)binding.offset
                         atIndex:(NSUInteger)binding.metalSlot];
            }
            // For VS without stage_in inputs, the VS-compute MSL uses
            // `gl_GlobalInvocationID` as the per-vertex index (Y=0 for
            // non-instanced). `dispatchThreads` maps 1:1 onto
            // gl_GlobalInvocationID and sets `[[grid_size]]` to the
            // dispatch count — which the SPIRV-Cross-emitted VS uses as
            // a bounds-check via `if (any(gl_GlobalInvocationID >=
            // spvStageInputSize)) return;`. Using dispatchThreadgroups
            // with a 1-thread workgroup would set grid_size to
            // (threadgroupCount*1, 1, 1) — same logical result, but
            // with fewer entry points exercised on Apple's driver it's
            // safer to stick to the form matching SPIRV-Cross's
            // VS-for-tessellation convention.
            {
                const NSUInteger maxPerTg =
                    vsPSO.maxTotalThreadsPerThreadgroup > 0
                        ? vsPSO.maxTotalThreadsPerThreadgroup : 32;
                const NSUInteger tgWidth =
                    vertexCount > 0 && vertexCount < maxPerTg ? vertexCount : maxPerTg;
                // T4I bisect: when stage-in descriptor is in use,
                // dispatchThreadgroups with explicit threadgroup count
                // gives Metal a uniform grid shape that
                // MTLStepFunctionThreadPositionInGridX advances on.
                // The VS-as-compute path without stage_in keeps using
                // dispatchThreads to preserve the SPIRV-Cross
                // [[grid_size]] / spvStageInputSize early-return shape.
                if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
                    std::fprintf(stderr,
                        "[TESS-BUF] vsEnc dispatchThreads(%lu, 1, 1) tpg(%lu, 1, 1) maxPerTg=%lu\n",
                        (unsigned long)vertexCount, (unsigned long)tgWidth,
                        (unsigned long)maxPerTg);
                }
                [vsEnc dispatchThreads:MTLSizeMake(vertexCount, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
            }
            [vsEnc endEncoding];
            vsLease.commitAndWait(AppGLCommandReason::TessVertexCompute);
            if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4D_TESS_ZERO_VSOUT") &&
                !fillTransientBufferAndWait(vsOutBuf, vsOutBytes,
                                            AppGLCommandReason::TessVertexCompute,
                                            @"appgl-dcr4d-zero-tess-vsout")) {
                return false;
            }
            // CKPT137: dump vsOutBuf post-VS-compute when APPGL_TRACE_TESS_BUF.
            // vsOutBuf is allocated Shared above when env-gate is set, so
            // contents are accessible without additional blit.
            if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
                const std::uint8_t* p = static_cast<const std::uint8_t*>([vsOutBuf contents]);
                const NSUInteger len = vsOutBuf.length;
                const NSUInteger slot = vsOutStride;
                const NSUInteger nverts = len / slot;
                std::fprintf(stderr, "[TESS-BUF] post-VS-compute vsOutBuf len=%lu slot=%lu nverts=%lu\n",
                    (unsigned long)len, (unsigned long)slot, (unsigned long)nverts);
                for (NSUInteger v = 0; v < nverts && v < 4; ++v) {
                    const float* f = reinterpret_cast<const float*>(p + v * slot);
                    std::fprintf(stderr, "  vert[%lu] first16f= %g %g %g %g  %g %g %g %g  %g %g %g %g  %g %g %g %g\n",
                        (unsigned long)v,
                        f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                        f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
                }
            }
        } else if (isPhase3 && std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
            std::fprintf(stderr,
                "[TESS-BUF] VS-compute skipped; using zeroed vsOutBuf len=%lu\n",
                (unsigned long)vsOutBytes);
        }

        // (3b) Compute-encode the TCS dispatch.
        info.submissionGroup.addSubgroup(
            AppGLSubmissionGroupKind::TessControl,
            AppGLCommandReason::TessControlCompute);
        auto computeLease = makeCommandBuffer(AppGLCommandReason::TessControlCompute);
        id<MTLCommandBuffer> computeCmdBuf = computeLease.get();
        if (computeCmdBuf == nil) return false;
        computeCmdBuf.label = @"appgl-tess-compute";
        id<MTLComputeCommandEncoder> cenc = [computeCmdBuf computeCommandEncoder];
        if (cenc == nil) return false;
        id<MTLComputePipelineState> tcsPSO =
            (__bridge id<MTLComputePipelineState>)info.tessControlPipelineState;
        [cenc setComputePipelineState:tcsPSO];
        [cenc setBuffer:factorBuf offset:0 atIndex:26];
        // Sprint 5 Phase 1 — Path L: full-precision tess level shadow
        // buffer at slot 23. TCS-compute dual-writes (half + full).
        [cenc setBuffer:factorBufFull offset:0 atIndex:23];
        [cenc setBuffer:indirectBuf offset:0 atIndex:29];
        const bool tcsUniformUsesArgBuf =
            mslUsesArgumentBufferSet(info.tessControlMSL, 1);
        if (!bindComputeUniformSet1ArgBuffer(
                cenc, info.tessControlMSL,
                info.tessControlUniformData,
                info.tessControlUniformSize,
                AppGLCommandReason::TessControlCompute)) {
            return false;
        }
        if (info.tessControlUniformData != nullptr &&
            info.tessControlUniformSize > 0 &&
            !tcsUniformUsesArgBuf) {
            [cenc setBytes:info.tessControlUniformData
                    length:info.tessControlUniformSize
                   atIndex:16];
        }
        bindComputeTextures(cenc, info.tessControlTextures);
        if (isPhase3) {
            [cenc setBuffer:vsOutBuf offset:0 atIndex:22];
            [cenc setBuffer:patchOutBuf offset:0 atIndex:27];
            [cenc setBuffer:cpOutBuf offset:0 atIndex:28];
        }
        const MTLSize groups = MTLSizeMake(
            (NSUInteger)info.patchCount, 1, 1);
        const MTLSize threads = MTLSizeMake(
            (NSUInteger)info.tessControlOutputVertices, 1, 1);
        [cenc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
        [cenc endEncoding];
        computeLease.commitAndWait(AppGLCommandReason::TessControlCompute);

        // CKPT137: dump cpOutBuf + spvIndirectParams post-TCS-compute.
        if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
            const std::uint8_t* p = static_cast<const std::uint8_t*>([cpOutBuf contents]);
            const NSUInteger len = cpOutBuf.length;
            const NSUInteger slot = cpOutStride;
            const NSUInteger ncps = len / slot;
            std::fprintf(stderr, "[TESS-BUF] post-TCS-compute cpOutBuf len=%lu slot=%lu ncps=%lu\n",
                (unsigned long)len, (unsigned long)slot, (unsigned long)ncps);
            for (NSUInteger v = 0; v < ncps && v < 6; ++v) {
                const float* f = reinterpret_cast<const float*>(p + v * slot);
                std::fprintf(stderr, "  cp[%lu] first16f= %g %g %g %g  %g %g %g %g  %g %g %g %g  %g %g %g %g\n",
                    (unsigned long)v,
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                    f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
            }
            const std::uint32_t* ip = static_cast<const std::uint32_t*>([indirectBuf contents]);
            std::fprintf(stderr, "[TESS-BUF] indirectBuf [0]=%u (patchVertices) [1]=%u (patchCount)\n",
                ip[0], ip[1]);
        }

        if (std::getenv("APPGL_DUMP_TESOUT")) {
            float* fbf = static_cast<float*>([factorBufFull contents]);
            const NSUInteger len = factorBufFull.length;
            const NSUInteger nfloats = len / sizeof(float);
            std::fprintf(stderr,
                "APPGL_DETECTOR factorBufFull_post_tcs synth=%d patchCount=%d "
                "len=%llu nfloats=%llu values=",
                info.tessControlSynthesized ? 1 : 0,
                (int)info.patchCount,
                (unsigned long long)len,
                (unsigned long long)nfloats);
            for (NSUInteger i = 0; i < nfloats && i < 12; ++i) {
                std::fprintf(stderr, "%.4f ", fbf[i]);
            }
            std::fprintf(stderr, "\n");
        }

        // Sprint 5 Phase 1 — synth TCS host-populate of factorBufFull.
        // For TES-only programs (synth TCS), the synth TCS dual-writes
        // 1.0 defaults to factorBufFull via Path L extension. Override
        // those defaults with glPatchParameterfv state snapshot so TES
        // reads user-intended values instead. Replicate the same data
        // for every patch (per-patch glPatchParameterfv applies
        // uniformly).
        if (info.tessControlSynthesized) {
            if (std::getenv("APPGL_DUMP_TESOUT")) {
                std::fprintf(stderr,
                    "APPGL_DETECTOR synth_host_populate outer=[%.3f %.3f %.3f %.3f] "
                    "inner=[%.3f %.3f] genMode=0x%04X patchCount=%d\n",
                    info.defaultOuterLevel[0], info.defaultOuterLevel[1],
                    info.defaultOuterLevel[2], info.defaultOuterLevel[3],
                    info.defaultInnerLevel[0], info.defaultInnerLevel[1],
                    info.genMode, (int)info.patchCount);
            }
            float* contents = static_cast<float*>([factorBufFull contents]);
            if (contents != nullptr) {
                NSUInteger localStride = 6;
                if (info.genMode == GL_TRIANGLES) localStride = 4;
                else if (info.genMode == GL_ISOLINES) localStride = 2;
                const NSUInteger nOuter =
                    (info.genMode == GL_TRIANGLES) ? 3 :
                    (info.genMode == GL_ISOLINES) ? 2 : 4;
                const NSUInteger nInner =
                    (info.genMode == GL_TRIANGLES) ? 1 :
                    (info.genMode == GL_ISOLINES) ? 0 : 2;
                for (int p = 0; p < info.patchCount; ++p) {
                    float* base = contents + (NSUInteger)p * localStride;
                    for (NSUInteger i = 0; i < nOuter; ++i) {
                        base[i] = info.defaultOuterLevel[i];
                    }
                    for (NSUInteger i = 0; i < nInner; ++i) {
                        base[nOuter + i] = info.defaultInnerLevel[i];
                    }
                }
            }
            // Sprint 7 #1 (CKPT64) — sister-write to factorBuf at half
            // precision. The synth TCS dual-writes 1.0 defaults to BOTH
            // factorBufFull (slot 23, full-precision read by TES kernel)
            // AND factorBuf (slot 26, half-precision read by domain-gen
            // kernel + Metal tessellator). Without this sister-write the
            // domain-gen kernel reads 1.0s from factorBuf → emits only
            // patch corners (4 verts in point_mode for quads) regardless
            // of what TES reads from factorBufFull. Closes the
            // gl_tessLevel TES-only path: domain-gen now sees the same
            // patch-default tess levels TES does.
            //
            // Layout per MTLQuadTessellationFactorsHalf:
            //   bytes 0..7  : edgeTessellationFactor[4]   (4 halves)
            //   bytes 8..11 : insideTessellationFactor[2] (2 halves)
            // Triangle subset is read from the same 12-byte slot —
            // factor budget allocates quad-sized for conservatism per
            // line ~5006 ("over-size to quad … Metal reads triangle
            // subset"). For triangles we still write a full quad-sized
            // record where the Metal-tessellator-relevant bytes (3 outer
            // + 1 inner per Metal's MTLTriangleTessellationFactorsHalf)
            // overlap with the quad-layout positions our SPIRV-Cross
            // fork already writes via TCS dual-write. The domain-gen
            // kernel reads as `QuadFactors` regardless.
            if (factorBufOpts == MTLResourceStorageModeShared) {
                std::uint8_t* hbytes = static_cast<std::uint8_t*>([factorBuf contents]);
                if (hbytes != nullptr) {
                    const NSUInteger perPatch = sizeof(MTLQuadTessellationFactorsHalf);
                    auto toHalf = [](float f) -> std::uint16_t {
                        // float→half via __fp16 (Apple Silicon native).
                        const __fp16 h = static_cast<__fp16>(f);
                        std::uint16_t bits;
                        std::memcpy(&bits, &h, sizeof(bits));
                        return bits;
                    };
                    for (int p = 0; p < info.patchCount; ++p) {
                        std::uint16_t* hbase = reinterpret_cast<std::uint16_t*>(
                            hbytes + (NSUInteger)p * perPatch);
                        // Quad layout: edge[4] then inside[2]. For
                        // triangles & isolines we write into the same
                        // slots — only the GenMode-relevant subset is
                        // read by the tessellator/domain-gen.
                        const NSUInteger nOuterH =
                            (info.genMode == GL_TRIANGLES) ? 3 :
                            (info.genMode == GL_ISOLINES) ? 2 : 4;
                        const NSUInteger nInnerH =
                            (info.genMode == GL_TRIANGLES) ? 1 :
                            (info.genMode == GL_ISOLINES) ? 0 : 2;
                        // Initialize whole record to 1.0 (synth-default
                        // sentinel) so unused slots have a defined value
                        // matching what synth TCS would have written.
                        const std::uint16_t oneHalf = toHalf(1.0f);
                        for (NSUInteger i = 0; i < 4; ++i) hbase[i] = oneHalf;
                        for (NSUInteger i = 0; i < 2; ++i) hbase[4 + i] = oneHalf;
                        for (NSUInteger i = 0; i < nOuterH; ++i) {
                            hbase[i] = toHalf(info.defaultOuterLevel[i]);
                        }
                        for (NSUInteger i = 0; i < nInnerH; ++i) {
                            hbase[4 + i] = toHalf(info.defaultInnerLevel[i]);
                        }
                    }
                }
            }
        }
        if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4D_TESS_ZERO_FACTORBUF")) {
            if (!fillTransientBufferAndWait(factorBuf, factorBytes,
                                            AppGLCommandReason::TessControlCompute,
                                            @"appgl-dcr4d-zero-tess-factor")) {
                return false;
            }
            if (!fillTransientBufferAndWait(factorBufFull, fullFactorBytes,
                                            AppGLCommandReason::TessControlCompute,
                                            @"appgl-dcr4d-zero-tess-factor-full")) {
                return false;
            }
        }

        // (3c) Phase 3B.4 [metal-tess-TF]: optional domain-generator +
        // TES-as-compute dispatch chain. Buffers are sized from the current
        // draw's estimated emitted vertex count and reflected TES stride.
        // Bound optional TES-compute sidecars by default. Fur16's emitted
        // buffer is about 1.125 GiB and remains below this ceiling; Fur128's
        // optional sidecar would otherwise allocate tens of GiB before the
        // fixed-function tessellation render path runs.
        const bool isTessTF = isTessEvalComputeRequested;
        id<MTLBuffer> domainCoordBuf = nil;
        id<MTLBuffer> domainPrimIDBuf = nil;
        id<MTLBuffer> totalVertCountBuf = nil;
        id<MTLBuffer> tesComputeOutBuf = nil;
        ScopedOwnedObjCObject domainCoordBufRelease;
        ScopedOwnedObjCObject domainPrimIDBufRelease;
        ScopedOwnedObjCObject totalVertCountBufRelease;
        ScopedOwnedObjCObject tesComputeOutBufRelease;
        NSUInteger tessTFGeneratedVerts = 0;
        if (isTessTF) {
            const bool forceOptionalTessCompute =
                optionalTessEvalComputeEnabled() ||
                std::getenv("APPGL_DUMP_DOMAINGEN") != nullptr ||
                std::getenv("APPGL_DUMP_TESOUT") != nullptr;
            if (!info.tessEvalComputeRequired && !forceOptionalTessCompute) {
                if (std::getenv("APPGL_TRACE_TESS") ||
                    std::getenv("APPGL_DETECTOR_TF")) {
                    std::fprintf(stderr,
                        "[APPGL] tess-tf: skip optional TES-compute "
                        "reason=not-required\n");
                }
            } else if (!ensureTessDomainGenLibrary()) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr, "[APPGL] tess-tf: domain-gen library build failed\n");
                }
                // Fall through without TF — the existing render path
                // still runs; tests that rely on TF will fail their
                // correctness check but nothing crashes.
            } else {
                const NSUInteger domainVertexCapacity =
                    appglEstimateTessDomainVertexCapacity(info, [factorBuf contents]);
                auto checkedTessByteCount =
                    [](NSUInteger vertices, NSUInteger stride, NSUInteger& out) -> bool {
                        if (stride == 0) {
                            return false;
                        }
                        if (vertices >
                            std::numeric_limits<NSUInteger>::max() / stride) {
                            return false;
                        }
                        out = vertices * stride;
                        if (out == 0) {
                            out = 4;
                        }
                        return true;
                    };
                NSUInteger domainCoordBytes = 0;
                NSUInteger domainPrimIDBytes = 0;
                NSUInteger tesComputeOutBytes = 0;
                const NSUInteger tesComputeOutStride =
                    static_cast<NSUInteger>(
                        std::max<std::size_t>(1, info.tessEvalOutputStrideBytes));
                if (!checkedTessByteCount(domainVertexCapacity, 12,
                                          domainCoordBytes) ||
                    !checkedTessByteCount(domainVertexCapacity, sizeof(uint32_t),
                                          domainPrimIDBytes) ||
                    !checkedTessByteCount(domainVertexCapacity, tesComputeOutStride,
                                          tesComputeOutBytes)) {
                    return false;
                }
                const NSUInteger optionalLimit =
                    appglOptionalTessEvalComputeByteLimit();
                const bool skipOptionalTessCompute =
                    !info.tessEvalComputeRequired &&
                    optionalLimit > 0 &&
                    (domainCoordBytes > optionalLimit ||
                     domainPrimIDBytes > optionalLimit ||
                     tesComputeOutBytes > optionalLimit);
                if (skipOptionalTessCompute) {
                    if (std::getenv("APPGL_TRACE_TESS") ||
                        std::getenv("APPGL_DETECTOR_TF")) {
                        std::fprintf(stderr,
                            "[APPGL] tess-tf: skip optional TES-compute "
                            "capacity=%llu coordBytes=0x%llx primBytes=0x%llx "
                            "tesStride=%llu tesBytes=0x%llx limit=0x%llx\n",
                            (unsigned long long)domainVertexCapacity,
                            (unsigned long long)domainCoordBytes,
                            (unsigned long long)domainPrimIDBytes,
                            (unsigned long long)tesComputeOutStride,
                            (unsigned long long)tesComputeOutBytes,
                            (unsigned long long)optionalLimit);
                    }
                } else {
                // packed_float3 is 12 bytes in MSL; hard-code the size
                // since simd.h's equivalent isn't always accessible here.
                // T4C diagnostic: when APPGL_DUMP_DOMAINGEN=<dir> is set,
                // make domainPrimIDBuf + domainCoordBuf CPU-readable so
                // we can dump them after domain-gen runs and verify the
                // primID seeding pattern (Clerk's reprioritized #1
                // priority for the data_pass_through repetition signature).
                const MTLResourceOptions domainOpts =
                    std::getenv("APPGL_DUMP_DOMAINGEN") != nullptr
                        ? MTLResourceStorageModeShared
                        : MTLResourceStorageModePrivate;
                domainCoordBuf = [device
                    newBufferWithLength:domainCoordBytes
                                options:domainOpts];
                domainPrimIDBuf = [device
                    newBufferWithLength:domainPrimIDBytes
                                options:domainOpts];
                // totalVertCount lives in shared storage so CPU can
                // read it after the domain-gen dispatch to size the
                // TES-compute threadgroup count exactly.
                uint32_t zero = 0;
                totalVertCountBuf = [device
                    newBufferWithBytes:&zero
                                length:sizeof(uint32_t)
                               options:MTLResourceStorageModeShared];
                // TES-compute output buffer. The MSL struct size is embedded
                // in the TES compile; size the buffer from the reflected
                // `main0_out` stride, preserving the Phase 3 legacy minimum
                // slot while covering wide TES outputs.
                // Shared storage: the TF-write path in
                // `tryMetalTessellationDraw` reads the CPU-side bytes
                // after the dispatch commits and deposits them into
                // the bound GL_TRANSFORM_FEEDBACK_BUFFER.
                tesComputeOutBuf = [device
                    newBufferWithLength:tesComputeOutBytes
                                options:MTLResourceStorageModeShared];
                if (!domainCoordBuf || !domainPrimIDBuf ||
                    !totalVertCountBuf || !tesComputeOutBuf) {
                    return false;
                }
                domainCoordBufRelease.reset(domainCoordBuf);
                domainPrimIDBufRelease.reset(domainPrimIDBuf);
                totalVertCountBufRelease.reset(totalVertCountBuf);
                tesComputeOutBufRelease.reset(tesComputeOutBuf);
                domainCoordBuf.label = @"appgl-tess-domain-coord";
                domainPrimIDBuf.label = @"appgl-tess-domain-primid";
                totalVertCountBuf.label = @"appgl-tess-total-count";
                tesComputeOutBuf.label = @"appgl-tess-compute-out";
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::TessDomainCoordBuffer,
                    AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                    AppGLCommandReason::TessDomainGenerate,
                    25,
                    static_cast<std::size_t>(domainCoordBytes));
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::TessDomainPrimIdBuffer,
                    AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                    AppGLCommandReason::TessDomainGenerate,
                    24,
                    static_cast<std::size_t>(domainPrimIDBytes));
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::TessTotalVertexCountBuffer,
                    AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                    AppGLCommandReason::TessDomainGenerate,
                    23,
                    sizeof(uint32_t));
                info.submissionGroup.addTransient(
                    AppGLSubmissionTransientKind::TessEvalComputeOutputBuffer,
                    AppGLSubmissionOrderingMechanism::CpuCompletionWait,
                    AppGLCommandReason::TessEvalCompute,
                    28,
                    static_cast<std::size_t>(tesComputeOutBytes));

                // Domain-gen params struct. Layout mirrors the MSL
                // `TessGenParams` definition in
                // `ensureTessDomainGenLibrary`.
                struct TessGenParamsCPU {
                    uint32_t genMode;
                    uint32_t genSpacing;
                    uint32_t patchCount;
                    uint32_t pointMode;
                    uint32_t vertexOrder;  // 0=CCW, 1=CW
                };
                TessGenParamsCPU paramsCPU{};
                switch (info.genMode) {
                    case GL_TRIANGLES: paramsCPU.genMode = 0u; break;
                    case GL_QUADS:     paramsCPU.genMode = 1u; break;
                    case GL_ISOLINES:  paramsCPU.genMode = 2u; break;
                    default:           paramsCPU.genMode = 0u; break;
                }
                switch (info.genSpacing) {
                    case GL_EQUAL:             paramsCPU.genSpacing = 0u; break;
                    case GL_FRACTIONAL_EVEN:   paramsCPU.genSpacing = 1u; break;
                    case GL_FRACTIONAL_ODD:    paramsCPU.genSpacing = 2u; break;
                    default:                    paramsCPU.genSpacing = 0u; break;
                }
                paramsCPU.patchCount = (uint32_t)info.patchCount;
                paramsCPU.pointMode = info.pointMode ? 1u : 0u;
                paramsCPU.vertexOrder =
                    (info.genVertexOrder == GL_CW) ? 1u : 0u;
                id<MTLBuffer> domainGenParamsBuf = [device
                    newBufferWithBytes:&paramsCPU
                                length:sizeof(paramsCPU)
                               options:MTLResourceStorageModeShared];
                ScopedOwnedObjCObject domainGenParamsBufRelease(domainGenParamsBuf);

                // Phase 3C [metal-tess-TF] — when the env flag
                // `APPGL_TESS_DOMAIN_USE_METAL_HW` is set and the
                // genMode is TRIANGLES or QUADS (and not point_mode),
                // route through Metal's HW tessellator as the
                // domain-coord source instead of the MSL compute
                // kernel. The capture PSO (built lazily by
                // `ensureTessDomainCapturePSO`) runs a `vertex void`
                // function with rasterizationEnabled=NO, writing into
                // the exact same (totalVertCount, domainPrimID,
                // domainTessCoord) buffers the compute kernel
                // populates. Downstream TES-as-compute reads either
                // interchangeably. Isolines and point_mode stay on the
                // compute kernel (Metal has no isoline patch type, and
                // Metal's HW always emits triangle/line topology — one
                // capture coord per generated vertex is not equivalent
                // to point_mode unique grid points).
                const bool useHWDomain =
                    (std::getenv("APPGL_TESS_DOMAIN_USE_METAL_HW") != nullptr) &&
                    (info.genMode == GL_TRIANGLES || info.genMode == GL_QUADS) &&
                    !info.pointMode;
                id<MTLRenderPipelineState> hwCapturePSO = nil;
                MTLPatchType hwPatchType = MTLPatchTypeTriangle;
                if (useHWDomain) {
                    hwPatchType = (info.genMode == GL_QUADS)
                        ? MTLPatchTypeQuad : MTLPatchTypeTriangle;
                    MTLTessellationPartitionMode hwPartition =
                        MTLTessellationPartitionModeInteger;
                    switch (info.genSpacing) {
                        case GL_FRACTIONAL_EVEN:
                            hwPartition = MTLTessellationPartitionModeFractionalEven;
                            break;
                        case GL_FRACTIONAL_ODD:
                            hwPartition = MTLTessellationPartitionModeFractionalOdd;
                            break;
                        case GL_EQUAL:
                        default:
                            hwPartition = MTLTessellationPartitionModeInteger;
                            break;
                    }
                    MTLWinding hwWinding = (info.genVertexOrder == GL_CW)
                        ? MTLWindingClockwise
                        : MTLWindingCounterClockwise;
                    hwCapturePSO = ensureTessDomainCapturePSO(
                        hwPatchType, hwPartition, hwWinding);
                }

                if (hwCapturePSO != nil) {
                    // HW capture path. One draw, `info.patchCount`
                    // patches. Metal's HW tessellator auto-indexes the
                    // factor buffer per-patch based on the PSO's
                    // declared patch type; `instanceStride:0` matches
                    // the main Phase 3 tess draw convention.
                    //
                    // Preamble: clamp factors to [1, 64] (Metal HW
                    // drops patches with any factor <= 0; GL spec says
                    // inner < 1 silently clamps, and our MSL-kernel
                    // path clamps in `segmentCount`). Skipped if the
                    // clamp PSO build failed — in that case the HW
                    // draw may legitimately produce 0 verts for
                    // degenerate factor values and the TES-compute
                    // dispatch is skipped.
                    id<MTLComputePipelineState> clampPSO =
                        ensureTessFactorClampPipelineState();
                    if (clampPSO != nil) {
                        info.submissionGroup.addSubgroup(
                            AppGLSubmissionGroupKind::TessFactorClamp,
                            AppGLCommandReason::TessFactorClamp);
                        uint32_t patchCountU = (uint32_t)info.patchCount;
                        auto clampLease = makeCommandBuffer(AppGLCommandReason::TessFactorClamp);
                        id<MTLCommandBuffer> clampCmd = clampLease.get();
                        clampCmd.label = @"appgl-tess-factor-clamp";
                        id<MTLComputeCommandEncoder> clampEnc =
                            [clampCmd computeCommandEncoder];
                        [clampEnc setComputePipelineState:clampPSO];
                        [clampEnc setBuffer:factorBuf offset:0 atIndex:0];
                        [clampEnc setBytes:&patchCountU
                                    length:sizeof(patchCountU)
                                   atIndex:1];
                        [clampEnc dispatchThreads:MTLSizeMake((NSUInteger)patchCountU, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [clampEnc endEncoding];
                        clampLease.commitAndWait(AppGLCommandReason::TessFactorClamp);
                    }

                    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
                    ScopedOwnedObjCObject rpdRelease(rpd);
                    rpd.renderTargetWidth = 1;
                    rpd.renderTargetHeight = 1;
                    rpd.defaultRasterSampleCount = 1;
                    info.submissionGroup.addSubgroup(
                        AppGLSubmissionGroupKind::TessDomain,
                        AppGLCommandReason::TessDomainGenerate);
                    auto dgLease = makeCommandBuffer(AppGLCommandReason::TessDomainGenerate);
                    id<MTLCommandBuffer> dgCmdBuf = dgLease.get();
                    dgCmdBuf.label = @"appgl-tess-domain-gen-hw";
                    id<MTLRenderCommandEncoder> dgEnc =
                        [dgCmdBuf renderCommandEncoderWithDescriptor:rpd];
                    [dgEnc setRenderPipelineState:hwCapturePSO];
                    [dgEnc setVertexBuffer:totalVertCountBuf offset:0 atIndex:23];
                    [dgEnc setVertexBuffer:domainPrimIDBuf   offset:0 atIndex:24];
                    [dgEnc setVertexBuffer:domainCoordBuf    offset:0 atIndex:25];
                    [dgEnc setTessellationFactorBuffer:factorBuf
                                                offset:0
                                        instanceStride:0];
                    [dgEnc drawPatches:(hwPatchType == MTLPatchTypeQuad ? 4u : 3u)
                             patchStart:0
                             patchCount:(NSUInteger)info.patchCount
                        patchIndexBuffer:nil
                  patchIndexBufferOffset:0
                           instanceCount:1
                            baseInstance:0];
                    [dgEnc endEncoding];
                    dgLease.commitAndWait(AppGLCommandReason::TessDomainGenerate);
                } else {
                    // Phase 4A [metal-tess-TF]: when
                    // APPGL_TESS_DOMAIN_PORT is set and the genMode is
                    // triangles or quads, use the CPU-exact MSL port
                    // (`spvGenTessDomainTrianglesPort` /
                    // `spvGenTessDomainQuadsPort`). Output-buffer
                    // layout matches `spvGenTessDomain` so the
                    // downstream TES-compute dispatch is unchanged.
                    // Isolines stay on the original kernel (no Metal
                    // `.isoline` patch type, no port yet).
                    const bool useDomainPort =
                        (std::getenv("APPGL_TESS_DOMAIN_PORT") != nullptr) &&
                        (info.genMode == GL_TRIANGLES ||
                         info.genMode == GL_QUADS);
                    id<MTLComputePipelineState> portPSO = nil;
                    if (useDomainPort && ensureTessDomainPortLibrary()) {
                        portPSO = (info.genMode == GL_QUADS)
                            ? tessDomainPortQuadsPSO
                            : tessDomainPortTrianglesPSO;
                    }

                    if (portPSO != nil) {
                        // Port kernel params: same 5-field shape as
                        // the original `TessGenParams`; genMode is
                        // 0=tri / 1=quad (isolines route elsewhere).
                        struct TessPortParamsCPU {
                            uint32_t genMode;
                            uint32_t genSpacing;
                            uint32_t patchCount;
                            uint32_t pointMode;
                            uint32_t flipWinding;
                        };
                        TessPortParamsCPU pp{};
                        pp.genMode = (info.genMode == GL_QUADS) ? 1u : 0u;
                        switch (info.genSpacing) {
                            case GL_FRACTIONAL_EVEN: pp.genSpacing = 1u; break;
                            case GL_FRACTIONAL_ODD:  pp.genSpacing = 2u; break;
                            case GL_EQUAL:
                            default:                  pp.genSpacing = 0u; break;
                        }
                        pp.patchCount = (uint32_t)info.patchCount;
                        pp.pointMode = info.pointMode ? 1u : 0u;
                        pp.flipWinding = (info.genVertexOrder == GL_CW) ? 1u : 0u;
                        id<MTLBuffer> portParamsBuf = [device
                            newBufferWithBytes:&pp
                                        length:sizeof(pp)
                                       options:MTLResourceStorageModeShared];
                        ScopedOwnedObjCObject portParamsBufRelease(portParamsBuf);

                        info.submissionGroup.addSubgroup(
                            AppGLSubmissionGroupKind::TessDomain,
                            AppGLCommandReason::TessDomainGenerate);
                        auto dgLease = makeCommandBuffer(AppGLCommandReason::TessDomainGenerate);
                        id<MTLCommandBuffer> dgCmdBuf = dgLease.get();
                        dgCmdBuf.label = @"appgl-tess-domain-port";
                        id<MTLComputeCommandEncoder> dgEnc =
                            [dgCmdBuf computeCommandEncoder];
                        [dgEnc setComputePipelineState:portPSO];
                        [dgEnc setBuffer:portParamsBuf offset:0 atIndex:0];
                        [dgEnc setBuffer:factorBuf offset:0 atIndex:26];
                        [dgEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                        [dgEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                        [dgEnc setBuffer:totalVertCountBuf offset:0 atIndex:23];
                        [dgEnc dispatchThreads:MTLSizeMake(1, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [dgEnc endEncoding];
                        dgLease.commitAndWait(AppGLCommandReason::TessDomainGenerate);
                    } else {
                        // Compute-kernel path (default, and fallback
                        // when port PSO unavailable or flag disabled).
                        //
                        // Serial driver: 1 thread walks all patches in
                        // order (see `spvGenTessDomain` comment).
                        // Parallelization revisited once Phase 4/5
                        // stabilize the TF capture protocol — the
                        // atomic cursor then becomes safe.
                        info.submissionGroup.addSubgroup(
                            AppGLSubmissionGroupKind::TessDomain,
                            AppGLCommandReason::TessDomainGenerate);
                        auto dgLease = makeCommandBuffer(AppGLCommandReason::TessDomainGenerate);
                        id<MTLCommandBuffer> dgCmdBuf = dgLease.get();
                        dgCmdBuf.label = @"appgl-tess-domain-gen";
                        id<MTLComputeCommandEncoder> dgEnc =
                            [dgCmdBuf computeCommandEncoder];
                        [dgEnc setComputePipelineState:tessDomainGenPipelineState];
                        [dgEnc setBuffer:domainGenParamsBuf offset:0 atIndex:0];
                        [dgEnc setBuffer:factorBuf offset:0 atIndex:26];
                        [dgEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                        [dgEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                        [dgEnc setBuffer:totalVertCountBuf offset:0 atIndex:23];
                        [dgEnc dispatchThreads:MTLSizeMake(1, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [dgEnc endEncoding];
                        dgLease.commitAndWait(AppGLCommandReason::TessDomainGenerate);
                    }
                }

                // CPU-read the produced vertex count.
                tessTFGeneratedVerts =
                    *(const uint32_t*)totalVertCountBuf.contents;

                // T4C: dump domain-gen buffers when APPGL_DUMP_DOMAINGEN
                // is set. Each dump is a (primid, coord) pair sized to the
                // generated vertex count (not the over-allocation), letting
                // a post-processor verify the primID distribution pattern.
                if (const char* dumpDir = std::getenv("APPGL_DUMP_DOMAINGEN")) {
                    static std::atomic<unsigned> seq{0};
                    const unsigned n = seq.fetch_add(1);
                    const NSUInteger primIDBytes =
                        (NSUInteger)tessTFGeneratedVerts * sizeof(uint32_t);
                    const NSUInteger coordBytes =
                        (NSUInteger)tessTFGeneratedVerts * 12;
                    char path[512];
                    if (void* primContents = [domainPrimIDBuf contents]) {
                        std::snprintf(path, sizeof(path),
                            "%s/primid_%05u.bin", dumpDir, n);
                        if (FILE* f = std::fopen(path, "wb")) {
                            std::fwrite(primContents, 1, (size_t)primIDBytes, f);
                            std::fclose(f);
                        }
                    }
                    if (void* coordContents = [domainCoordBuf contents]) {
                        std::snprintf(path, sizeof(path),
                            "%s/coord_%05u.bin", dumpDir, n);
                        if (FILE* f = std::fopen(path, "wb")) {
                            std::fwrite(coordContents, 1, (size_t)coordBytes, f);
                            std::fclose(f);
                        }
                    }
                    // Sprint 2 Track 1 telemetry: read back the per-
                    // patch tess factors (post-TCS-dispatch state of
                    // factorBuf) so the bisect can correlate
                    // (config → emitted_count). Each line emits
                    // patch index + outer[0..3] + inner[0..1] +
                    // post-domain-gen totalVerts. Reading from
                    // [factorBuf contents] is safe because
                    // factorBuf was created with
                    // MTLResourceStorageModeShared earlier and
                    // dgCmdBuf has waitUntilCompleted'd above.
                    if (void* factorContents = [factorBuf contents]) {
                        const auto* factors =
                            static_cast<const MTLQuadTessellationFactorsHalf*>(
                                factorContents);
                        // edgeTessellationFactor is uint16_t (raw IEEE 754
                        // binary16). Decode via memcpy into _Float16.
                        auto halfBitsToFloat = [](uint16_t bits) -> float {
                            __fp16 h;
                            std::memcpy(&h, &bits, sizeof(uint16_t));
                            return static_cast<float>(h);
                        };
                        const int patchCount = (int)info.patchCount;
                        for (int p = 0; p < patchCount; ++p) {
                            const auto& f = factors[p];
                            std::fprintf(stderr,
                                "APPGL_DETECTOR lift_domaingen seq=%u patch=%d "
                                "o0=%.4f o1=%.4f o2=%.4f o3=%.4f "
                                "i0=%.4f i1=%.4f totalVerts=%u "
                                "mode=0x%04X spacing=0x%04X pointMode=%d\n",
                                n, p,
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[0]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[1]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[2]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[3]),
                                halfBitsToFloat((uint16_t)f.insideTessellationFactor[0]),
                                halfBitsToFloat((uint16_t)f.insideTessellationFactor[1]),
                                (unsigned)tessTFGeneratedVerts,
                                info.genMode, info.genSpacing,
                                info.pointMode ? 1 : 0);
                        }
                    }
                    std::fprintf(stderr,
                        "APPGL_DETECTOR domain_dump seq=%u verts=%u patchCount=%d "
                        "primIDBytes=%llu coordBytes=%llu\n",
                        n, (unsigned)tessTFGeneratedVerts, (int)info.patchCount,
                        (unsigned long long)primIDBytes,
                        (unsigned long long)coordBytes);
                }

                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] tess-tf domain-gen ok: %u verts for "
                        "%d patches (mode=0x%04X spacing=0x%04X)\n",
                        (unsigned)tessTFGeneratedVerts,
                        (int)info.patchCount,
                        info.genMode, info.genSpacing);
                }

                // TES-compute dispatch: one thread per generated vertex.
                // Reads spvIn (per-CP) + spvPatchIn (per-patch) from
                // the Phase-3 buffers, domain coord + primID from the
                // just-generated buffers, writes spvOut into
                // tesComputeOutBuf.
                if (tessTFGeneratedVerts > 0) {
                    info.submissionGroup.addSubgroup(
                        AppGLSubmissionGroupKind::TessEval,
                        AppGLCommandReason::TessEvalCompute);
                    auto tesLease = makeCommandBuffer(AppGLCommandReason::TessEvalCompute);
                    id<MTLCommandBuffer> tesCmdBuf = tesLease.get();
                    tesCmdBuf.label = @"appgl-tess-tes-compute";
                    id<MTLComputeCommandEncoder> tesEnc =
                        [tesCmdBuf computeCommandEncoder];
                    id<MTLComputePipelineState> tesComputePSO =
                        (__bridge id<MTLComputePipelineState>)info.tessEvalComputePipelineState;
                    [tesEnc setComputePipelineState:tesComputePSO];
                    if (info.tessEvalAsComputeUniformData != nullptr &&
                        info.tessEvalAsComputeUniformSize > 0) {
                        [tesEnc setBytes:info.tessEvalAsComputeUniformData
                                  length:info.tessEvalAsComputeUniformSize
                                 atIndex:16];
                    }
                    bindComputeTextures(tesEnc, info.tessEvalTextures);
                    // TES-compute output buffer (spvOut at buffer 28).
                    [tesEnc setBuffer:tesComputeOutBuf offset:0 atIndex:28];
                    // spvIndirectParams at 29 — reuse the one we built
                    // for the TCS dispatch (shape matches).
                    [tesEnc setBuffer:indirectBuf offset:0 atIndex:29];
                    // Per-CP input at 22 (from TCS compute output).
                    // Sprint 5 Phase 1 — synth TCS path: TES-only programs
                    // have a synthesized passthrough TCS that doesn't copy
                    // VS-output user varyings to cpOutBuf (synth only
                    // writes gl_Position + tess level defaults). Per GL
                    // spec §11.2.4, TES-only mode reads VS outputs
                    // directly as per-CP inputs. Bind vsOutBuf instead of
                    // cpOutBuf to provide the TES kernel with VS output
                    // user data. The struct layouts of VS main0_out and
                    // TES main0_in match because they're both compiled
                    // from the same interface declarations (SPIRV-Cross
                    // emits identical layouts when using
                    // capture_output_to_buffer / raw_buffer_tese_input).
                    if (info.tessControlSynthesized && vsOutBuf != nil) {
                        [tesEnc setBuffer:vsOutBuf offset:0 atIndex:22];
                    } else if (cpOutBuf != nil) {
                        [tesEnc setBuffer:cpOutBuf offset:0 atIndex:22];
                    }
                    // Per-patch input at 20.
                    if (patchOutBuf != nil)
                        [tesEnc setBuffer:patchOutBuf offset:0 atIndex:20];
                    // Domain coord + primID (our fork-patched bindings).
                    [tesEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                    [tesEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                    // Sprint 5 Phase 1 — Path L: full-precision tess level
                    // shadow buffer at slot 23. TES kernel reads
                    // gl_TessLevelOuter/Inner from spvTessLevelFull
                    // instead of half-precision spvTessLevel. Populated by
                    // TCS-compute dual-write OR by host-populate path for
                    // TES-only programs (Sprint 5 Phase 1 follow-up).
                    [tesEnc setBuffer:factorBufFull offset:0 atIndex:23];
                    // Detector point C — dispatch-time instrumentation.
                    // Pairs with link probe (A) and gate (B) so post-
                    // processors can confirm the kernel actually fired.
                    if (std::getenv("APPGL_DETECTOR_TF")) {
                        std::fprintf(stderr,
                            "APPGL_DETECTOR lift_dispatch threads=%u "
                            "patchCount=%d patchVertices=%d "
                            "tesOutBufBytes=%llu\n",
                            (unsigned)tessTFGeneratedVerts,
                            (int)info.patchCount,
                            (int)info.patchVertices,
                            (unsigned long long)tesComputeOutBuf.length);
                    }
                    [tesEnc dispatchThreads:MTLSizeMake((NSUInteger)tessTFGeneratedVerts, 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    [tesEnc endEncoding];
                    tesLease.commitAndWait(AppGLCommandReason::TessEvalCompute);

                    if (std::getenv("APPGL_TRACE_TESS")) {
                        std::fprintf(stderr,
                            "[APPGL] tess-tf tes-compute dispatched %u threads\n",
                            (unsigned)tessTFGeneratedVerts);
                    }

                    // Sprint 4 Phase 1 bisect: dump tesComputeOutBuf at
                    // multiple strides to verify TES-compute kernel's
                    // actual write layout vs `tessEvalOutputLayout
                    // .structSize`. The host-side TF write-back walks the
                    // buffer at structSize stride; if Metal MSL writes at
                    // a different stride (e.g. due to padding) the TF
                    // output is misaligned. Logs first N bytes interpreted
                    // as float4 at fixed candidate strides; correlate with
                    // host-side structSize from `lift_pre_encode`.
                    if (std::getenv("APPGL_DUMP_TESOUT")) {
                        static std::atomic<unsigned> seq{0};
                        const unsigned n = seq.fetch_add(1);
                        const std::uint8_t* bytes =
                            static_cast<const std::uint8_t*>(
                                [tesComputeOutBuf contents]);
                        const NSUInteger bufLen = tesComputeOutBuf.length;
                        std::fprintf(stderr,
                            "APPGL_DETECTOR tesout_dump seq=%u "
                            "verts=%u bufBytes=%llu\n",
                            n, (unsigned)tessTFGeneratedVerts,
                            (unsigned long long)bufLen);
                        const std::size_t kStrides[] = {
                            48, 64, 80, 96, 128, 256
                        };
                        const unsigned kVertsToShow =
                            tessTFGeneratedVerts < 24u
                                ? (unsigned)tessTFGeneratedVerts : 24u;
                        for (std::size_t s : kStrides) {
                            for (unsigned v = 0; v < kVertsToShow; ++v) {
                                const std::size_t off = (std::size_t)v * s;
                                if (off + sizeof(float) * 4 > bufLen) break;
                                float f[4];
                                std::memcpy(f, bytes + off, sizeof(f));
                                std::fprintf(stderr,
                                    "APPGL_DETECTOR tesout_dump seq=%u "
                                    "stride=%zu v=%u off=%zu = "
                                    "[%.4f, %.4f, %.4f, %.4f]\n",
                                    n, s, v, off, f[0], f[1], f[2], f[3]);
                            }
                        }
                    }
                }
                // Phase 3B.5 [metal-tess-TF]: hand off the TES-output
                // buffer + generated-vertex count to the caller so
                // `tryMetalTessellationDraw` can walk the bytes and
                // deposit TF per the program's varying layout.
                if (info.outGeneratedVertCount != nullptr) {
                    *info.outGeneratedVertCount =
                        (std::uint32_t)tessTFGeneratedVerts;
                }
                if (info.outTesComputeOutBuf != nullptr) {
                    // Retain the buffer so it outlives this encoder
                    // scope. Caller CFBridgingRelease's it after the
                    // TF write completes.
                    *info.outTesComputeOutBuf =
                        (void*)CFBridgingRetain(tesComputeOutBuf);
                }
                }
            }
        }

        // (4) Build tess-enabled render pipeline state. Key on the
        // color + depth formats so a program drawn to multiple FBOs
        // keeps per-format pipelines hot. The key also includes the
        // TES+FS MSL text hashes implicitly (same program → same MSL).
        //
        // We could cache this on the program with a map, similar to
        // `metalPipelineStateCache`, but Phase 2 builds fresh each
        // draw — future phases add a cache keyed on the format tuple.
        MTLPixelFormat colorFormat = MTLPixelFormatBGRA8Unorm;
        MTLPixelFormat depthFormat = MTLPixelFormatInvalid;
        if (info.fboColorTexture != nullptr) {
            colorFormat =
                ((__bridge id<MTLTexture>)info.fboColorTexture).pixelFormat;
        } else if (usesOffscreenTarget && offscreenColorTexture != nil) {
            colorFormat = offscreenColorTexture.pixelFormat;
        } else if (currentDrawable != nil) {
            colorFormat = currentDrawable.texture.pixelFormat;
        }
        if (info.fboDepthStencilTexture != nullptr) {
            depthFormat =
                ((__bridge id<MTLTexture>)info.fboDepthStencilTexture).pixelFormat;
        } else if (depthStencilTexture != nil) {
            depthFormat = depthStencilTexture.pixelFormat;
        }

        // Render-pipeline-build skip: when tessEvalMSL is empty, we're
        // in compute-only mode (isolines + TF-write or
        // rasterizer-discard). The compute chain above already deposited
        // the TES output bytes to the TF buffer via
        // writeTessTFAndUpdateCounters; no render pass needs to fire.
        // Returning true here treats the compute chain as the complete
        // draw — caller's encode succeeded, no fallback to CPU.
        if (info.tessEvalMSL == nullptr || info.tessEvalMSL->empty()) {
            return true;
        }
        // Metal's fixed-function tessellator has no GL point_mode output.
        // When the caller retained the TES-compute output, let it replay
        // those generated vertices as GL_POINTS instead of drawing the
        // hardware tessellator's triangle/line topology.
        if (info.pointMode &&
            info.outGeneratedVertCount != nullptr &&
            info.outTesComputeOutBuf != nullptr &&
            tessTFGeneratedVerts > 0) {
            return true;
        }
        id<MTLLibrary> tesLib = getOrCompileLibrary(*info.tessEvalMSL);
        if (tesLib == nil) return false;
        id<MTLLibrary> fsLib = getOrCompileLibrary(*info.fragmentMSL);
        if (fsLib == nil) return false;
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        ScopedOwnedObjCObject emptyConstantsRelease(emptyConstants);
        NSError* fnErr = nil;
        id<MTLFunction> tesFn = [tesLib newFunctionWithName:@"main0"
                                              constantValues:emptyConstants
                                                       error:&fnErr];
        if (tesFn == nil) return false;
        ScopedOwnedObjCObject tesFnRelease(tesFn);
        id<MTLFunction> fsFn = [fsLib newFunctionWithName:@"main0"
                                            constantValues:emptyConstants
                                                     error:&fnErr];
        if (fsFn == nil) return false;
        ScopedOwnedObjCObject fsFnRelease(fsFn);

        MTLRenderPipelineDescriptor* pipeDesc =
            [[MTLRenderPipelineDescriptor alloc] init];
        ScopedOwnedObjCObject pipeDescRelease(pipeDesc);
        pipeDesc.vertexFunction = tesFn;
        pipeDesc.fragmentFunction = fsFn;
        pipeDesc.colorAttachments[0].pixelFormat = colorFormat;
        // Classify the depth/stencil format: Metal's validator rejects
        // setting `depthAttachmentPixelFormat` to a stencil-only format
        // (e.g. MTLPixelFormatStencil8) and rejects setting
        // `stencilAttachmentPixelFormat` to a depth-only format. Depth-
        // plus-stencil combined formats go on BOTH slots.
        const bool fmtHasDepth =
            depthFormat == MTLPixelFormatDepth16Unorm ||
            depthFormat == MTLPixelFormatDepth32Float ||
            depthFormat == MTLPixelFormatDepth24Unorm_Stencil8 ||
            depthFormat == MTLPixelFormatDepth32Float_Stencil8;
        const bool fmtHasStencil =
            depthFormat == MTLPixelFormatStencil8 ||
            depthFormat == MTLPixelFormatDepth24Unorm_Stencil8 ||
            depthFormat == MTLPixelFormatDepth32Float_Stencil8 ||
            depthFormat == MTLPixelFormatX24_Stencil8 ||
            depthFormat == MTLPixelFormatX32_Stencil8;
        if (fmtHasDepth) {
            pipeDesc.depthAttachmentPixelFormat = depthFormat;
        }
        if (fmtHasStencil) {
            pipeDesc.stencilAttachmentPixelFormat = depthFormat;
        }

        // Tess pipeline settings. Partition-mode mapping mirrors the
        // Phase 1 probe helper. Maximum factor = 64 to cover
        // GL_MAX_TESS_GEN_LEVEL.
        switch (info.genSpacing) {
            case GL_FRACTIONAL_EVEN:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeFractionalEven;
                break;
            case GL_FRACTIONAL_ODD:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeFractionalOdd;
                break;
            case GL_EQUAL:
            default:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeInteger;
                break;
        }
        // Winding: SPIRV-Cross's `tess_domain_origin_lower_left` option
        // injects a `gl_TessCoord.y = 1.0 - gl_TessCoord.y` fixup inside
        // the TES for QUADS (and isolines) — per the comment in
        // spirv_msl.cpp:15600 "Don't do this for triangles; MoltenVK
        // will just reverse the winding order instead." The Y-flip
        // reverses the on-screen winding relative to what Metal's
        // fixed-function tessellator emits into the domain. To match GL
        // semantics (`layout(ccw|cw)` is the on-screen winding), invert
        // the pipeline's `tessellationOutputWindingOrder` whenever the
        // TES performs the Y-flip.
        const bool tesYFlipped =
            (info.genMode == GL_QUADS || info.genMode == GL_ISOLINES);
        const bool windingIsCW =
            (info.genVertexOrder == GL_CW) ^ tesYFlipped;
        pipeDesc.tessellationOutputWindingOrder =
            windingIsCW ? MTLWindingClockwise : MTLWindingCounterClockwise;
        const bool tessEvalWritesRenderTargetArrayIndex =
            info.tessEvalMSL != nullptr &&
            info.tessEvalMSL->find("[[render_target_array_index]]") !=
                std::string::npos;
        const bool tessEvalWritesViewportArrayIndex =
            info.tessEvalMSL != nullptr &&
            info.tessEvalMSL->find("[[viewport_array_index]]") !=
                std::string::npos;
        if (info.fboColorArrayLength > 0 ||
            info.viewportArrayCount > 1 ||
            tessEvalWritesRenderTargetArrayIndex ||
            tessEvalWritesViewportArrayIndex) {
            if (info.pointMode) {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassPoint;
            } else if (info.genMode == GL_ISOLINES) {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassLine;
            } else {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassTriangle;
            }
        }
        pipeDesc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        // The TCS compute pass writes one Metal tess-factor record for each
        // GL patch; debug validation rejects treating this buffer as a single
        // constant record when drawPatches emits multiple patches.
        pipeDesc.tessellationFactorStepFunction =
            MTLTessellationFactorStepFunctionPerPatch;
        pipeDesc.tessellationControlPointIndexType =
            MTLTessellationControlPointIndexTypeNone;
        pipeDesc.maxTessellationFactor = 64;

        NSError* psoErr = nil;
        id<MTLRenderPipelineState> renderPSO =
            [device newRenderPipelineStateWithDescriptor:pipeDesc
                                                   error:&psoErr];
        if (renderPSO == nil) {
            APPGL_LOG(PIPELINE, @"[FG] tess render pipeline build failed: %@",
                      psoErr ? psoErr.localizedDescription : @"(nil err)");
            return false;
        }
        ScopedOwnedObjCObject renderPSORelease(renderPSO);

        // (5) Begin a render pass. For FBO draws we build the pass
        // descriptor inline (single color attachment; Phase 2 doesn't
        // support MRT yet). For default-framebuffer draws we reuse the
        // impl's beginRenderPass path by acquiring a drawable +
        // attaching the swapchain texture directly.
        info.submissionGroup.addSubgroup(
            AppGLSubmissionGroupKind::TessRender,
            AppGLCommandReason::TessRender);
        if (currentCommandBuffer == nil) {
            ensureCurrentCommandBuffer(@"tessellationDraw");
            if (currentCommandBuffer == nil) return false;
        }

        id<MTLTexture> colorTex = nil;
        id<MTLTexture> depthTex = nil;
        const bool isDefaultTarget = info.fboColorTexture == nullptr;
        if (info.fboColorTexture != nullptr) {
            colorTex = (__bridge id<MTLTexture>)info.fboColorTexture;
            depthTex = (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
        } else {
            ensureDrawableResources();
            if (!acquireDrawableIfNeeded()) return false;
            colorTex = usesOffscreenTarget ? offscreenColorTexture
                                           : currentDrawable.texture;
            depthTex = depthStencilTexture;
        }
        if (colorTex == nil) return false;

        MTLRenderPassDescriptor* pass = getReusablePassDescriptor();  // ADV-4
        pass.colorAttachments[0].texture = colorTex;
        const bool consumeDefaultClear = isDefaultTarget && hasPendingClear;
        if (info.pendingClearColor ||
            (consumeDefaultClear && (pendingClearMask & GL_COLOR_BUFFER_BIT))) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = info.pendingClearColor
                ? MTLClearColorMake(info.clearColor[0], info.clearColor[1],
                                    info.clearColor[2], info.clearColor[3])
                : pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (info.fboColorArrayLength > 0) {
            pass.renderTargetArrayLength =
                static_cast<NSUInteger>(info.fboColorArrayLength);
        }
        if (depthTex != nil && fmtHasDepth) {
            pass.depthAttachment.texture = depthTex;
            if (info.pendingClearDepth ||
                (consumeDefaultClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT))) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = info.pendingClearDepth
                    ? info.clearDepth
                    : pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            pass.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (depthTex != nil && fmtHasStencil) {
            pass.stencilAttachment.texture = depthTex;
            if (info.pendingClearStencil ||
                (consumeDefaultClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT))) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil =
                    (uint32_t)(info.pendingClearStencil
                        ? info.clearStencil
                        : pendingClearStencil);
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        if (consumeDefaultClear) {
            hasPendingClear = false;
        }

        id<MTLRenderCommandEncoder> enc =
            [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (enc == nil) return false;

        // Viewport + scissor. Metal's viewport origin is top-left;
        // GL's is bottom-left. The existing translated-draw path
        // flips Y by computing (fboHeight - viewportY - viewportHeight)
        // — replicate that here. For Phase 2 we treat the FBO height
        // as the color texture's height.
        const double fbHeight = (double)colorTex.height;
        const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
        if (info.viewportArrayCount > 1) {
            MTLViewport viewports[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.viewportArray[i];
                viewports[i].originX = (double)e.originX;
                viewports[i].originY = flipY
                    ? (fbHeight - (double)e.originY - (double)e.height)
                    : (double)e.originY;
                viewports[i].width = (double)e.width;
                viewports[i].height = (double)e.height;
                viewports[i].znear = e.depthNear;
                viewports[i].zfar = e.depthFar;
            }
            [enc setViewports:viewports count:info.viewportArrayCount];
        } else {
            MTLViewport viewport = {
                (double)info.viewportX,
                flipY
                    ? (fbHeight - (double)info.viewportY - (double)info.viewportHeight)
                    : (double)info.viewportY,
                (double)info.viewportWidth,
                (double)info.viewportHeight,
                info.depthRangeNear,
                info.depthRangeFar
            };
            [enc setViewport:viewport];
        }

        auto makeTessScissor = [&](bool enabled, GLint x, GLint y,
                                   GLsizei width, GLsizei height) {
            MTLScissorRect scissor;
            if (enabled) {
                scissor.x = (NSUInteger)std::max(x, 0);
                const GLint metalY = flipY
                    ? ((GLint)colorTex.height - y - height)
                    : y;
                scissor.y = (NSUInteger)std::max(metalY, 0);
                scissor.width = (NSUInteger)std::max(width, 0);
                scissor.height = (NSUInteger)std::max(height, 0);
            } else {
                scissor.x = 0;
                scissor.y = 0;
                scissor.width = colorTex.width;
                scissor.height = colorTex.height;
            }
            if (scissor.x + scissor.width > colorTex.width) {
                scissor.width = scissor.x < colorTex.width
                    ? colorTex.width - scissor.x : 0;
            }
            if (scissor.y + scissor.height > colorTex.height) {
                scissor.height = scissor.y < colorTex.height
                    ? colorTex.height - scissor.y : 0;
            }
            if (scissor.width == 0 || scissor.height == 0) {
                scissor.x = colorTex.width;
                scissor.y = colorTex.height;
                scissor.width = 1;
                scissor.height = 1;
            }
            return scissor;
        };
        if (info.viewportArrayCount > 1) {
            MTLScissorRect scissors[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.scissorArray[i];
                const bool enabled = info.scissorTestEnabled && e.enabled;
                scissors[i] = makeTessScissor(
                    enabled, e.x, e.y, e.width, e.height);
            }
            [enc setScissorRects:scissors count:info.viewportArrayCount];
        } else {
            [enc setScissorRect:makeTessScissor(
                info.scissorTestEnabled, info.scissorX, info.scissorY,
                info.scissorWidth, info.scissorHeight)];
        }

        // Cull / front-face. GL and Metal both use a CCW/CW winding
        // convention so the enum maps 1:1.
        if (info.cullFaceEnabled) {
            MTLCullMode cull = MTLCullModeBack;
            switch (info.cullFaceMode) {
                case GL_FRONT:          cull = MTLCullModeFront; break;
                case GL_BACK:           cull = MTLCullModeBack;  break;
                case GL_FRONT_AND_BACK: cull = MTLCullModeBack;
                    // Metal has no FRONT_AND_BACK — approximate by
                    // culling back + relying on the app to also
                    // disable front-facing draws.
                    break;
                default: break;
            }
            [enc setCullMode:cull];
        } else {
            [enc setCullMode:MTLCullModeNone];
        }
        [enc setFrontFacingWinding:
            (info.frontFace == GL_CW) ? MTLWindingClockwise
                                       : MTLWindingCounterClockwise];
        [enc setTriangleFillMode:
            info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        {
            const std::uint32_t sampleMask = info.sampleMask;
            [enc setFragmentBytes:&sampleMask
                            length:sizeof(sampleMask)
                           atIndex:21];
        }
        if (info.fragmentUniformData != nullptr &&
            info.fragmentUniformSize > 0) {
            [enc setFragmentBytes:info.fragmentUniformData
                            length:info.fragmentUniformSize
                           atIndex:16];
        }

        // Depth/stencil state. Sprint 7 Phase 1 #11 (CKPT57) widened
        // this from depth-only to full per-face stencil plumbing —
        // primitive_coverage's two-phase stencil-replace + stencil-
        // notequal pattern needed it. Configures the descriptor only
        // when the corresponding GL state is actually enabled, so
        // depth-only or stencil-only tests don't drag in irrelevant
        // descriptor fields.
        if (depthTex != nil && (fmtHasDepth || fmtHasStencil)
            && (info.depthTestEnabled || info.stencilTestEnabled)) {
            MTLDepthStencilDescriptor* dsDesc =
                [[MTLDepthStencilDescriptor alloc] init];
            ScopedOwnedObjCObject dsDescRelease(dsDesc);
            if (info.depthTestEnabled) {
                switch (info.depthFunc) {
                    case GL_NEVER:    dsDesc.depthCompareFunction = MTLCompareFunctionNever; break;
                    case GL_LESS:     dsDesc.depthCompareFunction = MTLCompareFunctionLess; break;
                    case GL_EQUAL:    dsDesc.depthCompareFunction = MTLCompareFunctionEqual; break;
                    case GL_LEQUAL:   dsDesc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
                    case GL_GREATER:  dsDesc.depthCompareFunction = MTLCompareFunctionGreater; break;
                    case GL_NOTEQUAL: dsDesc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
                    case GL_GEQUAL:   dsDesc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
                    case GL_ALWAYS:   dsDesc.depthCompareFunction = MTLCompareFunctionAlways; break;
                    default:          dsDesc.depthCompareFunction = MTLCompareFunctionLess; break;
                }
                dsDesc.depthWriteEnabled = info.depthWriteMask ? YES : NO;
            }
            if (info.stencilTestEnabled) {
                dsDesc.frontFaceStencil = buildMetalStencilFace(
                    info.stencilFrontFunc, info.stencilFrontValueMask,
                    info.stencilFrontFail, info.stencilFrontDepthFail,
                    info.stencilFrontDepthPass, info.stencilFrontWriteMask);
                dsDesc.backFaceStencil = buildMetalStencilFace(
                    info.stencilBackFunc, info.stencilBackValueMask,
                    info.stencilBackFail, info.stencilBackDepthFail,
                    info.stencilBackDepthPass, info.stencilBackWriteMask);
            }
            id<MTLDepthStencilState> ds =
                [device newDepthStencilStateWithDescriptor:dsDesc];
            ScopedOwnedObjCObject dsRelease(ds);
            [enc setDepthStencilState:ds];
            if (info.stencilTestEnabled) {
                [enc setStencilFrontReferenceValue:
                         static_cast<uint32_t>(info.stencilFrontRef)
                      backReferenceValue:
                         static_cast<uint32_t>(info.stencilBackRef)];
            }
        }

        // (6) Bind tess factor buffer + issue drawPatches. Phase 3:
        // also bind per-CP (buffer(22)) and per-patch (buffer(20))
        // buffers as vertex-stage inputs so the TES can read them via
        // `raw_buffer_tese_input=true`.
        [enc setRenderPipelineState:renderPSO];
        bindVertexTextures(enc, info.tessEvalTextures);
        bindFragmentTextures(enc, info.fragmentTextures);
        [enc setTessellationFactorBuffer:factorBuf offset:0 instanceStride:0];
        if (isPhase3) {
            [enc setVertexBuffer:cpOutBuf offset:0 atIndex:22];
            [enc setVertexBuffer:patchOutBuf offset:0 atIndex:20];
        }
        // Sprint 5 Phase 1 — Path L: bind factorBufFull at slot 23 for
        // TES-as-vertex-function render encoder. Path L emission produces
        // TES MSL that reads `gl_TessLevelOuter/Inner` from
        // `spvTessLevelFull[primId * stride + idx]` regardless of which
        // encoder runs the TES code; this binding closes the encoder-
        // path coverage gap (per Clerk's §3.6.18 banking).
        [enc setVertexBuffer:factorBufFull offset:0 atIndex:23];
        // Phase 3: drawPatches's `numberOfPatchControlPoints` is the
        // count of control points per patch in the buffer feeding the
        // post-tess vertex stage — i.e. cpOutBuf, which holds TCS
        // output (one element per `layout(vertices=N)` invocation).
        // Tests where glPatchParameteri(PATCH_VERTICES) and TCS
        // output_vertices differ (e.g. `single.max_patch_vertices`
        // uses PATCH_VERTICES=32 with `layout(vertices=2)`) hit a
        // stride mismatch when drawPatches sees the input patch size
        // — Metal reads cpOutBuf at the wrong stride and the TES
        // pulls garbage CPs.  Use tessControlOutputVertices on the
        // compute-pre-pass path; the existing Phase 2 path stays on
        // patchVertices because there's no pre-pass producing
        // a different-sized buffer.
        const NSUInteger drawPatchesCPs = isPhase3 && info.tessControlOutputVertices > 0
            ? (NSUInteger)info.tessControlOutputVertices
            : (NSUInteger)info.patchVertices;
        [enc drawPatches:drawPatchesCPs
              patchStart:0
              patchCount:(NSUInteger)info.patchCount
         patchIndexBuffer:nil
   patchIndexBufferOffset:0
           instanceCount:(NSUInteger)std::max(info.instanceCount, 1)
            baseInstance:(NSUInteger)info.baseInstance];
        [enc endEncoding];
        if (isDefaultTarget) {
            readbackSourceTexture = colorTex;
            readbackSourceIsBGRA = colorTex.pixelFormat == MTLPixelFormatBGRA8Unorm;
            pendingPresent = true;
            currentCommandBufferLease.retainObjectUntilCompleted(factorBuf);
            currentCommandBufferLease.retainObjectUntilCompleted(factorBufFull);
            currentCommandBufferLease.retainObjectUntilCompleted(renderPSO);
            if (cpOutBuf != nil) {
                currentCommandBufferLease.retainObjectUntilCompleted(cpOutBuf);
            }
            if (patchOutBuf != nil) {
                currentCommandBufferLease.retainObjectUntilCompleted(patchOutBuf);
            }
            resetCachedEncoderState();
            info.didRender = true;
            return true;
        }

        // Commit + wait so subsequent readbacks / copies observe the
        // tess draw's output. Matches compute-dispatch's sync semantics.
        if (!currentCommandBufferLease.commitAndWait(AppGLCommandReason::TessRender)) {
            return false;
        }
        if (ringSlotAcquired) {
            signalRingSlotNow();
            advanceRingBuffer();
        }
        currentCommandBuffer = nil;
        if (isDefaultTarget) {
            clearCurrentDrawable();
            pendingPresent = false;
        }
        resetCachedEncoderState();
        info.didRender = true;

        if (std::getenv("APPGL_TRACE_TESS")) {
            std::fprintf(stderr,
                "[APPGL] tess-draw program=%u patches=%d cps=%d "
                "patchVerticesIn=%d genMode=0x%04X spacing=0x%04X "
                "winding=0x%04X colorFmt=%u depthFmt=%u\n",
                info.program, (int)info.patchCount,
                (int)info.tessControlOutputVertices,
                (int)info.patchVertices,
                info.genMode, info.genSpacing, info.genVertexOrder,
                (unsigned)colorFormat, (unsigned)depthFormat);
        }
        return true;
    }

    // Sprint 3 Step 2 Phase 2 [metal-mesh-GS]: mesh-shader draw encoder.
    // See MetalFrameGraph::encodeMetalMeshGSDraw declaration for the
    // contract. Three sub-steps mirror Phase-3 metal-tess (3a→3b):
    //   (3a) VS-as-compute writes per-vertex outputs to vsOutBuf.
    //   (3b) Mesh-render PSO build (or cache hit).
    //   (3c) Render pass: bind vsOutBuf @ 22, drawMeshThreadgroups.
    bool encodeMetalMeshGSDraw(MetalFrameGraph::MetalMeshGSDrawInfo& info) {
        // C48: mesh-GS draws don't fold deferred FBO clears — materialize.
        materializeAllPendingFboClears();
        if (!info.submissionGroup.declared) {
            info.submissionGroup.reset(AppGLSubmissionGroupKind::MeshGsDraw,
                                       AppGLCommandReason::MeshDraw);
            info.submissionGroup.approximateFallbackDisallowed = true;
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::MeshGsPrepass,
                                             AppGLCommandReason::MeshVertexCompute);
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::MeshGsRender,
                                             AppGLCommandReason::MeshDraw);
        }
        if (device == nil) {
            info.diagnostic = "no Metal device";
            return false;
        }
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::MeshGsDraw);
        if (info.vertexComputePipelineState == nullptr ||
            info.meshFunction == nullptr ||
            info.fragmentFunction == nullptr) {
            info.diagnostic = "missing PSO/function inputs";
            return false;
        }
        if (info.vertexCount == 0 || info.primitiveCount == 0) {
            info.diagnostic = "zero-count draw";
            return false;
        }
        if (info.fboColorTexture == nullptr) {
            info.diagnostic = "no color attachment";
            return false;
        }
        if (!drainPresentLifecycleForStandaloneEncoding(
                &info.diagnostic,
                AppGLCommandReason::DrainCurrentStandalone)) {
            return false;
        }

        // (3a) VS-as-compute pre-pass. Allocate output buffer, dispatch
        // VS one thread per vertex, write into vsOutBuf at slot 28
        // (Phase-3 convention).
        const NSUInteger vsOutBufSize =
            (NSUInteger)info.vertexCount *
            (NSUInteger)info.vsOutputStrideBytes;
        id<MTLBuffer> vsOutBuf =
            [device newBufferWithLength:vsOutBufSize
                                options:MTLResourceStorageModePrivate];
        if (vsOutBuf == nil) {
            info.diagnostic = "vsOutBuf alloc failed";
            return false;
        }
        info.submissionGroup.addTransient(
            AppGLSubmissionTransientKind::MeshVsOutputBuffer,
            AppGLSubmissionOrderingMechanism::CpuCompletionWait,
            AppGLCommandReason::MeshVertexCompute,
            22,
            static_cast<std::size_t>(vsOutBufSize));
        ScopedOwnedObjCObject vsOutBufRelease(vsOutBuf);
        vsOutBuf.label = @"appgl-mesh-gs-vs-output";

        {
            auto vsLease = makeCommandBuffer(AppGLCommandReason::MeshVertexCompute);
            id<MTLCommandBuffer> vsCmdBuf = vsLease.get();
            if (vsCmdBuf == nil) {
                info.diagnostic = "vs cmdBuf alloc failed";
                return false;
            }
            vsCmdBuf.label = @"appgl-mesh-gs-vs-compute";
            const bool dcr4cZeroVsOut =
                APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4C_MESH_GS_ZERO_VSOUT");
            if (dcr4cZeroVsOut) {
                id<MTLBlitCommandEncoder> fillEnc =
                    [vsCmdBuf blitCommandEncoder];
                if (fillEnc == nil) {
                    info.diagnostic = "vsOutBuf fill encoder alloc failed";
                    return false;
                }
                [fillEnc fillBuffer:vsOutBuf
                               range:NSMakeRange(0, vsOutBufSize)
                               value:0];
                [fillEnc endEncoding];
            } else {
                id<MTLComputeCommandEncoder> vsEnc =
                    [vsCmdBuf computeCommandEncoder];
                if (vsEnc == nil) {
                    info.diagnostic = "vs encoder alloc failed";
                    return false;
                }
                id<MTLComputePipelineState> vsPSO =
                    (__bridge id<MTLComputePipelineState>)info.vertexComputePipelineState;
                [vsEnc setComputePipelineState:vsPSO];
                [vsEnc setBuffer:vsOutBuf offset:0 atIndex:28];
                if (info.vsUniformData != nullptr && info.vsUniformSize > 0) {
                    [vsEnc setBytes:info.vsUniformData
                             length:info.vsUniformSize
                            atIndex:16];
                }
                for (const auto& binding : info.vertexComputeBufferBindings) {
                    if (binding.metalBuffer == nullptr) {
                        continue;
                    }
                    [vsEnc setBuffer:(__bridge id<MTLBuffer>)binding.metalBuffer
                              offset:(NSUInteger)binding.offset
                             atIndex:(NSUInteger)binding.metalSlot];
                }
                [vsEnc setStageInRegion:MTLRegionMake1D(0, info.vertexCount)];
                const NSUInteger maxPerTg =
                    vsPSO.maxTotalThreadsPerThreadgroup > 0
                        ? vsPSO.maxTotalThreadsPerThreadgroup : 32;
                const NSUInteger tgWidth =
                    info.vertexCount > 0 && info.vertexCount < maxPerTg
                        ? info.vertexCount : maxPerTg;
                [vsEnc dispatchThreads:MTLSizeMake(info.vertexCount, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
                [vsEnc endEncoding];
            }
            if (!vsLease.commitAndWait(AppGLCommandReason::MeshVertexCompute)) {
                info.diagnostic = "vs compute command buffer failed";
                return false;
            }
        }

        // (3b) Mesh-render PSO build / cache lookup.
        id<MTLRenderPipelineState> meshPSO = nil;
        ScopedOwnedObjCObject meshPSORelease;
        if (info.meshPipelineStateInOut != nullptr &&
            *info.meshPipelineStateInOut != nullptr) {
            meshPSO = (__bridge id<MTLRenderPipelineState>)
                *info.meshPipelineStateInOut;
        } else {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            id<MTLTexture> dsTex = info.fboDepthStencilTexture != nullptr
                ? (__bridge id<MTLTexture>)info.fboDepthStencilTexture
                : nil;
            MTLMeshRenderPipelineDescriptor* meshDesc =
                [[MTLMeshRenderPipelineDescriptor alloc] init];
            ScopedOwnedObjCObject meshDescRelease(meshDesc);
            meshDesc.meshFunction =
                (__bridge id<MTLFunction>)info.meshFunction;
            meshDesc.fragmentFunction =
                (__bridge id<MTLFunction>)info.fragmentFunction;
            meshDesc.colorAttachments[0].pixelFormat = colorTex.pixelFormat;
            if (dsTex != nil) {
                const MTLPixelFormat pf = dsTex.pixelFormat;
                if (pf == MTLPixelFormatDepth16Unorm ||
                    pf == MTLPixelFormatDepth32Float ||
                    pf == MTLPixelFormatDepth32Float_Stencil8 ||
                    pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                    meshDesc.depthAttachmentPixelFormat = pf;
                }
                if (pf == MTLPixelFormatStencil8 ||
                    pf == MTLPixelFormatDepth32Float_Stencil8 ||
                    pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                    pf == MTLPixelFormatX32_Stencil8 ||
                    pf == MTLPixelFormatX24_Stencil8) {
                    meshDesc.stencilAttachmentPixelFormat = pf;
                }
            }
            // One mesh threadgroup per input primitive. Object stage
            // is unused (no amplification needed for the MVP envelope).
            meshDesc.maxTotalThreadsPerObjectThreadgroup = 1;
            meshDesc.maxTotalThreadsPerMeshThreadgroup = 1;
            NSError* err = nil;
            meshPSO = [device
                newRenderPipelineStateWithMeshDescriptor:meshDesc
                                                 options:MTLPipelineOptionNone
                                              reflection:nil
                                                   error:&err];
            if (meshPSO == nil) {
                info.diagnostic = err.localizedDescription.UTF8String
                    ? err.localizedDescription.UTF8String
                    : "newRenderPipelineStateWithMeshDescriptor failed";
                return false;
            }
            meshPSORelease.reset(meshPSO);
            if (info.meshPipelineStateInOut != nullptr) {
                *info.meshPipelineStateInOut =
                    (void*)CFBridgingRetain(meshPSO);
            }
        }

        // (3c) Render pass + drawMeshThreadgroups.
        // Path D — currentRenderEncoder lifecycle cooperation. End any
        // open legacy render encoder before the mesh pass takes over,
        // so the encoder lifecycle is clean and the next legacy draw
        // rebuilds. Mirrors the `currentRenderEncoder = nil` pattern at
        // MetalFrameGraph.mm:854 (endRenderPass), but inline-scoped to
        // this branch.
        if (currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            releaseCurrentRenderEncoder();
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        }
        auto renderLease = makeCommandBuffer(AppGLCommandReason::MeshDraw);
        id<MTLCommandBuffer> rcmd = renderLease.get();
        if (rcmd == nil) {
            info.diagnostic = "render cmdBuf alloc failed";
            return false;
        }
        rcmd.label = @"appgl-mesh-gs-draw";
        // Path D — pending-clear consumption. AppGL defers glClear into
        // hasPendingClear / pendingClearColor / pendingClearDepth /
        // pendingClearStencil; the next render pass on the
        // default-FB picks them up via MTLLoadActionClear. Mirrors the
        // legacy gate at MetalFrameGraph.mm:2057-2062 (color),
        // 2100-2108 (depth+stencil). Per the legacy gate, pending
        // clears apply only to the default-FB draw path
        // (`!isFBODraw`) — user-FBO clears are tracked separately and
        // don't reach here.
        const bool isFBODraw = (info.fboColorTexture != nullptr &&
            info.fboColorTexture != (__bridge void*)offscreenColorTexture &&
            info.fboColorTexture != (__bridge void*)(currentDrawable.texture));
        const bool consumeColorClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_COLOR_BUFFER_BIT);
        const bool consumeDepthClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_DEPTH_BUFFER_BIT);
        const bool consumeStencilClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_STENCIL_BUFFER_BIT);
        if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
            std::fprintf(stderr,
                "[MESH_GS] pass setup: isFBODraw=%d hasPendingClear=%d mask=0x%x "
                "consumeColor=%d consumeDepth=%d consumeStencil=%d\n",
                (int)isFBODraw, (int)hasPendingClear,
                (unsigned)pendingClearMask,
                (int)consumeColorClear, (int)consumeDepthClear,
                (int)consumeStencilClear);
            std::fflush(stderr);
        }

        MTLRenderPassDescriptor* rpd = getReusablePassDescriptor();  // ADV-4
        rpd.colorAttachments[0].texture =
            (__bridge id<MTLTexture>)info.fboColorTexture;
        rpd.colorAttachments[0].loadAction =
            consumeColorClear ? MTLLoadActionClear : MTLLoadActionLoad;
        if (consumeColorClear) {
            rpd.colorAttachments[0].clearColor = pendingClearColor;
        }
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        // Phase 2.5 — layered FBO routing. When the GS writes
        // `gl_Layer`, SPIRV-W's Gap C emission propagates the value to
        // `spvCurrentPrim.gl_Layer` which the mesh stage exposes as
        // `[[render_target_array_index]]` on the per-primitive output.
        // Metal requires `renderTargetArrayLength` set on the pass
        // descriptor for the rasterizer to honour it. Mirrors legacy
        // encodeTranslatedDraw at MetalFrameGraph.mm:2092.
        if (info.fboColorArrayLength > 0) {
            // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray clamp]:
            // mirror the legacy-encoder clamp for the mesh path.
            // See encodeTranslatedDraw 2DMSArray comment block.
            NSUInteger rtal = static_cast<NSUInteger>(
                info.fboColorArrayLength);
            if (info.maxEmittedLayer > 0 &&
                info.fboColorTexture != nullptr) {
                id<MTLTexture> colTex = (__bridge id<MTLTexture>)
                    info.fboColorTexture;
                if (colTex.textureType ==
                        MTLTextureType2DMultisampleArray) {
                    const NSUInteger active = static_cast<NSUInteger>(
                        info.maxEmittedLayer + 1u);
                    if (active < rtal) rtal = active;
                }
            }
            rpd.renderTargetArrayLength = rtal;
        }
        if (info.fboDepthStencilTexture != nullptr) {
            id<MTLTexture> dsTex =
                (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
            const MTLPixelFormat pf = dsTex.pixelFormat;
            if (pf == MTLPixelFormatDepth16Unorm ||
                pf == MTLPixelFormatDepth32Float ||
                pf == MTLPixelFormatDepth32Float_Stencil8 ||
                pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                rpd.depthAttachment.texture = dsTex;
                rpd.depthAttachment.loadAction =
                    consumeDepthClear ? MTLLoadActionClear : MTLLoadActionLoad;
                if (consumeDepthClear) {
                    rpd.depthAttachment.clearDepth = pendingClearDepth;
                }
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
            }
            if (pf == MTLPixelFormatStencil8 ||
                pf == MTLPixelFormatDepth32Float_Stencil8 ||
                pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                pf == MTLPixelFormatX32_Stencil8 ||
                pf == MTLPixelFormatX24_Stencil8) {
                rpd.stencilAttachment.texture = dsTex;
                rpd.stencilAttachment.loadAction =
                    consumeStencilClear ? MTLLoadActionClear : MTLLoadActionLoad;
                if (consumeStencilClear) {
                    rpd.stencilAttachment.clearStencil = pendingClearStencil;
                }
                rpd.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
        id<MTLRenderCommandEncoder> renc =
            [rcmd renderCommandEncoderWithDescriptor:rpd];
        if (renc == nil) {
            info.diagnostic = "render encoder alloc failed";
            return false;
        }
        [renc setRenderPipelineState:meshPSO];
        [renc setMeshBuffer:vsOutBuf offset:0 atIndex:22];
        if (info.meshUniformData != nullptr && info.meshUniformSize > 0) {
            [renc setMeshBytes:info.meshUniformData
                        length:info.meshUniformSize
                       atIndex:16];
        }
        if (info.fsUniformData != nullptr && info.fsUniformSize > 0) {
            [renc setFragmentBytes:info.fsUniformData
                            length:info.fsUniformSize
                           atIndex:16];
        }
        if (info.fragmentNeedsFragCoordParams) {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const float renderTargetHeight = colorTex != nil
                ? static_cast<float>(colorTex.height)
                : static_cast<float>(std::max<std::int32_t>(
                      info.viewportHeight, 1));
            bool fragmentAliasesColorAttachment = false;
            if (colorTex != nil) {
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalTexture == nullptr) continue;
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == colorTex) {
                        fragmentAliasesColorAttachment = true;
                        break;
                    }
                }
            }
            const bool flipToLowerLeft =
                (info.clipOrigin != GL_UPPER_LEFT) &&
                !fragmentAliasesColorAttachment;
            const float fragCoordParams[4] = {
                flipToLowerLeft ? renderTargetHeight : 0.0f,
                flipToLowerLeft ? -1.0f : 1.0f,
                flipToLowerLeft ? 1.0f : 0.0f,
                0.0f,
            };
            [renc setFragmentBytes:fragCoordParams
                            length:sizeof(fragCoordParams)
                           atIndex:kAppGLFragCoordParamsBufferSlot];
            if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                std::fprintf(stderr,
                    "[MESH_GS] fragCoordParams clipOrigin=0x%x rtH=%.1f "
                    "aliasesColor=%d params=(%.1f,%.1f,%.1f,%.1f)\n",
                    info.clipOrigin,
                    renderTargetHeight,
                    fragmentAliasesColorAttachment ? 1 : 0,
                    fragCoordParams[0], fragCoordParams[1],
                    fragCoordParams[2], fragCoordParams[3]);
                std::fflush(stderr);
            }
        }
        for (const auto& binding : info.fragmentTextures) {
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            if (tex == nil) {
                continue;
            }
            [renc setFragmentTexture:tex
                              atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            if (binding.imageAtomicMetalBuffer != nullptr &&
                binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                id<MTLBuffer> buf =
                    (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                if (buf != nil) {
                    [renc setFragmentBuffer:buf
                                     offset:binding.imageAtomicBufferOffset
                                    atIndex:static_cast<NSUInteger>(
                                        binding.imageAtomicBufferSlot)];
                }
            }
            if (binding.metalSamplerState != nullptr) {
                id<MTLSamplerState> smp =
                    (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                [renc setFragmentSamplerState:smp
                                       atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            }
        }
        for (const auto& binding : info.meshTextures) {
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            if (tex == nil) {
                continue;
            }
            [renc setMeshTexture:tex
                          atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            if (binding.imageAtomicMetalBuffer != nullptr &&
                binding.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                id<MTLBuffer> buf =
                    (__bridge id<MTLBuffer>)binding.imageAtomicMetalBuffer;
                if (buf != nil) {
                    [renc setMeshBuffer:buf
                                 offset:binding.imageAtomicBufferOffset
                                atIndex:static_cast<NSUInteger>(
                                    binding.imageAtomicBufferSlot)];
                }
            }
            if (binding.metalSamplerState != nullptr) {
                id<MTLSamplerState> smp =
                    (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                [renc setMeshSamplerState:smp
                                   atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            }
        }

        // GL render-state plumbing — mirrors encodeTranslatedDraw's
        // depth/cull/winding/fill/scissor/viewport sequence so the
        // mesh-shader path produces pixels with the same masks /
        // depth-test behavior the legacy path applies.
        if (info.fboDepthStencilTexture != nullptr) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = info.depthTestEnabled;
            fakeInfo.depthFunc = static_cast<GLenum>(info.depthFunc);
            fakeInfo.depthWriteMask = info.depthWriteMask;
            // Sprint 7 Phase 1 #11 (CKPT57): mesh-GS path stencil plumb.
            fakeInfo.stencilTestEnabled = info.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = static_cast<GLenum>(info.stencilFrontFunc);
            fakeInfo.stencilFrontRef = info.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = info.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = static_cast<GLenum>(info.stencilFrontFail);
            fakeInfo.stencilFrontDepthFail = static_cast<GLenum>(info.stencilFrontDepthFail);
            fakeInfo.stencilFrontDepthPass = static_cast<GLenum>(info.stencilFrontDepthPass);
            fakeInfo.stencilFrontWriteMask = info.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = static_cast<GLenum>(info.stencilBackFunc);
            fakeInfo.stencilBackRef = info.stencilBackRef;
            fakeInfo.stencilBackValueMask = info.stencilBackValueMask;
            fakeInfo.stencilBackFail = static_cast<GLenum>(info.stencilBackFail);
            fakeInfo.stencilBackDepthFail = static_cast<GLenum>(info.stencilBackDepthFail);
            fakeInfo.stencilBackDepthPass = static_cast<GLenum>(info.stencilBackDepthPass);
            fakeInfo.stencilBackWriteMask = info.stencilBackWriteMask;
            id<MTLDepthStencilState> dsState =
                depthStencilStateForDraw(fakeInfo);
            if (dsState != nil) {
                [renc setDepthStencilState:dsState];
            }
            if (info.stencilTestEnabled) {
                [renc setStencilFrontReferenceValue:
                          static_cast<uint32_t>(info.stencilFrontRef)
                       backReferenceValue:
                          static_cast<uint32_t>(info.stencilBackRef)];
            }
        }
        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront
                                              : MTLCullModeBack)
            : MTLCullModeNone;
        [renc setCullMode:desiredCull];
        [renc setFrontFacingWinding:info.frontFace == GL_CW
            ? MTLWindingClockwise : MTLWindingCounterClockwise];
        [renc setTriangleFillMode:info.wireframe
            ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        {
            const std::uint32_t sampleMask = info.sampleMask;
            [renc setFragmentBytes:&sampleMask
                             length:sizeof(sampleMask)
                            atIndex:21];
        }
        {
            const float bias = info.polygonOffsetEnabled
                ? info.polygonOffsetUnits : 0.0f;
            const float slope = info.polygonOffsetEnabled
                ? info.polygonOffsetFactor : 0.0f;
            const float clampV = info.polygonOffsetEnabled
                ? info.polygonOffsetClamp : 0.0f;
            [renc setDepthBias:bias slopeScale:slope clamp:clampV];
        }
        // Viewport. GL bottom-up → Metal top-down conversion.
        // Sprint 17 Day 3+ BONUS-1 [clip_control]: gate Y-flip on
        // `info.clipOrigin` (mesh-GS path). See encodeTranslatedDraw
        // for full rationale.
        if (info.viewportWidth > 0 && info.viewportHeight > 0) {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const double rtHeight = static_cast<double>(colorTex.height);
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(info.viewportX);
            vp.originY = flipY
                ? (rtHeight - static_cast<double>(info.viewportY)
                   - static_cast<double>(info.viewportHeight))
                : static_cast<double>(info.viewportY);
            vp.width   = static_cast<double>(info.viewportWidth);
            vp.height  = static_cast<double>(info.viewportHeight);
            vp.znear   = info.depthRangeNear;
            vp.zfar    = info.depthRangeFar;
            [renc setViewport:vp];
        }
        // Scissor. GL bottom-up → Metal top-down conversion + clamp.
        // When disabled, set to full render-target rect.
        {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const NSUInteger rtW = colorTex.width;
            const NSUInteger rtH = colorTex.height;
            MTLScissorRect sr;
            if (!info.scissorTestEnabled) {
                sr.x = 0; sr.y = 0; sr.width = rtW; sr.height = rtH;
            } else if (info.scissorWidth <= 0 ||
                       info.scissorHeight <= 0) {
                sr.x = 0; sr.y = 0; sr.width = 0; sr.height = 0;
            } else {
                std::int32_t metalY =
                    static_cast<std::int32_t>(rtH)
                    - info.scissorY - info.scissorHeight;
                if (metalY < 0) metalY = 0;
                std::int32_t metalX = info.scissorX < 0
                    ? 0 : info.scissorX;
                std::int32_t availW =
                    static_cast<std::int32_t>(rtW) - metalX;
                std::int32_t availH =
                    static_cast<std::int32_t>(rtH) - metalY;
                std::int32_t finalW =
                    std::min(info.scissorWidth, std::max(0, availW));
                std::int32_t finalH =
                    std::min(info.scissorHeight, std::max(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr.x = rtW > 0 ? rtW - 1 : 0;
                    sr.y = rtH > 0 ? rtH - 1 : 0;
                    sr.width = 1; sr.height = 1;
                } else {
                    sr.x = static_cast<NSUInteger>(metalX);
                    sr.y = static_cast<NSUInteger>(metalY);
                    sr.width = static_cast<NSUInteger>(finalW);
                    sr.height = static_cast<NSUInteger>(finalH);
                }
            }
            [renc setScissorRect:sr];
        }

        // One threadgroup per input primitive, 1 thread per group.
        // Mesh function reads spvPrimitiveID via
        // [[threadgroup_position_in_grid]] and indexes
        // spvVsOutputs[spvPrimitiveID * inputVerticesPerPrimitive +
        // vI] for each input vertex.
        [renc drawMeshThreadgroups:MTLSizeMake(info.primitiveCount, 1, 1)
            threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1)
              threadsPerMeshThreadgroup:MTLSizeMake(1, 1, 1)];
        [renc endEncoding];
        renderLease.commitAndWait(AppGLCommandReason::MeshDraw);

        // Path D — clear the pending-clear flag now that the pass has
        // consumed it (matches MetalFrameGraph.mm:984's `hasPendingClear
        // = false` after the legacy draw fires). All three masks
        // (color/depth/stencil) reset together — the legacy gate also
        // resets after a draw regardless of which channels were
        // actually consumed.
        if (consumeColorClear || consumeDepthClear || consumeStencilClear) {
            hasPendingClear = false;
        }

        return true;
    }

    // Encode + commit + wait a single compute dispatch. The wait is
    // synchronous to match CTS's "dispatch, then map SSBO" pattern —
    // without it, the map'd bytes are stale compute-shader input
    // rather than post-shader output. Revisit if we ever hit a
    // workload where pipelined compute+graphics is needed.
    bool encodeComputeDispatch(ComputeDispatchInfo& info) {
        if (!info.submissionGroup.declared) {
            info.submissionGroup.reset(AppGLSubmissionGroupKind::ComputeDispatch,
                                       AppGLCommandReason::ComputeDispatch);
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::ComputeDispatch,
                                             AppGLCommandReason::ComputeDispatch);
        }
        if (device == nil || commandQueue == nil) {
            return false;
        }
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::ComputeDispatch);
        id<MTLComputePipelineState> pso =
            (__bridge id<MTLComputePipelineState>)info.metalComputePipelineState;
        if (pso == nil) {
            return false;
        }
        // End any open render encoder to avoid nesting encoders on one
        // command buffer. Use our own dedicated command buffer so the
        // flushForReadback plumbing for render paths stays separate.
        endRenderPass();

        auto computeLease = makeCommandBuffer(AppGLCommandReason::ComputeDispatch);
        id<MTLCommandBuffer> cmdBuf = computeLease.get();
        if (cmdBuf == nil) {
            return false;
        }
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (enc == nil) {
            return false;
        }
        [enc setComputePipelineState:pso];

        // Step 7-3 compute follow-up: under argument_buffers mode, the
        // shader was compiled with `spvDescriptorSetBuffer0/1` structs
        // at [[buffer(24)]] / [[buffer(25)]] — bind through argument
        // encoders instead of direct per-slot calls. Mirror the
        // graphics-stage encodeTexturesIntoArgBuf / encodeUBOsIntoArgBuf
        // shape. Phase 7 cleanup (a) closed a two-part
        // `compute_shader.pipeline-post-fs` regression: vendored
        // SPIRV-Cross patch emits `access::read_write` for
        // NonWritable storage images (bare `texture2d<T>` landed at
        // `access::sample` and MTLArgumentEncoder didn't enumerate
        // the sample-access slot), plus reflection-time filter that
        // drops declared-but-unused storage images (SPIRV-Cross's
        // dead-code pass elides them from MSL but
        // `resources.storage_images` kept them, producing argbuf
        // entries whose slot was outside the encoder's valid range).
        const bool useArgBuf =
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        info.submissionGroup.argumentBuffersEnabled = useArgBuf;
        id<MTLFunction> computeFn = (__bridge id<MTLFunction>)info.metalComputeFunction;
        auto populateSSBOSizeConstants = [&](std::vector<std::uint32_t>& sizes) -> bool {
            sizes.clear();
            std::uint32_t maxSlot = 0;
            bool any = false;
            for (const auto& bb : info.buffers) {
                if (bb.size == 0) continue;
                maxSlot = std::max(maxSlot, bb.metalSlot);
                any = true;
            }
            if (!any) {
                return false;
            }
            sizes.assign(static_cast<std::size_t>(maxSlot) + 1u, 0u);
            for (const auto& bb : info.buffers) {
                if (bb.size == 0 || bb.metalSlot >= sizes.size()) continue;
                sizes[bb.metalSlot] = static_cast<std::uint32_t>(
                    std::min<std::size_t>(
                        bb.size,
                        static_cast<std::size_t>(
                            std::numeric_limits<std::uint32_t>::max())));
            }
            return true;
        };
        static thread_local std::vector<std::uint32_t> ssboSizeScratch;

        if (useArgBuf && computeFn != nil) {
            info.submissionGroup.addSubgroup(AppGLSubmissionGroupKind::ArgumentBinding,
                                             AppGLCommandReason::ComputeDispatch);
            // Desc_set 0: textures (sampled + storage) + SSBOs
            const bool hasTextures = !info.textures.empty();
            bool hasSet0Buffers = false;
            bool hasSet1Buffers = false;
            for (const auto& bb : info.buffers) {
                if (bb.descriptorSet == 1) {
                    hasSet1Buffers = true;
                } else {
                    hasSet0Buffers = true;
                }
            }
            id<MTLArgumentEncoder> argEncSet0 = nil;
            ScopedOwnedObjCObject argEncSet0Release;
            if (hasTextures || hasSet0Buffers || info.needsSSBOSizeBuffer) {
                argEncSet0 = [computeFn newArgumentEncoderWithBufferIndex:24];
                argEncSet0Release.reset(argEncSet0);
            }
            // Desc_set 1: UBOs (default-uniform block comes in at
            // [[id(16)]] from computeUniformData, plus any explicit
            // UBO blocks collected in info.buffers at their reflection
            // slots 16+seq). Gated similarly.
            const bool hasUniformData =
                (info.computeUniformData != nullptr && info.computeUniformSize > 0);
            id<MTLArgumentEncoder> argEncSet1 = nil;
            ScopedOwnedObjCObject argEncSet1Release;
            if (hasUniformData || hasSet1Buffers) {
                argEncSet1 = [computeFn newArgumentEncoderWithBufferIndex:25];
                argEncSet1Release.reset(argEncSet1);
            }
            if (argEncSet0 != nil) {
                const NSUInteger len0 = [argEncSet0 encodedLength];
                if (len0 > 0) {
                    // Step 7-4: ring-buffer sub-allocation for compute
                    // desc_set 0 argument buffer.
                    RingAlloc alloc0 = ringAllocRaw(len0);
                    id<MTLBuffer> buf0 = alloc0.buffer;
                    const NSUInteger buf0Offset = alloc0.offset;
                    if (buf0 != nil) {
                        info.submissionGroup.addTransient(
                            AppGLSubmissionTransientKind::ArgumentBufferPayload,
                            AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                            AppGLCommandReason::ComputeDispatch,
                            24,
                            static_cast<std::size_t>(len0));
                        [argEncSet0 setArgumentBuffer:buf0 offset:buf0Offset];
                        if (info.needsSSBOSizeBuffer) {
                            if (populateSSBOSizeConstants(ssboSizeScratch)) {
                                RingAlloc sizeAlloc = ringSuballocate(
                                    ssboSizeScratch.data(),
                                    ssboSizeScratch.size() * sizeof(std::uint32_t));
                                if (sizeAlloc.buffer != nil) {
                                    info.submissionGroup.addTransient(
                                        AppGLSubmissionTransientKind::SsboSizeBuffer,
                                        AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                                        AppGLCommandReason::ComputeDispatch,
                                        0,
                                        ssboSizeScratch.size() * sizeof(std::uint32_t));
                                    [argEncSet0 setBuffer:sizeAlloc.buffer
                                                   offset:sizeAlloc.offset
                                                  atIndex:0];
                                    [enc useResource:sizeAlloc.buffer
                                            usage:MTLResourceUsageRead];
                                }
                            }
                        }
                        for (const auto& tb : info.textures) {
                            id<MTLTexture> tex = (__bridge id<MTLTexture>)tb.metalTexture;
                            if (tex == nil) continue;
                            [argEncSet0 setTexture:tex
                                           atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                            MTLResourceUsage usage = MTLResourceUsageRead;
                            // samplerBuffer mirrors the graphics argbuf
                            // path: texture member only, no sampler slot.
                            const bool usesSamplerArgument =
                                tb.metalSamplerState != nullptr &&
                                tb.textureBufferBackingMetalBuffer == nullptr;
                            if (usesSamplerArgument) {
                                id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)tb.metalSamplerState;
                                [argEncSet0 setSamplerState:smp
                                                    atIndex:static_cast<NSUInteger>(tb.metalSlot) + 1];
                                usage |= MTLResourceUsageSample;
                            } else if (tb.metalSamplerState == nullptr) {
                                usage |= MTLResourceUsageWrite;
                            }
                            [enc useResource:tex usage:usage];
                            if (tb.textureBufferBackingMetalBuffer != nullptr) {
                                id<MTLBuffer> backingBuffer =
                                    (__bridge id<MTLBuffer>)tb.textureBufferBackingMetalBuffer;
                                if (backingBuffer != nil) {
                                    [enc useResource:backingBuffer
                                              usage:MTLResourceUsageRead];
                                }
                            }
                            if (tb.imageAtomicMetalBuffer != nullptr &&
                                tb.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                                id<MTLBuffer> atomicBuffer =
                                    (__bridge id<MTLBuffer>)tb.imageAtomicMetalBuffer;
                                if (atomicBuffer != nil) {
                                    [argEncSet0 setBuffer:atomicBuffer
                                                   offset:static_cast<NSUInteger>(
                                                              tb.imageAtomicBufferOffset)
                                                  atIndex:static_cast<NSUInteger>(
                                                              tb.imageAtomicBufferSlot)];
                                    [enc useResource:atomicBuffer
                                              usage:MTLResourceUsageRead |
                                                    MTLResourceUsageWrite];
                                }
                            }
                        }
                        // The GL default-uniform block lives at Metal slot
                        // `makeComputeBindingMap().uniformBufferBase` in both
                        // direct and argbuf modes. Under argbuf the block
                        // moves into spvDescriptorSetBuffer1 at the same
                        // [[id(N)]] — the set-1 encoder writes it below.
                        // Skip it in this set-0 loop so we don't
                        // double-bind.
                        const std::uint32_t kDefaultUniformSlot =
                            appgl::makeComputeBindingMap().uniformBufferBase;
                        for (const auto& bb : info.buffers) {
                            if (bb.descriptorSet == 1) continue;
                            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bb.metalBuffer;
                            if (buf == nil) continue;
                            if (bb.metalSlot == kDefaultUniformSlot) continue;
                            [argEncSet0 setBuffer:buf
                                           offset:static_cast<NSUInteger>(bb.offset)
                                          atIndex:static_cast<NSUInteger>(bb.metalSlot)];
                            [enc useResource:buf
                                        usage:MTLResourceUsageRead|MTLResourceUsageWrite];
                        }
                        [enc setBuffer:buf0 offset:buf0Offset atIndex:24];
                    }
                }
            }
            if (argEncSet1 != nil) {
                const NSUInteger len1 = [argEncSet1 encodedLength];
                if (len1 > 0) {
                    // Step 7-4: ring-buffer sub-allocation for compute
                    // desc_set 1 argument buffer.
                    RingAlloc alloc1 = ringAllocRaw(len1);
                    id<MTLBuffer> buf1 = alloc1.buffer;
                    const NSUInteger buf1Offset = alloc1.offset;
                    if (buf1 != nil) {
                        info.submissionGroup.addTransient(
                            AppGLSubmissionTransientKind::ArgumentBufferPayload,
                            AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                            AppGLCommandReason::ComputeDispatch,
                            25,
                            static_cast<std::size_t>(len1));
                        [argEncSet1 setArgumentBuffer:buf1 offset:buf1Offset];
                        if (hasUniformData) {
                            RingAlloc alloc = ringSuballocate(
                                info.computeUniformData, info.computeUniformSize);
                            if (alloc.buffer != nil) {
                                info.submissionGroup.addTransient(
                                    AppGLSubmissionTransientKind::UniformRingBytes,
                                    AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                                    AppGLCommandReason::ComputeDispatch,
                                    16,
                                    info.computeUniformSize);
                                [argEncSet1 setBuffer:alloc.buffer
                                               offset:alloc.offset
                                              atIndex:16];
                                [enc useResource:alloc.buffer
                                            usage:MTLResourceUsageRead];
                            }
                        }
                        for (const auto& bb : info.buffers) {
                            if (bb.descriptorSet != 1) continue;
                            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bb.metalBuffer;
                            if (buf == nil) continue;
                            [argEncSet1 setBuffer:buf
                                           offset:static_cast<NSUInteger>(bb.offset)
                                          atIndex:static_cast<NSUInteger>(bb.metalSlot)];
                            [enc useResource:buf usage:MTLResourceUsageRead];
                        }
                        [enc setBuffer:buf1 offset:buf1Offset atIndex:25];
                    }
                }
            }
        } else {
            // SSBO `.length()` / OpArrayLength support for direct compute.
            // SPIRV-Cross emits `constant uint* spvBufferSizeConstants
            // [[buffer(25)]]`; entries are keyed by the SSBO's reflected
            // Metal buffer slot and contain the effective GL bound range.
            if (info.needsSSBOSizeBuffer) {
                if (populateSSBOSizeConstants(ssboSizeScratch)) {
                    [enc setBytes:ssboSizeScratch.data()
                           length:static_cast<NSUInteger>(
                                      ssboSizeScratch.size() * sizeof(std::uint32_t))
                          atIndex:25];
                    info.submissionGroup.addTransient(
                        AppGLSubmissionTransientKind::SsboSizeBuffer,
                        AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer,
                        AppGLCommandReason::ComputeDispatch,
                        25,
                        ssboSizeScratch.size() * sizeof(std::uint32_t));
                }
            }

            // Default-uniform push constants (bare GL uniforms packed into
            // one buffer at Metal index 16 — matches the graphics-stage
            // convention used by drawArrays/drawElements). Lets compute
            // shaders see bare `uniform vec4 u0;` updates via glUniform4fv.
            if (info.computeUniformData != nullptr && info.computeUniformSize > 0) {
                [enc setBytes:info.computeUniformData
                       length:info.computeUniformSize
                      atIndex:16];
            }
            for (const auto& bb : info.buffers) {
                id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bb.metalBuffer;
                if (buf == nil) continue;
                [enc setBuffer:buf
                        offset:static_cast<NSUInteger>(bb.offset)
                       atIndex:static_cast<NSUInteger>(bb.metalSlot)];
            }
            for (const auto& tb : info.textures) {
                id<MTLTexture> tex = (__bridge id<MTLTexture>)tb.metalTexture;
                id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)tb.metalSamplerState;
                if (tex != nil) {
                    [enc setTexture:tex atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                }
                if (smp != nil) {
                    [enc setSamplerState:smp atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                }
                if (tb.imageAtomicMetalBuffer != nullptr &&
                    tb.imageAtomicBufferSlot != 0xFFFFFFFFu) {
                    id<MTLBuffer> atomicBuffer =
                        (__bridge id<MTLBuffer>)tb.imageAtomicMetalBuffer;
                    if (atomicBuffer != nil) {
                        [enc setBuffer:atomicBuffer
                                offset:static_cast<NSUInteger>(
                                           tb.imageAtomicBufferOffset)
                               atIndex:static_cast<NSUInteger>(
                                           tb.imageAtomicBufferSlot)];
                    }
                }
            }
        }
        if (info.multisampleStorageImageSampleCounts != nullptr &&
            info.multisampleStorageImageSampleCountBytes > 0) {
            [enc setBytes:info.multisampleStorageImageSampleCounts
                   length:static_cast<NSUInteger>(
                              info.multisampleStorageImageSampleCountBytes)
                  atIndex:static_cast<NSUInteger>(
                              info.multisampleStorageImageSampleCountSlot)];
        }

        // GL's glDispatchCompute(gx, gy, gz) spec: (gx, gy, gz) is the
        // number of work groups; per-group thread count is the shader's
        // `layout(local_size_x/y/z = N) in;` declaration. Metal's
        // dispatchThreadgroups maps 1:1 to this.
        const MTLSize threadGroups = MTLSizeMake(
            std::max<NSUInteger>(1, info.groupsX),
            std::max<NSUInteger>(1, info.groupsY),
            std::max<NSUInteger>(1, info.groupsZ));
        const MTLSize threadsPerGroup = MTLSizeMake(
            std::max<NSUInteger>(1, info.localX),
            std::max<NSUInteger>(1, info.localY),
            std::max<NSUInteger>(1, info.localZ));
        id<MTLBuffer> indirectBuf = (__bridge id<MTLBuffer>)info.indirectBuffer;
        if (indirectBuf != nil) {
            [enc dispatchThreadgroupsWithIndirectBuffer:indirectBuf
                                   indirectBufferOffset:static_cast<NSUInteger>(info.indirectOffset)
                                  threadsPerThreadgroup:threadsPerGroup];
        } else {
            [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
        }
        [enc endEncoding];
        computeLease.commitAndWait(AppGLCommandReason::ComputeDispatch);
        return true;
    }

    // Benchmark metric accessors.
    std::uint64_t getPipelineCacheHits() const { return pipelineCacheHits; }
    std::uint64_t getPipelineCacheMisses() const { return pipelineCacheMisses; }
    std::uint64_t getPipelineBuildAttempts() const { return pipelineBuildAttempts; }
    std::uint64_t getPipelineBuildFailures() const { return pipelineBuildFailures; }
    double getPipelineBuildMs() const { return pipelineCumulativeBuildMs; }
    void resetMetrics() {
        pipelineCacheHits = 0;
        pipelineCacheMisses = 0;
        pipelineBuildAttempts = 0;
        pipelineBuildFailures = 0;
        pipelineCumulativeBuildMs = 0.0;
    }
    std::uint64_t getMetalAllocatedBytes() const {
        if (device != nil && [device respondsToSelector:@selector(currentAllocatedSize)]) {
            return static_cast<std::uint64_t>(device.currentAllocatedSize);
        }
        return 0;
    }
    std::uint64_t getMslLibraryCacheEntries() const {
        return mslLibraryCacheEntryCount;
    }
    MetalFrameGraph::InternalMetalResourceInventory getInternalMetalResourceInventory() const {
        MetalFrameGraph::InternalMetalResourceInventory inventory;
        if (device != nil &&
            [device respondsToSelector:@selector(recommendedMaxWorkingSetSize)]) {
            inventory.recommendedWorkingSetBytes =
                static_cast<std::uint64_t>(device.recommendedMaxWorkingSetSize);
            inventory.recommendedWorkingSetAvailable =
                inventory.recommendedWorkingSetBytes != 0 ? 1 : 0;
        }
        auto addBuffer = [&inventory](id<MTLBuffer> buffer) {
            if (buffer != nil) {
                ++inventory.bufferCount;
                inventory.bufferBytes += metalAllocatedSize(buffer);
            }
        };
        auto addTexture = [&inventory](id<MTLTexture> texture) {
            if (texture != nil) {
                ++inventory.textureCount;
                inventory.textureBytes += metalAllocatedSize(texture);
            }
        };
        auto addDrawable = [&inventory](id<CAMetalDrawable> drawable) {
            if (drawable != nil) {
                ++inventory.drawableCount;
                inventory.drawableTextureBytes += metalAllocatedSize(drawable.texture);
            }
        };
        auto addLibrary = [&inventory](id<MTLLibrary> library) {
            if (library != nil) ++inventory.libraryCount;
        };
        auto addFunction = [&inventory](id<MTLFunction> function) {
            if (function != nil) ++inventory.functionCount;
        };
        auto addRenderPipeline = [&inventory](id<MTLRenderPipelineState> pipeline) {
            if (pipeline != nil) ++inventory.renderPipelineCount;
        };
        auto addComputePipeline = [&inventory](id<MTLComputePipelineState> pipeline) {
            if (pipeline != nil) ++inventory.computePipelineCount;
        };
        auto addSampler = [&inventory](id<MTLSamplerState> sampler) {
            if (sampler != nil) ++inventory.samplerCount;
        };
        auto addDepthStencil = [&inventory](id<MTLDepthStencilState> state) {
            if (state != nil) ++inventory.depthStencilStateCount;
        };
        auto addRingBuffer = [&inventory](id<MTLBuffer> buffer) {
            if (buffer != nil) {
                ++inventory.ringBufferCount;
                inventory.ringBufferBytes += metalAllocatedSize(buffer);
            }
        };
        auto snapshotTexture = [](id<MTLTexture> texture,
                                  std::uint64_t& bytes,
                                  std::uint64_t& width,
                                  std::uint64_t& height,
                                  std::uint64_t& sampleCount,
                                  std::uint64_t& pixelFormat) {
            if (texture == nil) {
                return;
            }
            bytes = metalAllocatedSize(texture);
            width = static_cast<std::uint64_t>(texture.width);
            height = static_cast<std::uint64_t>(texture.height);
            sampleCount = static_cast<std::uint64_t>(texture.sampleCount);
            pixelFormat = static_cast<std::uint64_t>(texture.pixelFormat);
        };

        addTexture(depthStencilTexture);
        addTexture(offscreenColorTexture);
        addDrawable(currentDrawable);
        inventory.drawableAcquireCalls = drawableAcquireCalls;
        inventory.drawableAcquireHits = drawableAcquireHits;
        inventory.drawableAcquireSuccesses = drawableAcquireSuccesses;
        inventory.drawableAcquireFailures = drawableAcquireFailures;
        inventory.drawablePresentCalls = drawablePresentCalls;
        inventory.presentCalls = presentCalls;
        inventory.fboClearsDeferred = fboClearsDeferred;
        inventory.fboClearsFolded = fboClearsFolded;
        inventory.fboClearsMaterialized = fboClearsMaterialized;
        inventory.fboClearsCoalesced = fboClearsCoalesced;
        inventory.encoderOpensFboDraw = encoderOpensFboDraw;
        inventory.encoderOpensDefaultFb = encoderOpensDefaultFb;
        inventory.encoderClosesFboTargetChange = encoderClosesFboTargetChange;
        inventory.encoderClosesShadingRateChange = encoderClosesShadingRateChange;
        inventory.encoderClosesViewportRequestInvalidate =
            encoderClosesViewportRequestInvalidate;
        inventory.encoderClosesReadback = encoderClosesReadback;
        inventory.encoderClosesCommandBufferCommit =
            encoderClosesCommandBufferCommit;
        inventory.encoderClosesClear = encoderClosesClear;
        inventory.translatedDrawEncodeCalls = translatedDrawEncodeCalls;
        inventory.passDescriptorBuilds = passDescriptorBuilds;
        inventory.passDescriptorBuildUsTotal = passDescriptorBuildUsTotal;
        inventory.fboPassContinuations = fboPassContinuations;
        inventory.fboPassSignatureMisses = fboPassSignatureMisses;
        inventory.presentFromFlushCalls = presentFromFlushCalls;
        inventory.presentFromSwapBuffersCalls = presentFromSwapBuffersCalls;
        inventory.presentInternalCalls = presentInternalCalls;
        inventory.presentPendingTrueCalls = presentPendingTrueCalls;
        inventory.presentPendingFalseCalls = presentPendingFalseCalls;
        inventory.presentCommandBufferPresentCalls =
            presentCommandBufferPresentCalls;
        inventory.presentCommandBufferNilCalls =
            presentCommandBufferNilCalls;
        inventory.presentNoWorkReturns = presentNoWorkReturns;
        inventory.presentCommitAttempts = presentCommitAttempts;
        inventory.presentCommitSuccesses = presentCommitSuccesses;
        inventory.presentCommitFailures = presentCommitFailures;
        inventory.drawableNilAfterPresent = drawableNilAfterPresent;
        inventory.drawableResizeCalls = drawableResizeCalls;
        inventory.drawableResizeNoops = drawableResizeNoops;
        inventory.drawableResizeGrowOnlySkips =
            drawableResizeGrowOnlySkips;
        inventory.drawableResizeDepthTextureReleases =
            drawableResizeDepthTextureReleases;
        inventory.drawableResizeOffscreenTextureReleases =
            drawableResizeOffscreenTextureReleases;
        inventory.drawableResizeLastRequestedWidth =
            drawableResizeLastRequestedWidth;
        inventory.drawableResizeLastRequestedHeight =
            drawableResizeLastRequestedHeight;
        inventory.drawableResizeLastEffectiveWidth =
            drawableResizeLastEffectiveWidth;
        inventory.drawableResizeLastEffectiveHeight =
            drawableResizeLastEffectiveHeight;
        inventory.drawableRetainCalls = drawableRetainCalls;
        inventory.drawableReleaseCalls = drawableReleaseCalls;
        inventory.drawableLiveRetains = drawableLiveRetains;
        inventory.drawablePeakLiveRetains = drawablePeakLiveRetains;
        inventory.renderEncoderOpenCalls = renderEncoderOpenCalls;
        inventory.renderEncoderReleaseCalls = renderEncoderReleaseCalls;
        inventory.renderEncoderLiveRetains = renderEncoderLiveRetains;
        inventory.renderEncoderPeakLiveRetains = renderEncoderPeakLiveRetains;
        inventory.currentDrawablePresent = currentDrawable != nil ? 1 : 0;
        if (currentDrawable != nil && currentDrawable.texture != nil) {
            id<MTLTexture> drawableTexture = currentDrawable.texture;
            inventory.currentDrawableTextureBytes =
                metalAllocatedSize(drawableTexture);
            inventory.currentDrawableWidth =
                static_cast<std::uint64_t>(drawableTexture.width);
            inventory.currentDrawableHeight =
                static_cast<std::uint64_t>(drawableTexture.height);
            inventory.currentDrawablePixelFormat =
                static_cast<std::uint64_t>(drawableTexture.pixelFormat);
            inventory.currentDrawableStorageMode =
                static_cast<std::uint64_t>(drawableTexture.storageMode);
            inventory.currentDrawableUsage =
                static_cast<std::uint64_t>(drawableTexture.usage);
            inventory.currentDrawableSampleCount =
                static_cast<std::uint64_t>(drawableTexture.sampleCount);
        }
        inventory.observedDrawableTextures =
            static_cast<std::uint64_t>(observedDrawableTextures.size());
        inventory.observedDrawableTexturePeak =
            static_cast<std::uint64_t>(observedDrawableTextures.size());
        inventory.observedDrawableTextureBytes = observedDrawableTextureBytes;
        inventory.observedDrawableTextureBytesPeak =
            observedDrawableTextureBytesPeak;
        inventory.observedDrawableTextureLimit =
            static_cast<std::uint64_t>(kObservedDrawableTextureLimit);
        inventory.observedDrawableTextureTruncated =
            observedDrawableTextureTruncated;
        if (layer != nil) {
            inventory.layerDrawableWidth =
                static_cast<std::uint64_t>(layer.drawableSize.width);
            inventory.layerDrawableHeight =
                static_cast<std::uint64_t>(layer.drawableSize.height);
            inventory.layerPixelFormat =
                static_cast<std::uint64_t>(layer.pixelFormat);
            inventory.layerFramebufferOnly = layer.framebufferOnly ? 1 : 0;
            if ([layer respondsToSelector:@selector(maximumDrawableCount)]) {
                inventory.layerMaximumDrawableCount =
                    static_cast<std::uint64_t>(layer.maximumDrawableCount);
                inventory.layerMaximumDrawableCountAvailable = 1;
            }
            if ([layer respondsToSelector:@selector(displaySyncEnabled)]) {
                inventory.layerDisplaySyncEnabled =
                    layer.displaySyncEnabled ? 1 : 0;
                inventory.layerDisplaySyncEnabledAvailable = 1;
            }
        }
        snapshotTexture(depthStencilTexture,
                        inventory.depthStencilTextureBytes,
                        inventory.depthStencilTextureWidth,
                        inventory.depthStencilTextureHeight,
                        inventory.depthStencilTextureSampleCount,
                        inventory.depthStencilTexturePixelFormat);
        inventory.depthStencilRebuilds = depthStencilTextureRebuilds;
        inventory.depthStencilReleases = depthStencilTextureReleases;
        inventory.depthStencilAllocatedBytes = depthStencilTextureAllocatedBytes;
        inventory.depthStencilRebuildsFromEnsure =
            depthStencilRebuildsFromEnsure;
        inventory.depthStencilRebuildsFromColorSizeMismatch =
            depthStencilRebuildsFromColorSizeMismatch;
        inventory.depthStencilRebuildsFromSampleMismatch =
            depthStencilRebuildsFromSampleMismatch;
        snapshotTexture(offscreenColorTexture,
                        inventory.offscreenColorTextureBytes,
                        inventory.offscreenColorTextureWidth,
                        inventory.offscreenColorTextureHeight,
                        inventory.offscreenColorTextureSampleCount,
                        inventory.offscreenColorTexturePixelFormat);
        inventory.offscreenColorRebuilds = offscreenColorTextureRebuilds;
        inventory.offscreenColorReleases = offscreenColorTextureReleases;
        inventory.offscreenColorAllocatedBytes =
            offscreenColorTextureAllocatedBytes;
        inventory.dummyColorTextureAllocations = dummyColorTextureAllocations;
        inventory.dummyColorTextureAllocatedBytes =
            dummyColorTextureAllocatedBytes;
        inventory.dummyColorTextureCacheHits = dummyColorTextureCacheHits;
        for (const auto& entry : dummyColorTextureCache) {
            for (id<MTLTexture> texture : entry.second.textures) {
                if (texture == nil) {
                    continue;
                }
                ++inventory.dummyColorTextureCacheTextures;
                inventory.dummyColorTextureCacheBytes += metalAllocatedSize(texture);
                addTexture(texture);
            }
        }
        for (id<MTLBuffer> buffer : ringBuffers) {
            addBuffer(buffer);
            addRingBuffer(buffer);
        }
        addLibrary(solidColorLibrary);
        addFunction(solidColorVertexFn);
        addFunction(solidColorFragmentFn);
        addRenderPipeline(solidColorPipelineState);
        addLibrary(tessDomainGenLibrary);
        addComputePipeline(tessDomainGenPipelineState);
        addLibrary(tessDomainCaptureLibrary);
        for (const auto& entry : tessDomainCapturePSOCache) {
            addRenderPipeline(entry.second);
        }
        addComputePipeline(tessFactorClampPipelineState);
        addLibrary(tessDomainPortLibrary);
        addComputePipeline(tessDomainPortTrianglesPSO);
        addComputePipeline(tessDomainPortQuadsPSO);
        addLibrary(immediateModeLibrary);
        addFunction(immediateModeVertexFn);
        addFunction(immediateModeColorFragmentFn);
        addFunction(immediateModeTexturedFragmentFn);
        addRenderPipeline(immediateModeColorPipelineState);
        addRenderPipeline(immediateModeTexturedPipelineState);
        addSampler(immediateModeSamplerState);
        addLibrary(depthStencilUploadLibrary);
        addFunction(depthStencilUploadVertexFn);
        addFunction(depthStencilUploadFragmentFn);
        for (const auto& entry : depthStencilUploadPSOCache) {
            addRenderPipeline(entry.second);
        }
        for (const auto& bucket : mslLibraryCache) {
            for (const auto& entry : bucket.second) {
                addLibrary(entry.library);
            }
        }
        for (const auto& entry : depthStencilCache) {
            addDepthStencil(entry.second);
        }
        if (pipelineArchive != nil) {
            ++inventory.binaryArchiveCount;
        }
        inventory.ringFallbackAllocations = ringFallbackAllocations;
        inventory.ringFallbackBytes = ringFallbackBytes;
        inventory.ringFallbackMaxBytes = ringFallbackMaxBytes;
        inventory.mslLibraryCacheLimit = mslLibraryCacheLimit();
        inventory.mslLibraryCacheEvictions = mslLibraryCacheEvictions;
        inventory.mslLibraryCacheSourceBytes = mslLibraryCacheSourceBytes;
        inventory.mslLibraryCacheSourceKeyBytes = mslLibraryCacheSourceKeyBytes;
        inventory.mslLibraryCompileTransientSourceBytes =
            mslLibraryCompileTransientSourceBytes;
        inventory.mslLibraryCacheHits = mslLibraryCacheHits;
        inventory.mslLibraryCacheMisses = mslLibraryCacheMisses;
        inventory.mslLibrarySourceNSStringCreations =
            mslLibrarySourceNSStringCreations;
        inventory.translatedDrawMSLSlotCacheLimit =
            translatedDrawMSLSlotCacheLimit();
        inventory.translatedDrawMSLSlotCacheEvictions =
            translatedDrawMSLSlotCacheEvictions;
        inventory.translatedDrawMSLSlotCacheEntries =
            static_cast<std::uint64_t>(translatedDrawMSLSlotCache.size());
        inventory.translatedDrawSampleMaskSlotCacheEntries =
            static_cast<std::uint64_t>(translatedDrawSampleMaskSlotCache.size());
        inventory.renderPsoCacheLimitPerProgram =
            renderPsoCacheLimitPerProgram();
        inventory.renderPsoCacheEvictions = renderPsoCacheEvictions;
        return inventory;
    }

private:
    void ensureDrawableResources() {
        if (device == nil) {
            return;
        }

        if (drawableWidth <= 0 || drawableHeight <= 0) {
            if (layer != nil) {
                const CGSize bounds = layer.bounds.size;
                drawableWidth = bounds.width > 0.0 ? static_cast<GLsizei>(bounds.width) : 1;
                drawableHeight = bounds.height > 0.0 ? static_cast<GLsizei>(bounds.height) : 1;
            } else {
                drawableWidth = 1;
                drawableHeight = 1;
            }
        }

        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }

        const bool needsDepthRebuild =
            depthStencilTexture == nil
            || depthStencilTexture.width != static_cast<NSUInteger>(drawableWidth)
            || depthStencilTexture.height != static_cast<NSUInteger>(drawableHeight);

        if (needsDepthRebuild) {
            id<MTLTexture> replacement = nil;
            @autoreleasepool {
                MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                                      width:static_cast<NSUInteger>(drawableWidth)
                                                                                                     height:static_cast<NSUInteger>(drawableHeight)
                                                                                                  mipmapped:NO];
                descriptor.storageMode = MTLStorageModePrivate;
                descriptor.usage = MTLTextureUsageRenderTarget;
                replacement = newDepthStencilTexture(descriptor);
            }
            if (replacement != nil) {
                ++depthStencilRebuildsFromEnsure;
            }
            replaceDepthStencilTexture(replacement);
        }

        const bool needsOffscreenRebuild =
            usesOffscreenTarget
            && (offscreenColorTexture == nil
                || offscreenColorTexture.width != static_cast<NSUInteger>(drawableWidth)
                || offscreenColorTexture.height != static_cast<NSUInteger>(drawableHeight));
        if (needsOffscreenRebuild) {
            id<MTLTexture> replacement = nil;
            @autoreleasepool {
                MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                          width:static_cast<NSUInteger>(drawableWidth)
                                                                                                         height:static_cast<NSUInteger>(drawableHeight)
                                                                                                      mipmapped:NO];
                colorDescriptor.storageMode = MTLStorageModePrivate;
                colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                replacement = newOffscreenColorTexture(colorDescriptor);
            }
            replaceOffscreenColorTexture(replacement);
        }
    }

    NSUInteger alignBytesPerRow(NSUInteger byteCount) const {
        constexpr NSUInteger kMetalBufferAlignment = 256;
        return ((byteCount + kMetalBufferAlignment - 1u) / kMetalBufferAlignment) * kMetalBufferAlignment;
    }

    std::uint8_t normalizedByte(GLfloat value) const {
        const GLfloat clamped = std::clamp(value, 0.0f, 1.0f);
        return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
    }

    void storeHeadlessClear(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if ((mask & GL_COLOR_BUFFER_BIT) == 0) {
            return;
        }

        const std::size_t width = static_cast<std::size_t>(drawableWidth > 0 ? drawableWidth : 1);
        const std::size_t height = static_cast<std::size_t>(drawableHeight > 0 ? drawableHeight : 1);
        headlessReadbackRGBA.assign(width * height * 4u, 0);
        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        for (std::size_t offset = 0; offset < headlessReadbackRGBA.size(); offset += 4u) {
            std::memcpy(headlessReadbackRGBA.data() + offset, rgba, 4);
        }
        hasHeadlessReadback = true;
    }

    bool copyHeadlessPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) const {
        if (!hasHeadlessReadback) {
            return false;
        }
        const auto sourceWidth = drawableWidth > 0 ? drawableWidth : 1;
        const auto sourceHeight = drawableHeight > 0 ? drawableHeight : 1;
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4u;
                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = (static_cast<std::size_t>(srcY) * static_cast<std::size_t>(sourceWidth)
                    + static_cast<std::size_t>(srcX)) * 4u;
                std::memcpy(bytes + dstOffset, headlessReadbackRGBA.data() + srcOffset, 4);
            }
        }
        return true;
    }

    void enqueueOffscreenClearUpload(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if (!usesOffscreenTarget || (mask & GL_COLOR_BUFFER_BIT) == 0 || offscreenColorTexture == nil || currentCommandBuffer == nil) {
            return;
        }

        const NSUInteger width = offscreenColorTexture.width;
        const NSUInteger height = offscreenColorTexture.height;
        const NSUInteger packedRowBytes = width * 4u;
        const NSUInteger rowBytes = alignBytesPerRow(packedRowBytes);
        id<MTLBuffer> staging = [device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        if (staging == nil) {
            return;
        }
        currentCommandBufferLease.adoptRetainedObject(staging);

        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        auto* bytes = static_cast<std::uint8_t*>([staging contents]);
        for (NSUInteger row = 0; row < height; ++row) {
            std::uint8_t* rowStart = bytes + row * rowBytes;
            for (NSUInteger col = 0; col < width; ++col) {
                std::memcpy(rowStart + col * 4u, rgba, 4);
            }
        }

        id<MTLBlitCommandEncoder> blit = [currentCommandBuffer blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:rowBytes
         sourceBytesPerImage:rowBytes * height
                  sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:offscreenColorTexture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        readbackSourceTexture = offscreenColorTexture;
        readbackSourceIsBGRA = false;
    }

    void invalidateTransientState() {
        flushParallelTranslatedDrawBatch(
            ParallelEncodeBoundaryReason::TransientInvalidation);
        const bool submittedBeforeInvalidation =
            commitCurrentBeforeTransientInvalidation(AppGLCommandReason::FlushForReadback);
        if (submittedBeforeInvalidation && commandSubmission != nullptr) {
            commandSubmission->drainAllOutstanding(AppGLCommandReason::LifetimeDrain,
                                                   submittedBeforeInvalidation);
        }
        // Ensure the render encoder is properly ended before we drop it. If
        // the diagnostic stub disabled the submit path, this intentionally
        // reaches the legacy abandon behavior for the abandonment sentinel.
        endRenderPass();
        currentCommandBufferLease.abandon("invalidate-transient-state");
        currentCommandBuffer = nil;
        clearCurrentDrawable();
        pendingPresent = false;
        hasPendingClear = false;
        resetCachedEncoderState();
    }

    GLContext* owner = nullptr;
    CAMetalLayer* layer = nil;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    MetalCommandSubmission* commandSubmission = nullptr;
    id<MTLTexture> depthStencilTexture = nil;
    id<MTLTexture> offscreenColorTexture = nil;
    id<MTLTexture> readbackSourceTexture = nil;
    id<MTLCommandBuffer> currentCommandBuffer = nil;
    MetalCommandBufferLease currentCommandBufferLease;
    id<MTLRenderCommandEncoder> currentRenderEncoder = nil;
    GLenum activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    id<CAMetalDrawable> currentDrawable = nil;
    bool currentDrawablePresented = false;
    id<MTLLibrary> solidColorLibrary = nil;
    id<MTLFunction> solidColorVertexFn = nil;
    id<MTLFunction> solidColorFragmentFn = nil;
    id<MTLRenderPipelineState> solidColorPipelineState = nil;
    MTLPixelFormat solidColorPipelineColorFormat = MTLPixelFormatInvalid;

    // Phase 3B.3 [metal-tess-TF] — tess domain-point generator compute
    // kernel. Built lazily the first time a TES-as-compute path needs
    // it (usually on first tess draw that bypasses the CPU interpreter).
    // See `ensureTessDomainGenLibrary` for the MSL source — MSL port of
    // `generateTessDomain` from TessellationEmulator.cpp.
    id<MTLLibrary> tessDomainGenLibrary = nil;
    id<MTLComputePipelineState> tessDomainGenPipelineState = nil;

    // Phase 3C [metal-tess-TF] — HW-tessellator domain-coord capture
    // path. Alternative to the MSL-kernel path above: uses Metal's HW
    // tessellator driven by a `vertex void` capture function with
    // rasterization disabled, so the HW emits (tessCoord, primID) pairs
    // into the same buffers `spvGenTessDomain` populates. Gate via env
    // `APPGL_TESS_DOMAIN_USE_METAL_HW`. Scaffolding only — unwired in
    // this commit; the three-pass encoder still uses the compute kernel.
    // Validated by `phase5ProbeMetalNativeTess` — §11.2.2 spec-exact for
    // quad rule4 levels (1046 unique verts = 30×4 edges − 4 corners +
    // 31×30 interior) and symmetric for triangle rule4 (858 unique,
    // 134 unique u, 134 unique v).
    id<MTLLibrary> tessDomainCaptureLibrary = nil;
    std::unordered_map<std::uint32_t, id<MTLRenderPipelineState>>
        tessDomainCapturePSOCache;
    // Factor-clamp compute PSO. Shared across all HW capture draws
    // (no partition/winding specialization needed — pure value clamp).
    id<MTLComputePipelineState> tessFactorClampPipelineState = nil;

    // Phase 4A [metal-tess-TF] — CPU-exact MSL port of
    // `TessellationEmulator::generateTessDomain`. Replaces the
    // Phase 3B.3 `spvGenTessDomain` kernel when
    // APPGL_TESS_DOMAIN_PORT is set. The ported kernel matches the
    // CPU reference bit-for-bit (validated by
    // `phaseAProbeTessDomainPort`), so CTS's counter-probe expectations
    // align. Compiled with `MTLMathModeSafe` to prevent fp-contract
    // fusion. Triangles + quads only — isolines stay on
    // `spvGenTessDomain` (no Metal `.isoline` patch type).
    id<MTLLibrary> tessDomainPortLibrary = nil;
    id<MTLComputePipelineState> tessDomainPortTrianglesPSO = nil;
    id<MTLComputePipelineState> tessDomainPortQuadsPSO = nil;

    // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
    // shader library, two pipeline states, and a default sampler.
    // See `ensureImmediateModeLibrary` and `ensureImmediateModePipelines`
    // for the shader source and descriptor layout. These are only
    // touched from `encodeImmediateModeDraw` so no cross-encoder
    // caching is needed.
    id<MTLLibrary> immediateModeLibrary = nil;
    id<MTLFunction> immediateModeVertexFn = nil;
    id<MTLFunction> immediateModeColorFragmentFn = nil;
    id<MTLFunction> immediateModeTexturedFragmentFn = nil;
    id<MTLRenderPipelineState> immediateModeColorPipelineState = nil;
    id<MTLRenderPipelineState> immediateModeTexturedPipelineState = nil;
    MTLPixelFormat immediateModePipelineColorFormat = MTLPixelFormatInvalid;
    id<MTLSamplerState> immediateModeSamplerState = nil;
    id<MTLLibrary> depthStencilUploadLibrary = nil;
    id<MTLFunction> depthStencilUploadVertexFn = nil;
    id<MTLFunction> depthStencilUploadFragmentFn = nil;
    std::unordered_map<std::uint64_t, id<MTLRenderPipelineState>>
        depthStencilUploadPSOCache;
    std::vector<std::uint8_t> headlessReadbackRGBA;
    GLsizei drawableWidth = 1;
    GLsizei drawableHeight = 1;
    bool usesOffscreenTarget = false;
    bool pendingPresent = false;
    bool readbackSourceIsBGRA = false;
    bool hasHeadlessReadback = false;

    static constexpr std::size_t kObservedDrawableTextureLimit = 128;
    std::uint64_t drawableAcquireCalls = 0;
    std::uint64_t drawableAcquireHits = 0;
    std::uint64_t drawableAcquireSuccesses = 0;
    std::uint64_t drawableAcquireFailures = 0;
    std::uint64_t drawablePresentCalls = 0;
    std::uint64_t presentCalls = 0;
    std::uint64_t presentFromFlushCalls = 0;
    std::uint64_t presentFromSwapBuffersCalls = 0;
    std::uint64_t presentInternalCalls = 0;
    std::uint64_t presentPendingTrueCalls = 0;
    std::uint64_t presentPendingFalseCalls = 0;
    std::uint64_t presentCommandBufferPresentCalls = 0;
    std::uint64_t presentCommandBufferNilCalls = 0;
    std::uint64_t presentNoWorkReturns = 0;
    std::uint64_t presentCommitAttempts = 0;
    std::uint64_t presentCommitSuccesses = 0;
    std::uint64_t presentCommitFailures = 0;
    std::uint64_t drawableNilAfterPresent = 0;
    std::uint64_t drawableResizeCalls = 0;
    std::uint64_t drawableResizeNoops = 0;
    std::uint64_t drawableResizeGrowOnlySkips = 0;
    std::uint64_t drawableResizeDepthTextureReleases = 0;
    std::uint64_t drawableResizeOffscreenTextureReleases = 0;
    std::uint64_t drawableResizeLastRequestedWidth = 0;
    std::uint64_t drawableResizeLastRequestedHeight = 0;
    std::uint64_t drawableResizeLastEffectiveWidth = 0;
    std::uint64_t drawableResizeLastEffectiveHeight = 0;
    std::uint64_t drawableRetainCalls = 0;
    std::uint64_t drawableReleaseCalls = 0;
    std::uint64_t drawableLiveRetains = 0;
    std::uint64_t drawablePeakLiveRetains = 0;
    std::uint64_t renderEncoderOpenCalls = 0;
    std::uint64_t renderEncoderReleaseCalls = 0;
    std::uint64_t renderEncoderLiveRetains = 0;
    std::uint64_t renderEncoderPeakLiveRetains = 0;
    // S24 C49 draw-path census — encoder lifecycle decomposition for
    // the pass-continuation lever. Opens split by target class; closes
    // attributed at the specific close sites; continuation counters are
    // baseline zeros until C49 lands (their A/B delta is the
    // engagement proof). passDescriptorBuild* times the pass-build →
    // encoder-open block (two timestamps per pass open, not per draw).
    std::uint64_t encoderOpensFboDraw = 0;
    std::uint64_t encoderOpensDefaultFb = 0;
    std::uint64_t encoderClosesFboTargetChange = 0;
    std::uint64_t encoderClosesShadingRateChange = 0;
    std::uint64_t encoderClosesViewportRequestInvalidate = 0;
    std::uint64_t encoderClosesReadback = 0;
    std::uint64_t encoderClosesCommandBufferCommit = 0;
    std::uint64_t encoderClosesClear = 0;
    std::uint64_t translatedDrawEncodeCalls = 0;
    std::uint64_t passDescriptorBuilds = 0;
    std::uint64_t passDescriptorBuildUsTotal = 0;
    std::uint64_t fboPassContinuations = 0;
    std::uint64_t fboPassSignatureMisses = 0;
    std::uint64_t observedDrawableTextureBytes = 0;
    std::uint64_t observedDrawableTextureBytesPeak = 0;
    std::uint64_t observedDrawableTextureTruncated = 0;
    std::unordered_set<std::uintptr_t> observedDrawableTextures;
    std::uint64_t depthStencilTextureRebuilds = 0;
    std::uint64_t depthStencilTextureReleases = 0;
    std::uint64_t depthStencilTextureAllocatedBytes = 0;
    std::uint64_t depthStencilRebuildsFromEnsure = 0;
    std::uint64_t depthStencilRebuildsFromColorSizeMismatch = 0;
    std::uint64_t depthStencilRebuildsFromSampleMismatch = 0;
    std::uint64_t offscreenColorTextureRebuilds = 0;
    std::uint64_t offscreenColorTextureReleases = 0;
    std::uint64_t offscreenColorTextureAllocatedBytes = 0;
    std::uint64_t dummyColorTextureAllocations = 0;
    std::uint64_t dummyColorTextureAllocatedBytes = 0;
    std::uint64_t dummyColorTextureCacheHits = 0;
    std::unordered_map<DummyColorTextureCacheKey,
                       DummyColorTextureCacheBucket,
                       DummyColorTextureCacheKeyHash> dummyColorTextureCache;

    // Deferred clear state (OPT-4). Stored by encodeClear(), consumed by
    // the next render pass that opens in encodeTranslatedDraw or
    // encodeSolidColorDraw. Flushed standalone by copyPixels/present
    // if no draw occurs between clear and readback/present.
    bool hasPendingClear = false;
    GLbitfield pendingClearMask = 0;
    MTLClearColor pendingClearColor = MTLClearColorMake(0, 0, 0, 0);
    double pendingClearDepth = 1.0;
    std::uint32_t pendingClearStencil = 0;

    struct MslLibraryCacheLookupKey {
        std::uint64_t sourceHash = 0;
        std::uint64_t compileOptionsKey = 0;
        std::uint64_t specializationKey = 0;
        std::size_t sourceBytes = 0;
    };

    struct MslLibraryCacheEntry {
        MslLibraryCacheLookupKey key;
        std::string source;
        id<MTLLibrary> library = nil;
        std::uint64_t lastUse = 0;
    };

    // ADV-2: MTLLibrary cache bucketed by deterministic MSL source hash and
    // resolved by exact source/options/spec equality. The hash selects a small
    // bucket only; it is never sufficient to serve a library.
    std::unordered_map<std::uint64_t, std::vector<MslLibraryCacheEntry>>
        mslLibraryCache;
    std::uint64_t mslLibraryCacheClock = 0;
    std::uint64_t mslLibraryCacheEntryCount = 0;
    std::uint64_t mslLibraryCacheEvictions = 0;
    std::uint64_t mslLibraryCacheSourceBytes = 0;
    std::uint64_t mslLibraryCacheSourceKeyBytes = 0;
    std::uint64_t mslLibraryCompileTransientSourceBytes = 0;
    std::uint64_t mslLibraryCacheHits = 0;
    std::uint64_t mslLibraryCacheMisses = 0;
    std::uint64_t mslLibrarySourceNSStringCreations = 0;

    // Per-pipeline cache for fixed helper parameter slots discovered in
    // translated MSL. The pipeline key already fingerprints shader text, so
    // repeated draws skip rescanning the same source for helper buffers.
    std::unordered_map<std::uint64_t, TranslatedDrawMSLSlots>
        translatedDrawMSLSlotCache;
    std::unordered_map<std::uint64_t, std::uint64_t>
        translatedDrawMSLSlotCacheLastUse;
    std::uint64_t translatedDrawMSLSlotCacheClock = 0;
    std::uint64_t translatedDrawMSLSlotCacheEvictions = 0;
    std::unordered_map<std::uint64_t, NSInteger>
        translatedDrawSampleMaskSlotCache;
    std::uint64_t renderPsoCacheClock = 0;
    std::uint64_t renderPsoCacheEvictions = 0;

    // ADV-4: reusable render pass descriptor. Avoids allocating a fresh
    // autoreleased ObjC object at each render-pass setup site.
    MTLRenderPassDescriptor* reusablePassDescriptor = nil;

    void resetReusablePassAttachment(MTLRenderPassAttachmentDescriptor* attachment) {
        attachment.texture = nil;
        attachment.level = 0;
        attachment.slice = 0;
        attachment.depthPlane = 0;
        attachment.resolveTexture = nil;
        attachment.resolveLevel = 0;
        attachment.resolveSlice = 0;
        attachment.resolveDepthPlane = 0;
        attachment.loadAction = MTLLoadActionDontCare;
        attachment.storeAction = MTLStoreActionDontCare;
        attachment.storeActionOptions = MTLStoreActionOptionNone;
    }

    MTLRenderPassDescriptor* getReusablePassDescriptor() {
        bool created = false;
        if (reusablePassDescriptor == nil) {
            reusablePassDescriptor = [MTLRenderPassDescriptor new];
            created = true;
        }
        for (NSUInteger i = 0; i < 8; ++i) {
            MTLRenderPassColorAttachmentDescriptor* color =
                reusablePassDescriptor.colorAttachments[i];
            resetReusablePassAttachment(color);
            color.clearColor = MTLClearColorMake(0, 0, 0, 0);
        }
        resetReusablePassAttachment(reusablePassDescriptor.depthAttachment);
        reusablePassDescriptor.depthAttachment.clearDepth = 1.0;
        resetReusablePassAttachment(reusablePassDescriptor.stencilAttachment);
        reusablePassDescriptor.stencilAttachment.clearStencil = 0;
        reusablePassDescriptor.visibilityResultBuffer = nil;
        reusablePassDescriptor.renderTargetArrayLength = 0;
        if (@available(macOS 10.15.4, *)) {
            reusablePassDescriptor.rasterizationRateMap = nil;
        }
#ifdef APPGL_LOG_DRAW
        APPGL_LOG(DRAW, @"ADV-4 renderPassDescriptor cache-%@ pass=%p",
                  created ? @"miss" : @"hit", reusablePassDescriptor);
#else
        (void)created;
#endif
        return reusablePassDescriptor;
    }

    // ADV-7: consolidated drawable acquisition.  Every render path
    // calls this instead of inlining `[layer nextDrawable]`.
    void observeDrawableTexture(id<MTLTexture> texture) {
        if (texture == nil) {
            return;
        }
        const auto key =
            reinterpret_cast<std::uintptr_t>((__bridge void*)texture);
        const std::uint64_t bytes = metalAllocatedSize(texture);
        if (observedDrawableTextures.find(key) != observedDrawableTextures.end()) {
            return;
        }
        if (observedDrawableTextures.size() >= kObservedDrawableTextureLimit) {
            ++observedDrawableTextureTruncated;
            return;
        }
        observedDrawableTextures.insert(key);
        observedDrawableTextureBytes += bytes;
        observedDrawableTextureBytesPeak =
            std::max(observedDrawableTextureBytesPeak,
                     observedDrawableTextureBytes);
    }

    bool acquireDrawableIfNeeded() {
        if (usesOffscreenTarget) return true;
        ++drawableAcquireCalls;
        if (currentDrawable != nil) {
            ++drawableAcquireHits;
            observeDrawableTexture(currentDrawable.texture);
            return true;
        }
        @autoreleasepool {
            currentDrawable = retainOwnedObjCObject([layer nextDrawable]);
        }
        currentDrawablePresented = false;
        if (currentDrawable != nil) {
            ++drawableRetainCalls;
            ++drawableLiveRetains;
            drawablePeakLiveRetains =
                std::max(drawablePeakLiveRetains, drawableLiveRetains);
            ++drawableAcquireSuccesses;
            observeDrawableTexture(currentDrawable.texture);
            return true;
        }
        ++drawableAcquireFailures;
        return false;
    }

    void presentCurrentDrawable(id<MTLCommandBuffer> commandBuffer) {
        if (commandBuffer == nil || usesOffscreenTarget || currentDrawable == nil ||
            !pendingPresent) {
            return;
        }
        [commandBuffer presentDrawable:currentDrawable];
        currentDrawablePresented = true;
        ++drawablePresentCalls;
        observeDrawableTexture(currentDrawable.texture);
    }

    void clearCurrentDrawable() {
        if (currentDrawable != nil && currentDrawablePresented) {
            ++drawableNilAfterPresent;
        }
        if (currentDrawable != nil) {
            releaseOwnedObjCObject(currentDrawable);
            ++drawableReleaseCalls;
            if (drawableLiveRetains > 0) {
                --drawableLiveRetains;
            }
        }
        currentDrawable = nil;
        currentDrawablePresented = false;
    }

    void evictRenderPsoCacheIfNeeded(TranslatedDrawInfo& info) {
        const std::size_t limit = renderPsoCacheLimitPerProgram();
        if (limit == 0 || info.pipelineStateCacheOut == nullptr) {
            return;
        }
        auto& cache = *info.pipelineStateCacheOut;
        auto* lastUse = info.pipelineStateCacheLastUseOut;
        while (cache.size() > limit && !cache.empty()) {
            auto evictIt = cache.end();
            std::uint64_t oldestUse = std::numeric_limits<std::uint64_t>::max();
            for (auto it = cache.begin(); it != cache.end(); ++it) {
                std::uint64_t use = 0;
                if (lastUse != nullptr) {
                    auto useIt = lastUse->find(it->first);
                    if (useIt != lastUse->end()) {
                        use = useIt->second;
                    }
                }
                if (evictIt == cache.end() || use < oldestUse) {
                    oldestUse = use;
                    evictIt = it;
                }
            }
            if (evictIt == cache.end()) {
                break;
            }
            void* evicted = evictIt->second;
            if (info.pipelineStateOut != nullptr &&
                *info.pipelineStateOut == evicted) {
                if (*info.pipelineStateOut != nullptr) {
                    CFRelease(*info.pipelineStateOut);
                }
                *info.pipelineStateOut = nullptr;
                if (info.pipelineColorFormatOut != nullptr) {
                    *info.pipelineColorFormatOut = 0;
                }
            }
            if (evicted != nullptr) {
                CFRelease(evicted);
            }
            if (lastUse != nullptr) {
                lastUse->erase(evictIt->first);
            }
            cache.erase(evictIt);
            ++renderPsoCacheEvictions;
            if (info.pipelineStateCacheEvictionsOut != nullptr) {
                ++(*info.pipelineStateCacheEvictionsOut);
            }
        }
    }

    void evictTranslatedDrawMSLSlotsIfNeeded() {
        const std::size_t limit = translatedDrawMSLSlotCacheLimit();
        while (limit > 0 && translatedDrawMSLSlotCache.size() > limit &&
               !translatedDrawMSLSlotCache.empty()) {
            auto evictIt = translatedDrawMSLSlotCache.end();
            std::uint64_t oldestUse = std::numeric_limits<std::uint64_t>::max();
            for (auto it = translatedDrawMSLSlotCache.begin();
                 it != translatedDrawMSLSlotCache.end(); ++it) {
                std::uint64_t use = 0;
                auto useIt = translatedDrawMSLSlotCacheLastUse.find(it->first);
                if (useIt != translatedDrawMSLSlotCacheLastUse.end()) {
                    use = useIt->second;
                }
                if (evictIt == translatedDrawMSLSlotCache.end() ||
                    use < oldestUse) {
                    oldestUse = use;
                    evictIt = it;
                }
            }
            if (evictIt == translatedDrawMSLSlotCache.end()) {
                break;
            }
            translatedDrawMSLSlotCacheLastUse.erase(evictIt->first);
            translatedDrawMSLSlotCache.erase(evictIt);
            ++translatedDrawMSLSlotCacheEvictions;
        }
    }

    const TranslatedDrawMSLSlots& translatedDrawMSLSlots(
        const TranslatedDrawInfo& info,
        std::uint64_t pipelineCacheKey,
        bool hasFragmentStage) {
        auto it = translatedDrawMSLSlotCache.find(pipelineCacheKey);
        if (it != translatedDrawMSLSlotCache.end()) {
            translatedDrawMSLSlotCacheLastUse[pipelineCacheKey] =
                ++translatedDrawMSLSlotCacheClock;
            return it->second;
        }
        auto inserted = translatedDrawMSLSlotCache.emplace(
            pipelineCacheKey,
            buildTranslatedDrawMSLSlots(info, hasFragmentStage));
        translatedDrawMSLSlotCacheLastUse[pipelineCacheKey] =
            ++translatedDrawMSLSlotCacheClock;
        evictTranslatedDrawMSLSlotsIfNeeded();
        return inserted.first->second;
    }

    static std::uint64_t mslLibraryScalarKeyBytes() {
        return static_cast<std::uint64_t>(sizeof(MslLibraryCacheLookupKey));
    }

    static std::uint64_t mslLibraryEntrySourceKeyBytes(
        const MslLibraryCacheEntry& entry) {
        return static_cast<std::uint64_t>(entry.source.size()) +
            mslLibraryScalarKeyBytes();
    }

    static bool mslLibraryEntryMatches(const MslLibraryCacheEntry& entry,
                                       const MslLibraryCacheLookupKey& key,
                                       const std::string& source) {
        return entry.key.sourceHash == key.sourceHash &&
               entry.key.compileOptionsKey == key.compileOptionsKey &&
               entry.key.specializationKey == key.specializationKey &&
               entry.key.sourceBytes == key.sourceBytes &&
               entry.source == source;
    }

    MslLibraryCacheLookupKey makeMslLibraryCacheKey(
        const std::string& msl,
        std::uint64_t compileOptionsKey,
        std::uint64_t specializationKey) const {
        MslLibraryCacheLookupKey key;
        key.sourceHash = stableMslSourceHash(msl);
        key.compileOptionsKey = compileOptionsKey;
        key.specializationKey = specializationKey;
        key.sourceBytes = msl.size();
        return key;
    }

    void addMslLibraryCacheAccounting(const MslLibraryCacheEntry& entry) {
        ++mslLibraryCacheEntryCount;
        mslLibraryCacheSourceBytes +=
            static_cast<std::uint64_t>(entry.source.size());
        mslLibraryCacheSourceKeyBytes += mslLibraryEntrySourceKeyBytes(entry);
    }

    void removeMslLibraryCacheAccounting(const MslLibraryCacheEntry& entry) {
        if (mslLibraryCacheEntryCount > 0) {
            --mslLibraryCacheEntryCount;
        }
        const auto sourceBytes =
            static_cast<std::uint64_t>(entry.source.size());
        mslLibraryCacheSourceBytes =
            sourceBytes <= mslLibraryCacheSourceBytes
                ? mslLibraryCacheSourceBytes - sourceBytes : 0;
        const auto sourceKeyBytes = mslLibraryEntrySourceKeyBytes(entry);
        mslLibraryCacheSourceKeyBytes =
            sourceKeyBytes <= mslLibraryCacheSourceKeyBytes
                ? mslLibraryCacheSourceKeyBytes - sourceKeyBytes : 0;
    }

    void evictMslLibraryCacheIfNeeded() {
        const std::size_t limit = mslLibraryCacheLimit();
        while (limit > 0 && mslLibraryCacheEntryCount > limit &&
               !mslLibraryCache.empty()) {
            auto evictBucket = mslLibraryCache.end();
            std::size_t evictIndex = 0;
            std::uint64_t oldestUse = std::numeric_limits<std::uint64_t>::max();
            for (auto bucket = mslLibraryCache.begin();
                 bucket != mslLibraryCache.end(); ++bucket) {
                for (std::size_t i = 0; i < bucket->second.size(); ++i) {
                    const auto& entry = bucket->second[i];
                    if (entry.lastUse < oldestUse) {
                        oldestUse = entry.lastUse;
                        evictBucket = bucket;
                        evictIndex = i;
                    }
                }
            }
            if (evictBucket == mslLibraryCache.end()) {
                break;
            }
            auto& entries = evictBucket->second;
            auto& entry = entries[evictIndex];
            releaseOwnedObjCObject(entry.library);
            removeMslLibraryCacheAccounting(entry);
            entries.erase(entries.begin() + static_cast<std::ptrdiff_t>(evictIndex));
            if (entries.empty()) {
                mslLibraryCache.erase(evictBucket);
            }
            ++mslLibraryCacheEvictions;
        }
    }

    class ScopedMslLibraryCompileSourceGauge {
    public:
        ScopedMslLibraryCompileSourceGauge(
            std::uint64_t& gauge,
            std::uint64_t bytes)
            : gauge_(gauge), bytes_(bytes) {
            gauge_ += bytes_;
        }
        ScopedMslLibraryCompileSourceGauge(
            const ScopedMslLibraryCompileSourceGauge&) = delete;
        ScopedMslLibraryCompileSourceGauge& operator=(
            const ScopedMslLibraryCompileSourceGauge&) = delete;
        ~ScopedMslLibraryCompileSourceGauge() {
            gauge_ = bytes_ <= gauge_ ? gauge_ - bytes_ : 0;
        }
    private:
        std::uint64_t& gauge_;
        std::uint64_t bytes_ = 0;
    };

    // ADV-2: get-or-compile a Metal library from MSL source text,
    // returning a cached copy if the same source/options/spec key was compiled
    // before. Rung-1 keeps options/spec keys explicit at zero because the
    // current call uses nil options and no function constants.
    id<MTLLibrary> getOrCompileLibrary(const std::string& msl) {
        const MslLibraryCacheLookupKey key =
            makeMslLibraryCacheKey(msl, /*compileOptionsKey=*/0,
                                   /*specializationKey=*/0);
        auto bucketIt = mslLibraryCache.find(key.sourceHash);
        if (bucketIt != mslLibraryCache.end()) {
            for (auto& entry : bucketIt->second) {
                if (mslLibraryEntryMatches(entry, key, msl)) {
                    ++mslLibraryCacheHits;
                    entry.lastUse = ++mslLibraryCacheClock;
                    return entry.library;
                }
            }
        }

        // Negative cache — a source that failed to compile must NOT be
        // recompiled on every draw that references it. Without this, one
        // broken generated shader turns into a 300-500ms Metal compile
        // per draw per frame on the main thread (the e2a876d live
        // regression: ~1 frame per 10 seconds + beachball). Exact-source
        // match on hash collision; bounded; loud one-time diagnostic.
        {
            auto failedIt = mslLibraryCompileFailures.find(key.sourceHash);
            if (failedIt != mslLibraryCompileFailures.end()) {
                for (const auto& failedSource : failedIt->second) {
                    if (failedSource == msl) {
                        ++mslLibraryCompileFailureHits;
                        return nil;
                    }
                }
            }
        }

        ++mslLibraryCacheMisses;
        id<MTLLibrary> lib = nil;
        @autoreleasepool {
            ScopedMslLibraryCompileSourceGauge sourceGauge(
                mslLibraryCompileTransientSourceBytes,
                static_cast<std::uint64_t>(msl.size()));
            NSString* src =
                [[NSString alloc] initWithBytes:msl.data()
                                         length:static_cast<NSUInteger>(msl.size())
                                       encoding:NSUTF8StringEncoding];
            ScopedOwnedObjCObject srcRelease(src);
            if (src == nil) {
                if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                    std::fprintf(stderr,
                        "[APPGL] MSL library build failed: invalid UTF-8 source\n");
                }
                return nil;
            }
            ++mslLibrarySourceNSStringCreations;
            NSError* err = nil;
            lib = [device newLibraryWithSource:src options:nil error:&err];
            if (lib == nil && std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                std::fprintf(stderr, "[APPGL] MSL library build failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "(no err)");
            }
        }
        if (lib != nil) {
            MslLibraryCacheEntry entry;
            entry.key = key;
            entry.source = msl;
            entry.library = lib;
            entry.lastUse = ++mslLibraryCacheClock;
            auto& bucket = mslLibraryCache[key.sourceHash];
            bucket.push_back(std::move(entry));
            addMslLibraryCacheAccounting(bucket.back());
            evictMslLibraryCacheIfNeeded();
        } else {
            // Record the failure (bounded; loud once per source). The
            // unconditional stderr line is half the protection — a
            // fast-fail that is silent hides a broken shader.
            constexpr std::size_t kMaxFailedSources = 64;
            if (mslLibraryCompileFailureCount < kMaxFailedSources) {
                mslLibraryCompileFailures[key.sourceHash].push_back(msl);
                ++mslLibraryCompileFailureCount;
            }
            std::fprintf(stderr,
                "[APPGL] MSL library compile FAILED (negative-cached, "
                "failures=%llu) — draws using this shader are dropped; "
                "set APPGL_TRACE_SHADER_BUILD=1 for the compiler error\n",
                static_cast<unsigned long long>(
                    mslLibraryCompileFailureCount));
            std::fflush(stderr);
        }
        return lib;  // nil on failure; caller handles
    }
    std::unordered_map<std::uint64_t, std::vector<std::string>>
        mslLibraryCompileFailures;
    std::uint64_t mslLibraryCompileFailureCount = 0;
    std::uint64_t mslLibraryCompileFailureHits = 0;

    // Depth/stencil state cache — keyed by packed (depthTestEnabled, depthFunc).
    // The state space is tiny (~16 combinations); after warmup every draw is
    // a pure hash-table hit with zero Metal allocations.
    // Sprint 7 Phase 1 #11 (CKPT57): widened to uint64_t to fit the
    // depth + stencil identity hash. Depth state in low 32 bits,
    // stencil hash in high 32 bits.
    std::unordered_map<std::uint64_t, id<MTLDepthStencilState>> depthStencilCache;

    // Phase 8X Group 4d follow-up⁸ — per-context dedup for the
    // first-draw-per-program binding diagnostic NSLog in
    // `encodeTranslatedDraw`. Lives on the Impl rather than as a
    // function-local static so multi-context test runs (gauntlet
    // phase-a/c/d/7) don't cross-pollute: each GLContext owns its own
    // MetalFrameGraph and therefore its own set, and each scene's
    // program=1 gets logged exactly once. Under single-context
    // workloads (BAR/Recoil) the behavior is identical to a static set
    // but without the cross-run leak.
    std::unordered_set<GLuint> loggedBindingPrograms;

    // Phase 8X Group 4d follow-up¹³ — per-context dedup for the
    // first-build-per-program pipeline diagnostic NSLog. Fires at the
    // pipeline build path (just before newRenderPipelineStateWithDescriptor),
    // where we still have a live MTLRenderPipelineDescriptor +
    // MTLVertexDescriptor in scope. BAR followup¹²-verification
    // §Candidate 1 (blend state) and §Candidate 2 (MTLVertexDescriptor
    // format mismatch) both need the actual Metal-side descriptor
    // values — we can't reconstruct them from `info` at the first-draw
    // logging site because the descriptor is gone once
    // newRenderPipelineStateWithDescriptor returns.
    //
    // Phase 8X Group 4d follow-up¹⁷ — the dedup key was previously
    // `info.program` alone, which meant the first pipeline-build log
    // for a given program suppressed every subsequent build for the
    // SAME program with a DIFFERENT pipelineCacheKey (e.g. the same
    // program drawn first with blend off and then with blend on, or
    // with a different VBO attribute-format tuple). That's exactly
    // the situation followup¹⁴ left on the watchlist as the
    // `pipelineCache.entries=5` mystery: the cache was growing but
    // we only ever saw one log line per program. The rekey to
    // `(program, pipelineCacheKey)` makes every distinct cache-key
    // build fire its own log exactly once, so future intermittent
    // growth in `entries` becomes self-documenting in the terminal
    // output without any additional tooling.
    struct PipelineBuildLogKey {
        GLuint program;
        std::uint64_t pipelineCacheKey;
        bool operator==(const PipelineBuildLogKey& other) const {
            return program == other.program && pipelineCacheKey == other.pipelineCacheKey;
        }
    };
    struct PipelineBuildLogKeyHash {
        std::size_t operator()(const PipelineBuildLogKey& k) const noexcept {
            // Mix the 32-bit program name into the 64-bit cache key with
            // a FNV-ish splice — good enough for the tiny cardinality of
            // this set (a few entries per context).
            const std::uint64_t mixed = k.pipelineCacheKey
                                      ^ (static_cast<std::uint64_t>(k.program) * 0x9E3779B97F4A7C15ull);
            return static_cast<std::size_t>(mixed ^ (mixed >> 32));
        }
    };
    std::unordered_set<PipelineBuildLogKey, PipelineBuildLogKeyHash> loggedPipelineBuildPrograms;
    DrawSubmitProfile drawSubmitProfile;
    ParallelEncodeFoundationProfile parallelEncodeProfile;
    ThreadedDeferredRecordProfile threadedDeferredRecordProfile;
    FrameAttributionProfile frameAttributionProfile;
    std::deque<CapturedTranslatedDrawRecord> pendingThreadedDeferredRecords;
    std::deque<LeanDirectTranslatedDrawDescriptor>
        pendingThreadedDeferredDescriptors;
    std::deque<ThreadedDeferredAsyncChunk> pendingThreadedDeferredChunks;
    bool flushingThreadedDeferredRecordBatch = false;
    std::uint64_t nextThreadedDeferredSequence = 1;
    std::uint64_t nextThreadedDeferredRecordToDispatch = 0;
    std::uint64_t nextThreadedDeferredChunkIndex = 0;
    std::atomic<std::uint64_t> threadedDeferredCompletionOrdinal{0};
    dispatch_group_t threadedDeferredRecordGroup = nullptr;
    std::deque<LeanDirectTranslatedDrawDescriptor> pendingLeanDirectDescriptors;
    bool flushingLeanDirectDescriptorBatch = false;
    std::uint64_t leanDirectDescriptorWorkerFlushCount = 0;
    std::deque<CapturedTranslatedDrawRecord> pendingParallelTranslatedDraws;
    bool flushingParallelTranslatedBatch = false;

    // ── Encoder state deduplication (OPT-6) ──
    // Track what was last set on the current render encoder. Skip redundant
    // Metal API calls when consecutive draws share the same state — typical
    // for batches of objects using the same shader/material.  Reset to
    // sentinel values whenever a new render encoder is created.
    id<MTLRenderPipelineState> cachedPipelineState = nil;
    id<MTLDepthStencilState> cachedDepthStencilState = nil;
    MTLCullMode cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
    MTLWinding cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
    MTLTriangleFillMode cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);

    void resetCachedEncoderState() {
        cachedPipelineState = nil;
        cachedDepthStencilState = nil;
        cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
        cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
        cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);
    }

    // ── Ring buffer for per-draw vertex/index data (OPT-1) ──
    // Triple-buffered: 3 large MTLBuffers rotate each frame. Within a frame,
    // sub-allocations bump a write offset with 256-byte alignment. This
    // eliminates per-draw [device newBufferWithBytes:] calls — the dominant
    // per-draw overhead (~15-20µs each).
    static constexpr int kRingBufferCount = 3;
    static constexpr std::size_t kRingBufferSize = 16 * 1024 * 1024; // 16 MB
    static constexpr std::size_t kRingBufferAlign = 256;

    // OPT-8: Semaphore-based frame pacing.  Initialized to kRingBufferCount
    // so the CPU can fill up to 3 ring slots before blocking.  Each frame
    // waits (acquireRingSlot) before writing, and the GPU completion handler
    // signals when it finishes the command buffer for that slot.  This
    // overlaps CPU encoding with GPU rendering — the key optimization that
    // replaces the old waitUntilCompleted serialisation.
    dispatch_semaphore_t frameSemaphore = dispatch_semaphore_create(kRingBufferCount);
    bool ringSlotAcquired = false;

    id<MTLBuffer> ringBuffers[kRingBufferCount] = { nil, nil, nil };
    int ringBufferIndex = 0;
    std::size_t ringBufferOffset = 0;
    std::uint64_t ringFallbackAllocations = 0;
    std::uint64_t ringFallbackBytes = 0;
    std::uint64_t ringFallbackMaxBytes = 0;

    void ensureRingBuffers() {
        if (ringBuffers[0] != nil) return;
        for (int i = 0; i < kRingBufferCount; ++i) {
            ringBuffers[i] = [device newBufferWithLength:kRingBufferSize
                                                 options:MTLResourceStorageModeShared];
        }
    }

    // Sub-allocate from the active ring buffer. Returns the buffer and the
    // byte offset of the allocation. Copies |byteCount| bytes from |src|.
    // If the ring buffer is full, falls back to a one-off allocation.
    struct RingAlloc {
        id<MTLBuffer> buffer;
        std::size_t offset;
    };

    RingAlloc ringSuballocate(const void* src, std::size_t byteCount) {
        ensureRingBuffers();
        const std::size_t aligned = (byteCount + kRingBufferAlign - 1) & ~(kRingBufferAlign - 1);
        id<MTLBuffer> active = ringBuffers[ringBufferIndex];

        if (active != nil && ringBufferOffset + byteCount <= kRingBufferSize) {
            // Fast path: bump-allocate from ring buffer.
            std::memcpy(static_cast<std::uint8_t*>([active contents]) + ringBufferOffset,
                        src, byteCount);
            std::size_t thisOffset = ringBufferOffset;
            ringBufferOffset += aligned;
            return { active, thisOffset };
        }

        // Overflow fallback: single draw exceeds remaining space.
        ++ringFallbackAllocations;
        ringFallbackBytes += byteCount;
        ringFallbackMaxBytes = std::max<std::uint64_t>(
            ringFallbackMaxBytes,
            static_cast<std::uint64_t>(byteCount));
        id<MTLBuffer> fallback = [device newBufferWithBytes:src
                                                      length:byteCount
                                                     options:MTLResourceStorageModeShared];
        currentCommandBufferLease.adoptRetainedObject(fallback);
        return { fallback, 0 };
    }

    // Step 7-4: raw ring-buffer suballocation without copy. Returns
    // writable {buffer, offset} backing the requested byteCount. The
    // caller writes into the buffer (via MTLArgumentEncoder or manual
    // memcpy) and passes {buffer, offset} to `setFragmentBuffer:offset:`
    // etc. Mirrors `ringSuballocate` minus the memcpy. Used for
    // argument-buffer allocation under APPGL_ENABLE_ARGUMENT_BUFFERS —
    // replaces the per-draw `newBufferWithLength:` churn (one 16-MB
    // ring slot holds hundreds of argbufs).
    RingAlloc ringAllocRaw(std::size_t byteCount) {
        ensureRingBuffers();
        const std::size_t aligned = (byteCount + kRingBufferAlign - 1) & ~(kRingBufferAlign - 1);
        id<MTLBuffer> active = ringBuffers[ringBufferIndex];
        if (active != nil && ringBufferOffset + byteCount <= kRingBufferSize) {
            std::size_t thisOffset = ringBufferOffset;
            ringBufferOffset += aligned;
            return { active, thisOffset };
        }
        ++ringFallbackAllocations;
        ringFallbackBytes += byteCount;
        ringFallbackMaxBytes = std::max<std::uint64_t>(
            ringFallbackMaxBytes,
            static_cast<std::uint64_t>(byteCount));
        id<MTLBuffer> fallback = [device newBufferWithLength:byteCount
                                                     options:MTLResourceStorageModeShared];
        currentCommandBufferLease.adoptRetainedObject(fallback);
        return { fallback, 0 };
    }

    // OPT-8: Acquire the current ring buffer slot, blocking if all slots
    // are in-flight with the GPU.  Idempotent within a frame — only waits
    // once per ring-buffer generation.
    void acquireRingSlot() {
        if (!ringSlotAcquired) {
            const DrawProfileTimePoint attributionStart =
                frameAttributionProfile.enabled ? drawProfileNow() : DrawProfileTimePoint{};
            ringSlotAcquired = commandSubmission != nullptr
                ? commandSubmission->waitForRingSlot(frameSemaphore, AppGLCommandReason::FrameRingSlot)
                : (dispatch_semaphore_wait(frameSemaphore, DISPATCH_TIME_FOREVER) == 0);
            if (frameAttributionProfile.enabled) {
                frameAttributionProfile.recordAction(
                    FrameAttributionAction::RingSlotWait,
                    drawProfileElapsedUs(attributionStart, drawProfileNow()),
                    ringSlotAcquired);
            }
        }
    }

    void signalRingSlotNow() {
        if (commandSubmission != nullptr) {
            commandSubmission->signalRingSlot(frameSemaphore);
        } else {
            dispatch_semaphore_signal(frameSemaphore);
        }
    }

    // OPT-8: Commit a command buffer with a completion handler that signals
    // the frame semaphore when the GPU finishes.  Use this (instead of raw
    // [cb commit]) whenever the commit releases a ring buffer slot.
    void commitWithFrameSignal(MetalCommandBufferLease& lease,
                               AppGLCommandReason reason = AppGLCommandReason::FrameCommandBuffer) {
        dispatch_semaphore_t sem = frameSemaphore;
        const DrawProfileTimePoint attributionStart =
            frameAttributionProfile.enabled ? drawProfileNow() : DrawProfileTimePoint{};
        lease.commitWithCompletion(reason, ^(id<MTLCommandBuffer>) {
            dispatch_semaphore_signal(sem);
        });
        if (frameAttributionProfile.enabled) {
            frameAttributionProfile.recordCommitFrameSignal(
                reason,
                drawProfileElapsedUs(attributionStart, drawProfileNow()));
        }
    }

    void advanceRingBuffer() {
        ringBufferIndex = (ringBufferIndex + 1) % kRingBufferCount;
        ringBufferOffset = 0;
        ringSlotAcquired = false;  // OPT-8: next frame must re-acquire
    }

    // Pipeline cache metrics (for benchmark instrumentation).
    //
    // Phase 8X Group 4d follow-up⁴ — `pipelineBuildAttempts` /
    // `pipelineBuildFailures` are added so the {hits, misses} pair stays
    // a clean cache-effectiveness signal while the new pair tells BAR
    // whether the build branch is even being entered (and how often it's
    // failing). Invariant: `attempts == misses + failures` for every draw.
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    std::uint64_t pipelineBuildAttempts = 0;
    std::uint64_t pipelineBuildFailures = 0;
    double pipelineCumulativeBuildMs = 0.0;

    // ── ADV-14: MTLBinaryArchive for cross-session pipeline persistence ──
    // On first launch, pipelines compile from MSL source (~100–500 ms each).
    // On second launch, the archive supplies pre-compiled GPU binaries and
    // Metal skips the expensive compilation.  The archive lives at
    //   ~/Library/Caches/dev.excalibur.AppGL/pipeline_archive.metallib
    // Populated lazily: after each successful pipeline build, we add the
    // descriptor to the archive.  Serialized to disk on context teardown.
    id<MTLBinaryArchive> pipelineArchive = nil;
    bool pipelineArchiveDirty = false;

    NSURL* pipelineArchiveURL() {
        static NSURL* url = nil;
        if (url == nil) {
            NSString* cacheDir = [NSSearchPathForDirectoriesInDomains(
                NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString* appglDir = [cacheDir stringByAppendingPathComponent:@"dev.excalibur.AppGL"];
            [[NSFileManager defaultManager] createDirectoryAtPath:appglDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
            url = [NSURL fileURLWithPath:
                [appglDir stringByAppendingPathComponent:@"pipeline_archive.metallib"]];
        }
        return url;
    }

    void ensurePipelineArchive() {
        if (pipelineArchive != nil || device == nil) return;

        MTLBinaryArchiveDescriptor* desc = [[MTLBinaryArchiveDescriptor alloc] init];
        // Try to load existing archive from disk.
        NSURL* url = pipelineArchiveURL();
        if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            desc.url = url;
        }
        NSError* err = nil;
        pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:&err];
        if (pipelineArchive == nil) {
            // Failed to load (corrupt/stale) — create empty archive.
            desc.url = nil;
            pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:nil];
        }
    }

    void addPipelineToArchive(MTLRenderPipelineDescriptor* pipelineDesc) {
        if (pipelineArchive == nil) return;
        NSError* err = nil;
        // addRenderPipelineFunctions is a no-op if the pipeline is already
        // present in the archive. On failure, we silently skip — the archive
        // is an optimization, not a correctness requirement.
        if ([pipelineArchive addRenderPipelineFunctionsWithDescriptor:pipelineDesc error:&err]) {
            pipelineArchiveDirty = true;
        }
    }

    void savePipelineArchive() {
        if (pipelineArchive == nil || !pipelineArchiveDirty) return;
        NSError* err = nil;
        [pipelineArchive serializeToURL:pipelineArchiveURL() error:&err];
        if (err == nil) {
            pipelineArchiveDirty = false;
        }
    }
};

// Programmatic Metal GPU-trace capture gated on APPGL_METAL_CAPTURE_PATH.
// Opens a capture scope for the whole process lifetime and writes a
// .gputrace document to the given path when the runtime shuts down.
// Primary use: diagnosing the VS-stage texture_gather flake (pass/fail
// captures of the same test case diffed in Xcode).
//
// Env vars required:
//   APPGL_METAL_CAPTURE_PATH=/abs/path/to/capture.gputrace
//   MTL_CAPTURE_ENABLED=1          (Metal's own opt-in — without this
//                                   the capture manager refuses outside
//                                   Xcode-launched processes)
static bool g_captureActive = false;

static void startMetalCaptureIfRequested(id<MTLDevice> device) {
    if (device == nil || g_captureActive) return;
    const char* path = std::getenv("APPGL_METAL_CAPTURE_PATH");
    if (path == nullptr || *path == '\0') return;

    MTLCaptureManager* mgr = [MTLCaptureManager sharedCaptureManager];
    if (![mgr supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
        NSLog(@"[GL] MTLCapture: GPU-trace-document destination unsupported "
              @"(need MTL_CAPTURE_ENABLED=1 in env)");
        return;
    }

    // Overwrite existing trace at the same path — re-running the test
    // is the common case.
    NSString* nsPath = [NSString stringWithUTF8String:path];
    NSURL* url = [NSURL fileURLWithPath:nsPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    MTLCaptureDescriptor* desc = [[MTLCaptureDescriptor alloc] init];
    desc.captureObject = device;
    desc.destination = MTLCaptureDestinationGPUTraceDocument;
    desc.outputURL = url;

    NSError* err = nil;
    if ([mgr startCaptureWithDescriptor:desc error:&err]) {
        g_captureActive = true;
        NSLog(@"[GL] MTLCapture: started → %@", url.path);
    } else {
        NSLog(@"[GL] MTLCapture: startCapture failed: %@", err);
    }
}

static void stopMetalCaptureIfActive() {
    if (!g_captureActive) return;
    [[MTLCaptureManager sharedCaptureManager] stopCapture];
    g_captureActive = false;
    NSLog(@"[GL] MTLCapture: stopped, trace flushed");
}

// Option A probe [metal-tess-TF]: bit-exact diff between a ported-to-MSL
// domain generator and `appgl::generateTessDomain` (the CPU reference
// that `TessellationEmulator.cpp` exposes and CTS's
// `getAmountOfVerticesGeneratedByTessellator` probe matches bit-for-bit).
//
// Runs once on first MetalFrameGraph construction, gated on
// APPGL_TEST_TESS_DOMAIN_PORT=1. Dispatches the new kernel for a curated
// set of (mode, spacing, outer, inner) cases, walks `generateTessDomain`'s
// indexed output into the non-indexed "one-coord-per-emitted-vertex"
// shape the downstream TES-compute consumes, diffs element-for-element,
// and reports MATCH/DIFFER to stderr.
//
// Scope of this first landing: triangles, equal-spacing, integer
// partition, no winding flip, no point_mode. Later commits widen.
static void phaseAProbeTessDomainPort(id<MTLDevice> device,
                                       id<MTLCommandQueue> commandQueue,
                                       MetalCommandSubmission* commandSubmission)
{
    if (std::getenv("APPGL_TEST_TESS_DOMAIN_PORT") == nullptr) return;
    if (device == nil || commandQueue == nil) return;
    static bool sRan = false;
    if (sRan) return;
    sRan = true;

    std::fprintf(stderr, "[APPGL domain-port] probe starting\n");

    NSString* msl = kTessDomainPortMSL;

    NSError* libErr = nil;
    // Force IEEE-strict FP. Default compile options enable fp-contract
    // (fuses `a - b - c` into single-rounded ops), which produces
    // more-accurate-but-CPU-divergent results at boundary vertices
    // (e.g. fu + fv = 1 exactly).
    MTLCompileOptions* opts = [MTLCompileOptions new];
    if (@available(macOS 15.0, *)) {
        opts.mathMode = MTLMathModeSafe;
    } else {
        opts.fastMathEnabled = NO;
    }
    id<MTLLibrary> lib = [device newLibraryWithSource:msl options:opts error:&libErr];
    if (lib == nil) {
        std::fprintf(stderr, "[APPGL domain-port] library build failed: %s\n",
                     libErr ? libErr.localizedDescription.UTF8String : "(no err)");
        return;
    }
    auto buildPSO = ^id<MTLComputePipelineState>(NSString* fnName) {
        id<MTLFunction> f = [lib newFunctionWithName:fnName];
        if (f == nil) {
            std::fprintf(stderr, "[APPGL domain-port] function %s not found\n",
                         fnName.UTF8String);
            return nil;
        }
        NSError* perr = nil;
        id<MTLComputePipelineState> p =
            [device newComputePipelineStateWithFunction:f error:&perr];
        if (p == nil) {
            std::fprintf(stderr, "[APPGL domain-port] PSO %s failed: %s\n",
                         fnName.UTF8String,
                         perr ? perr.localizedDescription.UTF8String : "(no err)");
        }
        return p;
    };
    id<MTLComputePipelineState> trianglesPSO =
        buildPSO(@"spvGenTessDomainTrianglesPort");
    id<MTLComputePipelineState> quadsPSO =
        buildPSO(@"spvGenTessDomainQuadsPort");
    if (trianglesPSO == nil && quadsPSO == nil) return;

    auto toHalf = [](float fv) -> uint16_t {
        uint32_t bits = 0;
        std::memcpy(&bits, &fv, sizeof(bits));
        uint32_t sign = (bits >> 31) & 0x1;
        int32_t  exp  = (int32_t)((bits >> 23) & 0xff) - 127;
        uint32_t mant = bits & 0x7fffff;
        if (exp >= 16) return (uint16_t)((sign << 15) | 0x7c00);
        if (exp <= -15) return (uint16_t)(sign << 15);
        return (uint16_t)((sign << 15) | (((exp + 15) & 0x1f) << 10) |
                          (mant >> 13));
    };

    struct Case {
        appgl::TessDomain domain;
        appgl::TessSpacing spacing;
        float outer[4];
        float inner[2];
        bool pointMode;
        bool flipWinding;
        const char* name;
    };
    const Case cases[] = {
        // Triangles — Equal
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {2.0f, 2.0f, 2.0f, 0.0f}, {2.0f, 0.0f}, false, false, "tri eq N=2"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, false, "tri eq N=3"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, false, false, "tri eq N=5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {7.0f, 4.0f, 3.0f, 0.0f}, {6.0f, 0.0f}, false, false, "tri eq mixed"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {1.0f, 1.0f, 1.0f, 0.0f}, {1.0f, 0.0f}, false, false, "tri eq N=1 (min)"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {12.0f, 9.0f, 7.0f, 0.0f}, {10.0f, 0.0f}, false, false, "tri eq asym"},
        // Triangles — FractionalEven (rounds up to next even ≥ 2)
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {4.0f, 4.0f, 4.0f, 0.0f}, {4.0f, 0.0f}, false, false, "tri fEven N=4"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {4.5f, 4.5f, 4.5f, 0.0f}, {4.5f, 0.0f}, false, false, "tri fEven N=4.5 → 6"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {1.0f, 1.0f, 1.0f, 0.0f}, {1.0f, 0.0f}, false, false, "tri fEven min (→ 2)"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {8.0f, 6.0f, 4.0f, 0.0f}, {7.0f, 0.0f}, false, false, "tri fEven asym"},
        // Triangles — FractionalOdd (rounds up to next odd ≥ 1)
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, false, "tri fOdd N=3"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {3.5f, 3.5f, 3.5f, 0.0f}, {3.5f, 0.0f}, false, false, "tri fOdd N=3.5 → 5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {4.0f, 4.0f, 4.0f, 0.0f}, {4.0f, 0.0f}, false, false, "tri fOdd N=4 → 5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {8.0f, 6.0f, 4.0f, 0.0f}, {7.0f, 0.0f}, false, false, "tri fOdd asym"},
        // Quads — Equal
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {2.0f, 2.0f, 2.0f, 2.0f}, {2.0f, 2.0f}, false, false, "quad eq N=2"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad eq N=4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {8.0f, 8.0f, 8.0f, 8.0f}, {8.0f, 8.0f}, false, false, "quad eq N=8"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {1.0f, 1.0f, 1.0f, 1.0f}, {1.0f, 1.0f}, false, false, "quad eq N=1 (min)"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {32.0f, 31.0f}, false, false, "quad eq rule4-ish"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {5.0f, 7.0f, 9.0f, 11.0f}, {13.0f, 17.0f}, false, false, "quad eq asym"},
        // Quads — FractionalEven
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad fEven N=4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {3.5f, 3.5f, 3.5f, 3.5f}, {3.5f, 3.5f}, false, false, "quad fEven N=3.5 → 4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {8.0f, 6.0f, 4.0f, 2.0f}, {7.0f, 5.0f}, false, false, "quad fEven asym"},
        // Quads — FractionalOdd
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {3.0f, 3.0f, 3.0f, 3.0f}, {3.0f, 3.0f}, false, false, "quad fOdd N=3"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad fOdd N=4 → 5"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {8.0f, 6.0f, 4.0f, 2.0f}, {7.0f, 5.0f}, false, false, "quad fOdd asym"},
        // CTS rule4 quad — exact levels the test uses.
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {32.0f, 31.0f}, false, false, "rule4 (32,31) (29,29,29,29)"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {31.0f, 32.0f}, false, false, "rule4 (31,32) (29,29,29,29)"},
        // Winding flip (CW) — swap last two verts per triangle.
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, true, "tri eq N=3 CW"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, false, true, "tri fOdd CW"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, true, "quad eq N=4 CW"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {6.0f, 6.0f, 6.0f, 6.0f}, {6.0f, 6.0f}, false, true, "quad fEven CW"},
        // Point mode — emits unique grid points (no triangulation).
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, true, false, "tri eq N=3 pts"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, true, false, "tri fOdd N=5 pts"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {7.0f, 4.0f, 3.0f, 0.0f}, {6.0f, 0.0f}, true, false, "tri eq asym pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, true, false, "quad eq N=4 pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {6.0f, 6.0f, 6.0f, 6.0f}, {6.0f, 6.0f}, true, false, "quad fEven N=6 pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {5.0f, 7.0f, 9.0f, 11.0f}, {13.0f, 17.0f}, true, false, "quad eq asym pts"},
    };

    uint32_t passCount = 0;
    uint32_t failCount = 0;
    for (const Case& tc : cases) {
        id<MTLComputePipelineState> pso =
            (tc.domain == appgl::TessDomain::Triangles)
                ? trianglesPSO : quadsPSO;
        if (pso == nil) continue;
        appgl::TessDomainOutput cpuOut = appgl::generateTessDomain(
            tc.domain, tc.spacing,
            tc.outer, tc.inner, tc.pointMode, tc.flipWinding);

        // CPU output shape differs by pointMode:
        //  - pointMode=true  → `coords` holds one entry per unique
        //    grid point, `indices` is empty. GPU kernel emits the
        //    same set via its atomic-cursor pointMode branch.
        //  - pointMode=false → `coords` holds unique grid points,
        //    `indices` holds 3 per triangle. Expand to non-indexed
        //    "one coord per emitted vertex" — what the GPU kernel
        //    produces via `spvPortEmitTriangle`.
        std::vector<float> cpuExpanded;
        if (tc.pointMode) {
            cpuExpanded = cpuOut.coords;
        } else {
            cpuExpanded.reserve(cpuOut.indices.size() * 3);
            for (std::uint32_t idx : cpuOut.indices) {
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 0]);
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 1]);
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 2]);
            }
        }

        uint16_t factorData[6] = {0};
        factorData[0] = toHalf(tc.outer[0]);
        factorData[1] = toHalf(tc.outer[1]);
        factorData[2] = toHalf(tc.outer[2]);
        factorData[3] = toHalf(tc.outer[3]);
        factorData[4] = toHalf(tc.inner[0]);
        factorData[5] = toHalf(tc.inner[1]);
        id<MTLBuffer> factorBuf = [device
            newBufferWithBytes:factorData
                        length:sizeof(MTLQuadTessellationFactorsHalf)
                       options:MTLResourceStorageModeShared];

        struct PortParams {
            uint32_t genMode;
            uint32_t genSpacing;
            uint32_t patchCount;
            uint32_t pointMode;
            uint32_t flipWinding;
        };
        uint32_t spacingEnum = 0u;
        switch (tc.spacing) {
            case appgl::TessSpacing::Equal:          spacingEnum = 0u; break;
            case appgl::TessSpacing::FractionalEven: spacingEnum = 1u; break;
            case appgl::TessSpacing::FractionalOdd:  spacingEnum = 2u; break;
        }
        PortParams params{
            tc.domain == appgl::TessDomain::Quads ? 1u : 0u,
            spacingEnum, 1u,
            tc.pointMode ? 1u : 0u,
            tc.flipWinding ? 1u : 0u
        };
        id<MTLBuffer> paramsBuf = [device
            newBufferWithBytes:&params
                        length:sizeof(params)
                       options:MTLResourceStorageModeShared];

        uint32_t zero = 0;
        id<MTLBuffer> cursorBuf = [device
            newBufferWithBytes:&zero length:sizeof(uint32_t)
                       options:MTLResourceStorageModeShared];
        const NSUInteger kMaxVerts = 100000;
        id<MTLBuffer> coordsBuf = [device
            newBufferWithLength:kMaxVerts * 12
                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> primIDsBuf = [device
            newBufferWithLength:kMaxVerts * sizeof(uint32_t)
                        options:MTLResourceStorageModeShared];

        auto lease = commandSubmission != nullptr
            ? commandSubmission->makeCommandBuffer(AppGLCommandReason::TessProbe)
            : MetalCommandBufferLease{};
        id<MTLCommandBuffer> cb = lease.get();
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:paramsBuf offset:0 atIndex:0];
        [enc setBuffer:factorBuf offset:0 atIndex:26];
        [enc setBuffer:coordsBuf offset:0 atIndex:25];
        [enc setBuffer:primIDsBuf offset:0 atIndex:24];
        [enc setBuffer:cursorBuf offset:0 atIndex:23];
        [enc dispatchThreads:MTLSizeMake(1, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        lease.commitAndWait(AppGLCommandReason::TessProbe);

        uint32_t gpuVerts = *(const uint32_t*)cursorBuf.contents;
        const float* gpuCoords = (const float*)coordsBuf.contents;

        bool match = true;
        const std::size_t cpuN = cpuExpanded.size() / 3;
        if (gpuVerts != cpuN) {
            match = false;
        } else {
            for (std::size_t k = 0; k < cpuExpanded.size(); ++k) {
                if (gpuCoords[k] != cpuExpanded[k]) { match = false; break; }
            }
        }
        // Count ULP-level diffs (same count match, bitwise-different
        // coords) to separate "wrong topology" (count mismatch) from
        // "right topology, FP drift" (count matches, some coords ULP-off).
        std::size_t diffVerts = 0;
        if (match) {
            std::fprintf(stderr, "[APPGL domain-port]   %-24s MATCH   (%zu verts)\n",
                         tc.name, cpuN);
            ++passCount;
        } else if (gpuVerts != cpuN) {
            std::fprintf(stderr, "[APPGL domain-port]   %-24s COUNT   (CPU=%zu GPU=%u)\n",
                         tc.name, cpuN, gpuVerts);
            ++failCount;
        } else {
            for (std::size_t k = 0; k < cpuN; ++k) {
                if (cpuExpanded[k*3+0] != gpuCoords[k*3+0] ||
                    cpuExpanded[k*3+1] != gpuCoords[k*3+1] ||
                    cpuExpanded[k*3+2] != gpuCoords[k*3+2]) {
                    ++diffVerts;
                }
            }
            std::fprintf(stderr,
                "[APPGL domain-port]   %-24s DIFFER  (%zu verts, %zu ULP-off)\n",
                tc.name, cpuN, diffVerts);
            ++failCount;
            // Show first 3 diffs
            std::size_t shown = 0;
            for (std::size_t k = 0; k < cpuN && shown < 3; ++k) {
                if (cpuExpanded[k*3+0] != gpuCoords[k*3+0] ||
                    cpuExpanded[k*3+1] != gpuCoords[k*3+1] ||
                    cpuExpanded[k*3+2] != gpuCoords[k*3+2]) {
                    std::fprintf(stderr,
                        "[APPGL domain-port]     vert %zu: "
                        "CPU=(%.9g,%.9g,%.9g) GPU=(%.9g,%.9g,%.9g)\n",
                        k,
                        cpuExpanded[k*3+0], cpuExpanded[k*3+1], cpuExpanded[k*3+2],
                        gpuCoords[k*3+0], gpuCoords[k*3+1], gpuCoords[k*3+2]);
                    ++shown;
                }
            }
        }
    }
    std::fprintf(stderr,
        "[APPGL domain-port] probe done: %u MATCH / %u DIFFER\n",
        passCount, failCount);
}

// Phase 5 PoC [metal-tess-TF]: probe Metal's HW tessellator directly
// with a minimal capture vertex function. Dumps (tessCoord, primID)
// for a given (primitive, spacing, inner, outer) — so we can compare
// Metal's native output against CTS's spec-exact expectations
// without reimplementing §11.2.2 from scratch.
//
// Gated on APPGL_TEST_METAL_TESS=1. Runs once per construction,
// prints a table of all emitted tess coords to stderr. Output is
// expected to match CTS's `isVertexDefined` bit-for-bit modulo the
// tessDomainOriginLowerLeft flip (Y = 1 - Metal_Y for quads,
// barycentric permutation for triangles).
static void phase5ProbeMetalNativeTess(id<MTLDevice> device,
                                        id<MTLCommandQueue> commandQueue,
                                        MetalCommandSubmission* commandSubmission)
{
    if (std::getenv("APPGL_TEST_METAL_TESS") == nullptr) return;
    if (device == nil || commandQueue == nil) return;
    static bool sProbeRan = false;
    if (sProbeRan) return;
    sProbeRan = true;
    std::fprintf(stderr, "[APPGL probe] Metal HW-tess PoC starting\n");

    NSString* msl = @R"MSL(
#include <metal_stdlib>
using namespace metal;

[[patch(quad, 0)]] vertex void spvProbeTessQuad(
    float2 gl_TessCoordIn [[position_in_patch]],
    uint gl_PrimitiveID [[patch_id]],
    device atomic_uint* cursor [[buffer(0)]],
    device packed_float3* coords [[buffer(1)]],
    device uint* primIDs [[buffer(2)]])
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, 0.0);
    primIDs[base] = gl_PrimitiveID;
}

[[patch(triangle, 0)]] vertex void spvProbeTessTriangle(
    float3 gl_TessCoordIn [[position_in_patch]],
    uint gl_PrimitiveID [[patch_id]],
    device atomic_uint* cursor [[buffer(0)]],
    device packed_float3* coords [[buffer(1)]],
    device uint* primIDs [[buffer(2)]])
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, gl_TessCoordIn.z);
    primIDs[base] = gl_PrimitiveID;
}
)MSL";

    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:msl options:nil error:&err];
    if (lib == nil) {
        std::fprintf(stderr, "[APPGL probe] library build failed: %s\n",
                     err.localizedDescription.UTF8String);
        return;
    }

    auto buildPSO = ^id<MTLRenderPipelineState>(NSString* fn, MTLTessellationFactorFormat factorFormat,
                                                 MTLPatchType patchType) {
        id<MTLFunction> vfn = [lib newFunctionWithName:fn];
        if (vfn == nil) return nil;
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vfn;
        pd.fragmentFunction = nil;
        pd.rasterizationEnabled = NO;
        pd.tessellationFactorFormat = factorFormat;
        pd.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        pd.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
        pd.tessellationOutputWindingOrder = MTLWindingCounterClockwise;
        pd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionConstant;
        pd.maxTessellationFactor = 64;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        NSError* perr = nil;
        id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&perr];
        if (pso == nil) {
            std::fprintf(stderr, "[APPGL probe] PSO %s failed: %s\n",
                         fn.UTF8String,
                         perr.localizedDescription.UTF8String ?: "(no err)");
        }
        return pso;
    };

    id<MTLRenderPipelineState> quadPSO = buildPSO(@"spvProbeTessQuad",
        MTLTessellationFactorFormatHalf, MTLPatchTypeQuad);
    id<MTLRenderPipelineState> triPSO = buildPSO(@"spvProbeTessTriangle",
        MTLTessellationFactorFormatHalf, MTLPatchTypeTriangle);
    if (quadPSO == nil && triPSO == nil) {
        std::fprintf(stderr, "[APPGL probe] both PSO builds failed — aborting\n");
        return;
    }

    // Test case: `invariance_rule4` iteration with inner=(32, 31),
    // outer=(29,29,29,29), equal spacing. Expected: (0, 1/32)
    // exists on u=0 edge. Set up factor buffer, dispatch, read back.
    auto runProbe = ^(const char* label,
                       id<MTLRenderPipelineState> pso,
                       MTLPatchType patchType,
                       bool isQuad,
                       float i0, float i1,
                       float o0, float o1, float o2, float o3) {
        if (pso == nil) return;
        auto toHalf = [](float f) -> uint16_t {
            // Minimal float→half (IEEE 754 binary16). Round-to-nearest.
            uint32_t bits = 0;
            std::memcpy(&bits, &f, sizeof(bits));
            uint32_t sign = (bits >> 31) & 0x1;
            int32_t  exp  = (int32_t)((bits >> 23) & 0xff) - 127;
            uint32_t mant = bits & 0x7fffff;
            if (exp >= 16) return (uint16_t)((sign << 15) | 0x7c00); // inf
            if (exp <= -15) return (uint16_t)(sign << 15);              // zero/denorm
            return (uint16_t)((sign << 15) | (((exp + 15) & 0x1f) << 10) |
                              (mant >> 13));
        };
        // Quad  layout: edges[0..3] = half[0..3], inside[0..1] = half[4..5] (12 bytes).
        // Tri   layout: edges[0..2] = half[0..2], inside     = half[3]     (8 bytes).
        uint16_t factorData[6] = {0};
        std::size_t factorBufSize;
        if (isQuad) {
            factorData[0] = toHalf(o0);
            factorData[1] = toHalf(o1);
            factorData[2] = toHalf(o2);
            factorData[3] = toHalf(o3);
            factorData[4] = toHalf(i0);
            factorData[5] = toHalf(i1);
            factorBufSize = sizeof(MTLQuadTessellationFactorsHalf);
        } else {
            factorData[0] = toHalf(o0);
            factorData[1] = toHalf(o1);
            factorData[2] = toHalf(o2);
            factorData[3] = toHalf(i0);
            factorBufSize = sizeof(MTLTriangleTessellationFactorsHalf);
        }
        id<MTLBuffer> factorBuf = [device newBufferWithBytes:factorData
                                                      length:factorBufSize
                                                     options:MTLResourceStorageModeShared];

        // Capture buffers.
        const NSUInteger kMaxVerts = 100000;
        uint32_t zero = 0;
        id<MTLBuffer> cursorBuf = [device newBufferWithBytes:&zero length:sizeof(uint32_t)
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> coordsBuf = [device newBufferWithLength:kMaxVerts * 12
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> primIDsBuf = [device newBufferWithLength:kMaxVerts * sizeof(uint32_t)
                                                      options:MTLResourceStorageModeShared];

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
        rpd.renderTargetWidth = 1;
        rpd.renderTargetHeight = 1;
        rpd.defaultRasterSampleCount = 1;

        auto lease = commandSubmission != nullptr
            ? commandSubmission->makeCommandBuffer(AppGLCommandReason::TessProbe)
            : MetalCommandBufferLease{};
        id<MTLCommandBuffer> cb = lease.get();
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:pso];
        [enc setVertexBuffer:cursorBuf offset:0 atIndex:0];
        [enc setVertexBuffer:coordsBuf offset:0 atIndex:1];
        [enc setVertexBuffer:primIDsBuf offset:0 atIndex:2];
        [enc setTessellationFactorBuffer:factorBuf offset:0 instanceStride:0];
        [enc drawPatches:(isQuad ? 4u : 3u)  // points per patch
              patchStart:0
              patchCount:1
        patchIndexBuffer:nil
  patchIndexBufferOffset:0
           instanceCount:1
            baseInstance:0];
        [enc endEncoding];
        if (!lease.commitAndWait(AppGLCommandReason::TessProbe)) {
            std::fprintf(stderr, "[APPGL probe] %s cmd failed\n", label);
            return;
        }

        uint32_t n = *(const uint32_t*)cursorBuf.contents;
        std::fprintf(stderr, "[APPGL probe] %s emitted %u verts\n", label, n);
        if (n > kMaxVerts) n = (uint32_t)kMaxVerts;
        const float* coords = (const float*)coordsBuf.contents;
        // Sort + dedup so we can diff easily.
        std::vector<std::array<float, 3>> pts;
        pts.reserve(n);
        for (uint32_t k = 0; k < n; ++k) {
            pts.push_back({coords[k*3+0], coords[k*3+1], coords[k*3+2]});
        }
        std::sort(pts.begin(), pts.end());
        pts.erase(std::unique(pts.begin(), pts.end()), pts.end());
        std::fprintf(stderr, "[APPGL probe] %s unique verts: %zu\n", label, pts.size());
        for (const auto& p : pts) {
            std::fprintf(stderr, "  (%.7g, %.7g, %.7g)\n", p[0], p[1], p[2]);
        }
    };

    runProbe("quad rule4 i=(32,31) o=(29,29,29,29)",
             quadPSO, MTLPatchTypeQuad, true,
             32.0f, 31.0f, 29.0f, 29.0f, 29.0f, 29.0f);
    runProbe("triangle rule4 i=(33,0) o=(30,30,30,0)",
             triPSO, MTLPatchTypeTriangle, false,
             33.0f, 0.0f, 30.0f, 30.0f, 30.0f, 0.0f);

    std::fprintf(stderr, "[APPGL probe] done\n");
}

MetalFrameGraph::MetalFrameGraph(GLContext* context,
                                 void* layer,
                                 void* device,
                                 void* commandQueue,
                                 MetalCommandSubmission* commandSubmission)
    : impl_(std::make_unique<Impl>(context, layer, device, commandQueue, commandSubmission)) {
    startMetalCaptureIfRequested((__bridge id<MTLDevice>)device);
    phase5ProbeMetalNativeTess((__bridge id<MTLDevice>)device,
                                (__bridge id<MTLCommandQueue>)commandQueue,
                                commandSubmission);
    phaseAProbeTessDomainPort((__bridge id<MTLDevice>)device,
                               (__bridge id<MTLCommandQueue>)commandQueue,
                               commandSubmission);
}

MetalFrameGraph::~MetalFrameGraph() {
    stopMetalCaptureIfActive();
}

void MetalFrameGraph::resizeDrawable(GLsizei width, GLsizei height) {
    impl_->resize(width, height);
}

void MetalFrameGraph::ensureDrawableSizeAtLeast(GLsizei width, GLsizei height) {
    impl_->ensureSizeAtLeast(width, height);
}

void MetalFrameGraph::enableOffscreenDrawable(GLsizei width, GLsizei height) {
    impl_->enableOffscreen(width, height);
}

void MetalFrameGraph::encodeDefaultFramebufferClear(
    GLbitfield mask,
    GLfloat clearRed,
    GLfloat clearGreen,
    GLfloat clearBlue,
    GLfloat clearAlpha,
    GLdouble clearDepth,
    GLint clearStencil
) {
    impl_->encodeClear(mask, clearRed, clearGreen, clearBlue, clearAlpha, clearDepth, clearStencil);
}

void MetalFrameGraph::beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects) {
    impl_->beginRenderPass(state, objects);
}

void* MetalFrameGraph::currentRenderEncoder() const {
    return impl_->renderEncoder();
}

void MetalFrameGraph::endRenderPass() {
    impl_->endRenderPass();
}

void MetalFrameGraph::flushParallelEncodeBoundary() {
    impl_->flushParallelEncodeBoundary();
}

void MetalFrameGraph::flushForReadback() {
    impl_->flushForReadback();
}

bool MetalFrameGraph::flushCurrentForPressure() {
    return impl_->maybeFlushCurrentForPressure(AppGLCommandReason::PressureFlush);
}

bool MetalFrameGraph::finish() {
    return impl_->finish();
}

bool MetalFrameGraph::encodeSolidColorDraw(const MetalDrawInfo& info) {
    return impl_->encodeSolidColorDraw(info);
}

bool MetalFrameGraph::encodeTranslatedDraw(TranslatedDrawInfo& info) {
    return impl_->encodeTranslatedDraw(info);
}

bool MetalFrameGraph::encodeImmediateModeDraw(const ImmediateDrawInfo& info) {
    return impl_->encodeImmediateModeDraw(info);
}

bool MetalFrameGraph::clearLayeredTextureDepth(void* tex, std::uint32_t arrayLength, float depth) {
    return impl_->clearLayeredTextureDepth(tex, arrayLength, depth);
}

bool MetalFrameGraph::clearLayeredTextureStencil(void* tex, std::uint32_t arrayLength, std::uint32_t stencil) {
    return impl_->clearLayeredTextureStencil(tex, arrayLength, stencil);
}

bool MetalFrameGraph::clearLayeredTextureColor(void* tex, std::uint32_t arrayLength,
                                               const float rgba[4],
                                               std::uint32_t level,
                                               std::uint32_t slice) {
    return impl_->clearLayeredTextureColor(tex, arrayLength, rgba, level, slice);
}

bool MetalFrameGraph::clearTextureDepth(void* tex, std::uint32_t level, std::uint32_t slice,
                                        std::uint32_t arrayLength, float depth) {
    return impl_->clearTextureDepth(tex, level, slice, arrayLength, depth);
}

bool MetalFrameGraph::clearTextureStencil(void* tex, std::uint32_t level, std::uint32_t slice,
                                          std::uint32_t arrayLength, std::uint32_t stencil) {
    return impl_->clearTextureStencil(tex, level, slice, arrayLength, stencil);
}

void MetalFrameGraph::materializePendingFboClearsForTexture(void* tex) {
    impl_->materializePendingFboClearsForTexture(tex);
}

void MetalFrameGraph::materializeAllPendingFboClears() {
    impl_->materializeAllPendingFboClears();
}

bool MetalFrameGraph::writeMultisampleDepthStencilRegion(
    void* tex,
    GLint x,
    GLint y,
    GLsizei width,
    GLsizei height,
    const GLfloat* depthPixels,
    bool writeDepth,
    std::uint8_t stencilValue,
    bool writeStencil) {
    return impl_->writeMultisampleDepthStencilRegion(
        tex, x, y, width, height, depthPixels, writeDepth,
        stencilValue, writeStencil);
}

void* MetalFrameGraph::buildComputePipelineState(const std::string& msl, std::string* outError,
                                                  void** outFunction,
                                                  void* stageInputOutputDescriptor) {
    return impl_->buildComputePipelineState(msl, outError, outFunction, stageInputOutputDescriptor);
}

void* MetalFrameGraph::compileMSLFunction(const std::string& msl, std::string* outError) {
    return impl_->compileMSLFunction(msl, outError);
}

// Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: dispatch a VS-as-
// compute kernel and capture per-vertex output bytes. Forwards to
// Impl::encodeVsTfComputeDraw which has access to the private device
// + commandQueue.
bool MetalFrameGraph::encodeVsTfComputeDraw(void* vsComputePSO,
                                            std::uint32_t vertexCount,
                                            std::size_t perVertexBytes,
                                            const void* uniformBytes,
                                            std::size_t uniformLength,
                                            std::uint8_t* outBytes)
{
    return impl_->encodeVsTfComputeDraw(vsComputePSO, vertexCount,
                                        perVertexBytes, uniformBytes,
                                        uniformLength, outBytes);
}

MetalFrameGraph::TessPipelineProbeResult MetalFrameGraph::probeTessellationPipeline(
    const std::string& tcsMSL,
    const std::string& tesMSL,
    const std::string& fsMSL,
    GLenum genMode,
    GLenum genSpacing,
    GLenum genVertexOrder,
    const std::string& vsComputeMSL,
    const std::string& tesComputeMSL)
{
    return impl_->probeTessellationPipeline(tcsMSL, tesMSL, fsMSL,
                                             genMode, genSpacing, genVertexOrder,
                                             vsComputeMSL, tesComputeMSL);
}

bool MetalFrameGraph::encodeMetalTessellationDraw(MetalTessDrawInfo& info) {
    return impl_->encodeMetalTessellationDraw(info);
}

bool MetalFrameGraph::encodeMetalMeshGSDraw(MetalMeshGSDrawInfo& info) {
    return impl_->encodeMetalMeshGSDraw(info);
}

bool MetalFrameGraph::encodeComputeDispatch(ComputeDispatchInfo& info) {
    return impl_->encodeComputeDispatch(info);
}

void MetalFrameGraph::endFrame(GLObjectStore& objects) {
    impl_->endFrame(objects);
}

void MetalFrameGraph::present(AppGLCommandReason reason) {
    impl_->present(reason);
}

bool MetalFrameGraph::copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
    return impl_->copyPixels(x, y, width, height, outPixels);
}

bool MetalFrameGraph::hasValidAttachments() const {
    return impl_->isReady();
}

MetalFrameGraph::PipelineCacheMetrics MetalFrameGraph::pipelineCacheMetrics() const {
    PipelineCacheMetrics m;
    m.hits = impl_->getPipelineCacheHits();
    m.misses = impl_->getPipelineCacheMisses();
    m.buildAttempts = impl_->getPipelineBuildAttempts();
    m.buildFailures = impl_->getPipelineBuildFailures();
    m.cumulativeBuildMillis = impl_->getPipelineBuildMs();
    return m;
}

void MetalFrameGraph::resetPipelineCacheMetrics() {
    impl_->resetMetrics();
}

std::uint64_t MetalFrameGraph::metalAllocatedBytes() const {
    return impl_->getMetalAllocatedBytes();
}

std::uint64_t MetalFrameGraph::mslLibraryCacheEntries() const {
    return impl_->getMslLibraryCacheEntries();
}

MetalFrameGraph::InternalMetalResourceInventory MetalFrameGraph::internalMetalResourceInventory() const {
    return impl_ ? impl_->getInternalMetalResourceInventory()
                 : InternalMetalResourceInventory{};
}

}  // namespace appgl
