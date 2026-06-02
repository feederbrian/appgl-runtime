#include "AppGLDiagnostics.h"

#include "AppGLFeatureFlags.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace appgl::diagnostics {
namespace {

namespace flags = appgl::feature_flags;

struct ComponentEntry {
    std::string_view name;
    DiagnosticComponent component;
};

constexpr ComponentEntry kComponentEntries[] = {
    {"runtime", DiagnosticComponent::Runtime},
    {"feature_flags", DiagnosticComponent::FeatureFlags},
    {"shader_translator", DiagnosticComponent::ShaderTranslator},
    {"frame_graph", DiagnosticComponent::FrameGraph},
    {"command_submission", DiagnosticComponent::CommandSubmission},
    {"extension_registry", DiagnosticComponent::ExtensionRegistry},
    {"draw", DiagnosticComponent::Draw},
    {"shader", DiagnosticComponent::Shader},
    {"texture", DiagnosticComponent::Texture},
    {"buffer", DiagnosticComponent::Buffer},
    {"pipeline", DiagnosticComponent::Pipeline},
};

std::mutex gOptionsMutex;
bool gOptionsInitialized = false;
DiagnosticOptions gOptions;

std::mutex gLogMutex;
std::FILE* gLogFile = nullptr;

std::mutex gDiagnosticsMutex;
std::vector<RuntimeDiagnostic> gDiagnostics;

std::string normalizeToken(std::string_view value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (unsigned char ch : value) {
        if (std::isalnum(ch)) {
            normalized.push_back(static_cast<char>(std::tolower(ch)));
        } else if (ch == '_' || ch == '-') {
            normalized.push_back('_');
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

bool componentFromToken(std::string_view token, DiagnosticComponent* out) {
    const std::string normalized = normalizeToken(trimAscii(token));
    for (const ComponentEntry& entry : kComponentEntries) {
        if (normalized == normalizeToken(entry.name)) {
            if (out != nullptr) {
                *out = entry.component;
            }
            return true;
        }
    }
    return false;
}

std::optional<std::uint32_t> parseComponentMask(std::string_view raw,
                                                std::string* error) {
    std::uint32_t mask = 0;
    bool sawToken = false;
    std::size_t begin = 0;
    while (begin <= raw.size()) {
        const std::size_t comma = raw.find(',', begin);
        const std::size_t end = comma == std::string_view::npos ? raw.size() : comma;
        const std::string token = trimAscii(raw.substr(begin, end - begin));
        if (!token.empty()) {
            sawToken = true;
            const std::string normalized = normalizeToken(token);
            if (normalized == "all") {
                mask = kAllDiagnosticComponents;
            } else {
                DiagnosticComponent component = DiagnosticComponent::Runtime;
                if (!componentFromToken(token, &component)) {
                    if (error != nullptr) {
                        *error = "unknown logging component: " + token;
                    }
                    return std::nullopt;
                }
                mask |= static_cast<std::uint32_t>(component);
            }
        }
        if (comma == std::string_view::npos) {
            break;
        }
        begin = comma + 1;
    }

    if (!sawToken) {
        if (error != nullptr) {
            *error = "logging component list is empty";
        }
        return std::nullopt;
    }
    return mask;
}

flags::FeatureFlagSpec loggingSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "logging";
    spec.aliases = {"log", "diagnostic-logging"};
    spec.environmentVariables = {"APPGL_LOGGING", "APPGL_DIAGNOSTIC_LOGGING"};
    spec.type = flags::FlagType::Enum;
    spec.defaultValue = flags::TypedFlagValue::enumeration("off");
    spec.scope = flags::FlagScope::Both;
    spec.invalidPolicy = flags::InvalidPolicy::DefaultSafe;
    spec.enumValues = {"off", "error", "warn", "info", "debug", "trace"};
    spec.allowEmpty = false;
    spec.normLabel = "NORM:diagnostic-init-logging";
    return spec;
}

flags::FeatureFlagSpec loggingFileSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "logging-file";
    spec.aliases = {"log-file", "logging-output", "log-output"};
    spec.environmentVariables = {"APPGL_LOGGING_FILE", "APPGL_LOG_FILE"};
    spec.type = flags::FlagType::Path;
    spec.defaultValue = flags::TypedFlagValue::path("");
    spec.scope = flags::FlagScope::Both;
    spec.invalidPolicy = flags::InvalidPolicy::FallThrough;
    spec.allowEmpty = true;
    spec.normLabel = "NORM:diagnostic-file-export";
    return spec;
}

flags::FeatureFlagSpec loggingComponentsSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "logging-components";
    spec.aliases = {"log-components", "logging-component-filter"};
    spec.environmentVariables = {"APPGL_LOGGING_COMPONENTS", "APPGL_LOG_COMPONENTS"};
    spec.type = flags::FlagType::String;
    spec.defaultValue = flags::TypedFlagValue::string("all");
    spec.scope = flags::FlagScope::Both;
    spec.invalidPolicy = flags::InvalidPolicy::FallThrough;
    spec.allowEmpty = false;
    spec.normLabel = "NORM:diagnostic-component-filter";
    spec.validator = [](const flags::TypedFlagValue& value) -> std::optional<std::string> {
        std::string error;
        if (!parseComponentMask(value.stringValue, &error)) {
            return error;
        }
        return std::nullopt;
    };
    return spec;
}

flags::FeatureFlagSpec metalValidationSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "metal-validation-layer";
    spec.aliases = {"metal-validation", "metal-debug-layer", "mtl-debug-layer"};
    spec.environmentVariables = {"APPGL_METAL_VALIDATION_LAYER",
                                 "APPGL_METAL_VALIDATION"};
    spec.type = flags::FlagType::Bool;
    spec.defaultValue = flags::TypedFlagValue::boolean(false);
    spec.scope = flags::FlagScope::Both;
    spec.invalidPolicy = flags::InvalidPolicy::DefaultSafe;
    spec.normLabel = "NORM:init-only-metal-device-validation";
    return spec;
}

LogVerbosity verbosityFromString(std::string_view raw) {
    const std::string normalized = normalizeToken(raw);
    if (normalized == "error") {
        return LogVerbosity::Error;
    }
    if (normalized == "warn") {
        return LogVerbosity::Warn;
    }
    if (normalized == "info") {
        return LogVerbosity::Info;
    }
    if (normalized == "debug") {
        return LogVerbosity::Debug;
    }
    if (normalized == "trace") {
        return LogVerbosity::Trace;
    }
    return LogVerbosity::Off;
}

bool metalValidationPrelaunchEnvEnabled() {
    const char* value = std::getenv("METAL_DEVICE_WRAPPER_TYPE");
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    if (auto parsed = flags::parseBoolean(value, false)) {
        return *parsed;
    }
    return true;
}

std::string lineFor(DiagnosticComponent component,
                    LogVerbosity verbosity,
                    std::string_view message) {
    std::ostringstream stream;
    stream << "[APPGL diagnostic] level=" << logVerbosityName(verbosity)
           << " component=" << componentName(component)
           << " " << message;
    return stream.str();
}

bool componentEnabled(std::uint32_t mask, DiagnosticComponent component) {
    return (mask & static_cast<std::uint32_t>(component)) != 0;
}

bool allowedByOptions(const DiagnosticOptions& options,
                      DiagnosticComponent component,
                      LogVerbosity verbosity) {
    if (options.logging.verbosity == LogVerbosity::Off ||
        verbosity == LogVerbosity::Off) {
        return false;
    }
    if (static_cast<int>(verbosity) > static_cast<int>(options.logging.verbosity)) {
        return false;
    }
    return componentEnabled(options.logging.components, component);
}

void emitLine(const DiagnosticOptions& options,
              DiagnosticComponent component,
              LogVerbosity verbosity,
              std::string_view message,
              bool forceStderr) {
    const bool allowed = allowedByOptions(options, component, verbosity);
    if (!forceStderr && !allowed) {
        return;
    }

    const std::string line = lineFor(component, verbosity, message);
    std::lock_guard<std::mutex> lock(gLogMutex);
    if (allowed && gLogFile != nullptr) {
        std::fprintf(gLogFile, "%s\n", line.c_str());
        std::fflush(gLogFile);
    }
    if (forceStderr || (allowed && options.logging.consoleEnabled)) {
        std::fprintf(stderr, "%s\n", line.c_str());
    }
}

void recordRuntimeDiagnostic(const DiagnosticOptions& options,
                             DiagnosticComponent component,
                             LogVerbosity verbosity,
                             std::string message,
                             bool forceStderr) {
    {
        std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
        gDiagnostics.push_back({std::string(componentName(component)),
                                verbosity,
                                message});
    }
    emitLine(options, component, verbosity, message, forceStderr);
}

DiagnosticOptions buildOptions(std::vector<std::pair<DiagnosticComponent, std::string>>*
                                   forcedDiagnostics) {
    DiagnosticOptions options;

    const flags::FeatureFlagResolution logging = flags::resolveFlag(loggingSpec());
    const flags::FeatureFlagResolution loggingFile = flags::resolveFlag(loggingFileSpec());
    const flags::FeatureFlagResolution loggingComponents =
        flags::resolveFlag(loggingComponentsSpec());
    const flags::FeatureFlagResolution metalValidation =
        flags::resolveFlag(metalValidationSpec());

    options.logging.verbosity = verbosityFromString(logging.value.stringValue);
    options.logging.filePath = loggingFile.value.stringValue;
    if (auto mask = parseComponentMask(loggingComponents.value.stringValue, nullptr)) {
        options.logging.components = *mask;
    }

    const bool loggingEnabled = options.logging.verbosity != LogVerbosity::Off;
    if (loggingEnabled && !options.logging.filePath.empty()) {
        std::lock_guard<std::mutex> lock(gLogMutex);
        gLogFile = std::fopen(options.logging.filePath.c_str(), "a");
        if (gLogFile != nullptr) {
            options.logging.fileEnabled = true;
        } else {
            options.logging.fileOpenFailed = true;
            options.logging.fileOpenDiagnostic =
                "logging-file could not be opened once at init; disabling file "
                "export: " + std::string(std::strerror(errno));
            if (forcedDiagnostics != nullptr) {
                forcedDiagnostics->push_back({DiagnosticComponent::FeatureFlags,
                                              options.logging.fileOpenDiagnostic});
            }
        }
    } else if (loggingEnabled) {
        options.logging.consoleEnabled = true;
    }

    options.metalValidation.requested = metalValidation.value.boolValue;
    options.metalValidation.prelaunchEnvEnabled = metalValidationPrelaunchEnvEnabled();
    if (options.metalValidation.requested &&
        !options.metalValidation.prelaunchEnvEnabled) {
        options.metalValidation.guidanceDiagnosticEmitted = true;
        if (forcedDiagnostics != nullptr) {
            forcedDiagnostics->push_back({
                DiagnosticComponent::Runtime,
                "metal-validation-layer requested but METAL_DEVICE_WRAPPER_TYPE "
                "is not enabled in the porter/launcher/pre-process environment "
                "before Metal loads; AppGL reconciles/advises and cannot "
                "guarantee or force Metal validation internally"});
        }
    }

    return options;
}

}  // namespace

const char* logVerbosityName(LogVerbosity verbosity) {
    switch (verbosity) {
        case LogVerbosity::Off: return "off";
        case LogVerbosity::Error: return "error";
        case LogVerbosity::Warn: return "warn";
        case LogVerbosity::Info: return "info";
        case LogVerbosity::Debug: return "debug";
        case LogVerbosity::Trace: return "trace";
    }
    return "unknown";
}

const char* componentName(DiagnosticComponent component) {
    switch (component) {
        case DiagnosticComponent::Runtime: return "runtime";
        case DiagnosticComponent::FeatureFlags: return "feature_flags";
        case DiagnosticComponent::ShaderTranslator: return "shader_translator";
        case DiagnosticComponent::FrameGraph: return "frame_graph";
        case DiagnosticComponent::CommandSubmission: return "command_submission";
        case DiagnosticComponent::ExtensionRegistry: return "extension_registry";
        case DiagnosticComponent::Draw: return "draw";
        case DiagnosticComponent::Shader: return "shader";
        case DiagnosticComponent::Texture: return "texture";
        case DiagnosticComponent::Buffer: return "buffer";
        case DiagnosticComponent::Pipeline: return "pipeline";
    }
    return "unknown";
}

const DiagnosticOptions& diagnosticOptions() {
    std::vector<std::pair<DiagnosticComponent, std::string>> forcedDiagnostics;
    bool initializedThisCall = false;
    {
        std::lock_guard<std::mutex> lock(gOptionsMutex);
        if (!gOptionsInitialized) {
            gOptions = buildOptions(&forcedDiagnostics);
            gOptionsInitialized = true;
            initializedThisCall = true;
        }
    }

    const DiagnosticOptions& options = gOptions;
    if (!forcedDiagnostics.empty()) {
        for (const auto& diagnostic : forcedDiagnostics) {
            recordRuntimeDiagnostic(options,
                                    diagnostic.first,
                                    LogVerbosity::Warn,
                                    diagnostic.second,
                                    true);
        }
    }
    if (initializedThisCall && options.logging.verbosity != LogVerbosity::Off) {
        emitLine(options,
                 DiagnosticComponent::Runtime,
                 LogVerbosity::Info,
                 "diagnostic logging initialized",
                 false);
    }
    return options;
}

bool isLoggingEnabledFor(DiagnosticComponent component, LogVerbosity verbosity) {
    return allowedByOptions(diagnosticOptions(), component, verbosity);
}

void log(DiagnosticComponent component, LogVerbosity verbosity, std::string_view message) {
    emitLine(diagnosticOptions(), component, verbosity, message, false);
}

bool isComponentEnabledForTesting(std::string_view name) {
    DiagnosticComponent component = DiagnosticComponent::Runtime;
    if (!componentFromToken(name, &component)) {
        return false;
    }
    return componentEnabled(diagnosticOptions().logging.components, component);
}

bool emitDiagnosticLogForTesting(std::string_view name,
                                 LogVerbosity verbosity,
                                 std::string_view message) {
    DiagnosticComponent component = DiagnosticComponent::Runtime;
    if (!componentFromToken(name, &component)) {
        return false;
    }
    if (!isLoggingEnabledFor(component, verbosity)) {
        return false;
    }
    log(component, verbosity, message);
    return true;
}

std::vector<RuntimeDiagnostic> diagnosticsSnapshotForTesting() {
    std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
    return gDiagnostics;
}

void clearDiagnosticsForTesting() {
    std::lock_guard<std::mutex> lock(gDiagnosticsMutex);
    gDiagnostics.clear();
}

void resetDiagnosticOptionsForTesting() {
    {
        std::lock_guard<std::mutex> lock(gLogMutex);
        if (gLogFile != nullptr) {
            std::fclose(gLogFile);
            gLogFile = nullptr;
        }
    }
    {
        std::lock_guard<std::mutex> lock(gOptionsMutex);
        gOptions = DiagnosticOptions{};
        gOptionsInitialized = false;
    }
    clearDiagnosticsForTesting();
}

}  // namespace appgl::diagnostics
