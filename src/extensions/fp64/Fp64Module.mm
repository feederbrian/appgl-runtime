#include "Fp64Module.h"

#include "Fp64StateBinding.h"
#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/fp64.h"

#include <cctype>
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

namespace appgl::extensions::fp64 {
namespace {

bool gActive = false;

std::optional<bool> parseBooleanString(const char* value,
                                       bool presenceMeansEnabled) {
    if (value == nullptr) {
        return std::nullopt;
    }
    std::string lower;
    for (const char* p = value; *p != '\0'; ++p) {
        if (!std::isspace(static_cast<unsigned char>(*p))) {
            lower.push_back(static_cast<char>(
                std::tolower(static_cast<unsigned char>(*p))));
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
        // Preserve existing AppGL env style: presence means enabled unless the
        // value is an explicit false token.
        return true;
    }
    return std::nullopt;
}

std::optional<bool> envBoolean(const char* name) {
    const char* value = std::getenv(name);
    if (value == nullptr) {
        return std::nullopt;
    }
    return parseBooleanString(value, true);
}

bool forceAdvertiseForMeasurement() {
    return envBoolean("APPGL_DF64_FORCE_ADVERTISE").value_or(false);
}

const char* advertisedGpuShaderFp64ExtensionString() {
    return APPGL_EXTENSION_ARB_GPU_SHADER_FP64;
}

const char* advertisedVertexAttrib64BitExtensionString() {
    return APPGL_EXTENSION_ARB_VERTEX_ATTRIB_64BIT;
}

bool supportsAppleGpuFamily(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    return device != nil && [device supportsFamily:MTLGPUFamilyApple7];
}

std::optional<bool> boolFromJsonValue(id value) {
    if (value == nil || value == [NSNull null]) {
        return std::nullopt;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [static_cast<NSNumber*>(value) boolValue] ? true : false;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return parseBooleanString([static_cast<NSString*>(value) UTF8String],
                                  false);
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary* dict = static_cast<NSDictionary*>(value);
        for (NSString* key in @[ @"enabled", @"force", @"value" ]) {
            id nested = [dict objectForKey:key];
            if (auto parsed = boolFromJsonValue(nested)) {
                return parsed;
            }
        }
    }
    return std::nullopt;
}

std::optional<bool> lookupFp64JsonOverride(NSDictionary* dict) {
    if (dict == nil) {
        return std::nullopt;
    }
    for (NSString* key in @[
             @"fp64_emulation",
             @"f64_emulation",
             @"gpu_shader_fp64",
             @"vertex_attrib_64bit"
         ]) {
        if (auto parsed = boolFromJsonValue([dict objectForKey:key])) {
            return parsed;
        }
    }
    for (NSString* nestedKey in @[ @"appgl", @"features" ]) {
        id nested = [dict objectForKey:nestedKey];
        if ([nested isKindOfClass:[NSDictionary class]]) {
            if (auto parsed =
                    lookupFp64JsonOverride(static_cast<NSDictionary*>(nested))) {
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
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    if (cwd != nil) {
        paths.push_back([cwd stringByAppendingPathComponent:@"appgl-options.json"]);
    }
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

std::optional<bool> readJsonRuntimeOverride() {
    static const std::optional<bool> cached = []() -> std::optional<bool> {
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
                    lookupFp64JsonOverride(static_cast<NSDictionary*>(json))) {
                return parsed;
            }
        }
        return std::nullopt;
    }();
    return cached;
}

std::optional<bool> porterRuntimeFlagOverride() {
    for (const char* envName : {
             "APPGL_ENABLE_FP64_EMULATION",
             "APPGL_ENABLE_GPU_SHADER_FP64",
             "APPGL_ENABLE_VERTEX_ATTRIB_64BIT"
         }) {
        if (auto parsed = envBoolean(envName)) {
            return parsed;
        }
    }
    return std::nullopt;
}

const ExtensionModuleDescriptor kDescriptor = {
    "fp64",
    advertisedGpuShaderFp64ExtensionString,
    isAvailable,
    initialize,
    shutdown,
    {},
    {}
};

const ExtensionModuleDescriptor kVertexAttrib64BitDescriptor = {
    "vertex_attrib_64bit",
    advertisedVertexAttrib64BitExtensionString,
    isAvailable,
    nullptr,
    nullptr,
    {},
    {}
};

struct Registrar {
    Registrar() {
        ExtensionRegistry::registerModule(kDescriptor);
        ExtensionRegistry::registerModule(kVertexAttrib64BitDescriptor);
    }
};

const Registrar kRegistrar;

}  // namespace

const char* extensionString() {
    return APPGL_EXTENSION_ARB_GPU_SHADER_FP64;
}

const char* vertexAttrib64BitExtensionString() {
    return APPGL_EXTENSION_ARB_VERTEX_ATTRIB_64BIT;
}

bool buildFlagEnabled() {
#if APPGL_FP64_EMULATION
    return true;
#else
    return false;
#endif
}

bool runtimeFlagEnabled() {
    if (auto jsonOverride = readJsonRuntimeOverride()) {
        return *jsonOverride;
    }
    if (auto porterOverride = porterRuntimeFlagOverride()) {
        return *porterOverride;
    }
    return buildFlagEnabled();
}

bool isAdvertisingHeld() {
    return false;
}

bool isAvailable(ExtensionContext& ctx) {
    return runtimeFlagEnabled() &&
           (supportsAppleGpuFamily(ctx) || forceAdvertiseForMeasurement());
}

void initialize(ExtensionContext& ctx) {
    gActive = isAvailable(ctx);
    resetContextBindingState(ctx, gActive);
}

void shutdown() {
    gActive = false;
    destroyAllContextBindingStates();
}

bool isActive() {
    return gActive;
}

}  // namespace appgl::extensions::fp64
