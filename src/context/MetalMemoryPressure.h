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

enum class MetalMemoryPressureClass : std::uint8_t {
    Unknown = 0,
    Low = 1,
    Mid = 2,
    High = 3,
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
    std::uint64_t processPhysicalFootprintBytes = 0;
    std::uint64_t processPhysicalFootprintAvailable = 0;
    std::uint64_t processHeapBytes = 0;
    std::uint64_t processHeapAvailable = 0;
    std::uint64_t processHeapBlocksInUse = 0;
    std::uint64_t processHeapMaxBytesInUse = 0;
    std::uint64_t processHeapAllocatedBytes = 0;
    std::uint64_t processHeapMinusTrackedHostCacheBytes = 0;
    std::uint64_t processHeapAllocatedMinusTrackedHostCacheBytes = 0;
    std::uint64_t processHeapAllZonesBytes = 0;
    std::uint64_t processHeapAllZonesBlocksInUse = 0;
    std::uint64_t processHeapAllZonesMaxBytesInUse = 0;
    std::uint64_t processHeapAllZonesAllocatedBytes = 0;
    std::uint64_t processHeapAllZonesCount = 0;
    std::uint64_t processHeapNonDefaultZoneBytes = 0;
    std::uint64_t processHeapNonDefaultZoneBlocksInUse = 0;
    std::uint64_t processHeapNonDefaultZoneAllocatedBytes = 0;
    std::uint64_t processMachPortsEnabled = 0;
    std::uint64_t processMachPortsAvailable = 0;
    std::uint64_t processMachPortSampleKernReturn = 0;
    std::uint64_t processMachPortNames = 0;
    std::uint64_t processMachPortTypeNames = 0;
    std::uint64_t processMachPortTypeCountMismatch = 0;
    std::uint64_t processMachPortSendNames = 0;
    std::uint64_t processMachPortReceiveNames = 0;
    std::uint64_t processMachPortSendOnceNames = 0;
    std::uint64_t processMachPortPortSetNames = 0;
    std::uint64_t processMachPortDeadNameNames = 0;
    std::uint64_t processMachPortDnRequestNames = 0;
    std::uint64_t processMachPortSpRequestNames = 0;
    std::uint64_t processMachPortSpRequestDelayedNames = 0;
    std::uint64_t processMachPortGuardedNames = 0;
    std::uint64_t processMachPortImmovableReceiveNames = 0;
    std::uint64_t processMachPortUnknownTypeNames = 0;
    std::uint64_t processMachPortUnknownTypeMask = 0;
    std::uint64_t memoryClass = 0;
    std::uint64_t osPressure = 0;
    std::uint64_t lastPressureEvent = 0;
    std::uint64_t lastPressureEventSequence = 0;
    std::uint64_t pendingPressurePeak = 0;
    std::uint64_t pendingPressureEventSequence = 0;
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

inline std::uint64_t metalMemoryPressureClassValue(
    MetalMemoryPressureClass memoryClass) {
    return static_cast<std::uint64_t>(memoryClass);
}

inline MetalMemoryPressureClass metalMemoryPressureClassFromValue(
    std::uint64_t value) {
    if (value >= metalMemoryPressureClassValue(
            MetalMemoryPressureClass::High)) {
        return MetalMemoryPressureClass::High;
    }
    if (value >= metalMemoryPressureClassValue(MetalMemoryPressureClass::Mid)) {
        return MetalMemoryPressureClass::Mid;
    }
    if (value >= metalMemoryPressureClassValue(MetalMemoryPressureClass::Low)) {
        return MetalMemoryPressureClass::Low;
    }
    return MetalMemoryPressureClass::Unknown;
}

inline MetalMemoryPressureClass metalMemoryPressureClassForWorkingSet(
    std::uint64_t recommendedWorkingSetBytes,
    bool recommendedWorkingSetAvailable) {
    if (!recommendedWorkingSetAvailable || recommendedWorkingSetBytes == 0) {
        return MetalMemoryPressureClass::Unknown;
    }
    constexpr std::uint64_t kGiB = 1024ull * 1024ull * 1024ull;
    constexpr std::uint64_t kLowWorkingSetCeiling = 8ull * kGiB;
    constexpr std::uint64_t kHighWorkingSetFloor = 24ull * kGiB;
    if (recommendedWorkingSetBytes < kLowWorkingSetCeiling) {
        return MetalMemoryPressureClass::Low;
    }
    if (recommendedWorkingSetBytes >= kHighWorkingSetFloor) {
        return MetalMemoryPressureClass::High;
    }
    return MetalMemoryPressureClass::Mid;
}

inline MetalMemoryPressureWatermarks metalMemoryPressureWatermarksForClass(
    MetalMemoryPressureClass memoryClass) {
    MetalMemoryPressureWatermarks watermarks;
    switch (memoryClass) {
    case MetalMemoryPressureClass::Low:
        watermarks.softTargetPermyriad = 7000;
        watermarks.hardTargetPermyriad = 9000;
        watermarks.criticalTargetPermyriad = 10000;
        watermarks.softExitPermyriad = 6200;
        watermarks.hardExitPermyriad = 8000;
        watermarks.criticalExitPermyriad = 9000;
        break;
    case MetalMemoryPressureClass::High:
        watermarks.softTargetPermyriad = 8800;
        watermarks.hardTargetPermyriad = 11000;
        watermarks.criticalTargetPermyriad = 12500;
        watermarks.softExitPermyriad = 8000;
        watermarks.hardExitPermyriad = 10000;
        watermarks.criticalExitPermyriad = 11000;
        break;
    case MetalMemoryPressureClass::Mid:
    case MetalMemoryPressureClass::Unknown:
        break;
    }
    return watermarks;
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
