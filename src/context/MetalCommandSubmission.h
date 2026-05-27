#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "AppGLCommandReasons.h"

#include <cassert>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

namespace appgl {

class MetalCommandSubmission;

inline NSString* appGLCommandReasonNSString(AppGLCommandReason reason) {
    switch (reason) {
        case AppGLCommandReason::BeginRenderPass: return @"beginRenderPass";
        case AppGLCommandReason::FlushClear: return @"flushClear";
        case AppGLCommandReason::SolidColorDraw: return @"solidColorDraw";
        case AppGLCommandReason::TranslatedDraw: return @"translatedDraw";
        case AppGLCommandReason::ImmediateModeDraw: return @"immediateModeDraw";
        case AppGLCommandReason::FrameCommandBuffer: return @"frame-command-buffer";
        case AppGLCommandReason::PresentPendingWork: return @"frame-command-buffer";
        case AppGLCommandReason::EndFrame: return @"frame-command-buffer";
        case AppGLCommandReason::FlushForReadback: return @"flush-for-readback";
        case AppGLCommandReason::DrainCurrentStandalone: return @"drain-current-standalone";
        case AppGLCommandReason::FrameRingSlot: return @"frame-ring-slot";
        case AppGLCommandReason::CompletionWait: return @"completion-wait";
        case AppGLCommandReason::FinishWait: return @"frame-command-buffer";
        case AppGLCommandReason::LifetimeDrain: return @"glFinish-drain-all";
        case AppGLCommandReason::Legacy:
        case AppGLCommandReason::Count:
            return @"legacy-command-buffer";
    }
    return @"legacy-command-buffer";
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
        retainedObjects_->objects.push_back((__bridge void*)object);
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
        recordSubmitted(state, reason, releaseLabel);
        [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completionCopy != nil) {
                completionCopy(completed);
            }
            recordCompleted(state, reason, releaseLabel, completed.status);
            releaseToken(state, released, releaseLabel.UTF8String);
            releaseRetainedObjects(retainedObjects);
        }];
        tokenReleaseTransferred_ = true;
        retainedReleaseTransferred_ = true;
        [commandBuffer_ commit];
        commandBuffer_ = nil;
        ownsToken_ = false;
    }

    struct SharedState {
        explicit SharedState(std::uint32_t bound)
            : inFlightBound(bound),
              inFlightSemaphore(dispatch_semaphore_create(static_cast<long>(bound))) {}

        std::uint32_t inFlightBound = 0;
        dispatch_semaphore_t inFlightSemaphore = nullptr;
        bool profileEnabled = std::getenv("APPGL_CB_PROFILE") != nullptr;
        std::atomic<std::uint32_t> inFlightCount{0};
        std::atomic<std::uint32_t> peakInFlight{0};
        std::atomic<std::uint64_t> totalAllocated{0};
        std::atomic<std::uint64_t> totalCompleted{0};
        std::atomic<std::uint64_t> submittedCommandBuffers{0};
        std::atomic<std::uint64_t> completedCommandBuffers{0};
        std::atomic<std::uint64_t> backpressureWaits{0};
        std::atomic<std::uint64_t> waitReasonLogEntries{0};
        std::atomic<std::uint32_t> lastWaitReason{static_cast<std::uint32_t>(AppGLCommandReason::Legacy)};
        std::atomic<std::uint32_t> lastWaitMode{static_cast<std::uint32_t>(AppGLSubmitMode::WaitOnly)};
        std::atomic<std::uint32_t> lastWaitDependencyClass{static_cast<std::uint32_t>(AppGLDependencyClass::Legacy)};
        std::atomic<std::uint64_t> inFlightTimeouts{0};
        std::atomic<std::uint64_t> ringSlotTimeouts{0};
        std::atomic<std::uint64_t> completionTimeouts{0};
        std::atomic<std::uint64_t> drainAllTimeouts{0};
    };

    struct RetainedObjects {
        id<MTLCommandBuffer> commandBuffer = nil;
        std::vector<void*> objects;
    };

    friend class MetalCommandSubmission;

    MetalCommandBufferLease(std::shared_ptr<SharedState> state, id<MTLCommandBuffer> commandBuffer)
        : state_(std::move(state)),
          released_(std::make_shared<std::atomic_bool>(false)),
          retainedObjects_(std::make_shared<RetainedObjects>()),
          commandBuffer_(commandBuffer),
          ownsToken_(commandBuffer != nil) {
        if (commandBuffer_ != nil) {
            [commandBuffer_ retain];
            retainedObjects_->commandBuffer = commandBuffer_;
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

    static void releaseRetainedObjects(const std::shared_ptr<RetainedObjects>& retainedObjects) {
        if (!retainedObjects) {
            return;
        }
        for (void* object : retainedObjects->objects) {
            if (object != nullptr) {
                [(__bridge id)object release];
            }
        }
        retainedObjects->objects.clear();
        if (retainedObjects->commandBuffer != nil) {
            [retainedObjects->commandBuffer release];
            retainedObjects->commandBuffer = nil;
        }
    }

    static void recordSubmitted(const std::shared_ptr<SharedState>& state,
                                AppGLCommandReason reason,
                                NSString* label) {
        if (!state) {
            return;
        }
        const std::uint64_t submitted = state->submittedCommandBuffers.fetch_add(1) + 1;
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
    static constexpr std::uint64_t kDefaultTimeoutMs = 300000;

private:
    enum class WaitKind {
        InFlightToken,
        RingSlot,
        Completion,
        DrainAll
    };

    friend class MetalCommandBufferLease;

public:
    explicit MetalCommandSubmission(id<MTLCommandQueue> commandQueue,
                                    std::uint32_t inFlightBound = kDefaultInFlightBound)
        : commandQueue_(commandQueue),
          state_(std::make_shared<MetalCommandBufferLease::SharedState>(inFlightBound)) {}

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
        counters.waitReasonLogEntries = state_->waitReasonLogEntries.load();
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
        if (state_->profileEnabled) {
            const auto& record = appGLCommandReasonRecord(reason);
            std::fprintf(stderr,
                         "[APPGL_CB_PROFILE] drain_all reason=%s mode=%s dependency=%s label=%s drained=%d submitted=%llu completed=%llu in_flight=%u bound=%u\n",
                         record.name,
                         appGLSubmitModeName(record.submitMode),
                         appGLDependencyClassName(record.dependencyClass),
                         label != nil ? label.UTF8String : "(none)",
                         drained ? 1 : 0,
                         static_cast<unsigned long long>(state_->submittedCommandBuffers.load()),
                         static_cast<unsigned long long>(state_->completedCommandBuffers.load()),
                         state_->inFlightCount.load(),
                         state_->inFlightBound);
            std::fflush(stderr);
        }
        return drained;
    }

private:
    MetalCommandBufferLease makeCommandBufferImpl(NSString* label,
                                                  AppGLCommandReason reason,
                                                  bool drainAutoreleasedCommandBuffer) {
        if (commandQueue_ == nil || !waitOnSemaphore(state_->inFlightSemaphore, WaitKind::InFlightToken, reason, label)) {
            return {};
        }
        const std::uint32_t afterAcquire = state_->inFlightCount.fetch_add(1) + 1;
        const std::uint64_t totalAllocated = state_->totalAllocated.fetch_add(1) + 1;
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
        recordWaitReason(kind, reason, label);
        if (kind == WaitKind::InFlightToken && state_ && state_->profileEnabled) {
            if (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
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
    __block MTLCommandBufferStatus finalStatus = MTLCommandBufferStatusNotEnqueued;
    auto state = state_;
    auto released = released_;
    auto retainedObjects = retainedObjects_;
    NSString* releaseLabel = label != nil ? label : commandBuffer_.label;
    recordSubmitted(state, reason, releaseLabel);
    [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        finalStatus = completed.status;
        recordCompleted(state, reason, releaseLabel, completed.status);
        releaseToken(state, released, releaseLabel.UTF8String);
        releaseRetainedObjects(retainedObjects);
        dispatch_semaphore_signal(done);
    }];
    tokenReleaseTransferred_ = true;
    retainedReleaseTransferred_ = true;
    [commandBuffer_ commit];
    commandBuffer_ = nil;
    ownsToken_ = false;

    MetalCommandSubmission waiter(nil, state->inFlightBound);
    waiter.state_ = state;
    if (!waiter.waitOnSemaphore(done, MetalCommandSubmission::WaitKind::Completion, reason, releaseLabel)) {
        return false;
    }
    return finalStatus == MTLCommandBufferStatusCompleted;
}

}  // namespace appgl
