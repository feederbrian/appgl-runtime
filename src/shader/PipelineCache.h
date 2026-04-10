#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string>
#include <string_view>

namespace appgl {

struct PipelineCacheKey {
    std::string vertexSPIRVHash;
    std::string fragmentSPIRVHash;
    std::string vertexDescriptorHash;
    std::string attachmentFormatsHash;
    std::string rasterStateHash;
    std::string blendStateHash;
    std::string depthStencilStateHash;

    std::string digest() const;
};

struct PipelineCacheEntry {
    std::filesystem::path directory;
    std::filesystem::path mslPath;
    std::filesystem::path metadataPath;
    bool hit = false;
};

class PipelineCache {
public:
    explicit PipelineCache(std::filesystem::path root = {});

    const std::filesystem::path& root() const;
    PipelineCacheEntry lookup(const PipelineCacheKey& key) const;
    bool persistTextMSL(const PipelineCacheKey& key, std::string_view msl, std::string* error = nullptr) const;

    static std::string sha256Hex(std::span<const std::uint8_t> bytes);
    static std::string sha256Hex(std::string_view text);

private:
    std::filesystem::path root_;
};

}  // namespace appgl
