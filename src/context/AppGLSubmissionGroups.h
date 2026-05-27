#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "../../include/AppGL/glcorearb.h"
#include "AppGLCommandReasons.h"

namespace appgl {

enum class AppGLSubmissionGroupKind : std::uint8_t {
    None,
    ArgumentBinding,
    TranslatedDraw,
    ComputeDispatch,
    MeshGsDraw,
    MeshGsPrepass,
    MeshGsRender,
    FallbackNs,
};

enum class AppGLSubmissionResourceKind : std::uint8_t {
    Texture,
    Renderbuffer,
    Buffer,
    DefaultFramebuffer,
};

enum class AppGLSubmissionTransientKind : std::uint8_t {
    ArgumentBufferPayload,
    UniformRingBytes,
    SsboSizeBuffer,
    MeshVsOutputBuffer,
    SidecarBinding,
};

enum class AppGLSubmissionOrderingMechanism : std::uint8_t {
    None,
    CpuBeforeEncodeSameCommandBuffer,
    SameCommandBuffer,
    MetalHazardTracked,
    ExplicitFence,
    CpuCompletionWait,
};

struct AppGLSubmissionResourceAccess {
    AppGLSubmissionResourceKind kind = AppGLSubmissionResourceKind::Texture;
    GLuint name = 0;
    std::uint32_t producerBits = 0;
};

struct AppGLSubmissionSubgroup {
    AppGLSubmissionGroupKind kind = AppGLSubmissionGroupKind::None;
    AppGLCommandReason reason = AppGLCommandReason::Legacy;
};

struct AppGLSubmissionTransient {
    AppGLSubmissionTransientKind kind = AppGLSubmissionTransientKind::ArgumentBufferPayload;
    AppGLSubmissionOrderingMechanism ordering =
        AppGLSubmissionOrderingMechanism::None;
    AppGLCommandReason reason = AppGLCommandReason::Legacy;
    std::uint32_t slot = 0;
    std::size_t bytes = 0;
};

struct AppGLSubmissionGroup {
    static constexpr std::size_t kMaxSubgroups = 8;
    static constexpr std::size_t kMaxResourceAccesses = 64;
    static constexpr std::size_t kMaxTransients = 24;

    AppGLSubmissionGroupKind kind = AppGLSubmissionGroupKind::None;
    AppGLCommandReason primaryReason = AppGLCommandReason::Legacy;
    bool declared = false;
    bool argumentBuffersEnabled = false;
    bool approximateFallbackDisallowed = false;
    std::uint8_t subgroupCount = 0;
    std::uint8_t readCount = 0;
    std::uint8_t writeCount = 0;
    std::uint8_t transientCount = 0;
    std::array<AppGLSubmissionSubgroup, kMaxSubgroups> subgroups{};
    std::array<AppGLSubmissionResourceAccess, kMaxResourceAccesses> reads{};
    std::array<AppGLSubmissionResourceAccess, kMaxResourceAccesses> writes{};
    std::array<AppGLSubmissionTransient, kMaxTransients> transients{};

    void reset(AppGLSubmissionGroupKind groupKind,
               AppGLCommandReason reason) {
        kind = groupKind;
        primaryReason = reason;
        declared = true;
        argumentBuffersEnabled = false;
        approximateFallbackDisallowed = false;
        subgroupCount = 0;
        readCount = 0;
        writeCount = 0;
        transientCount = 0;
    }

    bool hasSubgroup(AppGLSubmissionGroupKind subgroupKind) const {
        for (std::uint8_t i = 0; i < subgroupCount; ++i) {
            if (subgroups[i].kind == subgroupKind) {
                return true;
            }
        }
        return false;
    }

    void addSubgroup(AppGLSubmissionGroupKind subgroupKind,
                     AppGLCommandReason reason) {
        if (subgroupKind == AppGLSubmissionGroupKind::None ||
            hasSubgroup(subgroupKind) ||
            subgroupCount >= kMaxSubgroups) {
            return;
        }
        subgroups[subgroupCount++] = {subgroupKind, reason};
    }

    void addRead(AppGLSubmissionResourceKind resourceKind,
                 GLuint name,
                 std::uint32_t producerBits) {
        if ((name == 0 &&
             resourceKind != AppGLSubmissionResourceKind::DefaultFramebuffer) ||
            readCount >= kMaxResourceAccesses) {
            return;
        }
        for (std::uint8_t i = 0; i < readCount; ++i) {
            if (reads[i].kind == resourceKind &&
                reads[i].name == name &&
                reads[i].producerBits == producerBits) {
                return;
            }
        }
        reads[readCount++] = {resourceKind, name, producerBits};
    }

    void addWrite(AppGLSubmissionResourceKind resourceKind,
                  GLuint name,
                  std::uint32_t producerBits) {
        if ((name == 0 &&
             resourceKind != AppGLSubmissionResourceKind::DefaultFramebuffer) ||
            writeCount >= kMaxResourceAccesses) {
            return;
        }
        for (std::uint8_t i = 0; i < writeCount; ++i) {
            if (writes[i].kind == resourceKind &&
                writes[i].name == name &&
                writes[i].producerBits == producerBits) {
                return;
            }
        }
        writes[writeCount++] = {resourceKind, name, producerBits};
    }

    void addTransient(AppGLSubmissionTransientKind transientKind,
                      AppGLSubmissionOrderingMechanism ordering,
                      AppGLCommandReason reason,
                      std::uint32_t slot = 0,
                      std::size_t bytes = 0) {
        if (transientCount >= kMaxTransients) {
            return;
        }
        transients[transientCount++] =
            {transientKind, ordering, reason, slot, bytes};
    }
};

inline const char* appGLSubmissionGroupKindName(AppGLSubmissionGroupKind kind) {
    switch (kind) {
        case AppGLSubmissionGroupKind::None: return "None";
        case AppGLSubmissionGroupKind::ArgumentBinding: return "ArgumentBindingGroup";
        case AppGLSubmissionGroupKind::TranslatedDraw: return "TranslatedDrawGroup";
        case AppGLSubmissionGroupKind::ComputeDispatch: return "ComputeDispatchGroup";
        case AppGLSubmissionGroupKind::MeshGsDraw: return "MeshGsDrawGroup";
        case AppGLSubmissionGroupKind::MeshGsPrepass: return "MeshGsPrepassGroup";
        case AppGLSubmissionGroupKind::MeshGsRender: return "MeshGsRenderGroup";
        case AppGLSubmissionGroupKind::FallbackNs: return "FallbackNsGroup";
    }
    return "Unknown";
}

inline const char* appGLSubmissionOrderingMechanismName(
    AppGLSubmissionOrderingMechanism mechanism) {
    switch (mechanism) {
        case AppGLSubmissionOrderingMechanism::None: return "none";
        case AppGLSubmissionOrderingMechanism::CpuBeforeEncodeSameCommandBuffer:
            return "cpu-before-encode-same-command-buffer";
        case AppGLSubmissionOrderingMechanism::SameCommandBuffer:
            return "same-command-buffer";
        case AppGLSubmissionOrderingMechanism::MetalHazardTracked:
            return "metal-hazard-tracked";
        case AppGLSubmissionOrderingMechanism::ExplicitFence:
            return "explicit-fence";
        case AppGLSubmissionOrderingMechanism::CpuCompletionWait:
            return "cpu-completion-wait";
    }
    return "unknown";
}

}  // namespace appgl
