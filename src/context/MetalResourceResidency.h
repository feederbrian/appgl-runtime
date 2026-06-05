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

enum class MetalR8ResourceClass : std::uint8_t {
    None = 0,
    Buffer,
    Texture,
};

enum class MetalR8TextureClass : std::uint8_t {
    Unknown = 0,
    Color,
    DepthStencil,
    Compressed,
    Multisample,
    TextureBufferExpansion,
    Sidecar,
    Fp64Sidecar,
};

enum class MetalR8LifetimeBucket : std::uint8_t {
    Unknown = 0,
    InFlight,
    Hot,
    Warm,
    Cold,
};

inline constexpr std::uint64_t kMetalR5ResidencyRawRowLimit = 256;
inline constexpr std::uint64_t kMetalR5ResidencyCandidateLimit = 64;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketTextureView = 1;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketSwizzledTextureView = 2;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketExpandedIndexCache = 3;
inline constexpr std::uint32_t kMetalR5DiagnosticBucketPrimaryTexture = 4;
inline constexpr std::uint64_t kMetalR8HeapBucketLimit = 128;

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
    std::uint8_t r8CompatibilityKnown = 0;
    MetalR8ResourceClass r8ResourceClass = MetalR8ResourceClass::None;
    MetalR8TextureClass r8TextureClass = MetalR8TextureClass::Unknown;
    MetalR8LifetimeBucket r8LifetimeBucket = MetalR8LifetimeBucket::Unknown;
    std::uint32_t r8StorageMode = 0;
    std::uint32_t r8CpuCacheMode = 0;
    std::uint32_t r8HazardTrackingMode = 0;
    std::uint64_t r8ResourceOptions = 0;
    std::uint64_t r8TextureUsage = 0;
    std::uint32_t r8TextureType = 0;
    std::uint32_t r8PixelFormat = 0;
    std::uint32_t r8SampleCount = 0;
    std::uint32_t r8MipmapLevels = 0;
    std::uint32_t r8ArrayLength = 0;
    std::uint32_t r8SizeBucket = 0;
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
    std::uint64_t version = 3;
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
    std::uint64_t pendingPressureBoundaryConsumes = 0;
    std::uint64_t pendingPressurePeakAtBoundary = 0;
    std::uint64_t criticalPressureExhaustionLatches = 0;
    std::uint64_t criticalPressureOOMErrors = 0;
    std::uint64_t criticalPressureNoCandidateLatches = 0;
    std::uint64_t criticalPressureNoReliefLatches = 0;
    std::uint64_t criticalPressureBudgetExhaustedLatches = 0;
    std::uint64_t criticalPressureStillCriticalLatches = 0;
    std::uint64_t pressureMemoryClassAtEvict = 0;
    std::uint64_t pressurePolicySoftBudget = 0;
    std::uint64_t pressurePolicyHardBudget = 0;
    std::uint64_t pressurePolicyCriticalBudget = 0;
    std::uint64_t pressurePolicyMinIdleBoundaryAge = 0;
    std::uint64_t policyRetentionSkippedRecords = 0;
    std::uint64_t lowMemoryPolicyPasses = 0;
    std::uint64_t midMemoryPolicyPasses = 0;
    std::uint64_t highMemoryPolicyPasses = 0;
    std::uint64_t highMemoryRetentionSkippedRecords = 0;
    std::uint64_t highMemoryCriticalReliefPasses = 0;
    std::uint64_t highMemoryDeviceBytesFreed = 0;
};

struct MetalR8HeapBucketSummary {
    std::uint64_t bucketId = 0;
    MetalR8ResourceClass resourceClass = MetalR8ResourceClass::None;
    MetalR8TextureClass textureClass = MetalR8TextureClass::Unknown;
    MetalR8LifetimeBucket lifetimeBucket = MetalR8LifetimeBucket::Unknown;
    std::uint32_t storageMode = 0;
    std::uint32_t cpuCacheMode = 0;
    std::uint32_t hazardTrackingMode = 0;
    std::uint64_t resourceOptions = 0;
    std::uint64_t textureUsage = 0;
    std::uint32_t textureType = 0;
    std::uint32_t pixelFormat = 0;
    std::uint32_t sampleCount = 0;
    std::uint32_t mipmapLevels = 0;
    std::uint32_t arrayLength = 0;
    std::uint32_t sizeBucket = 0;
    std::uint64_t records = 0;
    std::uint64_t retainedBytes = 0;
    std::uint64_t metalBytes = 0;
    std::uint64_t hostBytes = 0;
    std::uint64_t oldestLastUseCommandSerial = 0;
    std::uint64_t newestLastUseCommandSerial = 0;
    std::uint64_t inFlightRecords = 0;
};

struct MetalR8HeapSegmentationSummary {
    std::uint64_t version = 1;
    std::uint64_t enabled = 0;
    std::uint64_t dryRunPasses = 0;
    std::uint64_t rowsSeen = 0;
    std::uint64_t rowsClassified = 0;
    std::uint64_t rowsTruncated = 0;
    std::uint64_t allocationChanges = 0;
    std::uint64_t heapCreations = 0;
    std::uint64_t setPurgeableStateCalls = 0;
    std::uint64_t drainRequests = 0;

    std::uint64_t reconstructableRecords = 0;
    std::uint64_t reconstructableBytes = 0;
    std::uint64_t authoritativeRecords = 0;
    std::uint64_t authoritativeBytes = 0;
    std::uint64_t transientRecords = 0;
    std::uint64_t transientBytes = 0;
    std::uint64_t sparseSpecialRecords = 0;
    std::uint64_t sparseSpecialBytes = 0;
    std::uint64_t unknownRecords = 0;
    std::uint64_t unknownBytes = 0;

    std::uint64_t hostHeapRecords = 0;
    std::uint64_t hostHeapBytes = 0;
    std::uint64_t metalDeviceHeapRecords = 0;
    std::uint64_t metalDeviceHeapBytes = 0;
    std::uint64_t frameGraphHeapRecords = 0;
    std::uint64_t frameGraphHeapBytes = 0;
    std::uint64_t cacheHeapRecords = 0;
    std::uint64_t cacheHeapBytes = 0;
    std::uint64_t sidecarHeapRecords = 0;
    std::uint64_t sidecarHeapBytes = 0;
    std::uint64_t sparseHeapRecords = 0;
    std::uint64_t sparseHeapBytes = 0;
    std::uint64_t unknownHeapRecords = 0;
    std::uint64_t unknownHeapBytes = 0;

    std::uint64_t frameGraphTransientExcludedRecords = 0;
    std::uint64_t frameGraphTransientExcludedBytes = 0;
    std::uint64_t sparseSpecialExcludedRecords = 0;
    std::uint64_t sparseSpecialExcludedBytes = 0;
    std::uint64_t unknownKindExcludedRecords = 0;
    std::uint64_t unknownKindExcludedBytes = 0;
    std::uint64_t unknownAuthorityExcludedRecords = 0;
    std::uint64_t unknownAuthorityExcludedBytes = 0;
    std::uint64_t authoritativeExcludedRecords = 0;
    std::uint64_t authoritativeExcludedBytes = 0;

    std::uint64_t candidateRecords = 0;
    std::uint64_t candidateBytes = 0;
    std::uint64_t candidateMetalBytes = 0;
    std::uint64_t candidateHostBytes = 0;
    std::uint64_t prospectiveBucketCount = 0;
    std::uint64_t prospectiveBucketRecords = 0;
    std::uint64_t prospectiveBucketBytes = 0;
    std::uint64_t reconstructableUnbucketedRecords = 0;
    std::uint64_t reconstructableUnbucketedBytes = 0;
    std::uint64_t compatibilityUnknownRows = 0;
    std::uint64_t compatibilityUnknownBytes = 0;
    std::uint64_t inFlightExcludedRows = 0;
    std::uint64_t inFlightExcludedBytes = 0;
    std::uint64_t hotLifetimeRows = 0;
    std::uint64_t hotLifetimeBytes = 0;
    std::uint64_t warmLifetimeRows = 0;
    std::uint64_t warmLifetimeBytes = 0;
    std::uint64_t coldLifetimeRows = 0;
    std::uint64_t coldLifetimeBytes = 0;
    std::uint64_t unknownLifetimeRows = 0;
    std::uint64_t unknownLifetimeBytes = 0;
    std::uint64_t bucketRowsTruncated = 0;
    std::uint64_t bucketBytesTruncated = 0;
    std::uint64_t bucketTruncationPermyriad = 0;

    std::uint64_t purgeAttempts = 0;
    std::uint64_t purgeSuccesses = 0;
    std::uint64_t purgeFailures = 0;
    std::uint64_t purgeAffectedObjects = 0;
    std::uint64_t purgeBytes = 0;
    std::uint64_t purgeSkippedFlagOff = 0;
    std::uint64_t purgeSkippedNoAllocator = 0;
    std::uint64_t reconstructionSuccesses = 0;
    std::uint64_t reconstructionFailures = 0;
    std::uint64_t reconstructionLatencySamples = 0;
    std::uint64_t reconstructionLatencyTotalNs = 0;
    std::uint64_t reconstructionLatencyMaxNs = 0;
    std::uint64_t deviceAllocatedBytesBefore = 0;
    std::uint64_t deviceAllocatedBytesAfter = 0;
    std::uint64_t deviceAllocatedBytesDelta = 0;
    std::uint64_t deviceBytesFreed = 0;
    std::uint64_t prospectivePurgeableMetalBytes = 0;
    std::uint64_t osPressure = 0;
    std::uint64_t pressureState = 0;
    std::uint64_t workingSetRatioPermyriad = 0;
    std::uint64_t memoryClass = 0;
    std::uint64_t pendingPressurePeak = 0;
    std::uint64_t warningEventCount = 0;
    std::uint64_t criticalEventCount = 0;
    std::uint64_t criticalPressureExhaustionLatches = 0;
    std::uint64_t criticalPressureOOMErrors = 0;
    std::uint64_t criticalPressureNoCandidateLatches = 0;
    std::uint64_t criticalPressureNoReliefLatches = 0;
    std::uint64_t criticalPressureBudgetExhaustedLatches = 0;
    std::uint64_t criticalPressureStillCriticalLatches = 0;
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

inline const char* metalR8ResourceClassName(MetalR8ResourceClass value) {
    switch (value) {
    case MetalR8ResourceClass::None: return "none";
    case MetalR8ResourceClass::Buffer: return "buffer";
    case MetalR8ResourceClass::Texture: return "texture";
    }
    return "none";
}

inline const char* metalR8TextureClassName(MetalR8TextureClass value) {
    switch (value) {
    case MetalR8TextureClass::Unknown: return "unknown";
    case MetalR8TextureClass::Color: return "color";
    case MetalR8TextureClass::DepthStencil: return "depth-stencil";
    case MetalR8TextureClass::Compressed: return "compressed";
    case MetalR8TextureClass::Multisample: return "multisample";
    case MetalR8TextureClass::TextureBufferExpansion:
        return "texture-buffer-expansion";
    case MetalR8TextureClass::Sidecar: return "sidecar";
    case MetalR8TextureClass::Fp64Sidecar: return "fp64-sidecar";
    }
    return "unknown";
}

inline const char* metalR8LifetimeBucketName(MetalR8LifetimeBucket value) {
    switch (value) {
    case MetalR8LifetimeBucket::Unknown: return "unknown";
    case MetalR8LifetimeBucket::InFlight: return "in-flight";
    case MetalR8LifetimeBucket::Hot: return "hot";
    case MetalR8LifetimeBucket::Warm: return "warm";
    case MetalR8LifetimeBucket::Cold: return "cold";
    }
    return "unknown";
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

inline std::uint32_t metalR8SizeBucketForBytes(std::uint64_t bytes) {
    if (bytes == 0) {
        return 0;
    }
    std::uint32_t bucket = 0;
    --bytes;
    while (bytes != 0) {
        bytes >>= 1u;
        ++bucket;
    }
    return bucket;
}

inline MetalR8LifetimeBucket metalR8LifetimeBucketForRecord(
    const ResourceResidencyRecord& record,
    std::uint64_t boundarySerial) {
    if (record.inFlightSerial != 0) {
        return MetalR8LifetimeBucket::InFlight;
    }
    if (record.lastUseCommandSerial == 0 || record.lastUseFrame == 0 ||
        boundarySerial == 0) {
        return MetalR8LifetimeBucket::Unknown;
    }
    if (record.lastUseFrame >= boundarySerial) {
        return MetalR8LifetimeBucket::Hot;
    }
    const std::uint64_t age = boundarySerial - record.lastUseFrame;
    if (age <= 2) {
        return MetalR8LifetimeBucket::Hot;
    }
    if (age <= 8) {
        return MetalR8LifetimeBucket::Warm;
    }
    return MetalR8LifetimeBucket::Cold;
}

inline bool metalR8IsFrameGraphTransient(
    const ResourceResidencyRecord& record) {
    return record.kind == MetalResidencyKind::FrameGraphResource ||
           record.heapClass == MetalResidencyHeapClass::FrameGraph ||
           record.authority == MetalResidencyAuthorityClass::Transient;
}

inline bool metalR8IsSparseSpecial(const ResourceResidencyRecord& record) {
    switch (record.kind) {
    case MetalResidencyKind::SparsePageTable:
    case MetalResidencyKind::SparseHeap:
    case MetalResidencyKind::SparseStorageSidecar:
        return true;
    default:
        break;
    }
    return record.owner == MetalResidencyOwner::SparseTexture ||
           record.heapClass == MetalResidencyHeapClass::Sparse ||
           record.authority == MetalResidencyAuthorityClass::SparseSpecial;
}

inline bool metalR8BucketKeyEquals(const MetalR8HeapBucketSummary& bucket,
                                   const ResourceResidencyRecord& record) {
    return bucket.resourceClass == record.r8ResourceClass &&
           bucket.textureClass == record.r8TextureClass &&
           bucket.lifetimeBucket == record.r8LifetimeBucket &&
           bucket.storageMode == record.r8StorageMode &&
           bucket.cpuCacheMode == record.r8CpuCacheMode &&
           bucket.hazardTrackingMode == record.r8HazardTrackingMode &&
           bucket.resourceOptions == record.r8ResourceOptions &&
           bucket.textureUsage == record.r8TextureUsage &&
           bucket.textureType == record.r8TextureType &&
           bucket.pixelFormat == record.r8PixelFormat &&
           bucket.sampleCount == record.r8SampleCount &&
           bucket.mipmapLevels == record.r8MipmapLevels &&
           bucket.arrayLength == record.r8ArrayLength &&
           bucket.sizeBucket == record.r8SizeBucket;
}

inline MetalR8HeapBucketSummary metalR8BucketForRecord(
    const ResourceResidencyRecord& record,
    std::uint64_t bucketId) {
    MetalR8HeapBucketSummary bucket;
    bucket.bucketId = bucketId;
    bucket.resourceClass = record.r8ResourceClass;
    bucket.textureClass = record.r8TextureClass;
    bucket.lifetimeBucket = record.r8LifetimeBucket;
    bucket.storageMode = record.r8StorageMode;
    bucket.cpuCacheMode = record.r8CpuCacheMode;
    bucket.hazardTrackingMode = record.r8HazardTrackingMode;
    bucket.resourceOptions = record.r8ResourceOptions;
    bucket.textureUsage = record.r8TextureUsage;
    bucket.textureType = record.r8TextureType;
    bucket.pixelFormat = record.r8PixelFormat;
    bucket.sampleCount = record.r8SampleCount;
    bucket.mipmapLevels = record.r8MipmapLevels;
    bucket.arrayLength = record.r8ArrayLength;
    bucket.sizeBucket = record.r8SizeBucket;
    return bucket;
}

inline void metalR8AccumulateBucketRecord(
    MetalR8HeapBucketSummary& bucket,
    const ResourceResidencyRecord& record) {
    ++bucket.records;
    bucket.retainedBytes += record.retainedBytes;
    bucket.metalBytes += record.metalBytes;
    bucket.hostBytes += record.hostBytes;
    if (record.lastUseCommandSerial != 0 &&
        (bucket.oldestLastUseCommandSerial == 0 ||
         record.lastUseCommandSerial < bucket.oldestLastUseCommandSerial)) {
        bucket.oldestLastUseCommandSerial = record.lastUseCommandSerial;
    }
    if (record.lastUseCommandSerial > bucket.newestLastUseCommandSerial) {
        bucket.newestLastUseCommandSerial = record.lastUseCommandSerial;
    }
    if (record.inFlightSerial != 0) {
        ++bucket.inFlightRecords;
    }
}

inline void metalR8RecordAuthorityAndHeapOccupancy(
    MetalR8HeapSegmentationSummary& summary,
    const ResourceResidencyRecord& record) {
    const std::uint64_t bytes = record.retainedBytes;
    switch (record.authority) {
    case MetalResidencyAuthorityClass::Reconstructable:
        ++summary.reconstructableRecords;
        summary.reconstructableBytes += bytes;
        break;
    case MetalResidencyAuthorityClass::Transient:
        ++summary.transientRecords;
        summary.transientBytes += bytes;
        break;
    case MetalResidencyAuthorityClass::SparseSpecial:
        ++summary.sparseSpecialRecords;
        summary.sparseSpecialBytes += bytes;
        break;
    case MetalResidencyAuthorityClass::Unknown:
        ++summary.unknownRecords;
        summary.unknownBytes += bytes;
        break;
    case MetalResidencyAuthorityClass::Authoritative:
        ++summary.authoritativeRecords;
        summary.authoritativeBytes += bytes;
        break;
    }

    switch (record.heapClass) {
    case MetalResidencyHeapClass::Host:
        ++summary.hostHeapRecords;
        summary.hostHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::MetalDevice:
        ++summary.metalDeviceHeapRecords;
        summary.metalDeviceHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::FrameGraph:
        ++summary.frameGraphHeapRecords;
        summary.frameGraphHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::Cache:
        ++summary.cacheHeapRecords;
        summary.cacheHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::Sidecar:
        ++summary.sidecarHeapRecords;
        summary.sidecarHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::Sparse:
        ++summary.sparseHeapRecords;
        summary.sparseHeapBytes += bytes;
        break;
    case MetalResidencyHeapClass::Unknown:
        ++summary.unknownHeapRecords;
        summary.unknownHeapBytes += bytes;
        break;
    }
}

inline bool metalR8AppendProspectiveBucketRecord(
    MetalR8HeapSegmentationSummary& summary,
    std::vector<MetalR8HeapBucketSummary>& buckets,
    const ResourceResidencyRecord& record,
    std::uint64_t limit = kMetalR8HeapBucketLimit) {
    for (MetalR8HeapBucketSummary& bucket : buckets) {
        if (metalR8BucketKeyEquals(bucket, record)) {
            metalR8AccumulateBucketRecord(bucket, record);
            return true;
        }
    }
    if (buckets.size() >= static_cast<std::size_t>(limit)) {
        ++summary.bucketRowsTruncated;
        summary.bucketBytesTruncated += record.metalBytes;
        return false;
    }

    MetalR8HeapBucketSummary bucket =
        metalR8BucketForRecord(record,
                               static_cast<std::uint64_t>(buckets.size()) + 1);
    metalR8AccumulateBucketRecord(bucket, record);
    buckets.push_back(bucket);
    return true;
}

inline void accumulateR8HeapSegmentationRecord(
    MetalR8HeapSegmentationSummary& summary,
    std::vector<MetalR8HeapBucketSummary>& buckets,
    ResourceResidencyRecord record,
    std::uint64_t boundarySerial,
    std::uint64_t bucketLimit = kMetalR8HeapBucketLimit) {
    ++summary.rowsSeen;
    ++summary.rowsClassified;
    metalR8RecordAuthorityAndHeapOccupancy(summary, record);

    // Forward invariant for R8-1/2/3: classification is authority-first and
    // monotonic fail-closed. Compatibility metadata can only narrow a proven
    // reconstructable candidate; it cannot promote unknown, authoritative,
    // transient, sparse-special, or FrameGraph transient rows.
    if (metalR8IsFrameGraphTransient(record)) {
        ++summary.frameGraphTransientExcludedRecords;
        summary.frameGraphTransientExcludedBytes += record.retainedBytes;
        return;
    }
    if (metalR8IsSparseSpecial(record)) {
        ++summary.sparseSpecialExcludedRecords;
        summary.sparseSpecialExcludedBytes += record.retainedBytes;
        return;
    }
    if (!metalResidencyKnownKind(record.kind)) {
        ++summary.unknownKindExcludedRecords;
        summary.unknownKindExcludedBytes += record.retainedBytes;
        return;
    }
    if (record.authority == MetalResidencyAuthorityClass::Unknown) {
        ++summary.unknownAuthorityExcludedRecords;
        summary.unknownAuthorityExcludedBytes += record.retainedBytes;
        return;
    }
    if (record.authority != MetalResidencyAuthorityClass::Reconstructable) {
        ++summary.authoritativeExcludedRecords;
        summary.authoritativeExcludedBytes += record.retainedBytes;
        return;
    }

    ++summary.candidateRecords;
    summary.candidateBytes += record.retainedBytes;
    summary.candidateMetalBytes += record.metalBytes;
    summary.candidateHostBytes += record.hostBytes;
    if (record.metalBytes == 0) {
        ++summary.reconstructableUnbucketedRecords;
        summary.reconstructableUnbucketedBytes += record.retainedBytes;
        return;
    }

    record.r8LifetimeBucket =
        metalR8LifetimeBucketForRecord(record, boundarySerial);
    switch (record.r8LifetimeBucket) {
    case MetalR8LifetimeBucket::InFlight:
        ++summary.inFlightExcludedRows;
        summary.inFlightExcludedBytes += record.retainedBytes;
        ++summary.reconstructableUnbucketedRecords;
        summary.reconstructableUnbucketedBytes += record.retainedBytes;
        return;
    case MetalR8LifetimeBucket::Unknown:
        ++summary.unknownLifetimeRows;
        summary.unknownLifetimeBytes += record.retainedBytes;
        ++summary.reconstructableUnbucketedRecords;
        summary.reconstructableUnbucketedBytes += record.retainedBytes;
        return;
    case MetalR8LifetimeBucket::Hot:
        ++summary.hotLifetimeRows;
        summary.hotLifetimeBytes += record.retainedBytes;
        break;
    case MetalR8LifetimeBucket::Warm:
        ++summary.warmLifetimeRows;
        summary.warmLifetimeBytes += record.retainedBytes;
        break;
    case MetalR8LifetimeBucket::Cold:
        ++summary.coldLifetimeRows;
        summary.coldLifetimeBytes += record.retainedBytes;
        break;
    }

    if (record.r8CompatibilityKnown == 0 ||
        record.r8ResourceClass == MetalR8ResourceClass::None) {
        ++summary.compatibilityUnknownRows;
        summary.compatibilityUnknownBytes += record.retainedBytes;
        ++summary.reconstructableUnbucketedRecords;
        summary.reconstructableUnbucketedBytes += record.retainedBytes;
        return;
    }

    record.r8SizeBucket = metalR8SizeBucketForBytes(record.metalBytes);
    if (metalR8AppendProspectiveBucketRecord(summary,
                                             buckets,
                                             record,
                                             bucketLimit)) {
        ++summary.prospectiveBucketRecords;
        summary.prospectiveBucketBytes += record.metalBytes;
        summary.prospectivePurgeableMetalBytes += record.metalBytes;
    }
}

inline void finalizeR8HeapSegmentationSummary(
    MetalR8HeapSegmentationSummary& summary,
    const std::vector<MetalR8HeapBucketSummary>& buckets) {
    summary.prospectiveBucketCount =
        static_cast<std::uint64_t>(buckets.size());
    const std::uint64_t considered =
        summary.prospectiveBucketRecords + summary.bucketRowsTruncated;
    if (considered != 0) {
        summary.bucketTruncationPermyriad =
            summary.bucketRowsTruncated * 10000u / considered;
    }
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
static_assert(std::is_standard_layout<MetalR8HeapBucketSummary>::value,
              "MetalR8HeapBucketSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalR8HeapSegmentationSummary>::value,
              "MetalR8HeapSegmentationSummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalResourceResidencySummary>::value,
              "MetalResourceResidencySummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalHostCacheSummary>::value,
              "MetalHostCacheSummary must remain POD-shaped");

}  // namespace appgl
