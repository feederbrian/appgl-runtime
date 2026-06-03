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
static_assert(std::is_standard_layout<MetalResourceResidencySummary>::value,
              "MetalResourceResidencySummary must remain POD-shaped");
static_assert(std::is_standard_layout<MetalHostCacheSummary>::value,
              "MetalHostCacheSummary must remain POD-shaped");

}  // namespace appgl
