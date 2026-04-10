#include "GoldenCompare.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <system_error>
#include <utility>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "../third_party/stb/stb_image.h"

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../third_party/stb/stb_image_write.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

namespace appgl::tests {

Image makeRGBA8Image(int width, int height, std::vector<std::uint8_t> pixels) {
    Image image;
    image.width = width;
    image.height = height;
    image.channels = 4;
    image.pixels = std::move(pixels);
    return image;
}

std::optional<Image> loadPNG(const std::filesystem::path& path, std::string* error) {
    int width = 0;
    int height = 0;
    int channels = 0;
    stbi_uc* loaded = stbi_load(path.string().c_str(), &width, &height, &channels, 4);
    if (loaded == nullptr) {
        if (error != nullptr) {
            *error = stbi_failure_reason() != nullptr ? stbi_failure_reason() : "Failed to load PNG.";
        }
        return std::nullopt;
    }

    const std::size_t byteCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 4;
    std::vector<std::uint8_t> pixels(byteCount);
    std::memcpy(pixels.data(), loaded, byteCount);
    stbi_image_free(loaded);
    return makeRGBA8Image(width, height, std::move(pixels));
}

bool savePNG(const std::filesystem::path& path, const Image& image, std::string* error) {
    if (image.empty() || image.channels != 4) {
        if (error != nullptr) {
            *error = "Only non-empty RGBA8 images can be saved.";
        }
        return false;
    }

    std::error_code fsError;
    std::filesystem::create_directories(path.parent_path(), fsError);
    if (fsError) {
        if (error != nullptr) {
            *error = fsError.message();
        }
        return false;
    }

    const int strideBytes = image.width * image.channels;
    if (stbi_write_png(path.string().c_str(), image.width, image.height, image.channels, image.pixels.data(), strideBytes) == 0) {
        if (error != nullptr) {
            *error = "stb_image_write failed to encode PNG.";
        }
        return false;
    }
    return true;
}

CompareResult compareImages(const Image& actual, const Image& expected, double channelTolerance) {
    CompareResult result;
    result.dimensionsMatch =
        actual.width == expected.width
        && actual.height == expected.height
        && actual.channels == expected.channels
        && actual.pixels.size() == expected.pixels.size()
        && !actual.empty()
        && !expected.empty();
    if (!result.dimensionsMatch) {
        return result;
    }

    result.maxChannelDelta = 0.0;
    result.totalChannels = actual.pixels.size();
    for (std::size_t index = 0; index < actual.pixels.size(); ++index) {
        const double delta = std::abs(static_cast<double>(actual.pixels[index]) - static_cast<double>(expected.pixels[index])) / 255.0;
        result.maxChannelDelta = std::max(result.maxChannelDelta, delta);
        if (delta > channelTolerance) {
            ++result.mismatchedChannels;
        }
    }

    result.diffRatio = result.totalChannels == 0
        ? 1.0
        : static_cast<double>(result.mismatchedChannels) / static_cast<double>(result.totalChannels);
    return result;
}

double goldenCompare(std::span<const unsigned char> lhs, std::span<const unsigned char> rhs, double channelTolerance) {
    if (lhs.size() != rhs.size() || lhs.empty()) {
        return 1.0;
    }

    const auto mismatchCount = std::count_if(lhs.begin(), lhs.end(), [&, index = std::size_t{0}](unsigned char value) mutable {
        const double delta = std::abs(static_cast<double>(value) - static_cast<double>(rhs[index++])) / 255.0;
        return delta > channelTolerance;
    });
    return static_cast<double>(mismatchCount) / static_cast<double>(lhs.size());
}

}  // namespace appgl::tests
