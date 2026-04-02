#include <gtest/gtest.h>
#include <atomic>
#include <chrono>
#include <future>
#include <thread>
#include "ImagePipeline.h"

// ImagePipeline constructor requires ANativeWindow* — pass nullptr for tests.
// blitToWindow guards against null window, so the CPU preview path is a no-op.

TEST(SinkRoutingTest, FullResSinkReceivesFullResFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::promise<void> called;
    std::atomic<int> fullResCalls{0};
    pipeline.addSink({"stitcher", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame&) {
                         fullResCalls++;
                         called.set_value();
                     });

    uint8_t fakePixels[4 * 4 * 4] = {};  // 4x4 RGBA
    pipeline.deliverFullResRgba(fakePixels, 4, 4, 16, 1, {});
    called.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_EQ(fullResCalls.load(), 1);
}

TEST(SinkRoutingTest, TrackerSinkReceivesTrackerFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::promise<void> called;
    std::atomic<int> trackerCalls{0};
    pipeline.addSink({"tracker", cam::SinkRole::TRACKER},
                     [&](const cam::SinkFrame&) {
                         trackerCalls++;
                         called.set_value();
                     });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverTrackerRgba(fakePixels, 4, 4, 16, 1, {});
    called.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_EQ(trackerCalls.load(), 1);
}

TEST(SinkRoutingTest, TrackerSinkDoesNotReceiveFullResFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::atomic<int> trackerCalls{0};
    pipeline.addSink({"tracker", cam::SinkRole::TRACKER},
                     [&](const cam::SinkFrame&) { trackerCalls++; });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverFullResRgba(fakePixels, 4, 4, 16, 1, {});
    // Negative test: no event fires when the callback should NOT be called.
    // A short sleep is required to allow any erroneous dispatch to arrive.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(trackerCalls.load(), 0);
}

TEST(SinkRoutingTest, FullResSinkDoesNotReceiveTrackerFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::atomic<int> fullResCalls{0};
    pipeline.addSink({"stitcher", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame&) { fullResCalls++; });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverTrackerRgba(fakePixels, 4, 4, 16, 1, {});
    // Negative test: no event fires when the callback should NOT be called.
    // A short sleep is required to allow any erroneous dispatch to arrive.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(fullResCalls.load(), 0);
}

TEST(SinkRoutingTest, BothSinksReceiveCorrectFramesIndependently) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::promise<void> fullResCalled, trackerCalled;
    std::atomic<int> fullResCalls{0}, trackerCalls{0};
    pipeline.addSink({"stitcher", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame&) {
                         fullResCalls++;
                         fullResCalled.set_value();
                     });
    pipeline.addSink({"tracker", cam::SinkRole::TRACKER},
                     [&](const cam::SinkFrame&) {
                         trackerCalls++;
                         trackerCalled.set_value();
                     });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverFullResRgba(fakePixels, 4, 4, 16, 1, {});
    pipeline.deliverTrackerRgba(fakePixels, 4, 4, 16, 2, {});
    fullResCalled.get_future().wait_for(std::chrono::seconds(2));
    trackerCalled.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_EQ(fullResCalls.load(), 1);
    EXPECT_EQ(trackerCalls.load(), 1);
}
