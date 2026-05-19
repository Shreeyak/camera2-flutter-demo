// PixelSinkPool — C++ PixelSink pool with pipeline > stage > consumer lock ordering (D-16).
// Thread cap: CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency).
#include "PixelSink.hpp"
#include "PixelSinkCallbacks.h"
#include "PixelSinkMetrics.h"
#include <mutex>
#include <vector>
#include <thread>
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>

static constexpr unsigned kMaxThreads = CPP_POOL_THREAD_COUNT;
static constexpr uint32_t kNumStreams = 3;
// Mirrors Constants.fpsMeasurementWindowFrames — the cadence at which the pool
// emits D-11 metrics. Not configurable; not a -D define on purpose.
static constexpr uint64_t kFpsWindow = 30;

struct ConsumerEntry {
    uint64_t           token;
    PixelSinkCallbacks cbs;
    uint32_t           stream;
};

class PixelSinkPool {
public:
    PixelSinkPool()
        : threadCount_(std::min(kMaxThreads,
                                std::thread::hardware_concurrency())) {}

    // G-26 quality gate (D-11): a consumer with no on_overwrite callback cannot
    // surface mailbox-overwrite drops — reject it with token 0 so the Swift
    // facade can throw InteropError.missingOnOverwrite.
    uint64_t registerConsumer(uint32_t stream, PixelSinkCallbacks cbs) {
        if (cbs.on_overwrite == nullptr) { return 0; }
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        uint64_t id = nextId_++;
        consumers_.push_back({id, cbs, stream});
        return id;
    }

    void unregisterConsumer(uint64_t token) {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        consumers_.erase(
            std::remove_if(consumers_.begin(), consumers_.end(),
                [token](const ConsumerEntry& e) { return e.token == token; }),
            consumers_.end());
    }

    void dispatch(uint32_t stream, uint64_t frameNumber,
                  int64_t presentationTimeNs, void* surface) {
        {
            std::lock_guard<std::mutex> pl(pipelineMutex_);
            std::lock_guard<std::mutex> sl(stageMutex_);
            std::lock_guard<std::mutex> cl(consumerMutex_);
            for (auto& e : consumers_) {
                if (e.stream == stream && e.cbs.on_frame) {
                    e.cbs.on_frame(e.cbs.context, stream, frameNumber,
                                   presentationTimeNs, surface);
                }
            }
        }
        // Cadence emission runs outside the fan-out locks: the metrics callback
        // crosses into Swift and must not be invoked while holding pool mutexes.
        uint64_t n = dispatchCount_.fetch_add(1, std::memory_order_relaxed) + 1;
        if (n % kFpsWindow == 0) { emitMetrics(); }
    }

    unsigned consumerCount(uint32_t stream) const {
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        unsigned n = 0;
        for (const auto& e : consumers_) {
            if (e.stream == stream) { n++; }
        }
        return n;
    }

    uintptr_t rawPointer() const { return reinterpret_cast<uintptr_t>(this); }

    // MARK: - D-11 observability

    void noteOverwrite(uint32_t stream) {
        if (stream >= kNumStreams) { return; }
        overwriteCount_[stream].fetch_add(1, std::memory_order_relaxed);
        std::lock_guard<std::mutex> pl(pipelineMutex_);
        std::lock_guard<std::mutex> sl(stageMutex_);
        std::lock_guard<std::mutex> cl(consumerMutex_);
        for (auto& e : consumers_) {
            if (e.stream == stream && e.cbs.on_overwrite) {
                e.cbs.on_overwrite(e.cbs.context, stream);
            }
        }
    }

    uint64_t overwriteCount(uint32_t stream) const {
        if (stream >= kNumStreams) { return 0; }
        return overwriteCount_[stream].load(std::memory_order_relaxed);
    }

    void setMetricsCallback(MetricsCallbackFn cb, void* context) {
        std::lock_guard<std::mutex> ml(metricsMutex_);
        metricsCb_  = cb;
        metricsCtx_ = context;
    }

    void emitMetrics() {
        std::lock_guard<std::mutex> ml(metricsMutex_);
        if (metricsCb_ == nullptr) { return; }
        for (uint32_t s = 0; s < kNumStreams; ++s) {
            PixelSinkMetrics m{
                s, overwriteCount_[s].load(std::memory_order_relaxed)};
            metricsCb_(metricsCtx_, m);
        }
    }

private:
    mutable std::mutex pipelineMutex_;
    mutable std::mutex stageMutex_;
    mutable std::mutex consumerMutex_;
    std::vector<ConsumerEntry> consumers_;
    uint64_t nextId_ = 1;
    unsigned threadCount_;

    // D-11 observability state.
    std::array<std::atomic<uint64_t>, kNumStreams> overwriteCount_{};
    std::atomic<uint64_t> dispatchCount_{0};
    std::mutex metricsMutex_;
    MetricsCallbackFn metricsCb_  = nullptr;
    void*             metricsCtx_ = nullptr;
};

extern "C" {

void* pixel_sink_pool_create(void) { return new PixelSinkPool(); }

void pixel_sink_pool_destroy(void* handle) {
    delete static_cast<PixelSinkPool*>(handle);
}

uint64_t pixel_sink_pool_register(void* handle, uint32_t stream, PixelSinkCallbacks cbs) {
    return static_cast<PixelSinkPool*>(handle)->registerConsumer(stream, cbs);
}

void pixel_sink_pool_unregister(void* handle, uint64_t token) {
    static_cast<PixelSinkPool*>(handle)->unregisterConsumer(token);
}

void pixel_sink_pool_dispatch(void* handle, uint32_t stream,
                              uint64_t frameNumber, int64_t presentationTimeNs,
                              void* surface) {
    static_cast<PixelSinkPool*>(handle)->dispatch(stream, frameNumber,
                                                   presentationTimeNs, surface);
}

unsigned pixel_sink_pool_consumer_count(void* handle, uint32_t stream) {
    return static_cast<PixelSinkPool*>(handle)->consumerCount(stream);
}

uintptr_t pixel_sink_pool_raw_pointer(void* handle) {
    return static_cast<PixelSinkPool*>(handle)->rawPointer();
}

void pixel_sink_pool_note_overwrite(void* handle, uint32_t stream) {
    static_cast<PixelSinkPool*>(handle)->noteOverwrite(stream);
}

uint64_t pixel_sink_pool_overwrite_count(void* handle, uint32_t stream) {
    return static_cast<PixelSinkPool*>(handle)->overwriteCount(stream);
}

void pixel_sink_pool_set_metrics_callback(void* handle, MetricsCallbackFn cb, void* context) {
    static_cast<PixelSinkPool*>(handle)->setMetricsCallback(cb, context);
}

void pixel_sink_pool_emit_metrics(void* handle) {
    static_cast<PixelSinkPool*>(handle)->emitMetrics();
}

}  // extern "C"
