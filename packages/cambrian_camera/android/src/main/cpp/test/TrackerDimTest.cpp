#include <gtest/gtest.h>
#include <tuple>

// The tracker width formula (mirrors GpuRenderer::init())
static int trackerWidth(int w, int h) {
    return ((w * 480 / h) + 1) & ~1;
}

struct TrackerDimTestParams { int w; int h; int expectedW; };

class TrackerDimTest : public ::testing::TestWithParam<TrackerDimTestParams> {};

TEST_P(TrackerDimTest, WidthIsCorrectAndEven) {
    auto [w, h, expectedW] = GetParam();
    int result = trackerWidth(w, h);
    EXPECT_EQ(result, expectedW);
    EXPECT_EQ(result % 2, 0) << "trackerWidth must be even";
}

INSTANTIATE_TEST_SUITE_P(KnownAspectRatios, TrackerDimTest, ::testing::Values(
    TrackerDimTestParams{3840, 2160, 854},  // 16:9 → 853.3 → 854 (even)
    TrackerDimTestParams{4160, 3120, 640},  // 4:3  → 640.0 → 640 (even)
    TrackerDimTestParams{4032, 3024, 640},  // 4:3  → 640.0 → 640 (even)
    TrackerDimTestParams{1920, 1080, 854}   // 1080p 16:9 → same as 4K
));
