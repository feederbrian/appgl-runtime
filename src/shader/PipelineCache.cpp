#include "PipelineCache.h"

#include <CommonCrypto/CommonDigest.h>

#include <array>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <system_error>
#include <utility>

namespace appgl {
namespace {

std::filesystem::path defaultCacheRoot() {
    if (const char* home = std::getenv("HOME"); home != nullptr && home[0] != '\0') {
        return std::filesystem::path(home) / "Library" / "Caches" / "dev.excalibur.AppGL" / "shaders";
    }
    return std::filesystem::temp_directory_path() / "dev.excalibur.AppGL" / "shaders";
}

}  // namespace

std::string PipelineCacheKey::digest() const {
    std::ostringstream stream;
    stream << vertexSPIRVHash << '\n'
           << fragmentSPIRVHash << '\n'
           << vertexDescriptorHash << '\n'
           << attachmentFormatsHash << '\n'
           << rasterStateHash << '\n'
           << blendStateHash << '\n'
           << depthStencilStateHash;
    return PipelineCache::sha256Hex(stream.str());
}

PipelineCache::PipelineCache(std::filesystem::path root)
    : root_(root.empty() ? defaultCacheRoot() : std::move(root)) {
}

const std::filesystem::path& PipelineCache::root() const {
    return root_;
}

PipelineCacheEntry PipelineCache::lookup(const PipelineCacheKey& key) const {
    PipelineCacheEntry entry;
    entry.directory = root_ / key.digest();
    entry.mslPath = entry.directory / "shader.msl";
    entry.metadataPath = entry.directory / "pipeline.json";
    entry.hit = std::filesystem::exists(entry.mslPath) && std::filesystem::exists(entry.metadataPath);
    return entry;
}

bool PipelineCache::persistTextMSL(const PipelineCacheKey& key, std::string_view msl, std::string* error) const {
    const PipelineCacheEntry entry = lookup(key);
    std::error_code fsError;
    std::filesystem::create_directories(entry.directory, fsError);
    if (fsError) {
        if (error != nullptr) {
            *error = fsError.message();
        }
        return false;
    }

    std::ofstream mslOut(entry.mslPath, std::ios::binary);
    if (!mslOut) {
        if (error != nullptr) {
            *error = "Failed to open MSL cache file for writing.";
        }
        return false;
    }
    mslOut.write(msl.data(), static_cast<std::streamsize>(msl.size()));

    std::ofstream metadataOut(entry.metadataPath, std::ios::binary);
    if (!metadataOut) {
        if (error != nullptr) {
            *error = "Failed to open pipeline metadata file for writing.";
        }
        return false;
    }
    metadataOut << "{"
                << "\"cacheKey\":\"" << key.digest() << "\","
                << "\"format\":\"text-msl\","
                << "\"version\":1"
                << "}";
    return true;
}

std::string PipelineCache::sha256Hex(std::span<const std::uint8_t> bytes) {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest.data());

    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (unsigned char byte : digest) {
        stream << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return stream.str();
}

std::string PipelineCache::sha256Hex(std::string_view text) {
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(text.data());
    return sha256Hex(std::span<const std::uint8_t>(bytes, text.size()));
}

}  // namespace appgl
