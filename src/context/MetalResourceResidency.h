#pragma once

#include <cstddef>
#include <cstdint>
#include <type_traits>
#include <vector>

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

enum class MetalR5EvictionScope : std::uint8_t {
    None = 0,
    TextureView,
    ExpandedIndexCache,
    PrimaryTexture,
};

inline constexpr std::uint64_t kMetalR5ResidencyRawRowLimit = 256;
inline constexpr std::uint64_t kMetalR5ResidencyCandidateLimit = 64;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketTextureView = 1;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketSwizzledTextureView = 2;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketExpandedIndexCache = 3;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketPrimaryTexture = 4;

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

struct MetalR5ResidencyOrderingSummary {
    std::uint64_t version = 1;
    std::uint64_t resourceUseSerial = 0;
    std::uint64_t boundarySerial = 0;
    std::uint64_t rowLimit = kMetalR5ResidencyRawRowLimit;
    std::uint64_t candidateLimit = kMetalR5ResidencyCandidateLimit;
    std::uint64_t rowsSeen = 0;
    std::uint64_t rowsExported = 0;
    std::uint64_t rowsTruncated = 0;
    std::uint64_t snapshotRowsStripped = 0;
    std::uint64_t candidateRows = 0;
    std::uint64_t candidateBytes = 0;
    std::uint64_t candidateMetalBytes = 0;
    std::uint64_t candidateHostBytes = 0;
    std::uint64_t textureViewCandidateRows = 0;
    std::uint64_t textureViewCandidateBytes = 0;
    std::uint64_t expandedIndexCandidateRows = 0;
    std::uint64_t expandedIndexCandidateBytes = 0;
    std::uint64_t primaryTextureCandidateRows = 0;
    std::uint64_t primaryTextureCandidateBytes = 0;
    std::uint64_t missingLastUseCandidateRows = 0;
    std::uint64_t oldestLastUseCommandSerial = 0;
    std::uint64_t newestLastUseCommandSerial = 0;
    std::uint64_t candidatesExported = 0;
    std::uint64_t candidatesTruncated = 0;
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

struct MetalR5EvictionSummary {
    std::uint64_t version = 1;
    std::uint64_t enabled = 0;
    std::uint64_t explicitTriggerRequests = 0;
    std::uint64_t softPressureRequests = 0;
    std::uint64_t hardPressureRequests = 0;
    std::uint64_t criticalPressureRequests = 0;
    std::uint64_t passesTriggered = 0;
    std::uint64_t passesSkippedHysteresis = 0;
    std::uint64_t passAttempts = 0;
    std::uint64_t passCompleted = 0;
    std::uint64_t passSkippedDisabled = 0;
    std::uint64_t passSkippedPressure = 0;
    std::uint64_t candidatesGatedInFlight = 0;
    std::uint64_t drainRequests = 0;
    std::uint64_t drainFailures = 0;
    std::uint64_t candidatesSeen = 0;
    std::uint64_t eligibleSeen = 0;
    std::uint64_t selectedRecords = 0;
    std::uint64_t mutatedRecords = 0;
    std::uint64_t budgetSkippedRecords = 0;
    std::uint64_t unknownLastUseSkipped = 0;
    std::uint64_t scopeSkipped = 0;
    std::uint64_t objectMissingSkipped = 0;
    std::uint64_t handleMissingSkipped = 0;
    std::uint64_t generationMismatchSkipped = 0;
    std::uint64_t lastUseMismatchSkipped = 0;
    std::uint64_t samplingProxySkipped = 0;
    std::uint64_t textureViewBaseReleaseAttempts = 0;
    std::uint64_t textureViewBaseReleaseSuccesses = 0;
    std::uint64_t swizzledViewReleaseAttempts = 0;
    std::uint64_t swizzledViewReleaseSuccesses = 0;
    std::uint64_t expandedIndexClearAttempts = 0;
    std::uint64_t expandedIndexClearSuccesses = 0;
    std::uint64_t primaryTextureReleaseAttempts = 0;
    std::uint64_t primaryTextureReleaseSuccesses = 0;
    std::uint64_t authoritativePrimaryEvictAttempts = 0;
    std::uint64_t primaryBufferReleaseAttempts = 0;
    std::uint64_t hostShadowMutationAttempts = 0;
    std::uint64_t setPurgeableStateCalls = 0;
    std::uint64_t lastBudget = 0;
    std::uint64_t lastPreTextureViewCount = 0;
    std::uint64_t lastPostTextureViewCount = 0;
    std::uint64_t lastPreTextureViewBytes = 0;
    std::uint64_t lastPostTextureViewBytes = 0;
    std::uint64_t lastPreExpandedIndexBuffers = 0;
    std::uint64_t lastPostExpandedIndexBuffers = 0;
    std::uint64_t lastPreExpandedIndexBytes = 0;
    std::uint64_t lastPostExpandedIndexBytes = 0;
    std::uint64_t pressureLevelAtEvict = 0;
    std::uint64_t recordsEvictedTextureView = 0;
    std::uint64_t recordsEvictedSwizzledTextureView = 0;
    std::uint64_t recordsEvictedExpandedIndexCache = 0;
    std::uint64_t reconstructablePrimariesEvicted = 0;
    std::uint64_t deviceBytesFreed = 0;
    std::uint64_t reclaimedMetalViewBytes = 0;
    std::uint64_t reclaimedHostCacheBytes = 0;
    std::uint64_t evictedPrimaryReconstructableBytes = 0;
    std::uint64_t evictedPrimaryAuthoritativeBytes = 0;
    std::uint64_t textureViewRebuildsAfterR5Evict = 0;
    std::uint64_t swizzledViewRebuildsAfterR5Evict = 0;
    std::uint64_t expandedIndexRebuildsAfterR5Evict = 0;
    std::uint64_t primaryReconstructions = 0;
    std::uint64_t primaryReconstructionFailures = 0;
    std::uint64_t primaryVolatileRestoreAttempts = 0;
    std::uint64_t primaryVolatileRestoreKept = 0;
    std::uint64_t primaryVolatileRestoreEmpty = 0;
    std::uint64_t reconstructionFailures = 0;
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

inline const char* metalResidencyOwnerName(MetalResidencyOwner owner) {
    switch (owner) {
    case MetalResidencyOwner::Unknown: return "unknown";
    case MetalResidencyOwner::Buffer: return "buffer";
    case MetalResidencyOwner::Texture: return "texture";
    case MetalResidencyOwner::Renderbuffer: return "renderbuffer";
    case MetalResidencyOwner::Shader: return "shader";
    case MetalResidencyOwner::Program: return "program";
    case MetalResidencyOwner::FrameGraph: return "framegraph";
    case MetalResidencyOwner::SparseTexture: return "sparse-texture";
    }
    return "unknown";
}

inline const char* metalResidencyKindName(MetalResidencyKind kind) {
    switch (kind) {
    case MetalResidencyKind::Unknown: return "unknown";
    case MetalResidencyKind::MetalBuffer: return "metal-buffer";
    case MetalResidencyKind::MetalTexture: return "metal-texture";
    case MetalResidencyKind::TextureView: return "texture-view";
    case MetalResidencyKind::Sampler: return "sampler";
    case MetalResidencyKind::RenderPipeline: return "render-pipeline";
    case MetalResidencyKind::ComputePipeline: return "compute-pipeline";
    case MetalResidencyKind::Function: return "function";
    case MetalResidencyKind::Library: return "library";
    case MetalResidencyKind::HostShadow: return "host-shadow";
    case MetalResidencyKind::ShaderSource: return "shader-source";
    case MetalResidencyKind::ShaderSpirv: return "shader-spirv";
    case MetalResidencyKind::ProgramMslSource: return "program-msl-source";
    case MetalResidencyKind::MslLibraryCacheSource: return "msl-library-cache-source";
    case MetalResidencyKind::MslLibraryCacheSourceKey: return "msl-library-cache-source-key";
    case MetalResidencyKind::MslLibraryCompileTransientSource: return "msl-library-compile-transient-source";
    case MetalResidencyKind::ExpandedIndexCache: return "expanded-index-cache";
    case MetalResidencyKind::Fp64SidecarCpu: return "fp64-sidecar-cpu";
    case MetalResidencyKind::Fp64SidecarMetal: return "fp64-sidecar-metal";
    case MetalResidencyKind::TextureBufferExpansion: return "texture-buffer-expansion";
    case MetalResidencyKind::ImageAtomicSidecar: return "image-atomic-sidecar";
    case MetalResidencyKind::SparsePageTable: return "sparse-page-table";
    case MetalResidencyKind::SparseHeap: return "sparse-heap";
    case MetalResidencyKind::SparseStorageSidecar: return "sparse-storage-sidecar";
    case MetalResidencyKind::MultisampleStorageSidecar: return "multisample-storage-sidecar";
    case MetalResidencyKind::FrameGraphResource: return "framegraph-resource";
    }
    return "unknown";
}

inline const char* metalResidencyAuthorityName(
    MetalResidencyAuthorityClass authority) {
    switch (authority) {
    case MetalResidencyAuthorityClass::Authoritative: return "authoritative";
    case MetalResidencyAuthorityClass::Reconstructable: return "reconstructable";
    case MetalResidencyAuthorityClass::Transient: return "transient";
    case MetalResidencyAuthorityClass::SparseSpecial: return "sparse-special";
    case MetalResidencyAuthorityClass::Unknown: return "unknown";
    }
    return "unknown";
}

inline const char* metalResidencyHeapClassName(
    MetalResidencyHeapClass heapClass) {
    switch (heapClass) {
    case MetalResidencyHeapClass::Host: return "host";
    case MetalResidencyHeapClass::MetalDevice: return "metal-device";
    case MetalResidencyHeapClass::FrameGraph: return "framegraph";
    case MetalResidencyHeapClass::Cache: return "cache";
    case MetalResidencyHeapClass::Sidecar: return "sidecar";
    case MetalResidencyHeapClass::Sparse: return "sparse";
    case MetalResidencyHeapClass::Unknown: return "unknown";
    }
    return "unknown";
}

inline const char* metalR5EvictionScopeName(MetalR5EvictionScope scope) {
    switch (scope) {
    case MetalR5EvictionScope::None: return "none";
    case MetalR5EvictionScope::TextureView: return "texture-view";
    case MetalR5EvictionScope::ExpandedIndexCache:
        return "expanded-index-cache";
    case MetalR5EvictionScope::PrimaryTexture:
        return "primary-texture";
    }
    return "none";
}

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

inline MetalR5EvictionScope metalR5EvictionScopeForRecord(
    const ResourceResidencyRecord& record) {
    if (record.authority != MetalResidencyAuthorityClass::Reconstructable) {
        return MetalR5EvictionScope::None;
    }
    if (record.owner == MetalResidencyOwner::Texture &&
        record.kind == MetalResidencyKind::TextureView &&
        (record.diagnosticBucketId == kMetalR5DiagnosticBucketTextureView ||
         record.diagnosticBucketId ==
             kMetalR5DiagnosticBucketSwizzledTextureView)) {
        return MetalR5EvictionScope::TextureView;
    }
    if (record.owner == MetalResidencyOwner::Buffer &&
        record.kind == MetalResidencyKind::ExpandedIndexCache &&
        record.diagnosticBucketId ==
            kMetalR5DiagnosticBucketExpandedIndexCache) {
        return MetalR5EvictionScope::ExpandedIndexCache;
    }
    if (record.owner == MetalResidencyOwner::Texture &&
        record.kind == MetalResidencyKind::MetalTexture &&
        record.diagnosticBucketId == kMetalR5DiagnosticBucketPrimaryTexture) {
        return MetalR5EvictionScope::PrimaryTexture;
    }
    return MetalR5EvictionScope::None;
}

inline bool metalR5LastUseKnown(const ResourceResidencyRecord& record) {
    return record.lastUseCommandSerial != 0;
}

inline bool metalR5OrderingRecordLess(const ResourceResidencyRecord& lhs,
                                      const ResourceResidencyRecord& rhs) {
    const bool lhsKnown = metalR5LastUseKnown(lhs);
    const bool rhsKnown = metalR5LastUseKnown(rhs);
    if (lhsKnown != rhsKnown) {
        return lhsKnown;
    }
    if (lhsKnown && lhs.lastUseCommandSerial != rhs.lastUseCommandSerial) {
        return lhs.lastUseCommandSerial < rhs.lastUseCommandSerial;
    }
    if (lhs.lastUseFrame != rhs.lastUseFrame) {
        return lhs.lastUseFrame < rhs.lastUseFrame;
    }
    if (lhs.retainedBytes != rhs.retainedBytes) {
        return lhs.retainedBytes > rhs.retainedBytes;
    }
    return lhs.recordId < rhs.recordId;
}

inline bool metalR5AppendBoundedResidencyRow(
    std::vector<ResourceResidencyRecord>& rows,
    const ResourceResidencyRecord& record,
    std::uint64_t limit = kMetalR5ResidencyRawRowLimit) {
    if (rows.size() >= static_cast<std::size_t>(limit)) {
        return false;
    }
    rows.push_back(record);
    return true;
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

inline void accumulateR5ResidencyOrderingRecord(
    MetalR5ResidencyOrderingSummary& summary,
    const ResourceResidencyRecord& record) {
    ++summary.rowsSeen;
    const MetalR5EvictionScope scope = metalR5EvictionScopeForRecord(record);
    if (scope == MetalR5EvictionScope::None) {
        return;
    }

    ++summary.candidateRows;
    summary.candidateBytes += record.retainedBytes;
    summary.candidateMetalBytes += record.metalBytes;
    summary.candidateHostBytes += record.hostBytes;
    if (scope == MetalR5EvictionScope::TextureView) {
        ++summary.textureViewCandidateRows;
        summary.textureViewCandidateBytes += record.retainedBytes;
    } else if (scope == MetalR5EvictionScope::ExpandedIndexCache) {
        ++summary.expandedIndexCandidateRows;
        summary.expandedIndexCandidateBytes += record.retainedBytes;
    } else if (scope == MetalR5EvictionScope::PrimaryTexture) {
        ++summary.primaryTextureCandidateRows;
        summary.primaryTextureCandidateBytes += record.retainedBytes;
    }

    if (!metalR5LastUseKnown(record)) {
        ++summary.missingLastUseCandidateRows;
        return;
    }
    if (summary.oldestLastUseCommandSerial == 0 ||
        record.lastUseCommandSerial < summary.oldestLastUseCommandSerial) {
        summary.oldestLastUseCommandSerial = record.lastUseCommandSerial;
    }
    if (record.lastUseCommandSerial > summary.newestLastUseCommandSerial) {
        summary.newestLastUseCommandSerial = record.lastUseCommandSerial;
    }
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
static_assert(std::is_standard_layout<MetalR5ResidencyOrderingSummary>::value,
              "MetalR5ResidencyOrderingSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR5ResidencyDryRunSummary>::value,
              "MetalR5ResidencyDryRunSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR5ResidencyTouchSummary>::value,
              "MetalR5ResidencyTouchSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR5EvictionSummary>::value,
              "MetalR5EvictionSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalResourceResidencySummary>::value,
              "MetalResourceResidencySummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalHostCacheSummary>::value,
              "MetalHostCacheSummary must remain POD-shaped");

}  // namespace appgl
