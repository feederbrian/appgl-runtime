#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cassert>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

namespace appgl {

class MetalCommandSubmission;

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

    void commitWithCompletion(NSString* label, void (^completion)(id<MTLCommandBuffer>)) {
        if (commandBuffer_ == nil || !ownsToken_) {
            return;
        }
        auto state = state_;
        auto released = released_;
        auto retainedObjects = retainedObjects_;
        NSString* releaseLabel = label != nil ? label : commandBuffer_.label;
        void (^completionCopy)(id<MTLCommandBuffer>) = completion;
        [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completionCopy != nil) {
                completionCopy(completed);
            }
            releaseToken(state, released, releaseLabel.UTF8String);
            releaseRetainedObjects(retainedObjects);
        }];
        tokenReleaseTransferred_ = true;
        retainedReleaseTransferred_ = true;
        [commandBuffer_ commit];
        commandBuffer_ = nil;
        ownsToken_ = false;
    }

    bool commitAndWait(NSString* label = nil);

private:
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
        std::atomic<std::uint64_t> backpressureWaits{0};
        std::atomic<std::uint64_t> inFlightTimeouts{0};
        std::atomic<std::uint64_t> ringSlotTimeouts{0};
        std::atomic<std::uint64_t> completionTimeouts{0};
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

    explicit MetalCommandSubmission(id<MTLCommandQueue> commandQueue,
                                    std::uint32_t inFlightBound = kDefaultInFlightBound)
        : commandQueue_(commandQueue),
          state_(std::make_shared<MetalCommandBufferLease::SharedState>(inFlightBound)) {}

    MetalCommandBufferLease makeCommandBuffer(NSString* label = nil) {
        if (commandQueue_ == nil || !waitOnSemaphore(state_->inFlightSemaphore, WaitKind::InFlightToken, label)) {
            return {};
        }
        const std::uint32_t afterAcquire = state_->inFlightCount.fetch_add(1) + 1;
        const std::uint64_t totalAllocated = state_->totalAllocated.fetch_add(1) + 1;
        std::uint32_t observedPeak = state_->peakInFlight.load();
        while (afterAcquire > observedPeak
               && !state_->peakInFlight.compare_exchange_weak(observedPeak, afterAcquire)) {}
        assert(afterAcquire <= state_->inFlightBound && "Metal command buffer in-flight bound exceeded");
        id<MTLCommandBuffer> commandBuffer = nil;
        @autoreleasepool {
            commandBuffer = [commandQueue_ commandBuffer];
            // `commandBuffer` is autoreleased. Take a temporary retain before
            // draining this local pool so the lease becomes the only owner that
            // survives until the completion handler releases it.
            if (commandBuffer != nil) {
                [commandBuffer retain];
            }
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
        [commandBuffer release];
        return lease;
    }

    bool waitForRingSlot(dispatch_semaphore_t semaphore, NSString* label = nil) {
        return waitOnSemaphore(semaphore, WaitKind::RingSlot, label);
    }

    void signalRingSlot(dispatch_semaphore_t semaphore) {
        dispatch_semaphore_signal(semaphore);
    }

    bool waitForCompletionSemaphore(dispatch_semaphore_t semaphore, NSString* label = nil) {
        return waitOnSemaphore(semaphore, WaitKind::Completion, label);
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

private:
    enum class WaitKind {
        InFlightToken,
        RingSlot,
        Completion
    };

    friend class MetalCommandBufferLease;

    bool waitOnSemaphore(dispatch_semaphore_t semaphore, WaitKind kind, NSString* label) {
        if (semaphore == nullptr) {
            return false;
        }
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
        recordTimeout(kind, label, timeoutMs);
        return false;
    }

    void recordTimeout(WaitKind kind, NSString* label, std::uint64_t timeoutMs) {
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
        }
        std::fprintf(stderr,
                     "[APPGL command-buffer-timeout] kind=%s label=%s count=%llu timeout_ms=%llu in_flight=%u bound=%u\n",
                     kindName,
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
    if (commandBuffer_ == nil || !ownsToken_ || !state_) {
        return false;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block MTLCommandBufferStatus finalStatus = MTLCommandBufferStatusNotEnqueued;
    auto state = state_;
    auto released = released_;
    auto retainedObjects = retainedObjects_;
    NSString* releaseLabel = label != nil ? label : commandBuffer_.label;
    [commandBuffer_ addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        finalStatus = completed.status;
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
    if (!waiter.waitForCompletionSemaphore(done, releaseLabel)) {
        return false;
    }
    return finalStatus == MTLCommandBufferStatusCompleted;
}

}  // namespace appgl
