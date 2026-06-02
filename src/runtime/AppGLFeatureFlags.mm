#include "AppGLFeatureFlags.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#import <Foundation/Foundation.h>

namespace appgl::feature_flags {
namespace {

struct ParsedValue {
    TypedFlagValue value;
    std::string rawValue;
};

struct ConfigSearchPath {
    NSString* path = nil;
    bool explicitPath = false;
    std::string sourceName;
};

std::mutex gDiagnosticsMutex;
std::vector<FeatureFlagDiagnostic> gDiagnostics;
std::set<std::string> gWarnedDiagnostics;

std::mutex gTestingMutex;
std::optional<std::vector<std::string>> gTestingArguments;

std::string normalizeName(std::string_view value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (unsigned char ch : value) {
        if (std::isalnum(ch)) {
            normalized.push_back(static_cast<char>(std::tolower(ch)));
        }
    }
    return normalized;
}

std::string trimAscii(std::string_view value) {
    std::size_t begin = 0;
    while (begin < value.size() &&
           std::isspace(static_cast<unsigned char>(value[begin]))) {
        ++begin;
    }

    std::size_t end = value.size();
    while (end > begin &&
           std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }

    return std::string(value.substr(begin, end - begin));
}

std::vector<std::string> normalizedNames(
    std::string_view canonicalName,
    const std::vector<std::string>& aliases) {
    std::vector<std::string> names;
    names.push_back(normalizeName(canonicalName));
    for (const std::string& alias : aliases) {
        const std::string normalized = normalizeName(alias);
        if (std::find(names.begin(), names.end(), normalized) == names.end()) {
            names.push_back(normalized);
        }
    }
    return names;
}

bool matchesAnyName(std::string_view candidate,
                    const std::vector<std::string>& normalizedNames) {
    const std::string normalized = normalizeName(candidate);
    return std::find(normalizedNames.begin(), normalizedNames.end(), normalized)
        != normalizedNames.end();
}

std::string stringFromNSString(NSString* value) {
    if (value == nil) {
        return {};
    }
    const char* utf8 = [value UTF8String];
    return utf8 != nullptr ? std::string(utf8) : std::string();
}

NSString* nsStringFromStdString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

std::vector<std::string> commandLineArguments() {
    {
        std::lock_guard<std::mutex> lock(gTestingMutex);
        if (gTestingArguments) {
            return *gTestingArguments;
        }
    }

    std::vector<std::string> arguments;
    NSArray<NSString*>* processArguments = [[NSProcessInfo processInfo] arguments];
    arguments.reserve([processArguments count]);
    for (NSString* argument in processArguments) {
        arguments.push_back(stringFromNSString(argument));
    }
    return arguments;
}

std::string diagnosticKey(const FeatureFlagDiagnostic& diagnostic) {
    std::ostringstream stream;
    stream << diagnostic.flag << '\n'
           << static_cast<int>(diagnostic.source) << '\n'
           << diagnostic.sourceName << '\n'
           << diagnostic.rawValue << '\n'
           << diagnostic.reason;
    return stream.str();
}

void recordDiagnostic(FeatureFlagDiagnostic diagnostic) {
    const std::string key = diagnosticKey(diagnostic);
    bool shouldWarn = false;
    {
        std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
        gDiagnostics.push_back(diagnostic);
        shouldWarn = gWarnedDiagnostics.insert(key).second;
    }

    if (shouldWarn) {
        std::fprintf(stderr,
                     "[APPGL feature-flag] flag=%s source=%s sourceName=%s raw=%s "
                     "reason=%s fallback=%s\n",
                     diagnostic.flag.c_str(),
                     sourceName(diagnostic.source),
                     diagnostic.sourceName.c_str(),
                     diagnostic.rawValue.c_str(),
                     diagnostic.reason.c_str(),
                     diagnostic.fallback.c_str());
    }
}

std::string fallbackSummary(const FeatureFlagResolution& resolution) {
    std::string fallback = sourceName(resolution.source);
    if (!resolution.sourceName.empty()) {
        fallback.append(":");
        fallback.append(resolution.sourceName);
    }
    return fallback;
}

void recordPendingDiagnostics(std::vector<FeatureFlagDiagnostic>& pending,
                              const FeatureFlagResolution& resolution) {
    const std::string fallback = fallbackSummary(resolution);
    for (FeatureFlagDiagnostic& diagnostic : pending) {
        diagnostic.fallback = fallback;
        recordDiagnostic(std::move(diagnostic));
    }
    pending.clear();
}

std::string jsonValueDescription(id value) {
    if (value == nil || value == [NSNull null]) {
        return "null";
    }
    if ([value isKindOfClass:[NSString class]]) {
        return stringFromNSString(static_cast<NSString*>(value));
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return stringFromNSString([static_cast<NSNumber*>(value) stringValue]);
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return "{...}";
    }
    if ([value isKindOfClass:[NSArray class]]) {
        return "[...]";
    }
    return stringFromNSString([value description]);
}

std::optional<std::string> validateParsedValue(const FeatureFlagSpec& spec,
                                               const TypedFlagValue& value) {
    if (value.type != spec.type) {
        return std::string("expected ") + typeName(spec.type);
    }

    switch (spec.type) {
        case FlagType::Int:
            if (spec.minInt && value.intValue < *spec.minInt) {
                return "integer below minimum";
            }
            if (spec.maxInt && value.intValue > *spec.maxInt) {
                return "integer above maximum";
            }
            break;
        case FlagType::Float:
            if (!std::isfinite(value.floatValue)) {
                return "float is not finite";
            }
            if (spec.minFloat && value.floatValue < *spec.minFloat) {
                return "float below minimum";
            }
            if (spec.maxFloat && value.floatValue > *spec.maxFloat) {
                return "float above maximum";
            }
            break;
        case FlagType::Enum:
            if (!spec.allowEmpty && value.stringValue.empty()) {
                return "empty enum value is not allowed";
            }
            if (!spec.enumValues.empty()) {
                const std::string normalizedValue = normalizeName(value.stringValue);
                bool matched = false;
                for (const std::string& allowed : spec.enumValues) {
                    if (normalizeName(allowed) == normalizedValue) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    return "enum value is not allowed";
                }
            }
            break;
        case FlagType::String:
        case FlagType::Path:
            if (!spec.allowEmpty && value.stringValue.empty()) {
                return std::string(typeName(spec.type)) + " value is empty";
            }
            break;
        case FlagType::Bool:
            break;
    }

    if (spec.validator) {
        return spec.validator(value);
    }
    return std::nullopt;
}

std::optional<ParsedValue> parseStringValue(const FeatureFlagSpec& spec,
                                            std::string_view value,
                                            bool presenceMeansEnabled,
                                            std::string* reason) {
    ParsedValue parsed;
    parsed.rawValue = std::string(value);

    switch (spec.type) {
        case FlagType::Bool: {
            if (auto boolValue = parseBoolean(value, presenceMeansEnabled)) {
                parsed.value = TypedFlagValue::boolean(*boolValue);
            } else {
                if (reason != nullptr) {
                    *reason = "expected boolean token";
                }
                return std::nullopt;
            }
            break;
        }
        case FlagType::Int: {
            const std::string trimmed = trimAscii(value);
            if (trimmed.empty()) {
                if (reason != nullptr) {
                    *reason = "expected integer";
                }
                return std::nullopt;
            }
            errno = 0;
            char* end = nullptr;
            const long long parsedInteger = std::strtoll(trimmed.c_str(), &end, 10);
            if (errno == ERANGE || end == trimmed.c_str() || *end != '\0') {
                if (reason != nullptr) {
                    *reason = "expected integer";
                }
                return std::nullopt;
            }
            if (parsedInteger < std::numeric_limits<std::int64_t>::min() ||
                parsedInteger > std::numeric_limits<std::int64_t>::max()) {
                if (reason != nullptr) {
                    *reason = "integer out of range";
                }
                return std::nullopt;
            }
            parsed.value = TypedFlagValue::integer(static_cast<std::int64_t>(parsedInteger));
            break;
        }
        case FlagType::Float: {
            const std::string trimmed = trimAscii(value);
            if (trimmed.empty()) {
                if (reason != nullptr) {
                    *reason = "expected float";
                }
                return std::nullopt;
            }
            errno = 0;
            char* end = nullptr;
            const double parsedFloat = std::strtod(trimmed.c_str(), &end);
            if (errno == ERANGE || end == trimmed.c_str() || *end != '\0' ||
                !std::isfinite(parsedFloat)) {
                if (reason != nullptr) {
                    *reason = "expected finite float";
                }
                return std::nullopt;
            }
            parsed.value = TypedFlagValue::floating(parsedFloat);
            break;
        }
        case FlagType::Enum: {
            const std::string raw = trimAscii(value);
            if (!spec.enumValues.empty()) {
                const std::string normalizedValue = normalizeName(raw);
                for (const std::string& allowed : spec.enumValues) {
                    if (normalizeName(allowed) == normalizedValue) {
                        parsed.value = TypedFlagValue::enumeration(allowed);
                        break;
                    }
                }
                if (parsed.value.type != FlagType::Enum) {
                    if (reason != nullptr) {
                        *reason = "enum value is not allowed";
                    }
                    return std::nullopt;
                }
            } else {
                parsed.value = TypedFlagValue::enumeration(raw);
            }
            break;
        }
        case FlagType::String:
            parsed.value = TypedFlagValue::string(std::string(value));
            break;
        case FlagType::Path:
            parsed.value = TypedFlagValue::path(std::string(value));
            break;
    }

    if (auto validationError = validateParsedValue(spec, parsed.value)) {
        if (reason != nullptr) {
            *reason = *validationError;
        }
        return std::nullopt;
    }
    return parsed;
}

std::optional<ParsedValue> parseJsonValue(const FeatureFlagSpec& spec,
                                          id value,
                                          std::string* reason) {
    if (value == nil || value == [NSNull null]) {
        if (reason != nullptr) {
            *reason = "JSON value is null";
        }
        return std::nullopt;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary* dict = static_cast<NSDictionary*>(value);
        for (NSString* key in @[ @"enabled", @"force", @"value" ]) {
            id nested = [dict objectForKey:key];
            if (nested != nil) {
                return parseJsonValue(spec, nested, reason);
            }
        }
        if (reason != nullptr) {
            *reason = "JSON object lacks enabled, force, or value";
        }
        return std::nullopt;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber* number = static_cast<NSNumber*>(value);
        if (spec.type == FlagType::Bool) {
            ParsedValue parsed;
            parsed.value = TypedFlagValue::boolean([number boolValue] ? true : false);
            parsed.rawValue = stringFromNSString([number stringValue]);
            return parsed;
        }
        return parseStringValue(spec, stringFromNSString([number stringValue]),
                                false, reason);
    }

    if ([value isKindOfClass:[NSString class]]) {
        return parseStringValue(spec,
                                stringFromNSString(static_cast<NSString*>(value)),
                                false,
                                reason);
    }

    if (reason != nullptr) {
        *reason = "unsupported JSON value type";
    }
    return std::nullopt;
}

FeatureFlagDiagnostic makeDiagnostic(const FeatureFlagSpec& spec,
                                     FlagSource source,
                                     std::string sourceNameValue,
                                     std::string rawValue,
                                     std::string reason) {
    FeatureFlagDiagnostic diagnostic;
    diagnostic.flag = spec.canonicalName;
    diagnostic.source = source;
    diagnostic.sourceName = std::move(sourceNameValue);
    diagnostic.rawValue = std::move(rawValue);
    diagnostic.reason = std::move(reason);
    return diagnostic;
}

std::optional<ParsedValue> lookupJsonOverride(
    NSDictionary* dict,
    const FeatureFlagSpec& spec,
    const std::vector<std::string>& names,
    const std::string& path,
    std::vector<FeatureFlagDiagnostic>& pendingDiagnostics) {
    if (dict == nil) {
        return std::nullopt;
    }

    for (id key in dict) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        if (!matchesAnyName(stringFromNSString(static_cast<NSString*>(key)), names)) {
            continue;
        }

        id value = [dict objectForKey:key];
        std::string reason;
        if (auto parsed = parseJsonValue(spec, value, &reason)) {
            return parsed;
        }
        pendingDiagnostics.push_back(makeDiagnostic(spec,
                                                    FlagSource::Json,
                                                    path,
                                                    jsonValueDescription(value),
                                                    reason));
    }

    for (NSString* nestedKey in @[ @"appgl", @"features" ]) {
        id nested = [dict objectForKey:nestedKey];
        if ([nested isKindOfClass:[NSDictionary class]]) {
            if (auto parsed =
                    lookupJsonOverride(static_cast<NSDictionary*>(nested),
                                       spec,
                                       names,
                                       path,
                                       pendingDiagnostics)) {
                return parsed;
            }
        }
    }

    return std::nullopt;
}

std::optional<std::string> commandLineConfigPath() {
    std::optional<std::string> result;
    constexpr std::string_view configPrefix = "--appgl-config=";
    for (const std::string& argument : commandLineArguments()) {
        if (argument.rfind(configPrefix, 0) == 0) {
            result = argument.substr(configPrefix.size());
        }
    }
    return result;
}

std::vector<ConfigSearchPath> configSearchPaths() {
    std::vector<ConfigSearchPath> paths;
    if (auto cliConfig = commandLineConfigPath()) {
        ConfigSearchPath config;
        config.path = nsStringFromStdString(*cliConfig);
        config.explicitPath = true;
        config.sourceName = "--appgl-config";
        paths.push_back(config);
    }

    for (const char* envName : {"APPGL_OPTIONS_JSON", "APPGL_CONFIG_JSON"}) {
        const char* value = std::getenv(envName);
        if (value != nullptr && value[0] != '\0') {
            ConfigSearchPath config;
            config.path = [NSString stringWithUTF8String:value];
            config.explicitPath = true;
            config.sourceName = envName;
            paths.push_back(config);
        }
    }

    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    if (cwd != nil) {
        ConfigSearchPath config;
        config.path = [cwd stringByAppendingPathComponent:@"appgl-options.json"];
        paths.push_back(config);
    }

    NSBundle* bundle = [NSBundle mainBundle];
    if (bundle != nil) {
        NSString* executable = [bundle executablePath];
        if (executable != nil) {
            ConfigSearchPath config;
            config.path = [[executable stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"appgl-options.json"];
            paths.push_back(config);
        }
        NSString* resource =
            [bundle pathForResource:@"appgl-options" ofType:@"json"];
        if (resource != nil) {
            ConfigSearchPath config;
            config.path = resource;
            paths.push_back(config);
        }
    }

    return paths;
}

std::optional<ParsedValue> commandLineOverride(
    const FeatureFlagSpec& spec,
    const std::vector<std::string>& names,
    std::vector<FeatureFlagDiagnostic>& pendingDiagnostics) {
    std::optional<ParsedValue> result;
    for (const std::string& token : commandLineArguments()) {
        constexpr std::string_view enablePrefix = "--appgl-enable=";
        constexpr std::string_view disablePrefix = "--appgl-disable=";
        constexpr std::string_view flagPrefix = "--appgl-";

        if (token.rfind(enablePrefix, 0) == 0) {
            const std::string flagName = token.substr(enablePrefix.size());
            if (matchesAnyName(flagName, names)) {
                if (spec.type == FlagType::Bool) {
                    result = ParsedValue{TypedFlagValue::boolean(true), token};
                } else {
                    pendingDiagnostics.push_back(makeDiagnostic(
                        spec, FlagSource::CommandLine, "argv", token,
                        "--appgl-enable is only valid for boolean flags"));
                }
            }
            continue;
        }

        if (token.rfind(disablePrefix, 0) == 0) {
            const std::string flagName = token.substr(disablePrefix.size());
            if (matchesAnyName(flagName, names)) {
                if (spec.type == FlagType::Bool) {
                    result = ParsedValue{TypedFlagValue::boolean(false), token};
                } else {
                    pendingDiagnostics.push_back(makeDiagnostic(
                        spec, FlagSource::CommandLine, "argv", token,
                        "--appgl-disable is only valid for boolean flags"));
                }
            }
            continue;
        }

        if (token.rfind(flagPrefix, 0) != 0 || token.rfind("--appgl-config=", 0) == 0) {
            continue;
        }

        std::string body = token.substr(flagPrefix.size());
        bool negated = false;
        if (body.rfind("no-", 0) == 0) {
            negated = true;
            body = body.substr(3);
        }

        std::string flagName = body;
        std::optional<std::string> explicitValue;
        const std::size_t equals = body.find('=');
        if (equals != std::string::npos) {
            flagName = body.substr(0, equals);
            explicitValue = body.substr(equals + 1);
        }

        if (!matchesAnyName(flagName, names)) {
            continue;
        }

        if (explicitValue) {
            std::string reason;
            if (auto parsed = parseStringValue(spec, *explicitValue, false, &reason)) {
                parsed->rawValue = token;
                result = *parsed;
            } else {
                pendingDiagnostics.push_back(makeDiagnostic(
                    spec, FlagSource::CommandLine, "argv", token, reason));
            }
        } else if (spec.type == FlagType::Bool) {
            result = ParsedValue{TypedFlagValue::boolean(!negated), token};
        } else {
            pendingDiagnostics.push_back(makeDiagnostic(
                spec, FlagSource::CommandLine, "argv", token,
                "missing value for non-boolean flag"));
        }
    }
    return result;
}

std::optional<ParsedValue> environmentOverride(
    const FeatureFlagSpec& spec,
    std::vector<FeatureFlagDiagnostic>& pendingDiagnostics) {
    for (const std::string& envName : spec.environmentVariables) {
        const char* value = std::getenv(envName.c_str());
        if (value == nullptr) {
            continue;
        }

        std::string reason;
        if (auto parsed = parseStringValue(spec,
                                           value,
                                           spec.type == FlagType::Bool,
                                           &reason)) {
            return *parsed;
        }

        pendingDiagnostics.push_back(makeDiagnostic(spec,
                                                    FlagSource::Environment,
                                                    envName,
                                                    value,
                                                    reason));
        return std::nullopt;
    }
    return std::nullopt;
}

std::optional<ParsedValue> jsonOverride(
    const FeatureFlagSpec& spec,
    const std::vector<std::string>& names,
    std::string* sourceNameOut,
    std::vector<FeatureFlagDiagnostic>& pendingDiagnostics) {
    for (const ConfigSearchPath& config : configSearchPaths()) {
        if (config.path == nil || config.path.length == 0) {
            if (config.explicitPath) {
                pendingDiagnostics.push_back(makeDiagnostic(
                    spec,
                    FlagSource::Json,
                    config.sourceName,
                    "",
                    "explicit JSON config path is empty"));
            }
            continue;
        }

        const std::string path = stringFromNSString(config.path);
        NSData* data = [NSData dataWithContentsOfFile:config.path];
        if (data == nil) {
            if (config.explicitPath) {
                pendingDiagnostics.push_back(makeDiagnostic(
                    spec,
                    FlagSource::Json,
                    path,
                    path,
                    "explicit JSON config is unreadable or missing"));
            }
            continue;
        }

        NSError* error = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&error];
        if (error != nil) {
            if (config.explicitPath) {
                pendingDiagnostics.push_back(makeDiagnostic(
                    spec,
                    FlagSource::Json,
                    path,
                    path,
                    stringFromNSString([error localizedDescription])));
            }
            continue;
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (config.explicitPath) {
                pendingDiagnostics.push_back(makeDiagnostic(
                    spec,
                    FlagSource::Json,
                    path,
                    path,
                    "JSON config root is not an object"));
            }
            continue;
        }

        if (auto parsed = lookupJsonOverride(static_cast<NSDictionary*>(json),
                                             spec,
                                             names,
                                             path,
                                             pendingDiagnostics)) {
            if (sourceNameOut != nullptr) {
                *sourceNameOut = path;
            }
            return parsed;
        }
    }
    return std::nullopt;
}

}  // namespace

TypedFlagValue TypedFlagValue::boolean(bool value) {
    TypedFlagValue result;
    result.type = FlagType::Bool;
    result.boolValue = value;
    return result;
}

TypedFlagValue TypedFlagValue::integer(std::int64_t value) {
    TypedFlagValue result;
    result.type = FlagType::Int;
    result.intValue = value;
    return result;
}

TypedFlagValue TypedFlagValue::floating(double value) {
    TypedFlagValue result;
    result.type = FlagType::Float;
    result.floatValue = value;
    return result;
}

TypedFlagValue TypedFlagValue::enumeration(std::string value) {
    TypedFlagValue result;
    result.type = FlagType::Enum;
    result.stringValue = std::move(value);
    return result;
}

TypedFlagValue TypedFlagValue::string(std::string value) {
    TypedFlagValue result;
    result.type = FlagType::String;
    result.stringValue = std::move(value);
    return result;
}

TypedFlagValue TypedFlagValue::path(std::string value) {
    TypedFlagValue result;
    result.type = FlagType::Path;
    result.stringValue = std::move(value);
    return result;
}

const char* sourceName(FlagSource source) {
    switch (source) {
        case FlagSource::BuildDefault: return "default";
        case FlagSource::Json: return "json";
        case FlagSource::Environment: return "environment";
        case FlagSource::CommandLine: return "command-line";
    }
    return "unknown";
}

const char* typeName(FlagType type) {
    switch (type) {
        case FlagType::Bool: return "bool";
        case FlagType::Int: return "int";
        case FlagType::Float: return "float";
        case FlagType::Enum: return "enum";
        case FlagType::String: return "string";
        case FlagType::Path: return "path";
    }
    return "unknown";
}

const char* scopeName(FlagScope scope) {
    switch (scope) {
        case FlagScope::Porter: return "porter";
        case FlagScope::App: return "app";
        case FlagScope::Runtime: return "runtime";
        case FlagScope::Both: return "both";
    }
    return "unknown";
}

const char* invalidPolicyName(InvalidPolicy policy) {
    switch (policy) {
        case InvalidPolicy::FallThrough: return "fall-through";
        case InvalidPolicy::DefaultSafe: return "default-safe";
    }
    return "unknown";
}

std::optional<bool> parseBoolean(std::string_view value,
                                 bool presenceMeansEnabled) {
    std::string lower;
    lower.reserve(value.size());
    for (unsigned char ch : value) {
        if (!std::isspace(ch)) {
            lower.push_back(static_cast<char>(std::tolower(ch)));
        }
    }

    if (lower.empty()) {
        return false;
    }
    if (lower == "1" || lower == "true" || lower == "yes" ||
        lower == "on" || lower == "enable" || lower == "enabled") {
        return true;
    }
    if (lower == "0" || lower == "false" || lower == "no" ||
        lower == "off" || lower == "disable" || lower == "disabled") {
        return false;
    }
    if (presenceMeansEnabled) {
        return true;
    }
    return std::nullopt;
}

FeatureFlagResolution resolveFlag(const FeatureFlagSpec& spec) {
    const std::vector<std::string> names = normalizedNames(spec.canonicalName,
                                                           spec.aliases);
    std::vector<FeatureFlagDiagnostic> pendingDiagnostics;

    FeatureFlagResolution resolution;
    if (auto parsed = commandLineOverride(spec, names, pendingDiagnostics)) {
        resolution = {parsed->value, FlagSource::CommandLine, "argv", parsed->rawValue};
    } else if (auto parsed = environmentOverride(spec, pendingDiagnostics)) {
        resolution = {parsed->value,
                      FlagSource::Environment,
                      "environment",
                      parsed->rawValue};
    } else {
        std::string jsonPath;
        if (auto parsed = jsonOverride(spec, names, &jsonPath, pendingDiagnostics)) {
            resolution = {parsed->value, FlagSource::Json, jsonPath, parsed->rawValue};
        } else {
            resolution = {spec.defaultValue, FlagSource::BuildDefault, "build-default", {}};
        }
    }

    if (spec.invalidPolicy == InvalidPolicy::DefaultSafe &&
        !pendingDiagnostics.empty()) {
        resolution = {spec.defaultValue,
                      FlagSource::BuildDefault,
                      "build-default",
                      {}};
    }

    recordPendingDiagnostics(pendingDiagnostics, resolution);
    return resolution;
}

BooleanFlagResolution resolveBooleanFlag(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault) {
    FeatureFlagSpec spec;
    spec.canonicalName = std::string(canonicalName);
    spec.aliases.reserve(aliases.size());
    for (std::string_view alias : aliases) {
        spec.aliases.push_back(std::string(alias));
    }
    spec.environmentVariables.reserve(environmentVariables.size());
    for (std::string_view envName : environmentVariables) {
        spec.environmentVariables.push_back(std::string(envName));
    }
    spec.type = FlagType::Bool;
    spec.defaultValue = TypedFlagValue::boolean(buildDefault);
    spec.scope = FlagScope::Runtime;
    spec.invalidPolicy = InvalidPolicy::FallThrough;

    FeatureFlagResolution resolution = resolveFlag(spec);
    return {resolution.value.boolValue,
            resolution.source,
            resolution.sourceName,
            resolution.rawValue};
}

bool isBooleanFlagEnabled(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault) {
    return resolveBooleanFlag(canonicalName, aliases, environmentVariables, buildDefault)
        .enabled;
}

std::vector<FeatureFlagDiagnostic> diagnosticsSnapshot() {
    std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
    return gDiagnostics;
}

void clearDiagnosticsForTesting() {
    std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
    gDiagnostics.clear();
    gWarnedDiagnostics.clear();
}

void setCommandLineArgumentsForTesting(std::vector<std::string> arguments) {
    std::lock_guard<std::mutex> lock(gTestingMutex);
    gTestingArguments = std::move(arguments);
}

void clearCommandLineArgumentsForTesting() {
    std::lock_guard<std::mutex> lock(gTestingMutex);
    gTestingArguments.reset();
}

}  // namespace appgl::feature_flags
