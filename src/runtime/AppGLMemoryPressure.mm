#include "AppGLMemoryPressure.h"

#include <atomic>
#include <cstdint>
#include <dispatch/dispatch.h>
#include <memory>
#include <mutex>

namespace appgl {

namespace {

struct AtomicPressureState {
    std::atomic<std::uint64_t> osPressure{
        static_cast<std::uint64_t>(MetalOSMemoryPressureLevel::None)};
    std::atomic<std::uint64_t> lastEventMask{0};
    std::atomic<std::uint64_t> eventSequence{0};
    std::atomic<std::uint64_t> pendingPressurePeak{
        metalMemoryPressureStateValue(MetalMemoryPressureState::Idle)};
    std::atomic<std::uint64_t> pendingPressureEventSequence{0};
    std::atomic<std::uint64_t> warningEventCount{0};
    std::atomic<std::uint64_t> criticalEventCount{0};
};

struct DispatchPressureContext {
    dispatch_source_t source = nullptr;
    AtomicPressureState* state = nullptr;
};

MetalOSMemoryPressureLevel memoryPressureLevelFromDispatchMask(
    unsigned long mask) {
#ifdef DISPATCH_MEMORYPRESSURE_CRITICAL
    if ((mask & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0) {
        return MetalOSMemoryPressureLevel::Critical;
    }
#endif
#ifdef DISPATCH_MEMORYPRESSURE_WARN
    if ((mask & DISPATCH_MEMORYPRESSURE_WARN) != 0) {
        return MetalOSMemoryPressureLevel::Warning;
    }
#endif
    return MetalOSMemoryPressureLevel::None;
}

std::uint64_t syntheticMaskForLevel(MetalOSMemoryPressureLevel level) {
    switch (level) {
    case MetalOSMemoryPressureLevel::Warning:
#ifdef DISPATCH_MEMORYPRESSURE_WARN
        return DISPATCH_MEMORYPRESSURE_WARN;
#else
        return 1;
#endif
    case MetalOSMemoryPressureLevel::Critical:
#ifdef DISPATCH_MEMORYPRESSURE_CRITICAL
        return DISPATCH_MEMORYPRESSURE_CRITICAL;
#else
        return 2;
#endif
    case MetalOSMemoryPressureLevel::None:
        return 0;
    }
    return 0;
}

MetalMemoryPressureState pressureStateForOSLevel(
    MetalOSMemoryPressureLevel level) {
    switch (level) {
    case MetalOSMemoryPressureLevel::Warning:
        return MetalMemoryPressureState::Soft;
    case MetalOSMemoryPressureLevel::Critical:
        return MetalMemoryPressureState::Critical;
    case MetalOSMemoryPressureLevel::None:
        return MetalMemoryPressureState::Idle;
    }
    return MetalMemoryPressureState::Idle;
}

void latchPendingPressurePeak(AtomicPressureState& state,
                              MetalMemoryPressureState peak,
                              std::uint64_t sequence) {
    const std::uint64_t peakValue = metalMemoryPressureStateValue(peak);
    if (peakValue == metalMemoryPressureStateValue(
            MetalMemoryPressureState::Idle)) {
        return;
    }
    state.pendingPressureEventSequence.store(sequence,
                                             std::memory_order_release);
    std::uint64_t current =
        state.pendingPressurePeak.load(std::memory_order_acquire);
    while (current < peakValue &&
           !state.pendingPressurePeak.compare_exchange_weak(
               current,
               peakValue,
               std::memory_order_acq_rel,
               std::memory_order_acquire)) {
    }
}

void recordPressureEvent(AtomicPressureState& state,
                         std::uint64_t eventMask,
                         MetalOSMemoryPressureLevel level) {
    state.lastEventMask.store(eventMask, std::memory_order_relaxed);
    state.osPressure.store(static_cast<std::uint64_t>(level),
                           std::memory_order_release);
    const std::uint64_t sequence =
        state.eventSequence.fetch_add(1, std::memory_order_relaxed) + 1;
    latchPendingPressurePeak(state, pressureStateForOSLevel(level), sequence);
    if (level == MetalOSMemoryPressureLevel::Critical) {
        state.criticalEventCount.fetch_add(1, std::memory_order_relaxed);
    } else if (level == MetalOSMemoryPressureLevel::Warning) {
        state.warningEventCount.fetch_add(1, std::memory_order_relaxed);
    }
}

void memoryPressureEventHandler(void* rawContext) {
    auto* context = static_cast<DispatchPressureContext*>(rawContext);
    if (context == nullptr || context->source == nullptr ||
        context->state == nullptr) {
        return;
    }
    const unsigned long eventMask = dispatch_source_get_data(context->source);
    recordPressureEvent(*context->state,
                        static_cast<std::uint64_t>(eventMask),
                        memoryPressureLevelFromDispatchMask(eventMask));
}

void dispatchNoop(void*) {}

}  // namespace

struct MemoryPressureObserver::Impl {
    explicit Impl(bool enableDispatchSource) {
        if (enableDispatchSource) {
            startDispatchSource();
        }
    }

    ~Impl() {
        stopDispatchSource();
    }

    void startDispatchSource() {
#ifdef DISPATCH_SOURCE_TYPE_MEMORYPRESSURE
        queue = dispatch_queue_create("com.appgl.memory-pressure",
                                      DISPATCH_QUEUE_SERIAL);
        if (queue == nullptr) {
            return;
        }

        unsigned long mask = 0;
#ifdef DISPATCH_MEMORYPRESSURE_NORMAL
        mask |= DISPATCH_MEMORYPRESSURE_NORMAL;
#endif
#ifdef DISPATCH_MEMORYPRESSURE_WARN
        mask |= DISPATCH_MEMORYPRESSURE_WARN;
#endif
#ifdef DISPATCH_MEMORYPRESSURE_CRITICAL
        mask |= DISPATCH_MEMORYPRESSURE_CRITICAL;
#endif
        if (mask == 0) {
            stopDispatchSource();
            return;
        }

        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
                                        0,
                                        mask,
                                        queue);
        if (source == nullptr) {
            stopDispatchSource();
            return;
        }
        dispatchContext.source = source;
        dispatchContext.state = &atomicState;
        dispatch_set_context(source, &dispatchContext);
        dispatch_source_set_event_handler_f(source, memoryPressureEventHandler);
        dispatch_resume(source);
#endif
    }

    void stopDispatchSource() {
        if (source != nullptr) {
            dispatch_source_cancel(source);
            if (queue != nullptr) {
                dispatch_sync_f(queue, nullptr, dispatchNoop);
            }
#if !OS_OBJECT_USE_OBJC
            dispatch_release(source);
#endif
            source = nullptr;
            dispatchContext.source = nullptr;
            dispatchContext.state = nullptr;
        }
        if (queue != nullptr) {
#if !OS_OBJECT_USE_OBJC
            dispatch_release(queue);
#endif
            queue = nullptr;
        }
    }

    MetalMemoryPressureSnapshot sample(MetalMemoryPressureInputs inputs,
                                       bool consumePending) {
        inputs.osPressure =
            atomicState.osPressure.load(std::memory_order_acquire);
        inputs.lastPressureEvent =
            atomicState.lastEventMask.load(std::memory_order_relaxed);
        inputs.lastPressureEventSequence =
            atomicState.eventSequence.load(std::memory_order_relaxed);
        MetalMemoryPressureClass memoryClass =
            metalMemoryPressureClassFromValue(inputs.memoryClass);
        if (memoryClass == MetalMemoryPressureClass::Unknown) {
            memoryClass = metalMemoryPressureClassForWorkingSet(
                inputs.recommendedWorkingSetBytes,
                inputs.recommendedWorkingSetAvailable != 0);
        }
        inputs.memoryClass = metalMemoryPressureClassValue(memoryClass);
        inputs.pendingPressurePeak = consumePending
            ? atomicState.pendingPressurePeak.exchange(
                  metalMemoryPressureStateValue(MetalMemoryPressureState::Idle),
                  std::memory_order_acq_rel)
            : atomicState.pendingPressurePeak.load(std::memory_order_acquire);
        inputs.pendingPressureEventSequence =
            atomicState.pendingPressureEventSequence.load(
                std::memory_order_acquire);
        inputs.warningEventCount =
            atomicState.warningEventCount.load(std::memory_order_relaxed);
        inputs.criticalEventCount =
            atomicState.criticalEventCount.load(std::memory_order_relaxed);

        std::lock_guard<std::mutex> lock(stateMutex);
        return sampleMetalMemoryPressure(stateMachine,
                                         inputs,
                                         watermarksForInputs(inputs));
    }

    void injectOSPressureForTesting(MetalOSMemoryPressureLevel level) {
        recordPressureEvent(atomicState, syntheticMaskForLevel(level), level);
    }

    MetalMemoryPressureWatermarks watermarksForInputs(
        const MetalMemoryPressureInputs& inputs) const {
        const MetalMemoryPressureClass memoryClass =
            metalMemoryPressureClassFromValue(inputs.memoryClass);
        if (memoryClass != MetalMemoryPressureClass::Unknown &&
            memoryClass != MetalMemoryPressureClass::Mid) {
            return metalMemoryPressureWatermarksForClass(memoryClass);
        }
        return watermarks;
    }

    AtomicPressureState atomicState;
    std::mutex stateMutex;
    MetalMemoryPressureStateMachine stateMachine;
    MetalMemoryPressureWatermarks watermarks;
    dispatch_queue_t queue = nullptr;
    dispatch_source_t source = nullptr;
    DispatchPressureContext dispatchContext;
};

MemoryPressureObserver::MemoryPressureObserver(bool enableDispatchSource)
    : impl_(std::make_unique<Impl>(enableDispatchSource)) {}

MemoryPressureObserver::~MemoryPressureObserver() = default;

MetalMemoryPressureSnapshot MemoryPressureObserver::sample(
    MetalMemoryPressureInputs inputs) {
    return impl_->sample(inputs, false);
}

MetalMemoryPressureSnapshot MemoryPressureObserver::sampleAndConsumePending(
    MetalMemoryPressureInputs inputs) {
    return impl_->sample(inputs, true);
}

void MemoryPressureObserver::injectOSPressureForTesting(
    MetalOSMemoryPressureLevel level) {
    impl_->injectOSPressureForTesting(level);
}

}  // namespace appgl
