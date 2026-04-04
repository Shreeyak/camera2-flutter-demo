#include <gtest/gtest.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <future>
#include <numeric>
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

TEST(SinkRoutingTest, RawSinkReceivesRawFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::promise<void> called;
    std::atomic<int> rawCalls{0};
    pipeline.addSink({"rawSink", cam::SinkRole::RAW},
                     [&](const cam::SinkFrame&) {
                         rawCalls++;
                         called.set_value();
                     });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverRawRgba(fakePixels, 4, 4, 16, 1, {});
    called.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_EQ(rawCalls.load(), 1);
}

TEST(SinkRoutingTest, RawSinkDoesNotReceiveFullResFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::atomic<int> rawCalls{0};
    pipeline.addSink({"rawSink", cam::SinkRole::RAW},
                     [&](const cam::SinkFrame&) { rawCalls++; });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverFullResRgba(fakePixels, 4, 4, 16, 1, {});
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(rawCalls.load(), 0);
}

TEST(SinkRoutingTest, FullResSinkDoesNotReceiveRawFrames) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    std::atomic<int> fullResCalls{0};
    pipeline.addSink({"stitcher", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame&) { fullResCalls++; });

    uint8_t fakePixels[4 * 4 * 4] = {};
    pipeline.deliverRawRgba(fakePixels, 4, 4, 16, 1, {});
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(fullResCalls.load(), 0);
}

// ---------------------------------------------------------------------------
// Buffer content verification tests
// ---------------------------------------------------------------------------

// Helper: fill buffer with a recognizable pattern (0x00, 0x01, 0x02, ...).
static void fillPattern(uint8_t* buf, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        buf[i] = static_cast<uint8_t>(i & 0xFF);
    }
}

TEST(SinkDataTest, FullResConsumerReceivesCorrectPixelData) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    constexpr int W = 8, H = 4, STRIDE = W * 4;
    uint8_t src[H * STRIDE];
    fillPattern(src, sizeof(src));

    std::promise<void> done;
    bool dataMatches = false;

    pipeline.addSink({"verify", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame& f) {
                         dataMatches = (f.width == W && f.height == H &&
                                        f.stride >= W * 4 &&
                                        std::memcmp(f.data, src, sizeof(src)) == 0);
                         done.set_value();
                     });

    pipeline.deliverFullResRgba(src, W, H, STRIDE, 1, {});
    done.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_TRUE(dataMatches);
}

TEST(SinkDataTest, TrackerConsumerReceivesCorrectPixelData) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    constexpr int W = 6, H = 3, STRIDE = W * 4;
    uint8_t src[H * STRIDE];
    fillPattern(src, sizeof(src));

    std::promise<void> done;
    bool dataMatches = false;

    pipeline.addSink({"verify", cam::SinkRole::TRACKER},
                     [&](const cam::SinkFrame& f) {
                         dataMatches = (f.width == W && f.height == H &&
                                        f.stride >= W * 4 &&
                                        std::memcmp(f.data, src, sizeof(src)) == 0);
                         done.set_value();
                     });

    pipeline.deliverTrackerRgba(src, W, H, STRIDE, 1, {});
    done.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_TRUE(dataMatches);
}

TEST(SinkDataTest, RawConsumerReceivesCorrectPixelData) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    constexpr int W = 4, H = 2, STRIDE = W * 4;
    uint8_t src[H * STRIDE];
    fillPattern(src, sizeof(src));

    std::promise<void> done;
    bool dataMatches = false;

    pipeline.addSink({"verify", cam::SinkRole::RAW},
                     [&](const cam::SinkFrame& f) {
                         dataMatches = (f.width == W && f.height == H &&
                                        f.stride >= W * 4 &&
                                        std::memcmp(f.data, src, sizeof(src)) == 0);
                         done.set_value();
                     });

    pipeline.deliverRawRgba(src, W, H, STRIDE, 1, {});
    done.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_TRUE(dataMatches);
}

TEST(SinkDataTest, SinkFrameMetadataMatchesInput) {
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    constexpr int W = 4, H = 4, STRIDE = W * 4;
    uint8_t src[H * STRIDE] = {};

    cam::FrameMetadata inMeta{};
    inMeta.frameNumber       = 42;
    inMeta.sensorTimestampNs = 123456789;
    inMeta.exposureTimeNs    = 33333333;
    inMeta.iso               = 800;
    inMeta.displayRotation   = 90;

    std::promise<void> done;
    cam::SinkFrame received{};

    pipeline.addSink({"verify", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame& f) {
                         received = f;
                         // Copy the pointer to verify non-null, but don't keep it.
                         done.set_value();
                     });

    pipeline.deliverFullResRgba(src, W, H, STRIDE, /*frameId=*/99, inMeta);
    done.get_future().wait_for(std::chrono::seconds(2));

    EXPECT_EQ(received.width, W);
    EXPECT_EQ(received.height, H);
    EXPECT_GE(received.stride, W * 4);
    EXPECT_EQ(received.format, cam::PixelFormat::RGBA);
    EXPECT_EQ(received.frameId, 99u);
    EXPECT_EQ(received.meta.frameNumber, 42);
    EXPECT_EQ(received.meta.sensorTimestampNs, 123456789);
    EXPECT_EQ(received.meta.exposureTimeNs, 33333333);
    EXPECT_EQ(received.meta.iso, 800);
    EXPECT_EQ(received.meta.displayRotation, 90);
}

TEST(SinkDataTest, PaddedStrideStripsRowPadding) {
    // Input has stride > width*4 (extra padding bytes per row).
    // Consumer should receive only the pixel data without the padding.
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    constexpr int W = 4, H = 3;
    constexpr int INPUT_STRIDE = W * 4 + 16;  // 16 bytes of padding per row
    uint8_t src[H * INPUT_STRIDE];
    memset(src, 0xAA, sizeof(src));  // fill everything (including padding) with 0xAA

    // Write a distinct pattern into actual pixel bytes only.
    for (int row = 0; row < H; ++row) {
        for (int col = 0; col < W * 4; ++col) {
            src[row * INPUT_STRIDE + col] = static_cast<uint8_t>((row * W * 4 + col) & 0xFF);
        }
    }

    std::promise<void> done;
    bool pixelsCorrect = false;

    pipeline.addSink({"verify", cam::SinkRole::FULL_RES},
                     [&](const cam::SinkFrame& f) {
                         // Verify each row's pixel data matches, ignoring output stride.
                         bool ok = (f.width == W && f.height == H);
                         for (int row = 0; row < H && ok; ++row) {
                             const uint8_t* expected = src + row * INPUT_STRIDE;
                             const uint8_t* actual   = f.data + row * f.stride;
                             if (std::memcmp(actual, expected, W * 4) != 0) {
                                 ok = false;
                             }
                         }
                         pixelsCorrect = ok;
                         done.set_value();
                     });

    pipeline.deliverFullResRgba(src, W, H, INPUT_STRIDE, 1, {});
    done.get_future().wait_for(std::chrono::seconds(2));
    EXPECT_TRUE(pixelsCorrect);
}

TEST(SinkDataTest, EmptyConsumerVectorSkipsAllocation) {
    // With no consumers, deliverFullResRgba should return immediately
    // and not crash. This is the fast-path test.
    cam::ImagePipeline pipeline(nullptr, 64, 64);

    uint8_t src[4 * 4 * 4] = {};
    // Should not crash or hang.
    pipeline.deliverFullResRgba(src, 4, 4, 16, 1, {});
    pipeline.deliverTrackerRgba(src, 4, 4, 16, 1, {});
    pipeline.deliverRawRgba(src, 4, 4, 16, 1, {});
}
