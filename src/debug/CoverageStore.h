#pragma once

#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "../generated/gl_dispatch.gen.h"

namespace appgl {

enum class CoverageState : std::uint8_t {
    Unimplemented,
    Stubbed,
    Implemented,
    SmokeTested,
    ScenarioTested,
    PerformanceTested,
    BlockedByUnsupportedFeature,
};

struct FunctionCoverage {
    CoverageState state = CoverageState::Unimplemented;
    std::string firstPassingTestId;
    std::string firstPassingBenchmarkId;
    std::string notes;
    std::uint64_t callCount = 0;
    std::uint64_t unimplementedHitCount = 0;
};

class CoverageStore {
public:
    CoverageStore();

    void recordCall(FunctionId id);
    void markImplemented(FunctionId id, std::string_view note = {});
    void markSmokeTested(FunctionId id, std::string_view testId, std::string_view note = {});
    void markScenarioTested(FunctionId id, std::string_view testId, std::string_view goldenPath, std::string_view note = {});
    void markStubbed(FunctionId id, std::string_view note = {});
    void recordUnimplementedHit(FunctionId id);

    // Phase 8X Landing C — split into two accessors:
    //
    //   claimedVersion()           — compile-time constant. This is what
    //                                glGetString(GL_VERSION) and
    //                                Runtime::claimedVersionString consult,
    //                                independent of coverage-store state.
    //                                Returns "4.6 AppGL core", or
    //                                "4.6 AppGL compatibility" when
    //                                APPGL_COMPAT_PROFILE is enabled.
    //
    //   fullyImplementedVersion()  — dynamic walk over the coverage table.
    //                                Reports the highest core version for
    //                                which every introduced entry point has
    //                                been smoke-tested. Used by the
    //                                diagnostic snapshot JSON so the
    //                                `claimedVersion` field in coverage
    //                                reports still reflects reality.
    //
    // The old highestFullyImplementedVersion() method was a single accessor
    // doing both jobs. It survived as a thin wrapper for a while but now
    // its two callers have diverged — the GL_VERSION path must return
    // declaratively, the coverage JSON must stay dynamic.
    static const char* claimedVersion();
    std::string fullyImplementedVersion() const;
    std::string buildSnapshotJson(std::string_view renderer, const std::vector<std::string>& traceTail) const;

    // S24 Map-v2 instrument: per-entry-point call census for the bridge
    // diagnostics. The counters pre-exist (recordCall has incremented them
    // since day one), so the hot path gains nothing; this only exports the
    // topN by cumulative count via a lock-free scan over the atomics and
    // self-reports its export cost in the exportUs field.
    void appendCallCensusJson(std::ostream& out, std::size_t topN) const;

    FunctionCoverage status(FunctionId id) const;

private:
    struct CoverageEntry {
        CoverageState state = CoverageState::Unimplemented;
        std::string firstPassingTestId;
        std::string firstPassingBenchmarkId;
        std::string notes;
        std::atomic<std::uint8_t> publishedState{
            static_cast<std::uint8_t>(CoverageState::Unimplemented)};
        std::atomic<bool> notesPublished{false};
        std::atomic<std::uint64_t> callCount{0};
        std::atomic<std::uint64_t> unimplementedHitCount{0};
    };

    static constexpr std::size_t indexOf(FunctionId id) {
        return static_cast<std::size_t>(id);
    }

    static CoverageState maxState(CoverageState lhs, CoverageState rhs);
    static constexpr std::uint8_t stateValue(CoverageState state) {
        return static_cast<std::uint8_t>(state);
    }
    static bool fastPathSatisfied(
        const CoverageEntry& entry,
        CoverageState requested,
        std::string_view note);
    static bool shouldStoreNote(
        const CoverageEntry& entry,
        CoverageState previous,
        CoverageState requested,
        std::string_view note);
    static void publishStateLocked(CoverageEntry& entry);
    static const char* stateName(CoverageState state);
    static bool isAtLeastImplemented(CoverageState state);
    static bool isAtLeastSmokeTested(CoverageState state);
    static std::string fullyImplementedVersionForSnapshot(const std::vector<FunctionCoverage>& statuses);

    FunctionCoverage statusSnapshotLocked(std::size_t index) const;
    std::vector<FunctionCoverage> snapshotStatuses() const;

    mutable std::mutex statusMutex_;
    std::array<CoverageEntry, kGLFunctionCount> statuses_;
};

}  // namespace appgl
