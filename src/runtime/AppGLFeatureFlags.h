#pragma once

#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>

namespace appgl::feature_flags {

enum class FlagSource {
    BuildDefault,
    Json,
    Environment,
    CommandLine,
};

struct BooleanFlagResolution {
    bool enabled = false;
    FlagSource source = FlagSource::BuildDefault;
    std::string sourceName;
    std::string rawValue;
};

const char* sourceName(FlagSource source);

std::optional<bool> parseBoolean(std::string_view value,
                                 bool presenceMeansEnabled);

BooleanFlagResolution resolveBooleanFlag(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault);

bool isBooleanFlagEnabled(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault);

}  // namespace appgl::feature_flags
