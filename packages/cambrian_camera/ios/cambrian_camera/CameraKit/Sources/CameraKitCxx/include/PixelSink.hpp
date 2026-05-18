#pragma once
#include <cstdint>

// C++ abstract PixelSink interface per ADR-31.
// No OpenCV in public headers (ADR-11) — only POD types.

struct PixelFrame {
    uint32_t stream;
    uint64_t frameNumber;
    int64_t  presentationTimeNs;
    void*    surface;  // IOSurfaceRef, valid for duration of call only
};

struct OverwriteEvent {
    uint32_t stream;
};

class PixelSink {
public:
    virtual void onFrame(const PixelFrame&) = 0;
    virtual void onOverwrite(const OverwriteEvent&) = 0;
    virtual ~PixelSink() = default;
};
