#include <cstdlib>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <unistd.h>
#include <vector>

#include "../src/runtime/AppGLFeatureFlags.h"

namespace {

namespace flags = appgl::feature_flags;

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
    const std::filesystem::path tempDir = makeTempDir();
    const std::filesystem::path jsonTrue = tempDir / "true.json";
    const std::filesystem::path jsonFalse = tempDir / "false.json";
    const std::filesystem::path jsonTyped = tempDir / "typed.json";
    const std::filesystem::path jsonMalformed = tempDir / "malformed.json";
    writeFile(jsonTrue, R"({"appgl":{"features":{"stage1-bool":true}}})");
    writeFile(jsonFalse, R"({"features":{"stage1-bool":false}})");
    writeFile(jsonTyped,
              R"({"appgl":{"features":{"stage1-float":1.25,"stage1-path":"/tmp/appgl-cache"}}})");
    writeFile(jsonMalformed, "{ this is not json");

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
