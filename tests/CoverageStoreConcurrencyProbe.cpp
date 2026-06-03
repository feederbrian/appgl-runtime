#include "../src/debug/CoverageStore.h"

#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

struct ProbeState {
    bool ok = true;
};

void expect(ProbeState& state, bool condition, const char* message) {
    if (!condition) {
        state.ok = false;
        std::cerr << "FAIL: " << message << "\n";
    }
}

void runIdempotencyProbe(ProbeState& state) {
    appgl::CoverageStore store;
    const appgl::FunctionId id = appgl::FunctionId::glClear;
    const auto goldenPath =
        std::filesystem::temp_directory_path() /
        "appgl_coverage_store_concurrency_probe.golden";
    {
        std::ofstream golden(goldenPath);
        golden << "golden\n";
    }

    store.markImplemented(id, "implemented-a");
    store.markImplemented(id, "implemented-b");
    auto status = store.status(id);
    expect(state, status.state == appgl::CoverageState::Implemented,
           "implemented state");
    expect(state, status.notes == "implemented-a",
           "same-state implemented mark keeps first note");

    store.markSmokeTested(id, "smoke-a", "smoke-note-a");
    store.markSmokeTested(id, "smoke-b", "smoke-note-b");
    status = store.status(id);
    expect(state, status.state == appgl::CoverageState::SmokeTested,
           "smoke state");
    expect(state, status.firstPassingTestId == "smoke-a",
           "smoke mark keeps first passing test");
    expect(state, status.notes == "smoke-note-a",
           "same-state smoke mark keeps first note");

    store.markStubbed(id, "stub-note");
    status = store.status(id);
    expect(state, status.state == appgl::CoverageState::SmokeTested,
           "stub mark does not downgrade smoke state");
    expect(state, status.notes == "smoke-note-a",
           "lower-state stub mark does not replace smoke note");

    store.markScenarioTested(id, "scenario-a", goldenPath.string(),
                             "scenario-note-a");
    store.markScenarioTested(id, "scenario-b", goldenPath.string(),
                             "scenario-note-b");
    status = store.status(id);
    expect(state, status.state == appgl::CoverageState::ScenarioTested,
           "scenario state");
    expect(state, status.firstPassingTestId == "smoke-a",
           "scenario mark preserves first passing test");
    expect(state, status.notes == "scenario-note-a",
           "same-state scenario mark keeps first note");

    std::filesystem::remove(goldenPath);
}

void runConcurrencyProbe(ProbeState& state) {
    appgl::CoverageStore store;
    const appgl::FunctionId hotId = appgl::FunctionId::glDrawArrays;
    const appgl::FunctionId unimplementedId = appgl::FunctionId::glBlendBarrier;
    const appgl::FunctionId promotedId = appgl::FunctionId::glClear;
    constexpr int kRecordThreads = 8;
    constexpr int kMarkThreads = 3;
    constexpr int kRecordIterations = 50000;
    constexpr int kMarkIterations = 3000;
    constexpr int kSnapshotIterations = 3000;

    std::atomic<bool> start{false};
    std::atomic<int> activeWorkers{0};
    std::atomic<int> overlapsObserved{0};
    std::vector<std::thread> threads;

    const auto goldenPath =
        std::filesystem::temp_directory_path() /
        "appgl_coverage_store_concurrency_probe.concurrent.golden";
    {
        std::ofstream golden(goldenPath);
        golden << "golden\n";
    }

    auto waitForStart = [&]() {
        while (!start.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
    };

    for (int t = 0; t < kRecordThreads; ++t) {
        threads.emplace_back([&, t]() {
            waitForStart();
            activeWorkers.fetch_add(1, std::memory_order_acq_rel);
            for (int i = 0; i < kRecordIterations; ++i) {
                store.recordCall(hotId);
                if (((i + t) % 7) == 0) {
                    store.recordUnimplementedHit(unimplementedId);
                }
                if ((i % 1024) == 0) {
                    std::this_thread::yield();
                }
            }
            activeWorkers.fetch_sub(1, std::memory_order_acq_rel);
        });
    }

    for (int t = 0; t < kMarkThreads; ++t) {
        threads.emplace_back([&, t]() {
            waitForStart();
            activeWorkers.fetch_add(1, std::memory_order_acq_rel);
            for (int i = 0; i < kMarkIterations; ++i) {
                store.markImplemented(promotedId, "implemented");
                store.markSmokeTested(promotedId, "smoke", "smoke");
                if (((i + t) % 3) == 0) {
                    store.markScenarioTested(promotedId, "scenario",
                                             goldenPath.string(), "scenario");
                }
                store.markStubbed(unimplementedId, "stubbed");
                if ((i % 128) == 0) {
                    std::this_thread::yield();
                }
            }
            activeWorkers.fetch_sub(1, std::memory_order_acq_rel);
        });
    }

    threads.emplace_back([&]() {
        waitForStart();
        for (int i = 0; i < kSnapshotIterations; ++i) {
            if (activeWorkers.load(std::memory_order_acquire) > 0) {
                overlapsObserved.fetch_add(1, std::memory_order_relaxed);
            }
            const auto status = store.status(promotedId);
            (void)status;
            const std::string version = store.fullyImplementedVersion();
            (void)version;
            const std::string json =
                store.buildSnapshotJson("coverage-probe", {"a", "b"});
            if (json.find("\"functions\"") == std::string::npos ||
                json.find("\"traceTail\"") == std::string::npos) {
                state.ok = false;
                std::cerr << "FAIL: snapshot json missing expected keys\n";
                break;
            }
            if ((i % 64) == 0) {
                std::this_thread::yield();
            }
        }
    });

    start.store(true, std::memory_order_release);
    for (auto& thread : threads) {
        thread.join();
    }

    const auto hotStatus = store.status(hotId);
    expect(state,
           hotStatus.callCount ==
               static_cast<std::uint64_t>(kRecordThreads) *
                   static_cast<std::uint64_t>(kRecordIterations),
           "recordCall relaxed atomic count is exact under overlap");

    const auto promotedStatus = store.status(promotedId);
    expect(state,
           promotedStatus.state == appgl::CoverageState::ScenarioTested,
           "concurrent marks converge to scenario state");
    expect(state, promotedStatus.firstPassingTestId == "smoke",
           "concurrent marks keep first passing test id stable");

    const auto stubStatus = store.status(unimplementedId);
    expect(state, stubStatus.state == appgl::CoverageState::Stubbed,
           "concurrent stub marks converge to stubbed state");
    expect(state, stubStatus.unimplementedHitCount > 0,
           "unimplemented hit count advanced");
    expect(state, overlapsObserved.load(std::memory_order_relaxed) > 0,
           "snapshot loop overlapped active writers");

    std::filesystem::remove(goldenPath);
}

void runRepeatedHotMarkProbe(ProbeState& state) {
    appgl::CoverageStore store;
    const appgl::FunctionId drawId = appgl::FunctionId::glDrawArrays;
    const appgl::FunctionId uniformId = appgl::FunctionId::glUniformMatrix4fv;
    const appgl::FunctionId vertexId = appgl::FunctionId::glBindVertexArray;
    constexpr int kMarkThreads = 6;
    constexpr int kMarkIterations = 20000;
    constexpr int kSnapshotIterations = 2000;

    const auto goldenPath =
        std::filesystem::temp_directory_path() /
        "appgl_coverage_store_concurrency_probe.hotmark.golden";
    {
        std::ofstream golden(goldenPath);
        golden << "golden\n";
    }

    store.markSmokeTested(drawId, "draw-first", "draw-note");
    store.markSmokeTested(uniformId, "uniform-first", "uniform-note");
    store.markSmokeTested(vertexId, "vertex-first", "vertex-note");

    std::atomic<bool> start{false};
    std::atomic<int> activeWorkers{0};
    std::atomic<int> overlapsObserved{0};
    std::vector<std::thread> threads;

    auto waitForStart = [&]() {
        while (!start.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
    };

    for (int t = 0; t < kMarkThreads; ++t) {
        threads.emplace_back([&, t]() {
            waitForStart();
            activeWorkers.fetch_add(1, std::memory_order_acq_rel);
            for (int i = 0; i < kMarkIterations; ++i) {
                store.markSmokeTested(drawId, "draw-later", "draw-later-note");
                store.markSmokeTested(uniformId, "uniform-later", "uniform-later-note");
                store.markStubbed(drawId, "draw-stub-note");
                if (((i + t) % 16) == 0) {
                    store.markScenarioTested(vertexId, "vertex-scenario",
                                             goldenPath.string(), "vertex-scenario-note");
                } else {
                    store.markSmokeTested(vertexId, "vertex-later", "vertex-later-note");
                }
                if ((i % 512) == 0) {
                    std::this_thread::yield();
                }
            }
            activeWorkers.fetch_sub(1, std::memory_order_acq_rel);
        });
    }

    threads.emplace_back([&]() {
        waitForStart();
        for (int i = 0; i < kSnapshotIterations; ++i) {
            if (activeWorkers.load(std::memory_order_acquire) > 0) {
                overlapsObserved.fetch_add(1, std::memory_order_relaxed);
            }
            const auto drawStatus = store.status(drawId);
            const auto vertexStatus = store.status(vertexId);
            (void)drawStatus;
            (void)vertexStatus;
            const std::string json =
                store.buildSnapshotJson("coverage-hotmark-probe", {"hot"});
            if (json.find("\"glDrawArrays\"") == std::string::npos ||
                json.find("\"glBindVertexArray\"") == std::string::npos) {
                state.ok = false;
                std::cerr << "FAIL: hot mark snapshot json missing expected functions\n";
                break;
            }
            if ((i % 64) == 0) {
                std::this_thread::yield();
            }
        }
    });

    start.store(true, std::memory_order_release);
    for (auto& thread : threads) {
        thread.join();
    }

    const auto drawStatus = store.status(drawId);
    expect(state, drawStatus.state == appgl::CoverageState::SmokeTested,
           "repeated draw marks stay smoke-tested");
    expect(state, drawStatus.firstPassingTestId == "draw-first",
           "repeated draw marks keep first passing test");
    expect(state, drawStatus.notes == "draw-note",
           "repeated draw marks keep first note");

    const auto uniformStatus = store.status(uniformId);
    expect(state, uniformStatus.state == appgl::CoverageState::SmokeTested,
           "repeated uniform marks stay smoke-tested");
    expect(state, uniformStatus.firstPassingTestId == "uniform-first",
           "repeated uniform marks keep first passing test");
    expect(state, uniformStatus.notes == "uniform-note",
           "repeated uniform marks keep first note");

    const auto vertexStatus = store.status(vertexId);
    expect(state, vertexStatus.state == appgl::CoverageState::ScenarioTested,
           "repeated mixed vertex marks converge to scenario state");
    expect(state, vertexStatus.firstPassingTestId == "vertex-first",
           "repeated mixed vertex marks keep first passing test");
    expect(state, vertexStatus.notes == "vertex-scenario-note",
           "scenario promotion replaces lower smoke note once");
    expect(state, overlapsObserved.load(std::memory_order_relaxed) > 0,
           "hot mark snapshot loop overlapped active writers");

    std::filesystem::remove(goldenPath);
}

}  // namespace

int main() {
    ProbeState state;
    runIdempotencyProbe(state);
    runConcurrencyProbe(state);
    runRepeatedHotMarkProbe(state);
    if (!state.ok) {
        return 1;
    }
    std::cout << "CoverageStore concurrency probe passed\n";
    return 0;
}
