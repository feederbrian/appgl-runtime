#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>

#include "../src/context/MetalResourceResidency.h"

namespace {

struct ProbeState {
    int failures = 0;
};

volatile std::uint64_t gTouchSelector = 0;
volatile std::uint64_t gTouchSink = 0;

void expect(ProbeState& state, bool condition, const std::string& message) {
    if (!condition) {
        ++state.failures;
        std::cerr << "FAIL: " << message << "\n";
    }
}

appgl::ResourceResidencyRecord record(
    appgl::MetalResidencyKind kind,
    appgl::MetalResidencyAuthorityClass authority,
    appgl::MetalResidencyHeapClass heap,
    std::uint64_t metalBytes,
    std::uint64_t hostBytes) {
    appgl::ResourceResidencyRecord result;
    result.kind = kind;
    result.authority = authority;
    result.heapClass = heap;
    result.metalBytes = metalBytes;
    result.hostBytes = hostBytes;
    result.retainedBytes = metalBytes + hostBytes;
    result.purgeableEligible =
        (authority == appgl::MetalResidencyAuthorityClass::Reconstructable &&
         metalBytes != 0 &&
         appgl::metalR5FuturePurgeableEligibleKind(kind))
            ? 1
            : 0;
    return result;
}

void runClassifierProbe(ProbeState& state) {
    using appgl::MetalR5ResidencyClass;
    using appgl::MetalResidencyAuthorityClass;
    using appgl::MetalResidencyHeapClass;
    using appgl::MetalResidencyKind;

    appgl::MetalR5ResidencyDryRunSummary summary;
    summary.dryRunPasses = 1;

    const auto unknownKind = record(
        MetalResidencyKind::Unknown,
        MetalResidencyAuthorityClass::Reconstructable,
        MetalResidencyHeapClass::Cache,
        0,
        7);
    expect(state,
           appgl::classifyMetalR5ResidencyRecord(unknownKind) ==
               MetalR5ResidencyClass::Authoritative,
           "unknown kind defaults authoritative/excluded");
    appgl::accumulateR5ResidencyDryRunRecord(summary, unknownKind);

    const auto unknownAuthority = record(
        MetalResidencyKind::ExpandedIndexCache,
        MetalResidencyAuthorityClass::Unknown,
        MetalResidencyHeapClass::Cache,
        0,
        11);
    expect(state,
           appgl::classifyMetalR5ResidencyRecord(unknownAuthority) ==
               MetalR5ResidencyClass::Authoritative,
           "unknown authority defaults authoritative/excluded");
    appgl::accumulateR5ResidencyDryRunRecord(summary, unknownAuthority);

    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::ExpandedIndexCache,
               MetalResidencyAuthorityClass::Reconstructable,
               MetalResidencyHeapClass::Cache,
               0,
               16));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::MetalTexture,
               MetalResidencyAuthorityClass::Reconstructable,
               MetalResidencyHeapClass::MetalDevice,
               64,
               0));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::HostShadow,
               MetalResidencyAuthorityClass::Authoritative,
               MetalResidencyHeapClass::Host,
               0,
               32));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::FrameGraphResource,
               MetalResidencyAuthorityClass::Transient,
               MetalResidencyHeapClass::FrameGraph,
               128,
               0));
    appgl::accumulateR5ResidencyDryRunRecord(
        summary,
        record(MetalResidencyKind::SparsePageTable,
               MetalResidencyAuthorityClass::SparseSpecial,
               MetalResidencyHeapClass::Sparse,
               0,
               4));

    expect(state, summary.dryRunPasses == 1, "dry-run pass counted");
    expect(state, summary.recordsSeen == 7, "records seen");
    expect(state, summary.candidateRecords == 2, "candidate records");
    expect(state, summary.candidateBytes == 80, "candidate bytes");
    expect(state, summary.candidateHostBytes == 16, "candidate host bytes");
    expect(state, summary.candidateMetalBytes == 64, "candidate metal bytes");
    expect(state, summary.candidateCacheHeapBytes == 16,
           "cache heap candidate bytes");
    expect(state, summary.candidateMetalDeviceHeapBytes == 64,
           "metal heap candidate bytes");
    expect(state, summary.authoritativeRecords == 5,
           "authoritative/excluded records");
    expect(state, summary.authoritativeBytes == 182,
           "authoritative/excluded bytes");
    expect(state, summary.unknownKindRecords == 1, "unknown kind counter");
    expect(state, summary.unknownAuthorityRecords == 1,
           "unknown authority counter");
    expect(state, summary.transientExcludedRecords == 1,
           "transient excluded counter");
    expect(state, summary.sparseExcludedRecords == 1,
           "sparse excluded counter");
    expect(state, summary.futurePurgeableEligibleRecords == 1,
           "future purgeable count only tracks MTLResource reconstructables");
    expect(state, summary.pressureMutationAttempts == 0,
           "R5-0 performs no pressure mutation");
    expect(state, summary.purgeableStateCalls == 0,
           "R5-0 performs no purgeableState calls");
    expect(state, summary.drainRequests == 0, "R5-0 performs no drains");
}

void runTouchProbe(ProbeState& state) {
    using appgl::MetalR5ResidencyTouchKind;

    appgl::MetalR5ResidencyTouchSummary touches;
    appgl::recordMetalR5ResidencyTouch(
        touches, MetalR5ResidencyTouchKind::BufferBind);
    appgl::recordMetalR5ResidencyTouch(
        touches, MetalR5ResidencyTouchKind::TextureBind);
    appgl::recordMetalR5ResidencyTouch(touches,
                                       MetalR5ResidencyTouchKind::Draw);
    appgl::recordMetalR5ResidencyTouch(touches,
                                       MetalR5ResidencyTouchKind::Dispatch);

    expect(state, touches.serial == 4, "touch serial");
    expect(state, touches.totalTouches == 4, "total touches");
    expect(state, touches.bufferBindTouches == 1, "buffer touch count");
    expect(state, touches.textureBindTouches == 1, "texture touch count");
    expect(state, touches.drawTouches == 1, "draw touch count");
    expect(state, touches.dispatchTouches == 1, "dispatch touch count");

    constexpr std::uint64_t iterations = 1000000;
    appgl::MetalR5ResidencyTouchSummary benchmarkTouches;
    const appgl::MetalR5ResidencyTouchKind benchmarkKinds[] = {
        MetalR5ResidencyTouchKind::BufferBind,
        MetalR5ResidencyTouchKind::TextureBind,
        MetalR5ResidencyTouchKind::Draw,
        MetalR5ResidencyTouchKind::Dispatch,
    };
    const auto start = std::chrono::steady_clock::now();
    for (std::uint64_t i = 0; i < iterations; ++i) {
        const std::size_t kindIndex =
            static_cast<std::size_t>((i + gTouchSelector) & 3u);
        appgl::recordMetalR5ResidencyTouch(
            benchmarkTouches, benchmarkKinds[kindIndex]);
    }
    const auto end = std::chrono::steady_clock::now();
    gTouchSink = benchmarkTouches.serial + benchmarkTouches.totalTouches +
        benchmarkTouches.drawTouches + benchmarkTouches.dispatchTouches;
    const auto nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
        end - start).count();
    expect(state, benchmarkTouches.serial == iterations,
           "benchmark serial count");
    expect(state, benchmarkTouches.totalTouches == iterations,
           "benchmark total count");
    std::cout << "r5 touch benchmark ns_per_touch="
              << (static_cast<double>(nanos) /
                  static_cast<double>(iterations))
              << "\n";
}

}  // namespace

int main() {
    ProbeState state;
    runClassifierProbe(state);
    runTouchProbe(state);

    if (state.failures != 0) {
        std::cerr << state.failures << " R5 residency dry-run probe failures\n";
        return EXIT_FAILURE;
    }
    std::cout << "R5 residency dry-run probe passed\n";
    return EXIT_SUCCESS;
}
