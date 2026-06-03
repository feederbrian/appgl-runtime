#pragma once

#include <cstdint>
#include <type_traits>

namespace appgl {

enum class MetalResidencyOwner : std::uint8_t {
    Unknown = 0,
    Buffer,
    Texture,
    Renderbuffer,
    Shader,
    Program,
    FrameGraph,
    SparseTexture,
};

enum class MetalResidencyKind : std::uint8_t {
    Unknown = 0,
    MetalBuffer,
    MetalTexture,
    TextureView,
    Sampler,
    RenderPipeline,
    ComputePipeline,
    Function,
    Library,
    HostShadow,
    ShaderSource,
    ShaderSpirv,
    ProgramMslSource,
    MslLibraryCacheSource,
    MslLibraryCacheSourceKey,
    MslLibraryCompileTransientSource,
    ExpandedIndexCache,
    Fp64SidecarCpu,
    Fp64SidecarMetal,
    TextureBufferExpansion,
    ImageAtomicSidecar,
    SparsePageTable,
    SparseHeap,
    SparseStorageSidecar,
    MultisampleStorageSidecar,
    FrameGraphResource,
};

enum class MetalResidencyAuthorityClass : std::uint8_t {
    Authoritative = 0,
    Reconstructable,
    Transient,
    SparseSpecial,
    Unknown,
};

enum class MetalResidencyHeapClass : std::uint8_t {
    Host = 0,
    MetalDevice,
    FrameGraph,
    Cache,
    Sidecar,
    Sparse,
    Unknown,
};

enum class MetalR5ResidencyClass : std::uint8_t {
    Authoritative = 0,
    Reconstructable,
};

enum class MetalR5ResidencyTouchKind : std::uint8_t {
    BufferBind = 0,
    TextureBind,
    SamplerBind,
    RenderbufferBind,
    FramebufferBind,
    VertexArrayBind,
    VertexBufferBind,
    ProgramBind,
    Draw,
    Dispatch,
};

struct ResourceResidencyRecord {
    std::uint64_t recordId = 0;
    MetalResidencyOwner owner = MetalResidencyOwner::Unknown;
    std::uint32_t glName = 0;
    MetalResidencyKind kind = MetalResidencyKind::Unknown;
    std::uint64_t retainedBytes = 0;
    std::uint64_t metalBytes = 0;
    std::uint64_t hostBytes = 0;
    MetalResidencyAuthorityClass authority =
        MetalResidencyAuthorityClass::Unknown;
    std::uint64_t recipeId = 0;
    std::uint64_t sourceGeneration = 0;
    std::uint64_t lastUseFrame = 0;
    std::uint64_t lastUseCommandSerial = 0;
    std::uint64_t inFlightSerial = 0;
    MetalResidencyHeapClass heapClass = MetalResidencyHeapClass::Unknown;
    std::uint8_t purgeableEligible = 0;
    std::uint32_t diagnosticBucketId = 0;
};

struct MetalR5ResidencyDryRunSummary {
    std::uint64_t dryRunPasses = 0;
    std::uint64_t recordsSeen = 0;
    std::uint64_t reconstructableRecords = 0;
    std::uint64_t reconstructableBytes = 0;
    std::uint64_t authoritativeRecords = 0;
    std::uint64_t authoritativeBytes = 0;
    std::uint64_t unknownKindRecords = 0;
    std::uint64_t unknownKindBytes = 0;
    std::uint64_t unknownAuthorityRecords = 0;
    std::uint64_t unknownAuthorityBytes = 0;
    std::uint64_t transientExcludedRecords = 0;
    std::uint64_t transientExcludedBytes = 0;
    std::uint64_t sparseExcludedRecords = 0;
    std::uint64_t sparseExcludedBytes = 0;
    std::uint64_t candidateRecords = 0;
    std::uint64_t candidateBytes = 0;
    std::uint64_t candidateHostBytes = 0;
    std::uint64_t candidateMetalBytes = 0;
    std::uint64_t candidateHostHeapBytes = 0;
    std::uint64_t candidateMetalDeviceHeapBytes = 0;
    std::uint64_t candidateFrameGraphHeapBytes = 0;
    std::uint64_t candidateCacheHeapBytes = 0;
    std::uint64_t candidateSidecarHeapBytes = 0;
    std::uint64_t candidateSparseHeapBytes = 0;
    std::uint64_t candidateUnknownHeapBytes = 0;
    std::uint64_t futurePurgeableEligibleRecords = 0;
    std::uint64_t futurePurgeableEligibleBytes = 0;
    std::uint64_t pressureMutationAttempts = 0;
    std::uint64_t purgeableStateCalls = 0;
    std::uint64_t drainRequests = 0;
};

struct MetalR5ResidencyTouchSummary {
    std::uint64_t serial = 0;
    std::uint64_t totalTouches = 0;
    std::uint64_t bufferBindTouches = 0;
    std::uint64_t textureBindTouches = 0;
    std::uint64_t samplerBindTouches = 0;
    std::uint64_t renderbufferBindTouches = 0;
    std::uint64_t framebufferBindTouches = 0;
    std::uint64_t vertexArrayBindTouches = 0;
    std::uint64_t vertexBufferBindTouches = 0;
    std::uint64_t programBindTouches = 0;
    std::uint64_t drawTouches = 0;
    std::uint64_t dispatchTouches = 0;
};

struct MetalResourceResidencySummary {
    std::uint64_t records = 0;
    std::uint64_t retainedBytes = 0;
    std::uint64_t metalBytes = 0;
    std::uint64_t hostBytes = 0;
    std::uint64_t authoritativeRecords = 0;
    std::uint64_t authoritativeBytes = 0;
    std::uint64_t reconstructableRecords = 0;
    std::uint64_t reconstructableBytes = 0;
    std::uint64_t transientRecords = 0;
    std::uint64_t transientBytes = 0;
    std::uint64_t sparseSpecialRecords = 0;
    std::uint64_t sparseSpecialBytes = 0;
    std::uint64_t unknownRecords = 0;
    std::uint64_t unknownBytes = 0;
    std::uint64_t hostRecords = 0;
    std::uint64_t metalDeviceRecords = 0;
    std::uint64_t frameGraphRecords = 0;
    std::uint64_t cacheRecords = 0;
    std::uint64_t sidecarRecords = 0;
    std::uint64_t sparseRecords = 0;
};

struct MetalHostCacheSummary {
    std::uint64_t totalBytes = 0;
    std::uint64_t bufferShadowObjects = 0;
    std::uint64_t bufferShadowBytes = 0;
    std::uint64_t textureShadowImages = 0;
    std::uint64_t textureShadowBytes = 0;
    std::uint64_t cubeFaceShadowImages = 0;
    std::uint64_t cubeFaceShadowBytes = 0;
    std::uint64_t renderbufferShadowObjects = 0;
    std::uint64_t renderbufferShadowBytes = 0;
    std::uint64_t expandedIndexBuffers = 0;
    std::uint64_t expandedIndexBytes = 0;
    std::uint64_t fp64Sidecars = 0;
    std::uint64_t fp64SidecarCpuBytes = 0;
    std::uint64_t shaderSourceBytes = 0;
    std::uint64_t shaderSpirvBytes = 0;
    std::uint64_t programMslSourceBytes = 0;
    std::uint64_t mslLibraryCacheSourceBytes = 0;
    std::uint64_t mslLibraryCacheSourceKeyBytes = 0;
    std::uint64_t mslLibraryCompileTransientSourceBytes = 0;
    std::uint64_t sparseBufferPageTableBytes = 0;
    std::uint64_t textureBufferExpansionMetalBuffers = 0;
    std::uint64_t textureBufferExpansionMetalBufferBytes = 0;
    std::uint64_t imageAtomicSidecars = 0;
    std::uint64_t imageAtomicSidecarBytes = 0;
    std::uint64_t sparseTextureHeaps = 0;
    std::uint64_t sparseTextureHeapBytes = 0;
    std::uint64_t sparseStorageImageSidecars = 0;
    std::uint64_t sparseStorageImageSidecarBytes = 0;
    std::uint64_t multisampleStorageImageSidecars = 0;
    std::uint64_t multisampleStorageImageSidecarBytes = 0;
};

inline bool metalResidencyKnownKind(MetalResidencyKind kind) {
    switch (kind) {
    case MetalResidencyKind::MetalBuffer:
    case MetalResidencyKind::MetalTexture:
    case MetalResidencyKind::TextureView:
    case MetalResidencyKind::Sampler:
    case MetalResidencyKind::RenderPipeline:
    case MetalResidencyKind::ComputePipeline:
    case MetalResidencyKind::Function:
    case MetalResidencyKind::Library:
    case MetalResidencyKind::HostShadow:
    case MetalResidencyKind::ShaderSource:
    case MetalResidencyKind::ShaderSpirv:
    case MetalResidencyKind::ProgramMslSource:
    case MetalResidencyKind::MslLibraryCacheSource:
    case MetalResidencyKind::MslLibraryCacheSourceKey:
    case MetalResidencyKind::MslLibraryCompileTransientSource:
    case MetalResidencyKind::ExpandedIndexCache:
    case MetalResidencyKind::Fp64SidecarCpu:
    case MetalResidencyKind::Fp64SidecarMetal:
    case MetalResidencyKind::TextureBufferExpansion:
    case MetalResidencyKind::ImageAtomicSidecar:
    case MetalResidencyKind::SparsePageTable:
    case MetalResidencyKind::SparseHeap:
    case MetalResidencyKind::SparseStorageSidecar:
    case MetalResidencyKind::MultisampleStorageSidecar:
    case MetalResidencyKind::FrameGraphResource:
        return true;
    case MetalResidencyKind::Unknown:
        return false;
    }
    return false;
}

inline bool metalR5FuturePurgeableEligibleKind(MetalResidencyKind kind) {
    switch (kind) {
    case MetalResidencyKind::MetalBuffer:
    case MetalResidencyKind::MetalTexture:
    case MetalResidencyKind::TextureView:
    case MetalResidencyKind::Fp64SidecarMetal:
    case MetalResidencyKind::TextureBufferExpansion:
        return true;
    case MetalResidencyKind::Unknown:
    case MetalResidencyKind::Sampler:
    case MetalResidencyKind::RenderPipeline:
    case MetalResidencyKind::ComputePipeline:
    case MetalResidencyKind::Function:
    case MetalResidencyKind::Library:
    case MetalResidencyKind::HostShadow:
    case MetalResidencyKind::ShaderSource:
    case MetalResidencyKind::ShaderSpirv:
    case MetalResidencyKind::ProgramMslSource:
    case MetalResidencyKind::MslLibraryCacheSource:
    case MetalResidencyKind::MslLibraryCacheSourceKey:
    case MetalResidencyKind::MslLibraryCompileTransientSource:
    case MetalResidencyKind::ExpandedIndexCache:
    case MetalResidencyKind::Fp64SidecarCpu:
    case MetalResidencyKind::ImageAtomicSidecar:
    case MetalResidencyKind::SparsePageTable:
    case MetalResidencyKind::SparseHeap:
    case MetalResidencyKind::SparseStorageSidecar:
    case MetalResidencyKind::MultisampleStorageSidecar:
    case MetalResidencyKind::FrameGraphResource:
        return false;
    }
    return false;
}

inline MetalR5ResidencyClass classifyMetalR5ResidencyRecord(
    const ResourceResidencyRecord& record) {
    if (!metalResidencyKnownKind(record.kind)) {
        return MetalR5ResidencyClass::Authoritative;
    }
    if (record.authority != MetalResidencyAuthorityClass::Reconstructable) {
        return MetalR5ResidencyClass::Authoritative;
    }
    return MetalR5ResidencyClass::Reconstructable;
}

inline void accumulateR5ResidencyDryRunRecord(
    MetalR5ResidencyDryRunSummary& summary,
    const ResourceResidencyRecord& record) {
    ++summary.recordsSeen;
    const bool knownKind = metalResidencyKnownKind(record.kind);
    const std::uint64_t bytes = record.retainedBytes;
    if (!knownKind) {
        ++summary.unknownKindRecords;
        summary.unknownKindBytes += bytes;
    }
    if (record.authority == MetalResidencyAuthorityClass::Unknown) {
        ++summary.unknownAuthorityRecords;
        summary.unknownAuthorityBytes += bytes;
    }
    if (record.authority == MetalResidencyAuthorityClass::Transient) {
        ++summary.transientExcludedRecords;
        summary.transientExcludedBytes += bytes;
    }
    if (record.authority == MetalResidencyAuthorityClass::SparseSpecial) {
        ++summary.sparseExcludedRecords;
        summary.sparseExcludedBytes += bytes;
    }

    if (classifyMetalR5ResidencyRecord(record) ==
        MetalR5ResidencyClass::Reconstructable) {
        ++summary.reconstructableRecords;
        summary.reconstructableBytes += bytes;
        ++summary.candidateRecords;
        summary.candidateBytes += bytes;
        summary.candidateHostBytes += record.hostBytes;
        summary.candidateMetalBytes += record.metalBytes;
        switch (record.heapClass) {
        case MetalResidencyHeapClass::Host:
            summary.candidateHostHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::MetalDevice:
            summary.candidateMetalDeviceHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::FrameGraph:
            summary.candidateFrameGraphHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::Cache:
            summary.candidateCacheHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::Sidecar:
            summary.candidateSidecarHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::Sparse:
            summary.candidateSparseHeapBytes += bytes;
            break;
        case MetalResidencyHeapClass::Unknown:
            summary.candidateUnknownHeapBytes += bytes;
            break;
        }
        if (record.metalBytes != 0 &&
            metalR5FuturePurgeableEligibleKind(record.kind)) {
            ++summary.futurePurgeableEligibleRecords;
            summary.futurePurgeableEligibleBytes += record.metalBytes;
        }
    } else {
        ++summary.authoritativeRecords;
        summary.authoritativeBytes += bytes;
    }
}

inline void recordMetalR5ResidencyTouch(
    MetalR5ResidencyTouchSummary& summary,
    MetalR5ResidencyTouchKind kind) noexcept {
    ++summary.serial;
    ++summary.totalTouches;
    switch (kind) {
    case MetalR5ResidencyTouchKind::BufferBind:
        ++summary.bufferBindTouches;
        break;
    case MetalR5ResidencyTouchKind::TextureBind:
        ++summary.textureBindTouches;
        break;
    case MetalR5ResidencyTouchKind::SamplerBind:
        ++summary.samplerBindTouches;
        break;
    case MetalR5ResidencyTouchKind::RenderbufferBind:
        ++summary.renderbufferBindTouches;
        break;
    case MetalR5ResidencyTouchKind::FramebufferBind:
        ++summary.framebufferBindTouches;
        break;
    case MetalR5ResidencyTouchKind::VertexArrayBind:
        ++summary.vertexArrayBindTouches;
        break;
    case MetalR5ResidencyTouchKind::VertexBufferBind:
        ++summary.vertexBufferBindTouches;
        break;
    case MetalR5ResidencyTouchKind::ProgramBind:
        ++summary.programBindTouches;
        break;
    case MetalR5ResidencyTouchKind::Draw:
        ++summary.drawTouches;
        break;
    case MetalR5ResidencyTouchKind::Dispatch:
        ++summary.dispatchTouches;
        break;
    }
}

inline void accumulateResidencyRecord(
    MetalResourceResidencySummary& summary,
    const ResourceResidencyRecord& record) {
    ++summary.records;
    summary.retainedBytes += record.retainedBytes;
    summary.metalBytes += record.metalBytes;
    summary.hostBytes += record.hostBytes;

    switch (record.authority) {
    case MetalResidencyAuthorityClass::Authoritative:
        ++summary.authoritativeRecords;
        summary.authoritativeBytes += record.retainedBytes;
        break;
    case MetalResidencyAuthorityClass::Reconstructable:
        ++summary.reconstructableRecords;
        summary.reconstructableBytes += record.retainedBytes;
        break;
    case MetalResidencyAuthorityClass::Transient:
        ++summary.transientRecords;
        summary.transientBytes += record.retainedBytes;
        break;
    case MetalResidencyAuthorityClass::SparseSpecial:
        ++summary.sparseSpecialRecords;
        summary.sparseSpecialBytes += record.retainedBytes;
        break;
    case MetalResidencyAuthorityClass::Unknown:
        ++summary.unknownRecords;
        summary.unknownBytes += record.retainedBytes;
        break;
    }

    switch (record.heapClass) {
    case MetalResidencyHeapClass::Host:
        ++summary.hostRecords;
        break;
    case MetalResidencyHeapClass::MetalDevice:
        ++summary.metalDeviceRecords;
        break;
    case MetalResidencyHeapClass::FrameGraph:
        ++summary.frameGraphRecords;
        break;
    case MetalResidencyHeapClass::Cache:
        ++summary.cacheRecords;
        break;
    case MetalResidencyHeapClass::Sidecar:
        ++summary.sidecarRecords;
        break;
    case MetalResidencyHeapClass::Sparse:
        ++summary.sparseRecords;
        break;
    case MetalResidencyHeapClass::Unknown:
        break;
    }
}

static_assert(std::is_standard_layout<ResourceResidencyRecord>::value,
              "ResourceResidencyRecord must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR5ResidencyDryRunSummary>::value,
              "MetalR5ResidencyDryRunSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR5ResidencyTouchSummary>::value,
              "MetalR5ResidencyTouchSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalResourceResidencySummary>::value,
              "MetalResourceResidencySummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalHostCacheSummary>::value,
              "MetalHostCacheSummary must remain POD-shaped");

}  // namespace appgl
