#pragma once

#include <cstdint>
#include <limits>
#include <type_traits>

namespace appgl {

enum class MetalMemoryPressureState : std::uint8_t {
    Idle = 0,
    Soft = 1,
    Hard = 2,
    Critical = 3,
};

enum class MetalOSMemoryPressureLevel : std::uint8_t {
    None = 0,
    Warning = 1,
    Critical = 2,
};

struct MetalMemoryPressureWatermarks {
    std::uint64_t softTargetPermyriad = 8000;
    std::uint64_t hardTargetPermyriad = 10000;
    std::uint64_t criticalTargetPermyriad = 11000;
    std::uint64_t softExitPermyriad = 7200;
    std::uint64_t hardExitPermyriad = 9000;
    std::uint64_t criticalExitPermyriad = 10000;
};

struct MetalMemoryPressureInputs {
    std::uint64_t currentAllocatedBytes = 0;
    std::uint64_t recommendedWorkingSetBytes = 0;
    std::uint64_t recommendedWorkingSetAvailable = 0;
    std::uint64_t trackedHostHeapBytes = 0;
    std::uint64_t trackedHostCacheBytes = 0;
    std::uint64_t processResidentBytes = 0;
    std::uint64_t processResidentAvailable = 0;
    std::uint64_t processHeapBytes = 0;
    std::uint64_t processHeapAvailable = 0;
    std::uint64_t osPressure = 0;
    std::uint64_t lastPressureEvent = 0;
    std::uint64_t lastPressureEventSequence = 0;
    std::uint64_t warningEventCount = 0;
    std::uint64_t criticalEventCount = 0;
    std::uint64_t cbPressureReserveSlots = 0;
    std::uint64_t cbPressureSoftCapSlots = 0;
    std::uint64_t cbPressureFlushCount = 0;
    std::uint64_t cbCurrentInFlight = 0;
    std::uint64_t cbInFlightBound = 0;
};

struct MetalMemoryPressureStateMachine {
    MetalMemoryPressureState state = MetalMemoryPressureState::Idle;
    std::uint64_t stateTransitionCount = 0;
    std::uint64_t softTransitionCount = 0;
    std::uint64_t hardTransitionCount = 0;
    std::uint64_t criticalTransitionCount = 0;
};

struct MetalMemoryPressureSnapshot {
    MetalMemoryPressureInputs inputs;
    MetalMemoryPressureWatermarks watermarks;
    std::uint64_t workingSetRatioPermyriad = 0;
    std::uint64_t workingSetRatioValid = 0;
    double workingSetRatio = 0.0;
    std::uint64_t state = 0;
    std::uint64_t stateTransitionCount = 0;
    std::uint64_t softTransitionCount = 0;
    std::uint64_t hardTransitionCount = 0;
    std::uint64_t criticalTransitionCount = 0;
};

inline std::uint64_t metalMemoryPressureStateValue(
    MetalMemoryPressureState state) {
    return static_cast<std::uint64_t>(state);
}

inline MetalOSMemoryPressureLevel metalOSMemoryPressureLevel(
    std::uint64_t level) {
    if (level >= static_cast<std::uint64_t>(
            MetalOSMemoryPressureLevel::Critical)) {
        return MetalOSMemoryPressureLevel::Critical;
    }
    if (level == static_cast<std::uint64_t>(
            MetalOSMemoryPressureLevel::Warning)) {
        return MetalOSMemoryPressureLevel::Warning;
    }
    return MetalOSMemoryPressureLevel::None;
}

inline std::uint64_t metalMemoryPressurePermyriad(
    std::uint64_t numerator,
    std::uint64_t denominator) {
    if (denominator == 0) {
        return 0;
    }
    const unsigned __int128 scaled =
        static_cast<unsigned __int128>(numerator) * 10000u / denominator;
    constexpr auto maxValue = std::numeric_limits<std::uint64_t>::max();
    if (scaled > static_cast<unsigned __int128>(maxValue)) {
        return maxValue;
    }
    return static_cast<std::uint64_t>(scaled);
}

inline void metalMemoryPressureRecordTransition(
    MetalMemoryPressureStateMachine& machine,
    MetalMemoryPressureState previous,
    MetalMemoryPressureState next) {
    if (previous == next) {
        return;
    }
    ++machine.stateTransitionCount;
    switch (next) {
    case MetalMemoryPressureState::Soft:
        ++machine.softTransitionCount;
        break;
    case MetalMemoryPressureState::Hard:
        ++machine.hardTransitionCount;
        break;
    case MetalMemoryPressureState::Critical:
        ++machine.criticalTransitionCount;
        break;
    case MetalMemoryPressureState::Idle:
        break;
    }
}

inline MetalMemoryPressureState metalMemoryPressureNextState(
    MetalMemoryPressureState current,
    const MetalMemoryPressureInputs& inputs,
    const MetalMemoryPressureWatermarks& watermarks,
    std::uint64_t ratioPermyriad,
    bool ratioValid) {
    const auto osLevel = metalOSMemoryPressureLevel(inputs.osPressure);
    if (osLevel == MetalOSMemoryPressureLevel::Critical) {
        return MetalMemoryPressureState::Critical;
    }

    const bool osWarning = osLevel == MetalOSMemoryPressureLevel::Warning;
    if (!ratioValid) {
        return osWarning ? MetalMemoryPressureState::Soft
                         : MetalMemoryPressureState::Idle;
    }

    switch (current) {
    case MetalMemoryPressureState::Critical:
        if (ratioPermyriad >= watermarks.criticalExitPermyriad) {
            return MetalMemoryPressureState::Critical;
        }
        if (ratioPermyriad >= watermarks.hardExitPermyriad) {
            return MetalMemoryPressureState::Hard;
        }
        if (ratioPermyriad >= watermarks.softExitPermyriad || osWarning) {
            return MetalMemoryPressureState::Soft;
        }
        return MetalMemoryPressureState::Idle;

    case MetalMemoryPressureState::Hard:
        if (ratioPermyriad >= watermarks.criticalTargetPermyriad) {
            return MetalMemoryPressureState::Critical;
        }
        if (ratioPermyriad >= watermarks.hardExitPermyriad) {
            return MetalMemoryPressureState::Hard;
        }
        if (ratioPermyriad >= watermarks.softExitPermyriad || osWarning) {
            return MetalMemoryPressureState::Soft;
        }
        return MetalMemoryPressureState::Idle;

    case MetalMemoryPressureState::Soft:
        if (ratioPermyriad >= watermarks.criticalTargetPermyriad) {
            return MetalMemoryPressureState::Critical;
        }
        if (ratioPermyriad >= watermarks.hardTargetPermyriad) {
            return MetalMemoryPressureState::Hard;
        }
        if (ratioPermyriad >= watermarks.softExitPermyriad || osWarning) {
            return MetalMemoryPressureState::Soft;
        }
        return MetalMemoryPressureState::Idle;

    case MetalMemoryPressureState::Idle:
        if (ratioPermyriad >= watermarks.criticalTargetPermyriad) {
            return MetalMemoryPressureState::Critical;
        }
        if (ratioPermyriad >= watermarks.hardTargetPermyriad) {
            return MetalMemoryPressureState::Hard;
        }
        if (ratioPermyriad >= watermarks.softTargetPermyriad || osWarning) {
            return MetalMemoryPressureState::Soft;
        }
        return MetalMemoryPressureState::Idle;
    }
    return MetalMemoryPressureState::Idle;
}

inline MetalMemoryPressureSnapshot sampleMetalMemoryPressure(
    MetalMemoryPressureStateMachine& machine,
    MetalMemoryPressureInputs inputs,
    const MetalMemoryPressureWatermarks& watermarks =
        MetalMemoryPressureWatermarks{}) {
    const bool ratioValid = inputs.recommendedWorkingSetAvailable != 0 &&
        inputs.recommendedWorkingSetBytes != 0;
    const std::uint64_t ratioPermyriad =
        ratioValid ? metalMemoryPressurePermyriad(
                         inputs.currentAllocatedBytes,
                         inputs.recommendedWorkingSetBytes)
                   : 0;

    const MetalMemoryPressureState previous = machine.state;
    const MetalMemoryPressureState next = metalMemoryPressureNextState(
        previous, inputs, watermarks, ratioPermyriad, ratioValid);
    metalMemoryPressureRecordTransition(machine, previous, next);
    machine.state = next;

    MetalMemoryPressureSnapshot snapshot;
    snapshot.inputs = inputs;
    snapshot.watermarks = watermarks;
    snapshot.workingSetRatioPermyriad = ratioPermyriad;
    snapshot.workingSetRatioValid = ratioValid ? 1 : 0;
    snapshot.workingSetRatio = ratioValid
        ? static_cast<double>(inputs.currentAllocatedBytes) /
              static_cast<double>(inputs.recommendedWorkingSetBytes)
        : 0.0;
    snapshot.state = metalMemoryPressureStateValue(machine.state);
    snapshot.stateTransitionCount = machine.stateTransitionCount;
    snapshot.softTransitionCount = machine.softTransitionCount;
    snapshot.hardTransitionCount = machine.hardTransitionCount;
    snapshot.criticalTransitionCount = machine.criticalTransitionCount;
    return snapshot;
}

static_assert(std::is_standard_layout<MetalMemoryPressureWatermarks>::value,
              "MetalMemoryPressureWatermarks must remain POD-shaped");
static_assert(std::is_standard_layout<MetalMemoryPressureInputs>::value,
              "MetalMemoryPressureInputs must remain POD-shaped");
static_assert(std::is_standard_layout<MetalMemoryPressureStateMachine>::value,
              "MetalMemoryPressureStateMachine must remain POD-shaped");
static_assert(std::is_standard_layout<MetalMemoryPressureSnapshot>::value,
              "MetalMemoryPressureSnapshot must remain POD-shaped");

}  // namespace appgl
