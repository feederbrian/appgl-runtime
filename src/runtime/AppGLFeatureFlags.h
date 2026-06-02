#pragma once

#include <cstdint>
#include <functional>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace appgl::feature_flags {

enum class FlagSource {
    BuildDefault,
    Json,
    Environment,
    CommandLine,
};

enum class FlagType {
    Bool,
    Int,
    Float,
    Enum,
    String,
    Path,
};

enum class FlagScope {
    Porter,
    App,
    Runtime,
    Both,
};

enum class InvalidPolicy {
    FallThrough,
    DefaultSafe,
};

struct TypedFlagValue {
    FlagType type = FlagType::Bool;
    bool boolValue = false;
    std::int64_t intValue = 0;
    double floatValue = 0.0;
    std::string stringValue;

    static TypedFlagValue boolean(bool value);
    static TypedFlagValue integer(std::int64_t value);
    static TypedFlagValue floating(double value);
    static TypedFlagValue enumeration(std::string value);
    static TypedFlagValue string(std::string value);
    static TypedFlagValue path(std::string value);
};

struct FeatureFlagSpec {
    std::string canonicalName;
    std::vector<std::string> aliases;
    std::vector<std::string> environmentVariables;
    FlagType type = FlagType::Bool;
    TypedFlagValue defaultValue = TypedFlagValue::boolean(false);
    FlagScope scope = FlagScope::Runtime;
    InvalidPolicy invalidPolicy = InvalidPolicy::FallThrough;
    std::vector<std::string> enumValues;
    std::optional<std::int64_t> minInt;
    std::optional<std::int64_t> maxInt;
    std::optional<double> minFloat;
    std::optional<double> maxFloat;
    bool allowEmpty = true;
    std::string normLabel;
    std::function<std::optional<std::string>(const TypedFlagValue&)> validator;
};

struct FeatureFlagResolution {
    TypedFlagValue value;
    FlagSource source = FlagSource::BuildDefault;
    std::string sourceName;
    std::string rawValue;
};

struct BooleanFlagResolution {
    bool enabled = false;
    FlagSource source = FlagSource::BuildDefault;
    std::string sourceName;
    std::string rawValue;
};

struct FeatureFlagDiagnostic {
    std::string flag;
    FlagSource source = FlagSource::BuildDefault;
    std::string sourceName;
    std::string rawValue;
    std::string reason;
    std::string fallback;
};

const char* sourceName(FlagSource source);
const char* typeName(FlagType type);
const char* scopeName(FlagScope scope);
const char* invalidPolicyName(InvalidPolicy policy);

std::optional<bool> parseBoolean(std::string_view value,
                                 bool presenceMeansEnabled);

FeatureFlagResolution resolveFlag(const FeatureFlagSpec& spec);

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

std::vector<FeatureFlagDiagnostic> diagnosticsSnapshot();
void clearDiagnosticsForTesting();
void setCommandLineArgumentsForTesting(std::vector<std::string> arguments);
void clearCommandLineArgumentsForTesting();

}  // namespace appgl::feature_flags
