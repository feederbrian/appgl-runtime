#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace appgl {

enum class AppGLSubmitMode : std::uint8_t {
    Allocate,
    AsyncCommit,
    CommitAndWait,
    WaitOnly,
    DrainAll,
};

enum class AppGLDependencyClass : std::uint8_t {
    Legacy,
    None,
    FrameRing,
    FrameSignal,
    Readback,
    Present,
    Standalone,
    Lifetime,
    GpuOnlyOrdering,
    CpuVisibleBarrier,
    Upload,
    Copy,
    Tessellation,
    Mesh,
    Compute,
    SparseResidency,
    Sidecar,
    Probe,
};

enum class AppGLCommandReason : std::uint8_t {
    Legacy,
    BeginRenderPass,
    FlushClear,
    SolidColorDraw,
    TranslatedDraw,
    ImmediateModeDraw,
    FrameCommandBuffer,
    PresentPendingWork,
    PresentFromFlush,
    PresentFromSwapBuffers,
    EndFrame,
    FlushForReadback,
    DrainCurrentStandalone,
    FrameRingSlot,
    CompletionWait,
    FinishWait,
    LifetimeDrain,
    FrameGraphDestruct,
    LayeredClearDrainCurrent,
    LayeredClear,
    LayeredClearDrainCurrentAsync,
    LayeredClearAsync,
    VertexTransformFeedbackReadback,
    TessDrainCurrent,
    TessVertexCompute,
    TessControlCompute,
    TessFactorClamp,
    TessDomainGenerate,
    TessEvalCompute,
    TessRender,
    TessProbe,
    MeshVertexCompute,
    MeshDraw,
    ComputeDispatch,
    CopyImageBlit,
    CopyTextureSubImage,
    TextureUpload,
    DepthStencilFlip,
    RenderbufferMirror,
    SparseResidency,
    SparseSidecar,
    CpuVisibleBarrier,
    Fp64Sidecar,
    PressureFlush,
    Count,
};

struct AppGLCommandReasonRecord {
    AppGLCommandReason reason;
    AppGLSubmitMode submitMode;
    AppGLDependencyClass dependencyClass;
    const char* name;
    const char* legacyLabel;
};

inline constexpr std::array<AppGLCommandReasonRecord,
                            static_cast<std::size_t>(AppGLCommandReason::Count)>
    kAppGLCommandReasonTable{{
        {AppGLCommandReason::Legacy, AppGLSubmitMode::Allocate, AppGLDependencyClass::Legacy,
         "Legacy", "legacy-command-buffer"},
        {AppGLCommandReason::BeginRenderPass, AppGLSubmitMode::Allocate, AppGLDependencyClass::None,
         "BeginRenderPass", "beginRenderPass"},
        {AppGLCommandReason::FlushClear, AppGLSubmitMode::Allocate, AppGLDependencyClass::Present,
         "FlushClear", "flushClear"},
        {AppGLCommandReason::SolidColorDraw, AppGLSubmitMode::Allocate, AppGLDependencyClass::None,
         "SolidColorDraw", "solidColorDraw"},
        {AppGLCommandReason::TranslatedDraw, AppGLSubmitMode::Allocate, AppGLDependencyClass::None,
         "TranslatedDraw", "translatedDraw"},
        {AppGLCommandReason::ImmediateModeDraw, AppGLSubmitMode::Allocate, AppGLDependencyClass::None,
         "ImmediateModeDraw", "immediateModeDraw"},
        {AppGLCommandReason::FrameCommandBuffer, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::FrameSignal,
         "FrameCommandBuffer", "frame-command-buffer"},
        {AppGLCommandReason::PresentPendingWork, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::Present,
         "PresentPendingWork", "frame-command-buffer"},
        {AppGLCommandReason::PresentFromFlush, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::Present,
         "PresentFromFlush", "frame-command-buffer"},
        {AppGLCommandReason::PresentFromSwapBuffers, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::Present,
         "PresentFromSwapBuffers", "frame-command-buffer"},
        {AppGLCommandReason::EndFrame, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::FrameSignal,
         "EndFrame", "frame-command-buffer"},
        {AppGLCommandReason::FlushForReadback, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Readback,
         "FlushForReadback", "flush-for-readback"},
        {AppGLCommandReason::DrainCurrentStandalone, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Standalone,
         "DrainCurrentStandalone", "drain-current-standalone"},
        {AppGLCommandReason::FrameRingSlot, AppGLSubmitMode::WaitOnly, AppGLDependencyClass::FrameRing,
         "FrameRingSlot", "frame-ring-slot"},
        {AppGLCommandReason::CompletionWait, AppGLSubmitMode::WaitOnly, AppGLDependencyClass::Legacy,
         "CompletionWait", "completion-wait"},
        {AppGLCommandReason::FinishWait, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::Lifetime,
         "FinishWait", "frame-command-buffer"},
        {AppGLCommandReason::LifetimeDrain, AppGLSubmitMode::DrainAll, AppGLDependencyClass::Lifetime,
         "LifetimeDrain", "glFinish-drain-all"},
        {AppGLCommandReason::FrameGraphDestruct, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Lifetime,
         "FrameGraphDestruct", "framegraph-destruct"},
        {AppGLCommandReason::LayeredClearDrainCurrent, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::GpuOnlyOrdering,
         "LayeredClearDrainCurrent", "layered-clear-drain-current"},
        {AppGLCommandReason::LayeredClear, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::GpuOnlyOrdering,
         "LayeredClear", "layered-clear-sync"},
        {AppGLCommandReason::LayeredClearDrainCurrentAsync, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::GpuOnlyOrdering,
         "LayeredClearDrainCurrentAsync", "layered-clear-drain-current-async"},
        {AppGLCommandReason::LayeredClearAsync, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::GpuOnlyOrdering,
         "LayeredClearAsync", "layered-clear-async"},
        {AppGLCommandReason::VertexTransformFeedbackReadback, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::CpuVisibleBarrier,
         "VertexTransformFeedbackReadback", "vstf-vs-compute"},
        {AppGLCommandReason::TessDrainCurrent, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::GpuOnlyOrdering,
         "TessDrainCurrent", "tess-drain-current"},
        {AppGLCommandReason::TessVertexCompute, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessVertexCompute", "tess-vs-compute"},
        {AppGLCommandReason::TessControlCompute, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessControlCompute", "tess-compute"},
        {AppGLCommandReason::TessFactorClamp, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessFactorClamp", "tess-factor-clamp"},
        {AppGLCommandReason::TessDomainGenerate, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessDomainGenerate", "tess-domain-gen"},
        {AppGLCommandReason::TessEvalCompute, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessEvalCompute", "tess-tes-compute"},
        {AppGLCommandReason::TessRender, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Tessellation,
         "TessRender", "tess-render"},
        {AppGLCommandReason::TessProbe, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Probe,
         "TessProbe", "tess-domain-probe"},
        {AppGLCommandReason::MeshVertexCompute, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Mesh,
         "MeshVertexCompute", "mesh-gs-vs-compute"},
        {AppGLCommandReason::MeshDraw, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Mesh,
         "MeshDraw", "mesh-gs-draw"},
        {AppGLCommandReason::ComputeDispatch, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Compute,
         "ComputeDispatch", "compute-dispatch"},
        {AppGLCommandReason::CopyImageBlit, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Copy,
         "CopyImageBlit", "copy-image-sub-data"},
        {AppGLCommandReason::CopyTextureSubImage, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Copy,
         "CopyTextureSubImage", "copy-texture-sub-image"},
        {AppGLCommandReason::TextureUpload, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Upload,
         "TextureUpload", "texture-blit-upload"},
        {AppGLCommandReason::DepthStencilFlip, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::CpuVisibleBarrier,
         "DepthStencilFlip", "depth-stencil-flip"},
        {AppGLCommandReason::RenderbufferMirror, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Upload,
         "RenderbufferMirror", "mirror-renderbuffer"},
        {AppGLCommandReason::SparseResidency, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::SparseResidency,
         "SparseResidency", "sparse-texture-map"},
        {AppGLCommandReason::SparseSidecar, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Sidecar,
         "SparseSidecar", "sparse-storage-sidecar"},
        {AppGLCommandReason::CpuVisibleBarrier, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::CpuVisibleBarrier,
         "CpuVisibleBarrier", "cpu-visible-barrier"},
        {AppGLCommandReason::Fp64Sidecar, AppGLSubmitMode::CommitAndWait, AppGLDependencyClass::Sidecar,
         "Fp64Sidecar", "fp64-sidecar"},
        {AppGLCommandReason::PressureFlush, AppGLSubmitMode::AsyncCommit, AppGLDependencyClass::GpuOnlyOrdering,
         "PressureFlush", "pressure-flush"},
    }};

inline const AppGLCommandReasonRecord& appGLCommandReasonRecord(AppGLCommandReason reason) {
    const auto index = static_cast<std::size_t>(reason);
    if (index < kAppGLCommandReasonTable.size()) {
        return kAppGLCommandReasonTable[index];
    }
    return kAppGLCommandReasonTable[static_cast<std::size_t>(AppGLCommandReason::Legacy)];
}

inline const char* appGLCommandReasonName(AppGLCommandReason reason) {
    return appGLCommandReasonRecord(reason).name;
}

inline const char* appGLSubmitModeName(AppGLSubmitMode mode) {
    switch (mode) {
        case AppGLSubmitMode::Allocate: return "allocate";
        case AppGLSubmitMode::AsyncCommit: return "async-commit";
        case AppGLSubmitMode::CommitAndWait: return "commit-and-wait";
        case AppGLSubmitMode::WaitOnly: return "wait-only";
        case AppGLSubmitMode::DrainAll: return "drain-all";
    }
    return "unknown";
}

inline const char* appGLDependencyClassName(AppGLDependencyClass dependencyClass) {
    switch (dependencyClass) {
        case AppGLDependencyClass::Legacy: return "legacy";
        case AppGLDependencyClass::None: return "none";
        case AppGLDependencyClass::FrameRing: return "frame-ring";
        case AppGLDependencyClass::FrameSignal: return "frame-signal";
        case AppGLDependencyClass::Readback: return "readback";
        case AppGLDependencyClass::Present: return "present";
        case AppGLDependencyClass::Standalone: return "standalone";
        case AppGLDependencyClass::Lifetime: return "lifetime";
        case AppGLDependencyClass::GpuOnlyOrdering: return "gpu-only-ordering";
        case AppGLDependencyClass::CpuVisibleBarrier: return "cpu-visible-barrier";
        case AppGLDependencyClass::Upload: return "upload";
        case AppGLDependencyClass::Copy: return "copy";
        case AppGLDependencyClass::Tessellation: return "tessellation";
        case AppGLDependencyClass::Mesh: return "mesh";
        case AppGLDependencyClass::Compute: return "compute";
        case AppGLDependencyClass::SparseResidency: return "sparse-residency";
        case AppGLDependencyClass::Sidecar: return "sidecar";
        case AppGLDependencyClass::Probe: return "probe";
    }
    return "unknown";
}

struct AppGLCommandSubmissionDebugCounters {
    std::uint64_t submittedCommandBuffers = 0;
    std::uint64_t completedCommandBuffers = 0;
    std::array<std::uint64_t, static_cast<std::size_t>(AppGLCommandReason::Count)> allocatedByReason{};
    std::array<std::uint64_t, static_cast<std::size_t>(AppGLCommandReason::Count)> submittedByReason{};
    std::array<std::uint64_t, static_cast<std::size_t>(AppGLCommandReason::Count)> completedByReason{};
    std::uint64_t waitReasonLogEntries = 0;
    std::uint64_t pressureFlushCount = 0;
    std::uint64_t plainCommandBufferAllocations = 0;
    std::uint64_t autoreleaseDrainedCommandBufferAllocations = 0;
    std::uint64_t retainedObjectsAdopted = 0;
    std::uint64_t retainedObjectsReleased = 0;
    std::uint64_t retainedObjectsLive = 0;
    std::uint64_t retainedObjectsPeakLive = 0;
    std::uint64_t retainedObjectApproxBytesAdopted = 0;
    std::uint64_t retainedObjectApproxBytesReleased = 0;
    std::uint64_t retainedObjectApproxBytesLive = 0;
    std::uint64_t retainedObjectApproxBytesPeakLive = 0;
    std::uint64_t retainedCommandBuffersLive = 0;
    std::uint64_t retainedCommandBuffersPeakLive = 0;
    std::uint64_t retainedCommandBuffersReleased = 0;
    std::uint64_t retainedReleaseCalls = 0;
    std::uint64_t retainedReleaseObjectMaxCount = 0;
    std::uint64_t retainedReleaseObjectMaxBytes = 0;
    std::uint32_t currentInFlight = 0;
    std::uint32_t peakInFlight = 0;
    std::uint32_t inFlightBound = 0;
    std::uint32_t pressureReserve = 0;
    std::uint32_t pressureSoftCap = 0;
    std::array<std::uint64_t, static_cast<std::size_t>(AppGLCommandReason::Count)> allocWaitTimeoutsByReason{};
    AppGLCommandReason lastWaitReason = AppGLCommandReason::Legacy;
    AppGLSubmitMode lastWaitMode = AppGLSubmitMode::WaitOnly;
    AppGLDependencyClass lastWaitDependencyClass = AppGLDependencyClass::Legacy;
};

}  // namespace appgl
