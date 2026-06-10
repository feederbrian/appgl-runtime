#include "CoverageStore.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <utility>
#include <vector>

#include "../shared/JsonUtil.h"

namespace appgl {

CoverageStore::CoverageStore() = default;

void CoverageStore::recordCall(FunctionId id) {
    statuses_[indexOf(id)].callCount.fetch_add(1, std::memory_order_relaxed);
}

void CoverageStore::markImplemented(FunctionId id, std::string_view note) {
    const std::size_t index = indexOf(id);
    if (fastPathSatisfied(statuses_[index], CoverageState::Implemented, note)) {
        return;
    }
    std::lock_guard<std::mutex> lock(statusMutex_);
    auto& status = statuses_[index];
    const CoverageState previous = status.state;
    status.state = maxState(status.state, CoverageState::Implemented);
    if (shouldStoreNote(status, previous, CoverageState::Implemented, note)) {
        status.notes = std::string(note);
    }
    publishStateLocked(status);
}

void CoverageStore::markSmokeTested(FunctionId id, std::string_view testId, std::string_view note) {
    assert(!testId.empty() && "Smoke-tested coverage requires a test ID.");
    const std::size_t index = indexOf(id);
    if (fastPathSatisfied(statuses_[index], CoverageState::SmokeTested, note)) {
        return;
    }
    std::lock_guard<std::mutex> lock(statusMutex_);
    auto& status = statuses_[index];
    const CoverageState previous = status.state;
    status.state = maxState(status.state, CoverageState::SmokeTested);
    if (status.firstPassingTestId.empty()) {
        status.firstPassingTestId = std::string(testId);
    }
    if (shouldStoreNote(status, previous, CoverageState::SmokeTested, note)) {
        status.notes = std::string(note);
    }
    publishStateLocked(status);
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
    const std::size_t index = indexOf(id);
    if (fastPathSatisfied(statuses_[index], CoverageState::ScenarioTested, note)) {
        return;
    }
    std::lock_guard<std::mutex> lock(statusMutex_);
    auto& status = statuses_[index];
    const CoverageState previous = status.state;
    status.state = maxState(status.state, CoverageState::ScenarioTested);
    if (status.firstPassingTestId.empty()) {
        status.firstPassingTestId = std::string(testId);
    }
    if (shouldStoreNote(status, previous, CoverageState::ScenarioTested, note)) {
        status.notes = std::string(note);
    }
    publishStateLocked(status);
}

void CoverageStore::markStubbed(FunctionId id, std::string_view note) {
    const std::size_t index = indexOf(id);
    if (fastPathSatisfied(statuses_[index], CoverageState::Stubbed, note)) {
        return;
    }
    std::lock_guard<std::mutex> lock(statusMutex_);
    auto& status = statuses_[index];
    const CoverageState previous = status.state;
    status.state = maxState(status.state, CoverageState::Stubbed);
    if (shouldStoreNote(status, previous, CoverageState::Stubbed, note)) {
        status.notes = std::string(note);
    }
    publishStateLocked(status);
}

void CoverageStore::recordUnimplementedHit(FunctionId id) {
    statuses_[indexOf(id)].unimplementedHitCount.fetch_add(
        1, std::memory_order_relaxed);
}

const char* CoverageStore::claimedVersion() {
    // Compile-time constant: what AppGL advertises to external GL loaders
    // via glGetString(GL_VERSION). This is independent of coverage-store
    // state because engines (Recoil in particular) parse the version string
    // on context creation — long before any coverage-tracking entry point
    // has run — and gate entire codepaths on the result. Reporting a
    // dynamic bootstrap string here caused engines to fall back to GL3
    // even though the translator actually accepts 4.x source.
    //
    // The coverage-derived dynamic walk still exists on the other side of
    // the split: see fullyImplementedVersion(), consulted by
    // buildSnapshotJson() to keep the diagnostic coverage JSON honest
    // about what's been exercised.
    return "4.6 AppGL core";
}

std::string CoverageStore::fullyImplementedVersion() const {
    return fullyImplementedVersionForSnapshot(snapshotStatuses());
}

std::string CoverageStore::fullyImplementedVersionForSnapshot(
    const std::vector<FunctionCoverage>& statuses) {
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
            const auto& status = statuses[index];
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
    // Coverage table is empty (cold-boot or selective tests). Report a
    // diagnostic-only "nothing qualified yet" sentinel. This string is
    // consumed only by the coverage JSON snapshot — glGetString(GL_VERSION)
    // consults the declarative claimedVersion() path instead, so a cold
    // boot no longer advertises a bootstrap suffix to engines.
    return "0.0 AppGL (no coverage)";
}

std::string CoverageStore::buildSnapshotJson(std::string_view renderer, const std::vector<std::string>& traceTail) const {
    const std::vector<FunctionCoverage> statuses = snapshotStatuses();

    std::ostringstream stream;
    stream << "{";
    stream << "\"claimedVersion\":\""
           << jsonEscape(fullyImplementedVersionForSnapshot(statuses)) << "\",";
    stream << "\"renderer\":\"" << jsonEscape(renderer) << "\",";
    stream << "\"functions\":[";
    for (std::size_t index = 0; index < kGLFunctionCount; ++index) {
        if (index != 0) {
            stream << ",";
        }
        const auto& meta = kGLFunctionMetadata[index];
        const auto& status = statuses[index];
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

void CoverageStore::appendCallCensusJson(std::ostream& out,
                                         std::size_t topN) const {
    const auto exportStart = std::chrono::steady_clock::now();
    std::uint64_t total = 0;
    std::vector<std::pair<std::uint64_t, std::size_t>> nonZero;
    nonZero.reserve(256);
    for (std::size_t index = 0; index < kGLFunctionCount; ++index) {
        const std::uint64_t count =
            statuses_[index].callCount.load(std::memory_order_relaxed);
        if (count > 0) {
            total += count;
            nonZero.emplace_back(count, index);
        }
    }
    const std::size_t keep = std::min(topN, nonZero.size());
    std::partial_sort(
        nonZero.begin(), nonZero.begin() + static_cast<std::ptrdiff_t>(keep),
        nonZero.end(),
        [](const auto& a, const auto& b) { return a.first > b.first; });
    const double exportUs =
        std::chrono::duration<double, std::micro>(
            std::chrono::steady_clock::now() - exportStart)
            .count();
    out << "{\"totalCalls\":" << total
        << ",\"distinctFunctions\":" << nonZero.size()
        << ",\"exportUs\":" << exportUs << ",\"top\":[";
    for (std::size_t i = 0; i < keep; ++i) {
        if (i != 0) out << ",";
        out << "{\"name\":\"" << kGLFunctionMetadata[nonZero[i].second].name
            << "\",\"count\":" << nonZero[i].first << "}";
    }
    out << "]}";
}

FunctionCoverage CoverageStore::status(FunctionId id) const {
    std::lock_guard<std::mutex> lock(statusMutex_);
    return statusSnapshotLocked(indexOf(id));
}

FunctionCoverage CoverageStore::statusSnapshotLocked(std::size_t index) const {
    const auto& entry = statuses_[index];
    FunctionCoverage snapshot;
    snapshot.state = entry.state;
    snapshot.firstPassingTestId = entry.firstPassingTestId;
    snapshot.firstPassingBenchmarkId = entry.firstPassingBenchmarkId;
    snapshot.notes = entry.notes;
    snapshot.callCount = entry.callCount.load(std::memory_order_relaxed);
    snapshot.unimplementedHitCount =
        entry.unimplementedHitCount.load(std::memory_order_relaxed);
    return snapshot;
}

std::vector<FunctionCoverage> CoverageStore::snapshotStatuses() const {
    std::lock_guard<std::mutex> lock(statusMutex_);
    std::vector<FunctionCoverage> snapshot;
    snapshot.reserve(kGLFunctionCount);
    for (std::size_t index = 0; index < kGLFunctionCount; ++index) {
        snapshot.push_back(statusSnapshotLocked(index));
    }
    return snapshot;
}

CoverageState CoverageStore::maxState(CoverageState lhs, CoverageState rhs) {
    return static_cast<int>(lhs) > static_cast<int>(rhs) ? lhs : rhs;
}

bool CoverageStore::fastPathSatisfied(
    const CoverageEntry& entry,
    CoverageState requested,
    std::string_view note) {
    const std::uint8_t published =
        entry.publishedState.load(std::memory_order_acquire);
    const std::uint8_t requestedValue = stateValue(requested);
    if (published < requestedValue) {
        return false;
    }
    if (!note.empty() && published == requestedValue &&
        !entry.notesPublished.load(std::memory_order_acquire)) {
        return false;
    }
    return true;
}

bool CoverageStore::shouldStoreNote(
    const CoverageEntry& entry,
    CoverageState previous,
    CoverageState requested,
    std::string_view note) {
    return !note.empty() &&
           (previous < requested ||
            (previous == requested && entry.notes.empty()));
}

void CoverageStore::publishStateLocked(CoverageEntry& entry) {
    if (!entry.notes.empty()) {
        entry.notesPublished.store(true, std::memory_order_release);
    }
    entry.publishedState.store(stateValue(entry.state), std::memory_order_release);
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
