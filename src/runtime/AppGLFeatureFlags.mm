#include "AppGLFeatureFlags.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>

namespace appgl::feature_flags {
namespace {

struct ParsedBoolean {
    bool enabled = false;
    std::string rawValue;
};

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

std::vector<std::string> normalizedNames(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases) {
    std::vector<std::string> names;
    names.push_back(normalizeName(canonicalName));
    for (std::string_view alias : aliases) {
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

std::optional<ParsedBoolean> parseBooleanValue(std::string_view value,
                                               bool presenceMeansEnabled) {
    if (auto parsed = parseBoolean(value, presenceMeansEnabled)) {
        return ParsedBoolean{*parsed, std::string(value)};
    }
    return std::nullopt;
}

std::optional<ParsedBoolean> boolFromJsonValue(id value) {
    if (value == nil || value == [NSNull null]) {
        return std::nullopt;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return ParsedBoolean{[static_cast<NSNumber*>(value) boolValue] ? true : false,
                             stringFromNSString([static_cast<NSNumber*>(value) stringValue])};
    }
    if ([value isKindOfClass:[NSString class]]) {
        return parseBooleanValue(
            stringFromNSString(static_cast<NSString*>(value)),
            false);
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary* dict = static_cast<NSDictionary*>(value);
        for (NSString* key in @[ @"enabled", @"force", @"value" ]) {
            if (auto parsed = boolFromJsonValue([dict objectForKey:key])) {
                return parsed;
            }
        }
    }
    return std::nullopt;
}

std::optional<ParsedBoolean> lookupJsonOverride(
    NSDictionary* dict,
    const std::vector<std::string>& names) {
    if (dict == nil) {
        return std::nullopt;
    }

    for (id key in dict) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        if (matchesAnyName(stringFromNSString(static_cast<NSString*>(key)), names)) {
            if (auto parsed = boolFromJsonValue([dict objectForKey:key])) {
                return parsed;
            }
        }
    }

    for (NSString* nestedKey in @[ @"appgl", @"features" ]) {
        id nested = [dict objectForKey:nestedKey];
        if ([nested isKindOfClass:[NSDictionary class]]) {
            if (auto parsed =
                    lookupJsonOverride(static_cast<NSDictionary*>(nested), names)) {
                return parsed;
            }
        }
    }

    return std::nullopt;
}

std::vector<NSString*> configSearchPaths() {
    std::vector<NSString*> paths;
    for (const char* envName : {"APPGL_OPTIONS_JSON", "APPGL_CONFIG_JSON"}) {
        const char* value = std::getenv(envName);
        if (value != nullptr && value[0] != '\0') {
            paths.push_back([NSString stringWithUTF8String:value]);
        }
    }

    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    if (cwd != nil) {
        paths.push_back([cwd stringByAppendingPathComponent:@"appgl-options.json"]);
    }

    NSBundle* bundle = [NSBundle mainBundle];
    if (bundle != nil) {
        NSString* executable = [bundle executablePath];
        if (executable != nil) {
            NSString* sibling = [[executable stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"appgl-options.json"];
            paths.push_back(sibling);
        }
        NSString* resource =
            [bundle pathForResource:@"appgl-options" ofType:@"json"];
        if (resource != nil) {
            paths.push_back(resource);
        }
    }

    return paths;
}

std::optional<ParsedBoolean> commandLineOverride(
    const std::vector<std::string>& names) {
    std::optional<ParsedBoolean> result;
    NSArray<NSString*>* arguments = [[NSProcessInfo processInfo] arguments];
    for (NSString* argument in arguments) {
        std::string token = stringFromNSString(argument);

        constexpr std::string_view enablePrefix = "--appgl-enable=";
        constexpr std::string_view disablePrefix = "--appgl-disable=";
        constexpr std::string_view flagPrefix = "--appgl-";

        if (token.rfind(enablePrefix, 0) == 0) {
            const std::string flagName = token.substr(enablePrefix.size());
            if (matchesAnyName(flagName, names)) {
                result = ParsedBoolean{true, token};
            }
            continue;
        }

        if (token.rfind(disablePrefix, 0) == 0) {
            const std::string flagName = token.substr(disablePrefix.size());
            if (matchesAnyName(flagName, names)) {
                result = ParsedBoolean{false, token};
            }
            continue;
        }

        if (token.rfind(flagPrefix, 0) != 0) {
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
            if (auto parsed = parseBooleanValue(*explicitValue, false)) {
                result = ParsedBoolean{parsed->enabled, token};
            }
        } else {
            result = ParsedBoolean{!negated, token};
        }
    }
    return result;
}

std::optional<ParsedBoolean> environmentOverride(
    std::initializer_list<std::string_view> environmentVariables) {
    for (std::string_view envName : environmentVariables) {
        const std::string name(envName);
        const char* value = std::getenv(name.c_str());
        if (value == nullptr) {
            continue;
        }
        if (auto parsed = parseBooleanValue(value, true)) {
            return *parsed;
        }
    }
    return std::nullopt;
}

std::optional<ParsedBoolean> jsonOverride(const std::vector<std::string>& names,
                                          std::string* sourceName) {
    for (NSString* path : configSearchPaths()) {
        if (path == nil || path.length == 0) {
            continue;
        }
        NSData* data = [NSData dataWithContentsOfFile:path];
        if (data == nil) {
            continue;
        }
        NSError* error = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&error];
        if (error != nil || ![json isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if (auto parsed =
                lookupJsonOverride(static_cast<NSDictionary*>(json), names)) {
            if (sourceName != nullptr) {
                *sourceName = stringFromNSString(path);
            }
            return parsed;
        }
    }
    return std::nullopt;
}

}  // namespace

const char* sourceName(FlagSource source) {
    switch (source) {
        case FlagSource::BuildDefault: return "default";
        case FlagSource::Json: return "json";
        case FlagSource::Environment: return "environment";
        case FlagSource::CommandLine: return "command-line";
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

BooleanFlagResolution resolveBooleanFlag(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault) {
    const std::vector<std::string> names = normalizedNames(canonicalName, aliases);

    if (auto parsed = commandLineOverride(names)) {
        return {parsed->enabled,
                FlagSource::CommandLine,
                "argv",
                parsed->rawValue};
    }

    if (auto parsed = environmentOverride(environmentVariables)) {
        return {parsed->enabled,
                FlagSource::Environment,
                "environment",
                parsed->rawValue};
    }

    std::string jsonPath;
    if (auto parsed = jsonOverride(names, &jsonPath)) {
        return {parsed->enabled,
                FlagSource::Json,
                jsonPath,
                parsed->rawValue};
    }

    return {buildDefault, FlagSource::BuildDefault, "build-default", {}};
}

bool isBooleanFlagEnabled(
    std::string_view canonicalName,
    std::initializer_list<std::string_view> aliases,
    std::initializer_list<std::string_view> environmentVariables,
    bool buildDefault) {
    return resolveBooleanFlag(canonicalName, aliases, environmentVariables, buildDefault)
        .enabled;
}

}  // namespace appgl::feature_flags
