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
    EndFrame,
    FlushForReadback,
    DrainCurrentStandalone,
    FrameRingSlot,
    CompletionWait,
    FinishWait,
    LifetimeDrain,
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
    }
    return "unknown";
}

struct AppGLCommandSubmissionDebugCounters {
    std::uint64_t submittedCommandBuffers = 0;
    std::uint64_t completedCommandBuffers = 0;
    std::uint64_t waitReasonLogEntries = 0;
    AppGLCommandReason lastWaitReason = AppGLCommandReason::Legacy;
    AppGLSubmitMode lastWaitMode = AppGLSubmitMode::WaitOnly;
    AppGLDependencyClass lastWaitDependencyClass = AppGLDependencyClass::Legacy;
};

}  // namespace appgl
