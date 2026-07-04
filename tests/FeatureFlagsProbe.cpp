#include <cstdlib>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <optional>
#include <string>
#include <unistd.h>
#include <vector>

#include "../src/runtime/AppGLDiagnostics.h"
#include "../src/runtime/AppGLFeatureFlags.h"
#include "../src/runtime/AppGLProfile.h"

namespace {

namespace flags = appgl::feature_flags;
namespace diagnostics = appgl::diagnostics;
using appgl::AppGLCompatAdmissionMode;
using appgl::AppGLCompatFeature;
using appgl::AppGLCompatSemanticTier;

class ScopedEnv {
public:
    ScopedEnv(std::string name, std::optional<std::string> value)
        : name_(std::move(name)) {
        const char* existing = std::getenv(name_.c_str());
        if (existing != nullptr) {
            oldValue_ = std::string(existing);
        }
        if (value) {
            setenv(name_.c_str(), value->c_str(), 1);
        } else {
            unsetenv(name_.c_str());
        }
    }

    ~ScopedEnv() {
        if (oldValue_) {
            setenv(name_.c_str(), oldValue_->c_str(), 1);
        } else {
            unsetenv(name_.c_str());
        }
    }

private:
    std::string name_;
    std::optional<std::string> oldValue_;
};

class ScopedBatchAEnv {
public:
    ScopedBatchAEnv()
        : logging_("APPGL_LOGGING", std::nullopt),
          diagnosticLogging_("APPGL_DIAGNOSTIC_LOGGING", std::nullopt),
          loggingFile_("APPGL_LOGGING_FILE", std::nullopt),
          logFile_("APPGL_LOG_FILE", std::nullopt),
          loggingComponents_("APPGL_LOGGING_COMPONENTS", std::nullopt),
          logComponents_("APPGL_LOG_COMPONENTS", std::nullopt),
          metalValidation_("APPGL_METAL_VALIDATION_LAYER", std::nullopt),
          metalValidationAlias_("APPGL_METAL_VALIDATION", std::nullopt),
          metalWrapper_("METAL_DEVICE_WRAPPER_TYPE", std::nullopt),
          optionsJson_("APPGL_OPTIONS_JSON", std::nullopt),
          configJson_("APPGL_CONFIG_JSON", std::nullopt) {}

private:
    ScopedEnv logging_;
    ScopedEnv diagnosticLogging_;
    ScopedEnv loggingFile_;
    ScopedEnv logFile_;
    ScopedEnv loggingComponents_;
    ScopedEnv logComponents_;
    ScopedEnv metalValidation_;
    ScopedEnv metalValidationAlias_;
    ScopedEnv metalWrapper_;
    ScopedEnv optionsJson_;
    ScopedEnv configJson_;
};

class ScopedArgs {
public:
    explicit ScopedArgs(std::vector<std::string> args) {
        flags::setCommandLineArgumentsForTesting(std::move(args));
    }

    ~ScopedArgs() {
        flags::clearCommandLineArgumentsForTesting();
    }
};

class ScopedCurrentPath {
public:
    explicit ScopedCurrentPath(const std::filesystem::path& path)
        : oldPath_(std::filesystem::current_path()) {
        std::filesystem::current_path(path);
    }

    ~ScopedCurrentPath() {
        std::filesystem::current_path(oldPath_);
    }

private:
    std::filesystem::path oldPath_;
};

struct TestState {
    int checks = 0;
    bool failed = false;
};

void expect(TestState& state, bool condition, const std::string& label) {
    ++state.checks;
    if (!condition) {
        state.failed = true;
        std::cerr << "[feature-flags-self-test] FAIL: " << label << "\n";
    }
}

std::filesystem::path makeTempDir() {
    std::filesystem::path dir =
        std::filesystem::temp_directory_path() /
        ("appgl-feature-flags-" + std::to_string(getpid()));
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

void writeFile(const std::filesystem::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::binary);
    out << text;
}

std::string readFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in),
                       std::istreambuf_iterator<char>());
}

void resetDiagnosticsForProbe() {
    flags::clearDiagnosticsForTesting();
    diagnostics::resetDiagnosticOptionsForTesting();
}

void runCompatPolicySelfTest(TestState& state) {
    {
        auto policy = appgl::appglCompatPolicyFromEnv(nullptr, nullptr);
        expect(state, !appgl::appglAdvertiseCompatProfile(policy),
               "compat policy default-off does not advertise compatibility");
        expect(state, !appgl::appglCompatProfileEnabled(policy),
               "compat policy default-off keeps semantic tier core");
        expect(state, appgl::appglContextProfileMask(policy) == appgl::kAppGLCoreProfileBit,
               "compat policy default-off reports core profile mask");
        expect(state, std::string(appgl::appglClaimedVersionString(policy)) == "4.6 AppGL core",
               "compat policy default-off reports core version string");
        expect(state, !appgl::appglCompatVersionAtLeast(policy, 1, 0),
               "compat policy default-off has no compat-version admission");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv("1", "off");
        expect(state, policy.admissionMode == AppGLCompatAdmissionMode::LegacyAlias,
               "APPGL_COMPAT_PROFILE remains the legacy alias");
        expect(state, appgl::appglAdvertiseCompatProfile(policy),
               "legacy compat alias advertises compatibility");
        expect(state, appgl::appglCompatProfileEnabled(policy),
               "legacy compat alias enables broad semantic tier");
        expect(state, appgl::appglCompatFeatureEnabled(policy, AppGLCompatFeature::GpuShader4),
               "legacy compat alias preserves gpu_shader4 advertising");
        expect(state, std::string(appgl::appglClaimedVersionString(policy)) ==
                          "4.6 AppGL compatibility",
               "legacy compat alias preserves claimed version string");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv("0", "scoped");
        expect(state, policy.admissionMode == AppGLCompatAdmissionMode::Scoped,
               "scoped admission parses with disabled legacy alias");
        expect(state, appgl::appglAdvertiseCompatProfile(policy),
               "scoped admission advertises compatibility");
        expect(state, !appgl::appglCompatProfileEnabled(policy),
               "scoped admission leaves broad semantic tier disabled");
        expect(state, policy.semanticTier == AppGLCompatSemanticTier::Core,
               "scoped admission records core semantic tier");
        expect(state, policy.advertiseArbCompatibility,
               "scoped admission advertises GL_ARB_compatibility");
        expect(state, !appgl::appglCompatFeatureEnabled(policy, AppGLCompatFeature::GpuShader4),
               "scoped admission does not advertise gpu_shader4");
        expect(state, appgl::appglContextProfileMask(policy) ==
                          appgl::kAppGLCompatibilityProfileBit,
               "scoped admission reports compatibility profile mask");
        expect(state, appgl::appglCompatVersionAtLeast(policy, 4, 6),
               "scoped admission defaults to compatibility 4.6");
        expect(state, !appgl::appglCompatVersionAtLeast(policy, 4, 7),
               "scoped admission does not exceed AppGL 4.6");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv(nullptr, "compat-2.1");
        expect(state, policy.admissionMode == AppGLCompatAdmissionMode::CompatVersion,
               "compat-X.Y admission parses requested version");
        expect(state, appgl::appglCompatVersionAtLeast(policy, 2, 0),
               "compat-2.1 satisfies lower compat request");
        expect(state, !appgl::appglCompatVersionAtLeast(policy, 3, 0),
               "compat-2.1 does not satisfy higher compat request");
        expect(state, std::string(appgl::appglClaimedVersionString(policy)) ==
                          "2.1 AppGL compatibility",
               "compat-X.Y controls claimed version string");
        expect(state, !appgl::appglCompatProfileEnabled(policy),
               "compat-X.Y admission remains advertising-only");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv(nullptr, "scoped", "3.0");
        expect(state, std::string(appgl::appglClaimedVersionString(policy)) ==
                          "3.0 AppGL compatibility",
               "APPGL_COMPAT_VERSION overrides scoped claimed version");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv(nullptr, "full");
        expect(state, policy.admissionMode == AppGLCompatAdmissionMode::Full,
               "full admission parses");
        expect(state, appgl::appglAdvertiseCompatProfile(policy),
               "full admission advertises compatibility");
        expect(state, appgl::appglCompatProfileEnabled(policy),
               "full admission enables broad semantic tier");
        expect(state, appgl::appglCompatFeatureEnabled(policy, AppGLCompatFeature::GpuShader4),
               "full admission preserves broad legacy extensions");
    }

    {
        auto policy = appgl::appglCompatPolicyFromEnv(nullptr, "compat-4.7");
        expect(state, !appgl::appglAdvertiseCompatProfile(policy),
               "unsupported future compat version falls back to default-off");
    }
}

flags::FeatureFlagSpec boolSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-bool";
    spec.aliases = {"stage1-bool-alias", "stage1_bool_legacy"};
    spec.environmentVariables = {"APPGL_STAGE1_BOOL"};
    spec.type = flags::FlagType::Bool;
    spec.defaultValue = flags::TypedFlagValue::boolean(false);
    spec.scope = flags::FlagScope::Runtime;
    return spec;
}

flags::FeatureFlagSpec intSpec(flags::InvalidPolicy policy =
                                   flags::InvalidPolicy::FallThrough) {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-int";
    spec.environmentVariables = {"APPGL_STAGE1_INT"};
    spec.type = flags::FlagType::Int;
    spec.defaultValue = flags::TypedFlagValue::integer(5);
    spec.minInt = 0;
    spec.maxInt = 100;
    spec.scope = flags::FlagScope::Runtime;
    spec.invalidPolicy = policy;
    spec.normLabel = "NORM#1-test";
    return spec;
}

flags::FeatureFlagSpec floatSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-float";
    spec.environmentVariables = {"APPGL_STAGE1_FLOAT"};
    spec.type = flags::FlagType::Float;
    spec.defaultValue = flags::TypedFlagValue::floating(1.0);
    spec.minFloat = 0.0;
    spec.maxFloat = 4.0;
    spec.scope = flags::FlagScope::App;
    return spec;
}

flags::FeatureFlagSpec enumSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-enum";
    spec.environmentVariables = {"APPGL_STAGE1_ENUM"};
    spec.type = flags::FlagType::Enum;
    spec.defaultValue = flags::TypedFlagValue::enumeration("auto");
    spec.enumValues = {"auto", "on", "off"};
    spec.scope = flags::FlagScope::Porter;
    return spec;
}

flags::FeatureFlagSpec stringSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-string";
    spec.environmentVariables = {"APPGL_STAGE1_STRING"};
    spec.type = flags::FlagType::String;
    spec.defaultValue = flags::TypedFlagValue::string("default");
    spec.allowEmpty = false;
    spec.scope = flags::FlagScope::App;
    return spec;
}

flags::FeatureFlagSpec pathSpec() {
    flags::FeatureFlagSpec spec;
    spec.canonicalName = "stage1-path";
    spec.environmentVariables = {"APPGL_STAGE1_PATH"};
    spec.type = flags::FlagType::Path;
    spec.defaultValue = flags::TypedFlagValue::path("");
    spec.allowEmpty = false;
    spec.scope = flags::FlagScope::Both;
    return spec;
}

bool hasDiagnosticFor(const std::string& flag, flags::FlagSource source) {
    for (const auto& diagnostic : flags::diagnosticsSnapshot()) {
        if (diagnostic.flag == flag && diagnostic.source == source) {
            return true;
        }
    }
    return false;
}

bool hasRuntimeDiagnosticContaining(const std::string& needle) {
    for (const auto& diagnostic : diagnostics::diagnosticsSnapshotForTesting()) {
        if (diagnostic.message.find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

bool fp64RuntimeFlagForProbe() {
#if APPGL_FP64_EMULATION
    constexpr bool buildDefault = true;
#else
    constexpr bool buildDefault = false;
#endif
    return flags::resolveBooleanFlag(
        "f64-emulation",
        {
            "fp64-emulation",
            "gpu-shader-fp64",
            "vertex-attrib-64bit",
        },
        {
            "APPGL_ENABLE_FP64_EMULATION",
            "APPGL_ENABLE_GPU_SHADER_FP64",
            "APPGL_ENABLE_VERTEX_ATTRIB_64BIT",
        },
        buildDefault)
        .enabled;
}

int runSelfTest() {
    TestState state;
    runCompatPolicySelfTest(state);

    const std::filesystem::path tempDir = makeTempDir();
    const std::filesystem::path jsonTrue = tempDir / "true.json";
    const std::filesystem::path jsonFalse = tempDir / "false.json";
    const std::filesystem::path jsonTyped = tempDir / "typed.json";
    const std::filesystem::path jsonMalformed = tempDir / "malformed.json";
    const std::filesystem::path jsonBatchA = tempDir / "batch-a.json";
    const std::filesystem::path jsonBatchALog = tempDir / "batch-a-json.log";
    writeFile(jsonTrue, R"({"appgl":{"features":{"stage1-bool":true}}})");
    writeFile(jsonFalse, R"({"features":{"stage1-bool":false}})");
    writeFile(jsonTyped,
              R"({"appgl":{"features":{"stage1-float":1.25,"stage1-path":"/tmp/appgl-cache"}}})");
    writeFile(jsonMalformed, "{ this is not json");
    writeFile(jsonBatchA,
              "{\"features\":{\"logging\":\"warn\","
              "\"logging-file\":\"" + jsonBatchALog.string() + "\","
              "\"logging-components\":\"frame_graph\","
              "\"metal-validation-layer\":true}}");

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe",
                         "--appgl-stage1-bool=false",
                         "--appgl-stage1-bool-alias=1"});
        ScopedEnv env("APPGL_STAGE1_BOOL", std::string("0"));
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonTrue.string());
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, resolution.value.boolValue, "CLI beats env and JSON");
        expect(state, resolution.source == flags::FlagSource::CommandLine,
               "CLI source recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe",
                         "--appgl-enable=stage1-bool",
                         "--appgl-disable=stage1-bool-alias"});
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, !resolution.value.boolValue, "last matching CLI wins");
        expect(state, resolution.rawValue == "--appgl-disable=stage1-bool-alias",
               "last CLI raw value recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv env("APPGL_STAGE1_BOOL", std::string("0"));
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonTrue.string());
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, !resolution.value.boolValue, "env beats JSON");
        expect(state, resolution.source == flags::FlagSource::Environment,
               "env source recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv env("APPGL_STAGE1_BOOL", std::nullopt);
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonTrue.string());
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, resolution.value.boolValue, "JSON beats default");
        expect(state, resolution.source == flags::FlagSource::Json,
               "JSON source recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-config=" + jsonFalse.string()});
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonTrue.string());
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, !resolution.value.boolValue,
               "--appgl-config selects JSON file without source promotion");
        expect(state, resolution.source == flags::FlagSource::Json,
               "--appgl-config values remain JSON source");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv jsonA("APPGL_OPTIONS_JSON", std::nullopt);
        ScopedEnv jsonB("APPGL_CONFIG_JSON", std::nullopt);
        ScopedCurrentPath cwd(tempDir);
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, !resolution.value.boolValue, "missing default JSON falls to default");
        expect(state, resolution.source == flags::FlagSource::BuildDefault,
               "default source recorded");
        expect(state, flags::diagnosticsSnapshot().empty(),
               "missing default JSON remains silent");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-stage1-int=42"});
        auto resolution = flags::resolveFlag(intSpec());
        expect(state, resolution.value.intValue == 42, "CLI int parsing");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonTyped.string());
        auto floatResolution = flags::resolveFlag(floatSpec());
        auto pathResolution = flags::resolveFlag(pathSpec());
        expect(state, std::abs(floatResolution.value.floatValue - 1.25) < 0.0001,
               "JSON float parsing");
        expect(state, pathResolution.value.stringValue == "/tmp/appgl-cache",
               "JSON path parsing");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-stage1-enum=ON"});
        auto resolution = flags::resolveFlag(enumSpec());
        expect(state, resolution.value.stringValue == "on",
               "case-insensitive enum parsing returns canonical value");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-stage1-string=custom"});
        auto resolution = flags::resolveFlag(stringSpec());
        expect(state, resolution.value.stringValue == "custom",
               "CLI string parsing");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-stage1-int=bad"});
        ScopedEnv env("APPGL_STAGE1_INT", std::string("7"));
        auto resolution = flags::resolveFlag(intSpec());
        expect(state, resolution.value.intValue == 7,
               "invalid CLI int falls through to env");
        expect(state, hasDiagnosticFor("stage1-int", flags::FlagSource::CommandLine),
               "invalid CLI int diagnostic recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe", "--appgl-stage1-int=bad"});
        ScopedEnv env("APPGL_STAGE1_INT", std::string("7"));
        auto resolution = flags::resolveFlag(intSpec(flags::InvalidPolicy::DefaultSafe));
        expect(state, resolution.value.intValue == 5,
               "default-safe invalid policy returns default");
        expect(state, resolution.source == flags::FlagSource::BuildDefault,
               "default-safe source is default");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv json("APPGL_OPTIONS_JSON", jsonMalformed.string());
        auto resolution = flags::resolveFlag(boolSpec());
        expect(state, !resolution.value.boolValue,
               "malformed explicit JSON falls to default");
        expect(state, hasDiagnosticFor("stage1-bool", flags::FlagSource::Json),
               "malformed explicit JSON diagnostic recorded");
    }

    {
        flags::clearDiagnosticsForTesting();
        ScopedArgs args({"probe"});
        ScopedEnv f64Env("APPGL_ENABLE_FP64_EMULATION", std::string("1"));
        expect(state, fp64RuntimeFlagForProbe(),
               "F64 existing env alias remains compatible");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe"});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Off,
               "Batch-A logging default is off");
        expect(state, options.logging.filePath.empty(),
               "Batch-A logging-file default is empty");
        expect(state, !options.logging.consoleEnabled && !options.logging.fileEnabled,
               "Batch-A logging default creates no sink");
        expect(state, diagnostics::isComponentEnabledForTesting("draw"),
               "Batch-A logging-components default covers all components");
        expect(state, !options.metalValidation.requested,
               "Batch-A metal validation default is not requested");
        expect(state, diagnostics::diagnosticsSnapshotForTesting().empty(),
               "Batch-A defaults are diagnostic-silent");
    }

    {
        const std::filesystem::path cliLog = tempDir / "batch-a-cli.log";
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe",
                         "--appgl-config=" + jsonBatchA.string(),
                         "--appgl-logging=debug",
                         "--appgl-logging-file=" + cliLog.string(),
                         "--appgl-logging-components=shader_translator,frame_graph",
                         "--appgl-no-metal-validation-layer"});
        ScopedEnv envLogging("APPGL_LOGGING", std::string("info"));
        ScopedEnv envFile("APPGL_LOGGING_FILE", (tempDir / "batch-a-env.log").string());
        ScopedEnv envComponents("APPGL_LOGGING_COMPONENTS", std::string("draw"));
        ScopedEnv envMetal("APPGL_METAL_VALIDATION_LAYER", std::string("1"));
        ScopedEnv metalWrapper("METAL_DEVICE_WRAPPER_TYPE", std::string("1"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Debug,
               "Batch-A CLI logging beats env and JSON");
        expect(state, options.logging.filePath == cliLog.string(),
               "Batch-A CLI logging-file beats env and JSON");
        expect(state, diagnostics::isComponentEnabledForTesting("shader_translator") &&
                          diagnostics::isComponentEnabledForTesting("frame_graph") &&
                          !diagnostics::isComponentEnabledForTesting("draw"),
               "Batch-A CLI logging-components beats env and JSON");
        expect(state, !options.metalValidation.requested,
               "Batch-A CLI metal disable beats env and JSON");
    }

    {
        const std::filesystem::path envLog = tempDir / "batch-a-env.log";
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-config=" + jsonBatchA.string()});
        ScopedEnv envLogging("APPGL_LOGGING", std::string("info"));
        ScopedEnv envFile("APPGL_LOGGING_FILE", envLog.string());
        ScopedEnv envComponents("APPGL_LOGGING_COMPONENTS", std::string("shader"));
        ScopedEnv envMetal("APPGL_METAL_VALIDATION_LAYER", std::string("1"));
        ScopedEnv metalWrapper("METAL_DEVICE_WRAPPER_TYPE", std::string("1"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Info,
               "Batch-A env logging beats JSON");
        expect(state, options.logging.filePath == envLog.string(),
               "Batch-A env logging-file beats JSON");
        expect(state, diagnostics::isComponentEnabledForTesting("shader") &&
                          !diagnostics::isComponentEnabledForTesting("frame_graph"),
               "Batch-A env logging-components beats JSON");
        expect(state, options.metalValidation.requested &&
                          options.metalValidation.prelaunchEnvEnabled,
               "Batch-A env metal request reconciles with prelaunch env");
        expect(state, diagnostics::diagnosticsSnapshotForTesting().empty(),
               "Batch-A requested metal with env enabled is silent");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-config=" + jsonBatchA.string()});
        ScopedEnv metalWrapper("METAL_DEVICE_WRAPPER_TYPE", std::string("1"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Warn,
               "Batch-A JSON logging beats default");
        expect(state, options.logging.filePath == jsonBatchALog.string(),
               "Batch-A JSON logging-file beats default");
        expect(state, diagnostics::isComponentEnabledForTesting("frame_graph") &&
                          !diagnostics::isComponentEnabledForTesting("shader"),
               "Batch-A JSON logging-components beats default");
        expect(state, options.metalValidation.requested &&
                          options.metalValidation.prelaunchEnvEnabled,
               "Batch-A JSON metal request beats default");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-logging=verbose"});
        ScopedEnv envLogging("APPGL_LOGGING", std::string("trace"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Off,
               "Batch-A invalid logging uses default-safe off");
        expect(state, hasDiagnosticFor("logging", flags::FlagSource::CommandLine),
               "Batch-A invalid logging diagnostic recorded");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-config=" + jsonBatchA.string()});
        ScopedEnv envComponents("APPGL_LOGGING_COMPONENTS",
                                std::string("bad_component"));
        ScopedEnv metalWrapper("METAL_DEVICE_WRAPPER_TYPE", std::string("1"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.verbosity == diagnostics::LogVerbosity::Warn,
               "Batch-A component invalid source falls through to JSON");
        expect(state, diagnostics::isComponentEnabledForTesting("frame_graph") &&
                          !diagnostics::isComponentEnabledForTesting("draw"),
               "Batch-A component fallthrough uses JSON value");
        expect(state, hasDiagnosticFor("logging-components",
                                      flags::FlagSource::Environment),
               "Batch-A invalid component diagnostic recorded");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-metal-validation-layer=maybe"});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, !options.metalValidation.requested,
               "Batch-A invalid metal bool uses default-safe false");
        expect(state, hasDiagnosticFor("metal-validation-layer",
                                      flags::FlagSource::CommandLine),
               "Batch-A invalid metal bool diagnostic recorded");
    }

    {
        const std::filesystem::path smokeLog = tempDir / "batch-a-smoke.log";
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe",
                         "--appgl-logging=info",
                         "--appgl-logging-file=" + smokeLog.string(),
                         "--appgl-logging-components=feature_flags"});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.fileEnabled && !options.logging.consoleEnabled,
               "Batch-A logging-file opens once when logging is enabled");
        expect(state,
               diagnostics::emitDiagnosticLogForTesting("feature_flags",
                                                        diagnostics::LogVerbosity::Info,
                                                        "batch-a logging smoke"),
               "Batch-A logging-on smoke emitted");
        expect(state,
               readFile(smokeLog).find("batch-a logging smoke") != std::string::npos,
               "Batch-A logging-on smoke writes file");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-logging=info"});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.consoleEnabled && !options.logging.fileEnabled,
               "Batch-A logging without logging-file uses console sink");
    }

    {
        const std::filesystem::path badLog = tempDir / "missing-parent" / "log.txt";
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe",
                         "--appgl-logging=info",
                         "--appgl-logging-file=" + badLog.string()});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.logging.fileOpenFailed && !options.logging.fileEnabled,
               "Batch-A logging-file open failure disables file export");
        expect(state, hasRuntimeDiagnosticContaining("logging-file could not be opened"),
               "Batch-A logging-file open failure diagnostic recorded");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-metal-validation-layer=1"});
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.metalValidation.requested &&
                          !options.metalValidation.prelaunchEnvEnabled,
               "Batch-A metal requested-state recorded without Apple env");
        expect(state, options.metalValidation.guidanceDiagnosticEmitted,
               "Batch-A metal missing-env guidance flag recorded");
        expect(state, hasRuntimeDiagnosticContaining("porter/launcher/pre-process"),
               "Batch-A metal missing-env diagnostic cites porter pre-process");
    }

    {
        ScopedBatchAEnv cleanEnv;
        ScopedArgs args({"probe", "--appgl-metal-validation-layer=1"});
        ScopedEnv metalWrapper("METAL_DEVICE_WRAPPER_TYPE", std::string("1"));
        resetDiagnosticsForProbe();
        const auto& options = diagnostics::diagnosticOptions();
        expect(state, options.metalValidation.requested &&
                          options.metalValidation.prelaunchEnvEnabled,
               "Batch-A metal requested-state reconciles with Apple env");
        expect(state, !options.metalValidation.guidanceDiagnosticEmitted,
               "Batch-A metal env-enabled request is silent");
        expect(state, diagnostics::diagnosticsSnapshotForTesting().empty(),
               "Batch-A metal env-enabled request records no runtime diagnostic");
    }

    std::filesystem::remove_all(tempDir);

    if (state.failed) {
        std::cerr << "[feature-flags-self-test] checks=" << state.checks << "\n";
        return 1;
    }
    std::cout << "{\"selfTest\":true,\"checks\":" << state.checks << "}\n";
    return 0;
}

bool hasArg(int argc, char** argv, const std::string& value) {
    for (int i = 1; i < argc; ++i) {
        if (value == argv[i]) {
            return true;
        }
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    if (hasArg(argc, argv, "--self-test")) {
        return runSelfTest();
    }

    std::cout << "{\"fp64RuntimeFlag\":"
              << (fp64RuntimeFlagForProbe() ? "true" : "false")
              << "}\n";
    return 0;
}
