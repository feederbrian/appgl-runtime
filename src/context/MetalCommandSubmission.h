#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "AppGLCommandReasons.h"

#include <array>
#include <cassert>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

namespace appgl {

class MetalCommandSubmission;

inline NSString* appGLCommandReasonNSString(AppGLCommandReason reason) {
    return [NSString stringWithUTF8String:appGLCommandReasonRecord(reason).legacyLabel];
}

class MetalCommandBufferLease {
public:
    MetalCommandBufferLease() = default;
    MetalCommandBufferLease(const MetalCommandBufferLease&) = delete;
    MetalCommandBufferLease& operator=(const MetalCommandBufferLease&) = delete;

    MetalCommandBufferLease(MetalCommandBufferLease&& other) noexcept {
        moveFrom(std::move(other));
    }

    MetalCommandBufferLease& operator=(MetalCommandBufferLease&& other) noexcept {
        if (this != &other) {
            abandon("move-assign");
            moveFrom(std::move(other));
        }
        return *this;
    }

    ~MetalCommandBufferLease() {
        abandon("destruct");
    }

    id<MTLCommandBuffer> get() const { return commandBuffer_; }
    explicit operator bool() const { return commandBuffer_ != nil; }

    void abandon(const char* reason = "abandon") {
        if (ownsToken_ && !tokenReleaseTransferred_) {
            releaseToken(state_, released_, reason);
        }
        if (retainedObjects_ && !retainedReleaseTransferred_) {
            releaseRetainedObjects(retainedObjects_);
        }
        commandBuffer_ = nil;
        ownsToken_ = false;
        tokenReleaseTransferred_ = false;
        retainedReleaseTransferred_ = false;
        state_.reset();
        released_.reset();
        retainedObjects_.reset();
    }

    // Transfer an Objective-C +1 object to this command buffer lease. The
    // completion handler releases it, bounding transient Metal resources by
    // the outstanding command-buffer count instead of the process lifetime.
    void adoptRetainedObject(id object) {
        if (object == nil || !retainedObjects_) {
            return;
        }
        const std::uint64_t approxBytes = retainedObjectApproxBytes(object);
        retainedObjects_->objects.push_back((__bridge void*)object);
        retainedObjects_->adoptedObjectCount += 1;
        retainedObjects_->adoptedApproxBytes += approxBytes;
        recordRetainedObjectAdopted(retainedObjects_->state.lock(), approxBytes);
    }

    void retainObjectUntilCompleted(id object) {
        if (object == nil) {
            return;
        }
        [object retain];
        adoptRetainedObject(object);
    }

    void commit(NSString* label = nil) {
        commitWithCompletion(label, nil);
    }

    void commit(AppGLCommandReason reason) {
        commitWithCompletion(reason, nil);
    }

    void commitWithCompletion(NSString* label, void (^completion)(id<MTLCommandBuffer>)) {
        commitWithCompletionImpl(label, AppGLCommandReason::Legacy, completion);
    }

    void commitWithCompletion(AppGLCommandReason reason, void (^completion)(id<MTLCommandBuffer>)) {
        commitWithCompletionImpl(appGLCommandReasonNSString(reason), reason, completion);
    }

    bool commitAndWait(NSString* label = nil);
    bool commitAndWait(AppGLCommandReason reason);

private:
    bool commitAndWaitImpl(NSString* label, AppGLCommandReason reason);

    void commitWithCompletionImpl(NSString* label,
                                  AppGLCommandReason reason,
                                  void (^completion)(id<MTLCommandBuffer>)) {
        if (commandBuffer_ == nil || !ownsToken_) {
            return;
        }
        auto state = state_;
        auto released = released_;
        auto retainedObjects = retainedObjects_;
        NSString* releaseLabel = label != nil ? label : commandBuffer_.label;
        void (^completionCopy)(id<MTLCommandBuffer>) = completion;
        const bool profileEnabled = state && state->profileEnabled;
        const auto submittedAt = profileEnabled
            ? std::chrono::steady_clock::now()
            : std::chrono::steady_clock::time_point{};
        recordSubmitted(state, reason, releaseLabel);
        [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completionCopy != nil) {
                completionCopy(completed);
            }
            recordCompleted(state, reason, releaseLabel, completed.status);
            recordCompletionLatency(state, reason, releaseLabel, submittedAt);
            releaseToken(state, released, releaseLabel.UTF8String);
            releaseRetainedObjects(retainedObjects);
        }];
        tokenReleaseTransferred_ = true;
        retainedReleaseTransferred_ = true;
        const auto commitStart = profileEnabled
            ? std::chrono::steady_clock::now()
            : std::chrono::steady_clock::time_point{};
        [commandBuffer_ commit];
        if (profileEnabled) {
            recordCommitCall(state, reason, releaseLabel, commitStart);
        }
        commandBuffer_ = nil;
        ownsToken_ = false;
    }

    struct SharedState {
        static std::uint32_t computePressureSoftCap(std::uint32_t bound,
                                                    std::uint32_t reserve) {
            return bound > reserve ? bound - reserve : 1;
        }

        explicit SharedState(std::uint32_t bound, std::uint32_t reserve)
            : inFlightBound(bound == 0 ? 1 : bound),
              pressureReserve(reserve),
              pressureSoftCap(computePressureSoftCap(inFlightBound, reserve)),
              inFlightSemaphore(dispatch_semaphore_create(static_cast<long>(inFlightBound))) {
            for (auto& allocationCount : allocatedByReason) {
                allocationCount.store(0);
            }
            for (auto& submissionCount : submittedByReason) {
                submissionCount.store(0);
            }
            for (auto& completionCount : completedByReason) {
                completionCount.store(0);
            }
            for (auto& timeoutCount : allocWaitTimeoutsByReason) {
                timeoutCount.store(0);
            }
        }

        ~SharedState() {
#if !__has_feature(objc_arc)
            if (inFlightSemaphore != nullptr) {
                dispatch_release(inFlightSemaphore);
            }
#endif
        }

        std::uint32_t inFlightBound = 0;
        std::uint32_t pressureReserve = 0;
        std::uint32_t pressureSoftCap = 0;
        dispatch_semaphore_t inFlightSemaphore = nullptr;
        bool profileEnabled = std::getenv("APPGL_CB_PROFILE") != nullptr;
        std::atomic<std::uint32_t> inFlightCount{0};
        std::atomic<std::uint32_t> peakInFlight{0};
        std::atomic<std::uint64_t> totalAllocated{0};
        std::atomic<std::uint64_t> totalCompleted{0};
        std::atomic<std::uint64_t> submittedCommandBuffers{0};
        std::atomic<std::uint64_t> completedCommandBuffers{0};
        std::array<std::atomic<std::uint64_t>,
                   static_cast<std::size_t>(AppGLCommandReason::Count)>
            allocatedByReason;
        std::array<std::atomic<std::uint64_t>,
                   static_cast<std::size_t>(AppGLCommandReason::Count)>
            submittedByReason;
        std::array<std::atomic<std::uint64_t>,
                   static_cast<std::size_t>(AppGLCommandReason::Count)>
            completedByReason;
        std::atomic<std::uint64_t> backpressureWaits{0};
        std::atomic<std::uint64_t> waitReasonLogEntries{0};
        // S24 census: drain-all (full-pipeline) waits were invisible in
        // the per-reason tables (Step-1 found 9.2s/210s hiding here) —
        // count + total wall time, unconditional.
        std::atomic<std::uint64_t> drainAllCalls{0};
        std::atomic<std::uint64_t> drainAllWaitUsTotal{0};
        std::atomic<std::uint64_t> plainCommandBufferAllocations{0};
        std::atomic<std::uint64_t> autoreleaseDrainedCommandBufferAllocations{0};
        std::atomic<std::uint64_t> retainedObjectsAdopted{0};
        std::atomic<std::uint64_t> retainedObjectsReleased{0};
        std::atomic<std::uint64_t> retainedObjectsLive{0};
        std::atomic<std::uint64_t> retainedObjectsPeakLive{0};
        std::atomic<std::uint64_t> retainedObjectApproxBytesAdopted{0};
        std::atomic<std::uint64_t> retainedObjectApproxBytesReleased{0};
        std::atomic<std::uint64_t> retainedObjectApproxBytesLive{0};
        std::atomic<std::uint64_t> retainedObjectApproxBytesPeakLive{0};
        std::atomic<std::uint64_t> retainedCommandBuffersLive{0};
        std::atomic<std::uint64_t> retainedCommandBuffersPeakLive{0};
        std::atomic<std::uint64_t> retainedCommandBuffersReleased{0};
        std::atomic<std::uint64_t> retainedReleaseCalls{0};
        std::atomic<std::uint64_t> retainedReleaseObjectMaxCount{0};
        std::atomic<std::uint64_t> retainedReleaseObjectMaxBytes{0};
        std::atomic<std::uint32_t> lastWaitReason{static_cast<std::uint32_t>(AppGLCommandReason::Legacy)};
        std::atomic<std::uint32_t> lastWaitMode{static_cast<std::uint32_t>(AppGLSubmitMode::WaitOnly)};
        std::atomic<std::uint32_t> lastWaitDependencyClass{static_cast<std::uint32_t>(AppGLDependencyClass::Legacy)};
        std::atomic<std::uint64_t> inFlightTimeouts{0};
        std::atomic<std::uint64_t> ringSlotTimeouts{0};
        std::atomic<std::uint64_t> completionTimeouts{0};
        std::atomic<std::uint64_t> drainAllTimeouts{0};
        std::atomic<std::uint64_t> pressureFlushCount{0};
        std::array<std::atomic<std::uint64_t>,
                   static_cast<std::size_t>(AppGLCommandReason::Count)>
            allocWaitTimeoutsByReason;
    };

    struct RetainedObjects {
        std::weak_ptr<SharedState> state;
        id<MTLCommandBuffer> commandBuffer = nil;
        std::vector<void*> objects;
        std::uint64_t adoptedObjectCount = 0;
        std::uint64_t adoptedApproxBytes = 0;
        bool commandBufferRetained = false;
    };

    friend class MetalCommandSubmission;

    MetalCommandBufferLease(std::shared_ptr<SharedState> state, id<MTLCommandBuffer> commandBuffer)
        : state_(std::move(state)),
          released_(std::make_shared<std::atomic_bool>(false)),
          retainedObjects_(std::make_shared<RetainedObjects>()),
          commandBuffer_(commandBuffer),
          ownsToken_(commandBuffer != nil) {
        retainedObjects_->state = state_;
        if (commandBuffer_ != nil) {
            [commandBuffer_ retain];
            retainedObjects_->commandBuffer = commandBuffer_;
            retainedObjects_->commandBufferRetained = true;
            recordCommandBufferRetained(state_);
        }
    }

    void moveFrom(MetalCommandBufferLease&& other) noexcept {
        state_ = std::move(other.state_);
        released_ = std::move(other.released_);
        retainedObjects_ = std::move(other.retainedObjects_);
        commandBuffer_ = other.commandBuffer_;
        ownsToken_ = other.ownsToken_;
        tokenReleaseTransferred_ = other.tokenReleaseTransferred_;
        retainedReleaseTransferred_ = other.retainedReleaseTransferred_;
        other.commandBuffer_ = nil;
        other.ownsToken_ = false;
        other.tokenReleaseTransferred_ = false;
        other.retainedReleaseTransferred_ = false;
    }

    static std::uint64_t retainedObjectApproxBytes(id object) {
        if (object == nil || ![object respondsToSelector:@selector(allocatedSize)]) {
            return 0;
        }
        return static_cast<std::uint64_t>([(id<MTLResource>)object allocatedSize]);
    }

    static void updatePeak(std::atomic<std::uint64_t>& peak,
                           std::uint64_t value) {
        std::uint64_t observed = peak.load();
        while (value > observed &&
               !peak.compare_exchange_weak(observed, value)) {}
    }

    static void boundedSubtract(std::atomic<std::uint64_t>& value,
                                std::uint64_t amount) {
        if (amount == 0) {
            return;
        }
        std::uint64_t observed = value.load();
        while (observed != 0) {
            const std::uint64_t next = observed > amount
                ? observed - amount
                : 0;
            if (value.compare_exchange_weak(observed, next)) {
                return;
            }
        }
    }

    static void recordRetainedObjectAdopted(
        const std::shared_ptr<SharedState>& state,
        std::uint64_t approxBytes) {
        if (!state) {
            return;
        }
        state->retainedObjectsAdopted.fetch_add(1);
        const std::uint64_t live =
            state->retainedObjectsLive.fetch_add(1) + 1;
        updatePeak(state->retainedObjectsPeakLive, live);
        if (approxBytes != 0) {
            state->retainedObjectApproxBytesAdopted.fetch_add(approxBytes);
            const std::uint64_t liveBytes =
                state->retainedObjectApproxBytesLive.fetch_add(approxBytes) +
                approxBytes;
            updatePeak(state->retainedObjectApproxBytesPeakLive, liveBytes);
        }
    }

    static void recordCommandBufferRetained(
        const std::shared_ptr<SharedState>& state) {
        if (!state) {
            return;
        }
        const std::uint64_t live =
            state->retainedCommandBuffersLive.fetch_add(1) + 1;
        updatePeak(state->retainedCommandBuffersPeakLive, live);
    }

    static void releaseRetainedObjects(const std::shared_ptr<RetainedObjects>& retainedObjects) {
        if (!retainedObjects) {
            return;
        }
        const auto state = retainedObjects->state.lock();
        const std::uint64_t releaseCount = retainedObjects->adoptedObjectCount;
        const std::uint64_t releaseBytes = retainedObjects->adoptedApproxBytes;
        for (void* object : retainedObjects->objects) {
            if (object != nullptr) {
                [(__bridge id)object release];
            }
        }
        retainedObjects->objects.clear();
        retainedObjects->adoptedObjectCount = 0;
        retainedObjects->adoptedApproxBytes = 0;
        if (state && releaseCount != 0) {
            state->retainedObjectsReleased.fetch_add(releaseCount);
            boundedSubtract(state->retainedObjectsLive, releaseCount);
            state->retainedReleaseCalls.fetch_add(1);
            updatePeak(state->retainedReleaseObjectMaxCount, releaseCount);
            if (releaseBytes != 0) {
                state->retainedObjectApproxBytesReleased.fetch_add(releaseBytes);
                boundedSubtract(state->retainedObjectApproxBytesLive, releaseBytes);
                updatePeak(state->retainedReleaseObjectMaxBytes, releaseBytes);
            }
        }
        if (retainedObjects->commandBuffer != nil) {
            [retainedObjects->commandBuffer release];
            retainedObjects->commandBuffer = nil;
            if (state && retainedObjects->commandBufferRetained) {
                state->retainedCommandBuffersReleased.fetch_add(1);
                boundedSubtract(state->retainedCommandBuffersLive, 1);
            }
            retainedObjects->commandBufferRetained = false;
        }
    }

    static void recordSubmitted(const std::shared_ptr<SharedState>& state,
                                AppGLCommandReason reason,
                                NSString* label) {
        if (!state) {
            return;
        }
        const std::uint64_t submitted = state->submittedCommandBuffers.fetch_add(1) + 1;
        if (static_cast<std::size_t>(reason) < state->submittedByReason.size()) {
            state->submittedByReason[static_cast<std::size_t>(reason)].fetch_add(1);
        }
        if (state->profileEnabled) {
            const auto& record = appGLCommandReasonRecord(reason);
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] cb_submit reason=%s mode=%s dependency=%s label=%s submitted=%llu completed=%llu in_flight=%u\n",
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         label != nil ? label.UTF8String : "(none)",
                         static_cast<unsigned long long>(submitted),
                         static_cast<unsigned long long>(state->completedCommandBuffers.load()),
                         state->inFlightCount.load());
            std::fflush(stderr);
        }
    }

    static void recordCompleted(const std::shared_ptr<SharedState>& state,
                                AppGLCommandReason reason,
                                NSString* label,
                                MTLCommandBufferStatus status) {
        if (!state) {
            return;
        }
        const std::uint64_t completed = state->completedCommandBuffers.fetch_add(1) + 1;
        if (static_cast<std::size_t>(reason) < state->completedByReason.size()) {
            state->completedByReason[static_cast<std::size_t>(reason)].fetch_add(1);
        }
        if (state->profileEnabled) {
            const auto& record = appGLCommandReasonRecord(reason);
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] cb_complete reason=%s mode=%s dependency=%s label=%s submitted=%llu completed=%llu status=%ld in_flight=%u\n",
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         label != nil ? label.UTF8String : "(none)",
                         static_cast<unsigned long long>(state->submittedCommandBuffers.load()),
                         static_cast<unsigned long long>(completed),
                         static_cast<long>(status),
                         state->inFlightCount.load());
            std::fflush(stderr);
        }
    }

    static void recordCommitCall(const std::shared_ptr<SharedState>& state,
                                 AppGLCommandReason reason,
                                 NSString* label,
                                 std::chrono::steady_clock::time_point start) {
        if (!state || !state->profileEnabled) {
            return;
        }
        const double commitUs =
            std::chrono::duration<double, std::micro>(
                std::chrono::steady_clock::now() - start).count();
        const auto& record = appGLCommandReasonRecord(reason);
        std::fprintf(stderr,
                     "[APPGL_CB_PROFILE] cb_commit reason=%s mode=%s dependency=%s label=%s commit_us=%.3f submitted=%llu completed=%llu in_flight=%u\n",
                     record.name,
                     appGLSubmitModeName(record.submitMode),
                     appGLDependencyClassName(record.dependencyClass),
                     label != nil ? label.UTF8String : "(none)",
                     commitUs,
                     static_cast<unsigned long long>(state->submittedCommandBuffers.load()),
                     static_cast<unsigned long long>(state->completedCommandBuffers.load()),
                     state->inFlightCount.load());
        std::fflush(stderr);
    }

    static void recordCompletionLatency(const std::shared_ptr<SharedState>& state,
                                        AppGLCommandReason reason,
                                        NSString* label,
                                        std::chrono::steady_clock::time_point submittedAt) {
        if (!state || !state->profileEnabled) {
            return;
        }
        const double latencyUs =
            std::chrono::duration<double, std::micro>(
                std::chrono::steady_clock::now() - submittedAt).count();
        const auto& record = appGLCommandReasonRecord(reason);
        std::fprintf(stderr,
                     "[APPGL_CB_PROFILE] cb_latency reason=%s mode=%s dependency=%s label=%s latency_us=%.3f submitted=%llu completed=%llu in_flight=%u\n",
                     record.name,
                     appGLSubmitModeName(record.submitMode),
                     appGLDependencyClassName(record.dependencyClass),
                     label != nil ? label.UTF8String : "(none)",
                     latencyUs,
                     static_cast<unsigned long long>(state->submittedCommandBuffers.load()),
                     static_cast<unsigned long long>(state->completedCommandBuffers.load()),
                     state->inFlightCount.load());
        std::fflush(stderr);
    }

    static void releaseToken(const std::shared_ptr<SharedState>& state,
                             const std::shared_ptr<std::atomic_bool>& released,
                             const char* reason) {
        if (!state || !released) {
            return;
        }
        const bool wasReleased = released->exchange(true);
        assert(!wasReleased && "Metal command buffer token released more than once");
        if (wasReleased) {
            return;
        }
        const std::uint32_t previous = state->inFlightCount.fetch_sub(1);
        assert(previous > 0 && "Metal command buffer in-flight count underflow");
        state->totalCompleted.fetch_add(1);
        dispatch_semaphore_signal(state->inFlightSemaphore);
        (void)reason;
    }

    std::shared_ptr<SharedState> state_;
    std::shared_ptr<std::atomic_bool> released_;
    std::shared_ptr<RetainedObjects> retainedObjects_;
    id<MTLCommandBuffer> commandBuffer_ = nil;
    bool ownsToken_ = false;
    bool tokenReleaseTransferred_ = false;
    bool retainedReleaseTransferred_ = false;
};

class MetalCommandSubmission {
public:
    static constexpr std::uint32_t kDefaultInFlightBound = 48;
    static constexpr std::uint32_t kDefaultPressureReserve = 4;
    static constexpr std::uint64_t kDefaultTimeoutMs = 300000;
    using PressureFlushCallback = std::function<bool(AppGLCommandReason)>;

private:
    enum class WaitKind {
        InFlightToken,
        RingSlot,
        Completion,
        DrainAll
    };

    friend class MetalCommandBufferLease;

    static std::uint32_t parseEnvUInt(const char* name,
                                      std::uint32_t fallback,
                                      std::uint32_t minimum = 1) {
        const char* raw = std::getenv(name);
        if (raw == nullptr || raw[0] == '\0') {
            return fallback;
        }
        char* end = nullptr;
        const unsigned long parsed = std::strtoul(raw, &end, 10);
        if (end == raw || parsed < minimum) {
            return fallback;
        }
        if (parsed > std::numeric_limits<std::uint32_t>::max()) {
            return fallback;
        }
        return static_cast<std::uint32_t>(parsed);
    }

    static std::shared_ptr<MetalCommandBufferLease::SharedState>
    makeSharedState(std::uint32_t requestedBound) {
        const std::uint32_t fallbackBound = requestedBound == 0 ? kDefaultInFlightBound : requestedBound;
        const std::uint32_t bound = parseEnvUInt("APPGL_COMMAND_BUFFER_BOUND",
                                                 fallbackBound,
                                                 1);
        const std::uint32_t reserve = parseEnvUInt("APPGL_COMMAND_BUFFER_RESERVE",
                                                   kDefaultPressureReserve,
                                                   kDefaultPressureReserve);
        return std::make_shared<MetalCommandBufferLease::SharedState>(bound, reserve);
    }

    static bool forceDrainAutoreleasedCommandBuffers() {
        static const bool enabled = [] {
            const char* raw = std::getenv("APPGL_COMMAND_BUFFER_FORCE_DRAIN_AUTORELEASE");
            return raw != nullptr && raw[0] != '\0' && std::strcmp(raw, "0") != 0;
        }();
        return enabled;
    }

    explicit MetalCommandSubmission(
        std::shared_ptr<MetalCommandBufferLease::SharedState> state)
        : commandQueue_(nil),
          state_(std::move(state)) {}

public:
    explicit MetalCommandSubmission(id<MTLCommandQueue> commandQueue,
                                    std::uint32_t inFlightBound = kDefaultInFlightBound)
        : commandQueue_(commandQueue),
          state_(makeSharedState(inFlightBound)) {}

    void setPressureFlushCallback(PressureFlushCallback callback) {
        pressureFlushCallback_ = std::move(callback);
    }

    MetalCommandBufferLease makeCommandBuffer(NSString* label = nil) {
        return makeCommandBufferImpl(label, AppGLCommandReason::Legacy, false);
    }

    MetalCommandBufferLease makeCommandBuffer(AppGLCommandReason reason) {
        return makeCommandBufferImpl(appGLCommandReasonNSString(reason), reason, false);
    }

    MetalCommandBufferLease makeCommandBufferDrainingAutorelease(NSString* label = nil) {
        return makeCommandBufferImpl(label, AppGLCommandReason::Legacy, true);
    }

    MetalCommandBufferLease makeCommandBufferDrainingAutorelease(AppGLCommandReason reason) {
        return makeCommandBufferImpl(appGLCommandReasonNSString(reason), reason, true);
    }

    AppGLCommandSubmissionDebugCounters debugCounters() const {
        AppGLCommandSubmissionDebugCounters counters;
        if (!state_) {
            return counters;
        }
        counters.submittedCommandBuffers = state_->submittedCommandBuffers.load();
        counters.completedCommandBuffers = state_->completedCommandBuffers.load();
        for (std::size_t index = 0; index < counters.allocatedByReason.size(); ++index) {
            counters.allocatedByReason[index] =
                state_->allocatedByReason[index].load();
            counters.submittedByReason[index] =
                state_->submittedByReason[index].load();
            counters.completedByReason[index] =
                state_->completedByReason[index].load();
        }
        counters.waitReasonLogEntries = state_->waitReasonLogEntries.load();
        counters.drainAllCalls = state_->drainAllCalls.load();
        counters.drainAllWaitUsTotal = state_->drainAllWaitUsTotal.load();
        counters.pressureFlushCount = state_->pressureFlushCount.load();
        counters.plainCommandBufferAllocations =
            state_->plainCommandBufferAllocations.load();
        counters.autoreleaseDrainedCommandBufferAllocations =
            state_->autoreleaseDrainedCommandBufferAllocations.load();
        counters.retainedObjectsAdopted =
            state_->retainedObjectsAdopted.load();
        counters.retainedObjectsReleased =
            state_->retainedObjectsReleased.load();
        counters.retainedObjectsLive = state_->retainedObjectsLive.load();
        counters.retainedObjectsPeakLive =
            state_->retainedObjectsPeakLive.load();
        counters.retainedObjectApproxBytesAdopted =
            state_->retainedObjectApproxBytesAdopted.load();
        counters.retainedObjectApproxBytesReleased =
            state_->retainedObjectApproxBytesReleased.load();
        counters.retainedObjectApproxBytesLive =
            state_->retainedObjectApproxBytesLive.load();
        counters.retainedObjectApproxBytesPeakLive =
            state_->retainedObjectApproxBytesPeakLive.load();
        counters.retainedCommandBuffersLive =
            state_->retainedCommandBuffersLive.load();
        counters.retainedCommandBuffersPeakLive =
            state_->retainedCommandBuffersPeakLive.load();
        counters.retainedCommandBuffersReleased =
            state_->retainedCommandBuffersReleased.load();
        counters.retainedReleaseCalls = state_->retainedReleaseCalls.load();
        counters.retainedReleaseObjectMaxCount =
            state_->retainedReleaseObjectMaxCount.load();
        counters.retainedReleaseObjectMaxBytes =
            state_->retainedReleaseObjectMaxBytes.load();
        counters.currentInFlight = state_->inFlightCount.load();
        counters.peakInFlight = state_->peakInFlight.load();
        counters.inFlightBound = state_->inFlightBound;
        counters.pressureReserve = state_->pressureReserve;
        counters.pressureSoftCap = state_->pressureSoftCap;
        for (std::size_t index = 0; index < counters.allocWaitTimeoutsByReason.size(); ++index) {
            counters.allocWaitTimeoutsByReason[index] =
                state_->allocWaitTimeoutsByReason[index].load();
        }
        counters.lastWaitReason =
            static_cast<AppGLCommandReason>(state_->lastWaitReason.load());
        counters.lastWaitMode =
            static_cast<AppGLSubmitMode>(state_->lastWaitMode.load());
        counters.lastWaitDependencyClass =
            static_cast<AppGLDependencyClass>(state_->lastWaitDependencyClass.load());
        return counters;
    }

    std::uint32_t inFlightCommandBufferCount() const {
        return state_ ? state_->inFlightCount.load() : 0;
    }

    std::uint32_t inFlightBound() const {
        return state_ ? state_->inFlightBound : 0;
    }

    std::uint32_t pressureReserve() const {
        return state_ ? state_->pressureReserve : 0;
    }

    std::uint32_t pressureSoftCap() const {
        return state_ ? state_->pressureSoftCap : 0;
    }

    bool hasOutstandingCommandBuffers() const {
        return inFlightCommandBufferCount() != 0;
    }

    bool drainAllOutstanding(AppGLCommandReason reason = AppGLCommandReason::LifetimeDrain,
                             bool recordWhenIdle = false) {
        if (!state_ || state_->inFlightSemaphore == nullptr) {
            return true;
        }
        if (!recordWhenIdle && !hasOutstandingCommandBuffers()) {
            return true;
        }
        NSString* label = appGLCommandReasonNSString(reason);
        recordWaitReason(WaitKind::DrainAll, reason, label);
        // S24 census: time every drain-all unconditionally (two
        // timestamps on a ~per-frame-at-most path) so this bucket can
        // never hide from the standard counters again.
        state_->drainAllCalls.fetch_add(1, std::memory_order_relaxed);
        const auto waitStart = std::chrono::steady_clock::now();
        const std::uint64_t timeoutMs = timeoutMilliseconds();
        const dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            static_cast<int64_t>(timeoutMs * static_cast<std::uint64_t>(NSEC_PER_MSEC)));
        std::uint32_t acquired = 0;
        for (; acquired < state_->inFlightBound; ++acquired) {
            if (dispatch_semaphore_wait(state_->inFlightSemaphore, deadline) != 0) {
                recordTimeout(WaitKind::DrainAll, reason, label, timeoutMs);
                break;
            }
        }
        for (std::uint32_t i = 0; i < acquired; ++i) {
            dispatch_semaphore_signal(state_->inFlightSemaphore);
        }
        const bool drained = acquired == state_->inFlightBound;
        state_->drainAllWaitUsTotal.fetch_add(
            static_cast<std::uint64_t>(
                std::chrono::duration<double, std::micro>(
                    std::chrono::steady_clock::now() - waitStart).count()),
            std::memory_order_relaxed);
        if (state_->profileEnabled) {
            const double waitUs =
                std::chrono::duration<double, std::micro>(
                    std::chrono::steady_clock::now() - waitStart).count();
            const auto& record = appGLCommandReasonRecord(reason);
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] drain_all reason=%s mode=%s dependency=%s label=%s drained=%d submitted=%llu completed=%llu in_flight=%u bound=%u wait_us=%.3f\n",
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         label != nil ? label.UTF8String : "(none)",
                         drained ? 1 : 0,
                         static_cast<unsigned long long>(state_->submittedCommandBuffers.load()),
                         static_cast<unsigned long long>(state_->completedCommandBuffers.load()),
                         state_->inFlightCount.load(),
                         state_->inFlightBound,
                         waitUs);
            std::fflush(stderr);
        }
        return drained;
    }

    void recordPressureFlush(AppGLCommandReason reason = AppGLCommandReason::PressureFlush) {
        if (!state_) {
            return;
        }
        state_->pressureFlushCount.fetch_add(1);
        if (state_->profileEnabled) {
            const auto& record = appGLCommandReasonRecord(reason);
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] pressure_flush reason=%s mode=%s dependency=%s count=%llu submitted=%llu completed=%llu in_flight=%u bound=%u\n",
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         static_cast<unsigned long long>(state_->pressureFlushCount.load()),
                         static_cast<unsigned long long>(state_->submittedCommandBuffers.load()),
                         static_cast<unsigned long long>(state_->completedCommandBuffers.load()),
                         state_->inFlightCount.load(),
                         state_->inFlightBound);
            std::fflush(stderr);
        }
    }

private:
    bool maybeFlushCurrentForPressure(AppGLCommandReason reason) {
        if (!state_ || !pressureFlushCallback_) {
            return false;
        }
        if (state_->inFlightCount.load() < state_->pressureSoftCap) {
            return false;
        }
        const bool flushed = pressureFlushCallback_(reason);
        if (flushed) {
            recordPressureFlush(AppGLCommandReason::PressureFlush);
        }
        return flushed;
    }

    MetalCommandBufferLease makeCommandBufferImpl(NSString* label,
                                                  AppGLCommandReason reason,
                                                  bool drainAutoreleasedCommandBuffer) {
        if (commandQueue_ == nil || !state_) {
            return {};
        }
        drainAutoreleasedCommandBuffer =
            drainAutoreleasedCommandBuffer || forceDrainAutoreleasedCommandBuffers();
        maybeFlushCurrentForPressure(reason);
        if (!waitOnSemaphore(state_->inFlightSemaphore, WaitKind::InFlightToken, reason, label)) {
            return {};
        }
        const std::uint32_t afterAcquire = state_->inFlightCount.fetch_add(1) + 1;
        const std::uint64_t totalAllocated = state_->totalAllocated.fetch_add(1) + 1;
        if (static_cast<std::size_t>(reason) < state_->allocatedByReason.size()) {
            state_->allocatedByReason[static_cast<std::size_t>(reason)].fetch_add(1);
        }
        std::uint32_t observedPeak = state_->peakInFlight.load();
        while (afterAcquire > observedPeak
               && !state_->peakInFlight.compare_exchange_weak(observedPeak, afterAcquire)) {}
        assert(afterAcquire <= state_->inFlightBound && "Metal command buffer in-flight bound exceeded");
        id<MTLCommandBuffer> commandBuffer = nil;
        bool releaseTemporaryRetain = false;
        if (drainAutoreleasedCommandBuffer) {
            @autoreleasepool {
                commandBuffer = [commandQueue_ commandBuffer];
                if (commandBuffer != nil) {
                    [commandBuffer retain];
                    releaseTemporaryRetain = true;
                }
            }
        } else {
            commandBuffer = [commandQueue_ commandBuffer];
        }
        if (commandBuffer == nil) {
            const std::uint32_t previous = state_->inFlightCount.fetch_sub(1);
            assert(previous > 0 && "Metal command buffer in-flight count underflow after allocation failure");
            dispatch_semaphore_signal(state_->inFlightSemaphore);
            return {};
        }
        if (drainAutoreleasedCommandBuffer) {
            state_->autoreleaseDrainedCommandBufferAllocations.fetch_add(1);
        } else {
            state_->plainCommandBufferAllocations.fetch_add(1);
        }
        if (label != nil) {
            commandBuffer.label = label;
        }
        if (state_->profileEnabled) {
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] cb_alloc label=%s total=%llu in_flight=%u peak=%u bound=%u\n",
                         label != nil ? label.UTF8String : "(none)",
                         static_cast<unsigned long long>(totalAllocated),
                         afterAcquire,
                         state_->peakInFlight.load(),
                         state_->inFlightBound);
            std::fflush(stderr);
        }
        MetalCommandBufferLease lease(state_, commandBuffer);
        if (releaseTemporaryRetain) {
            [commandBuffer release];
        }
        return lease;
    }

public:
    bool waitForRingSlot(dispatch_semaphore_t semaphore, NSString* label = nil) {
        return waitOnSemaphore(semaphore, WaitKind::RingSlot, AppGLCommandReason::Legacy, label);
    }

    bool waitForRingSlot(dispatch_semaphore_t semaphore, AppGLCommandReason reason) {
        return waitOnSemaphore(semaphore, WaitKind::RingSlot, reason, appGLCommandReasonNSString(reason));
    }

    void signalRingSlot(dispatch_semaphore_t semaphore) {
        dispatch_semaphore_signal(semaphore);
    }

    bool waitForCompletionSemaphore(dispatch_semaphore_t semaphore, NSString* label = nil) {
        return waitOnSemaphore(semaphore, WaitKind::Completion, AppGLCommandReason::Legacy, label);
    }

    bool waitForCompletionSemaphore(dispatch_semaphore_t semaphore, AppGLCommandReason reason) {
        return waitOnSemaphore(semaphore, WaitKind::Completion, reason, appGLCommandReasonNSString(reason));
    }

    std::uint64_t timeoutMilliseconds() const {
        const char* env = std::getenv("APPGL_COMMAND_BUFFER_TIMEOUT_MS");
        if (env == nullptr || env[0] == '\0') {
            return kDefaultTimeoutMs;
        }
        char* end = nullptr;
        const unsigned long long parsed = std::strtoull(env, &end, 10);
        if (end == env || parsed == 0) {
            return kDefaultTimeoutMs;
        }
        return static_cast<std::uint64_t>(parsed);
    }

    bool waitOnSemaphore(dispatch_semaphore_t semaphore,
                         WaitKind kind,
                         AppGLCommandReason reason,
                         NSString* label) {
        if (semaphore == nullptr) {
            return false;
        }
        const bool profileEnabled = state_ && state_->profileEnabled;
        const auto waitStart = profileEnabled
            ? std::chrono::steady_clock::now()
            : std::chrono::steady_clock::time_point{};
        recordWaitReason(kind, reason, label);
        if (kind == WaitKind::InFlightToken && profileEnabled) {
            if (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
                recordWaitComplete(kind, reason, label, waitStart);
                return true;
            }
            const std::uint64_t count = state_->backpressureWaits.fetch_add(1) + 1;
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] factory_backpressure label=%s count=%llu in_flight=%u peak=%u bound=%u\n",
                         label != nil ? label.UTF8String : "(none)",
                         static_cast<unsigned long long>(count),
                         state_->inFlightCount.load(),
                         state_->peakInFlight.load(),
                         state_->inFlightBound);
            std::fflush(stderr);
        }
        const std::uint64_t timeoutMs = timeoutMilliseconds();
        const dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            static_cast<int64_t>(timeoutMs * static_cast<std::uint64_t>(NSEC_PER_MSEC)));
        if (dispatch_semaphore_wait(semaphore, deadline) == 0) {
            if (profileEnabled) {
                recordWaitComplete(kind, reason, label, waitStart);
            }
            return true;
        }
        recordTimeout(kind, reason, label, timeoutMs);
        return false;
    }

    void recordWaitReason(WaitKind kind, AppGLCommandReason reason, NSString* label) {
        if (!state_) {
            return;
        }
        const auto& record = appGLCommandReasonRecord(reason);
        const std::uint64_t sequence = state_->waitReasonLogEntries.fetch_add(1) + 1;
        state_->lastWaitReason.store(static_cast<std::uint32_t>(record.reason));
        state_->lastWaitMode.store(static_cast<std::uint32_t>(record.submitMode));
        state_->lastWaitDependencyClass.store(static_cast<std::uint32_t>(record.dependencyClass));
        if (state_->profileEnabled) {
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] wait_reason seq=%llu kind=%s reason=%s mode=%s dependency=%s label=%s submitted=%llu completed=%llu in_flight=%u\n",
                         static_cast<unsigned long long>(sequence),
                         waitKindName(kind),
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         label != nil ? label.UTF8String : "(none)",
                         static_cast<unsigned long long>(state_->submittedCommandBuffers.load()),
                         static_cast<unsigned long long>(state_->completedCommandBuffers.load()),
                         state_->inFlightCount.load());
            std::fflush(stderr);
        }
    }

    void recordWaitComplete(WaitKind kind,
                            AppGLCommandReason reason,
                            NSString* label,
                            std::chrono::steady_clock::time_point waitStart) {
        if (!state_ || !state_->profileEnabled) {
            return;
        }
        const auto waitEnd = std::chrono::steady_clock::now();
        const double waitUs =
            std::chrono::duration<double, std::micro>(waitEnd - waitStart).count();
        const auto& record = appGLCommandReasonRecord(reason);
        std::fprintf(stderr,
                     "[APPGL_CB_PROFILE] wait_complete kind=%s reason=%s mode=%s dependency=%s label=%s wait_us=%.3f submitted=%llu completed=%llu in_flight=%u\n",
                     waitKindName(kind),
                     record.name,
                     appGLSubmitModeName(record.submitMode),
                     appGLDependencyClassName(record.dependencyClass),
                     label != nil ? label.UTF8String : "(none)",
                     waitUs,
                     static_cast<unsigned long long>(state_->submittedCommandBuffers.load()),
                     static_cast<unsigned long long>(state_->completedCommandBuffers.load()),
                     state_->inFlightCount.load());
        std::fflush(stderr);
    }

    const char* waitKindName(WaitKind kind) const {
        switch (kind) {
            case WaitKind::InFlightToken: return "in-flight-token";
            case WaitKind::RingSlot: return "ring-slot";
            case WaitKind::Completion: return "completion";
            case WaitKind::DrainAll: return "drain-all";
        }
        return "unknown";
    }

    void recordTimeout(WaitKind kind,
                       AppGLCommandReason reason,
                       NSString* label,
                       std::uint64_t timeoutMs) {
        const char* kindName = "unknown";
        std::uint64_t count = 0;
        switch (kind) {
            case WaitKind::InFlightToken:
                kindName = "in-flight-token";
                count = state_->inFlightTimeouts.fetch_add(1) + 1;
                if (static_cast<std::size_t>(reason) < state_->allocWaitTimeoutsByReason.size()) {
                    state_->allocWaitTimeoutsByReason[static_cast<std::size_t>(reason)].fetch_add(1);
                }
                break;
            case WaitKind::RingSlot:
                kindName = "ring-slot";
                count = state_->ringSlotTimeouts.fetch_add(1) + 1;
                break;
            case WaitKind::Completion:
                kindName = "completion";
                count = state_->completionTimeouts.fetch_add(1) + 1;
                break;
            case WaitKind::DrainAll:
                kindName = "drain-all";
                count = state_->drainAllTimeouts.fetch_add(1) + 1;
                break;
        }
        const auto& record = appGLCommandReasonRecord(reason);
        std::fprintf(stderr,
                     "[APPGL command-buffer-timeout] kind=%s reason=%s mode=%s dependency=%s label=%s count=%llu timeout_ms=%llu in_flight=%u bound=%u\n",
                     kindName,
                     record.name,
                     appGLSubmitModeName(record.submitMode),
                     appGLDependencyClassName(record.dependencyClass),
                     label != nil ? label.UTF8String : "(none)",
                     static_cast<unsigned long long>(count),
                     static_cast<unsigned long long>(timeoutMs),
                     state_->inFlightCount.load(),
                     state_->inFlightBound);
        std::fflush(stderr);
    }

    id<MTLCommandQueue> commandQueue_ = nil;
    std::shared_ptr<MetalCommandBufferLease::SharedState> state_;
    PressureFlushCallback pressureFlushCallback_;
};

inline bool MetalCommandBufferLease::commitAndWait(NSString* label) {
    return commitAndWaitImpl(label, AppGLCommandReason::Legacy);
}

inline bool MetalCommandBufferLease::commitAndWait(AppGLCommandReason reason) {
    return commitAndWaitImpl(appGLCommandReasonNSString(reason), reason);
}

inline bool MetalCommandBufferLease::commitAndWaitImpl(NSString* label, AppGLCommandReason reason) {
    if (commandBuffer_ == nil || !ownsToken_ || !state_) {
        return false;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    if (done == nullptr) {
        return false;
    }
#if !__has_feature(objc_arc)
    dispatch_retain(done);
#endif
    __block MTLCommandBufferStatus finalStatus = MTLCommandBufferStatusNotEnqueued;
    auto state = state_;
    auto released = released_;
    auto retainedObjects = retainedObjects_;
    NSString* releaseLabel = label != nil ? label : commandBuffer_.label;
    const bool profileEnabled = state && state->profileEnabled;
    const auto submittedAt = profileEnabled
        ? std::chrono::steady_clock::now()
        : std::chrono::steady_clock::time_point{};
    recordSubmitted(state, reason, releaseLabel);
    [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        finalStatus = completed.status;
        recordCompleted(state, reason, releaseLabel, completed.status);
        recordCompletionLatency(state, reason, releaseLabel, submittedAt);
        releaseToken(state, released, releaseLabel.UTF8String);
        releaseRetainedObjects(retainedObjects);
        dispatch_semaphore_signal(done);
#if !__has_feature(objc_arc)
        dispatch_release(done);
#endif
    }];
    tokenReleaseTransferred_ = true;
    retainedReleaseTransferred_ = true;
    const auto commitStart = profileEnabled
        ? std::chrono::steady_clock::now()
        : std::chrono::steady_clock::time_point{};
    [commandBuffer_ commit];
    if (profileEnabled) {
        recordCommitCall(state, reason, releaseLabel, commitStart);
    }
    commandBuffer_ = nil;
    ownsToken_ = false;

    MetalCommandSubmission waiter(state);
    const bool waitCompleted =
        waiter.waitOnSemaphore(done, MetalCommandSubmission::WaitKind::Completion, reason, releaseLabel);
#if !__has_feature(objc_arc)
    dispatch_release(done);
#endif
    if (!waitCompleted) {
        return false;
    }
    return finalStatus == MTLCommandBufferStatusCompleted;
}

}  // namespace appgl
