#include <cstdlib>
#include <iostream>
#include <string>

#include "../src/context/MetalMemoryPressure.h"
#include "../src/runtime/AppGLMemoryPressure.h"

namespace {

struct ProbeState {
    int failures = 0;
};

void expect(ProbeState& state, bool condition, const std::string& message) {
    if (!condition) {
        ++state.failures;
        std::cerr << "FAIL: " << message << "\n";
    }
}

appgl::MetalMemoryPressureInputs ratioInput(std::uint64_t current,
                                            std::uint64_t recommended) {
    appgl::MetalMemoryPressureInputs inputs;
    inputs.currentAllocatedBytes = current;
    inputs.recommendedWorkingSetBytes = recommended;
    inputs.recommendedWorkingSetAvailable = recommended != 0 ? 1 : 0;
    return inputs;
}

void expectState(ProbeState& state,
                 const appgl::MetalMemoryPressureSnapshot& snapshot,
                 appgl::MetalMemoryPressureState expected,
                 const std::string& label) {
    expect(state,
           snapshot.state == appgl::metalMemoryPressureStateValue(expected),
           label + " state");
}

void runHysteresisProbe(ProbeState& state) {
    appgl::MetalMemoryPressureStateMachine machine;

    auto snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                     ratioInput(0, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "initial idle");
    expect(state, snapshot.workingSetRatioValid == 1, "initial ratio valid");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(800, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Soft,
                "soft enter at 80%");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(999, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Soft,
                "soft holds below hard target");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(1000, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Hard,
                "hard enter at 100%");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(1099, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Hard,
                "hard holds below critical target");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(1100, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Critical,
                "critical enter at 110%");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(1050, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Critical,
                "critical hysteresis holds above critical exit");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(999, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Hard,
                "critical exits to hard below 100%");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(890, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Soft,
                "hard exits to soft below 90%");

    snapshot = appgl::sampleMetalMemoryPressure(machine,
                                                ratioInput(710, 1000));
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "soft exits to idle below 72%");

    expect(state, snapshot.stateTransitionCount == 6,
           "expected transition count across full hysteresis ladder");
    expect(state, snapshot.softTransitionCount == 2,
           "soft transition count");
    expect(state, snapshot.hardTransitionCount == 2,
           "hard transition count");
    expect(state, snapshot.criticalTransitionCount == 1,
           "critical transition count");
}

void runOSOnlyProbe(ProbeState& state) {
    appgl::MetalMemoryPressureStateMachine machine;
    auto inputs = ratioInput(999999, 0);

    auto snapshot = appgl::sampleMetalMemoryPressure(machine, inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "unavailable WSS stays idle without OS pressure");
    expect(state, snapshot.workingSetRatioValid == 0,
           "unavailable WSS disables ratio");
    expect(state, snapshot.workingSetRatioPermyriad == 0,
           "unavailable WSS reports zero ratio");

    inputs.osPressure = static_cast<std::uint64_t>(
        appgl::MetalOSMemoryPressureLevel::Warning);
    snapshot = appgl::sampleMetalMemoryPressure(machine, inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Soft,
                "OS warning forces soft without ratio");

    inputs.osPressure = static_cast<std::uint64_t>(
        appgl::MetalOSMemoryPressureLevel::Critical);
    snapshot = appgl::sampleMetalMemoryPressure(machine, inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Critical,
                "OS critical forces critical without ratio");

    inputs.osPressure = static_cast<std::uint64_t>(
        appgl::MetalOSMemoryPressureLevel::None);
    snapshot = appgl::sampleMetalMemoryPressure(machine, inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "OS-only state clears when OS pressure clears");
}

void runObserverInjectionProbe(ProbeState& state) {
    appgl::MemoryPressureObserver observer(false);
    auto inputs = ratioInput(0, 0);
    inputs.cbPressureReserveSlots = 4;
    inputs.cbPressureSoftCapSlots = 1;
    inputs.cbPressureFlushCount = 42;
    inputs.cbCurrentInFlight = 0;
    inputs.cbInFlightBound = 5;

    auto snapshot = observer.sample(inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "observer initial idle");

    observer.injectOSPressureForTesting(
        appgl::MetalOSMemoryPressureLevel::Warning);
    snapshot = observer.sample(inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Soft,
                "observer warning injection");
    expect(state, snapshot.inputs.warningEventCount == 1,
           "observer warning count");
    expect(state, snapshot.inputs.cbPressureFlushCount == 42,
           "observer does not consume reserve/flush on warning");
    expect(state, snapshot.inputs.cbPressureReserveSlots == 4,
           "observer reports reserve slots");
    expect(state, snapshot.inputs.cbPressureSoftCapSlots == 1,
           "observer reports soft cap slots");

    observer.injectOSPressureForTesting(
        appgl::MetalOSMemoryPressureLevel::Critical);
    snapshot = observer.sample(inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Critical,
                "observer critical injection");
    expect(state, snapshot.inputs.criticalEventCount == 1,
           "observer critical count");
    expect(state, snapshot.inputs.lastPressureEventSequence == 2,
           "observer event sequence");
    expect(state, snapshot.inputs.cbPressureFlushCount == 42,
           "observer does not consume reserve/flush on critical");

    observer.injectOSPressureForTesting(appgl::MetalOSMemoryPressureLevel::None);
    snapshot = observer.sample(inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "observer clear injection");
    expect(state, snapshot.inputs.lastPressureEventSequence == 3,
           "observer clear increments sequence");
    expect(state,
           snapshot.inputs.pendingPressurePeak ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Critical),
           "observer retains pending critical peak across clear");

    snapshot = observer.sampleAndConsumePending(inputs);
    expectState(state, snapshot, appgl::MetalMemoryPressureState::Idle,
                "observer consume leaves current state idle");
    expect(state,
           snapshot.inputs.pendingPressurePeak ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Critical),
           "observer consume reports pending critical peak");

    snapshot = observer.sample(inputs);
    expect(state,
           snapshot.inputs.pendingPressurePeak ==
               appgl::metalMemoryPressureStateValue(
                   appgl::MetalMemoryPressureState::Idle),
           "observer consume clears pending peak");
}

void runMemoryClassPolicyProbe(ProbeState& state) {
    constexpr std::uint64_t kGiB = 1024ull * 1024ull * 1024ull;
    appgl::MemoryPressureObserver observer(false);

    auto inputs = ratioInput(0, 4ull * kGiB);
    auto snapshot = observer.sample(inputs);
    expect(state,
           snapshot.inputs.memoryClass ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::Low),
           "low working-set memory class");
    expect(state, snapshot.watermarks.softTargetPermyriad == 7000,
           "low memory soft watermark");
    expect(state, snapshot.watermarks.criticalTargetPermyriad == 10000,
           "low memory critical watermark");

    inputs = ratioInput(0, 16ull * kGiB);
    snapshot = observer.sample(inputs);
    expect(state,
           snapshot.inputs.memoryClass ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::Mid),
           "mid working-set memory class");
    expect(state, snapshot.watermarks.softTargetPermyriad == 8000,
           "mid memory soft watermark");
    expect(state, snapshot.watermarks.criticalTargetPermyriad == 11000,
           "mid memory critical watermark");

    inputs = ratioInput(0, 32ull * kGiB);
    snapshot = observer.sample(inputs);
    expect(state,
           snapshot.inputs.memoryClass ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::High),
           "high working-set memory class");
    expect(state, snapshot.watermarks.softTargetPermyriad == 8800,
           "high memory soft watermark");
    expect(state, snapshot.watermarks.criticalTargetPermyriad == 12500,
           "high memory critical watermark");

    inputs = ratioInput(0, 32ull * kGiB);
    inputs.memoryClass =
        appgl::metalMemoryPressureClassValue(
            appgl::MetalMemoryPressureClass::Low);
    snapshot = observer.sample(inputs);
    expect(state,
           snapshot.inputs.memoryClass ==
               appgl::metalMemoryPressureClassValue(
                   appgl::MetalMemoryPressureClass::Low),
           "injected memory class overrides working-set classification");
    expect(state, snapshot.watermarks.softTargetPermyriad == 7000,
           "injected low memory class uses low watermarks");
}

}  // namespace

int main() {
    ProbeState state;
    runHysteresisProbe(state);
    runOSOnlyProbe(state);
    runObserverInjectionProbe(state);
    runMemoryClassPolicyProbe(state);

    if (state.failures != 0) {
        std::cerr << state.failures << " memory pressure probe failures\n";
        return EXIT_FAILURE;
    }
    std::cout << "memory pressure probe passed\n";
    return EXIT_SUCCESS;
}
