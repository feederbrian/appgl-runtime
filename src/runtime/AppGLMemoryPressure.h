#pragma once

#include <memory>

#include "../context/MetalMemoryPressure.h"

namespace appgl {

class MemoryPressureObserver {
public:
    explicit MemoryPressureObserver(bool enableDispatchSource = true);
    ~MemoryPressureObserver();

    MemoryPressureObserver(const MemoryPressureObserver&) = delete;
    MemoryPressureObserver& operator=(const MemoryPressureObserver&) = delete;

    MetalMemoryPressureSnapshot sample(MetalMemoryPressureInputs inputs);
    MetalMemoryPressureSnapshot sampleAndConsumePending(
        MetalMemoryPressureInputs inputs);
    void injectOSPressureForTesting(MetalOSMemoryPressureLevel level);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
