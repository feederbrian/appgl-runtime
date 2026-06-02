#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace appgl::diagnostics {

enum class LogVerbosity : std::uint8_t {
    Off = 0,
    Error = 1,
    Warn = 2,
    Info = 3,
    Debug = 4,
    Trace = 5,
};

enum class DiagnosticComponent : std::uint32_t {
    Runtime = 1u << 0,
    FeatureFlags = 1u << 1,
    ShaderTranslator = 1u << 2,
    FrameGraph = 1u << 3,
    CommandSubmission = 1u << 4,
    ExtensionRegistry = 1u << 5,
    Draw = 1u << 6,
    Shader = 1u << 7,
    Texture = 1u << 8,
    Buffer = 1u << 9,
    Pipeline = 1u << 10,
};

constexpr std::uint32_t kAllDiagnosticComponents =
    static_cast<std::uint32_t>(DiagnosticComponent::Runtime) |
    static_cast<std::uint32_t>(DiagnosticComponent::FeatureFlags) |
    static_cast<std::uint32_t>(DiagnosticComponent::ShaderTranslator) |
    static_cast<std::uint32_t>(DiagnosticComponent::FrameGraph) |
    static_cast<std::uint32_t>(DiagnosticComponent::CommandSubmission) |
    static_cast<std::uint32_t>(DiagnosticComponent::ExtensionRegistry) |
    static_cast<std::uint32_t>(DiagnosticComponent::Draw) |
    static_cast<std::uint32_t>(DiagnosticComponent::Shader) |
    static_cast<std::uint32_t>(DiagnosticComponent::Texture) |
    static_cast<std::uint32_t>(DiagnosticComponent::Buffer) |
    static_cast<std::uint32_t>(DiagnosticComponent::Pipeline);

struct LoggingOptions {
    LogVerbosity verbosity = LogVerbosity::Off;
    std::string filePath;
    std::uint32_t components = kAllDiagnosticComponents;
    bool consoleEnabled = false;
    bool fileEnabled = false;
    bool fileOpenFailed = false;
    std::string fileOpenDiagnostic;
};

struct MetalValidationOptions {
    bool requested = false;
    bool prelaunchEnvEnabled = false;
    bool guidanceDiagnosticEmitted = false;
};

struct DiagnosticOptions {
    LoggingOptions logging;
    MetalValidationOptions metalValidation;
};

struct RuntimeDiagnostic {
    std::string component;
    LogVerbosity verbosity = LogVerbosity::Info;
    std::string message;
};

const char* logVerbosityName(LogVerbosity verbosity);
const char* componentName(DiagnosticComponent component);

const DiagnosticOptions& diagnosticOptions();
bool isLoggingEnabledFor(DiagnosticComponent component, LogVerbosity verbosity);
void log(DiagnosticComponent component, LogVerbosity verbosity, std::string_view message);

bool isComponentEnabledForTesting(std::string_view componentName);
bool emitDiagnosticLogForTesting(std::string_view componentName,
                                 LogVerbosity verbosity,
                                 std::string_view message);
std::vector<RuntimeDiagnostic> diagnosticsSnapshotForTesting();
void clearDiagnosticsForTesting();
void resetDiagnosticOptionsForTesting();

}  // namespace appgl::diagnostics
