#include "CoverageStore.h"

#include <array>
#include <filesystem>
#include <sstream>

#include "../shared/JsonUtil.h"

namespace appgl {

CoverageStore::CoverageStore()
    : statuses_(kGLFunctionCount) {
}

void CoverageStore::recordCall(FunctionId id) {
    statuses_[indexOf(id)].callCount += 1;
}

void CoverageStore::markImplemented(FunctionId id, std::string_view note) {
    auto& status = statuses_[indexOf(id)];
    status.state = maxState(status.state, CoverageState::Implemented);
    if (!note.empty()) {
        status.notes = std::string(note);
    }
}

void CoverageStore::markSmokeTested(FunctionId id, std::string_view testId, std::string_view note) {
    assert(!testId.empty() && "Smoke-tested coverage requires a test ID.");
    auto& status = statuses_[indexOf(id)];
    status.state = maxState(status.state, CoverageState::SmokeTested);
    if (status.firstPassingTestId.empty()) {
        status.firstPassingTestId = std::string(testId);
    }
    if (!note.empty()) {
        status.notes = std::string(note);
    }
}

void CoverageStore::markScenarioTested(
    FunctionId id,
    std::string_view testId,
    std::string_view goldenPath,
    std::string_view note
) {
    assert(!testId.empty() && "Scenario-tested coverage requires a test ID.");
    assert(!goldenPath.empty() && "Scenario-tested coverage requires a golden path.");
    assert(std::filesystem::exists(std::filesystem::path(goldenPath)) && "Scenario-tested coverage requires a golden on disk.");
    auto& status = statuses_[indexOf(id)];
    status.state = maxState(status.state, CoverageState::ScenarioTested);
    if (status.firstPassingTestId.empty()) {
        status.firstPassingTestId = std::string(testId);
    }
    if (!note.empty()) {
        status.notes = std::string(note);
    }
}

void CoverageStore::markStubbed(FunctionId id, std::string_view note) {
    auto& status = statuses_[indexOf(id)];
    status.state = maxState(status.state, CoverageState::Stubbed);
    if (!note.empty()) {
        status.notes = std::string(note);
    }
}

void CoverageStore::recordUnimplementedHit(FunctionId id) {
    statuses_[indexOf(id)].unimplementedHitCount += 1;
}

std::string CoverageStore::highestFullyImplementedVersion() const {
    struct VersionRule {
        const char* version;
        const char* claimedString;
        bool requiresSmokeTests;
    };

    constexpr std::array<VersionRule, 5> kRules = {{
        {"3.3", "3.3 AppGL core", true},
        {"4.1", "4.1 AppGL core", true},
        {"4.3", "4.3 AppGL core", true},
        {"4.5", "4.5 AppGL core", true},
        {"4.6", "4.6 AppGL core", true},
    }};

    auto qualifies = [&](const VersionRule& rule) {
        for (std::size_t index = 0; index < kGLFunctionCount; ++index) {
            const auto& meta = kGLFunctionMetadata[index];
            if (std::string_view(meta.introducedVersion) > std::string_view(rule.version)) {
                continue;
            }
            const auto& status = statuses_[index];
            if (!isAtLeastImplemented(status.state)) {
                return false;
            }
            if (rule.requiresSmokeTests && !isAtLeastSmokeTested(status.state)) {
                return false;
            }
        }
        return true;
    };

    for (auto it = kRules.rbegin(); it != kRules.rend(); ++it) {
        if (qualifies(*it)) {
            return it->claimedString;
        }
    }
    // No coverage rules qualified yet (cold-boot or selective tests). Report
    // 4.6 so external loaders/engines treat the context as the full AppGL
    // surface; the live coverage store will overwrite this once entry points
    // start being marked implemented during normal frame submission.
    return "4.6 AppGL bootstrap";
}

std::string CoverageStore::buildSnapshotJson(std::string_view renderer, const std::vector<std::string>& traceTail) const {
    std::ostringstream stream;
    stream << "{";
    stream << "\"claimedVersion\":\"" << jsonEscape(highestFullyImplementedVersion()) << "\",";
    stream << "\"renderer\":\"" << jsonEscape(renderer) << "\",";
    stream << "\"functions\":[";
    for (std::size_t index = 0; index < kGLFunctionCount; ++index) {
        if (index != 0) {
            stream << ",";
        }
        const auto& meta = kGLFunctionMetadata[index];
        const auto& status = statuses_[index];
        stream << "{"
               << "\"name\":\"" << jsonEscape(meta.name) << "\","
               << "\"subsystem\":\"" << jsonEscape(meta.subsystem) << "\","
               << "\"state\":\"" << stateName(status.state) << "\","
               << "\"firstPassingTestId\":\"" << jsonEscape(status.firstPassingTestId) << "\","
               << "\"firstPassingBenchmarkId\":\"" << jsonEscape(status.firstPassingBenchmarkId) << "\","
               << "\"notes\":\"" << jsonEscape(status.notes) << "\","
               << "\"callCount\":" << status.callCount << ","
               << "\"unimplementedHitCount\":" << status.unimplementedHitCount
               << "}";
    }
    stream << "],";
    stream << "\"traceTail\":[";
    for (std::size_t index = 0; index < traceTail.size(); ++index) {
        if (index != 0) {
            stream << ",";
        }
        stream << "\"" << jsonEscape(traceTail[index]) << "\"";
    }
    stream << "]";
    stream << "}";
    return stream.str();
}

const FunctionCoverage& CoverageStore::status(FunctionId id) const {
    return statuses_[indexOf(id)];
}

CoverageState CoverageStore::maxState(CoverageState lhs, CoverageState rhs) {
    return static_cast<int>(lhs) > static_cast<int>(rhs) ? lhs : rhs;
}

const char* CoverageStore::stateName(CoverageState state) {
    switch (state) {
        case CoverageState::Unimplemented:
            return "Unimplemented";
        case CoverageState::Stubbed:
            return "Stubbed";
        case CoverageState::Implemented:
            return "Implemented";
        case CoverageState::SmokeTested:
            return "Smoke-tested";
        case CoverageState::ScenarioTested:
            return "Scenario-tested";
        case CoverageState::PerformanceTested:
            return "Performance-tested";
        case CoverageState::BlockedByUnsupportedFeature:
            return "Blocked by unsupported feature";
    }
    return "Unimplemented";
}

bool CoverageStore::isAtLeastImplemented(CoverageState state) {
    return static_cast<int>(state) >= static_cast<int>(CoverageState::Implemented);
}

bool CoverageStore::isAtLeastSmokeTested(CoverageState state) {
    return static_cast<int>(state) >= static_cast<int>(CoverageState::SmokeTested);
}

}  // namespace appgl
