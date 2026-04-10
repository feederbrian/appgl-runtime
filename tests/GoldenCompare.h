#pragma once

#include <cstdint>
#include <cstddef>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace appgl::tests {

struct Image {
    int width = 0;
    int height = 0;
    int channels = 4;
    std::vector<std::uint8_t> pixels;

    bool empty() const {
        return width <= 0 || height <= 0 || channels <= 0 || pixels.empty();
    }
};

struct CompareResult {
    bool dimensionsMatch = false;
    double diffRatio = 1.0;
    double maxChannelDelta = 1.0;
    std::size_t mismatchedChannels = 0;
    std::size_t totalChannels = 0;
};

Image makeRGBA8Image(int width, int height, std::vector<std::uint8_t> pixels);
std::optional<Image> loadPNG(const std::filesystem::path& path, std::string* error = nullptr);
bool savePNG(const std::filesystem::path& path, const Image& image, std::string* error = nullptr);
CompareResult compareImages(const Image& actual, const Image& expected, double channelTolerance);
double goldenCompare(std::span<const unsigned char> lhs, std::span<const unsigned char> rhs, double channelTolerance);

}  // namespace appgl::tests
