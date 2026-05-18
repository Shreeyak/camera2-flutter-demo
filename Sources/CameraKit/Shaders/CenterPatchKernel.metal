#include <metal_stdlib>
using namespace metal;

// Stage 04 — center-patch sampler. One thread per pixel in the
// CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX region centered on processedTex.
// Each thread writes (R, G, B) at the linear index `gid.y * patchSize + gid.x`
// into three flat float buffers. CPU sorts + trimmed-means per channel.
//
// Dispatch: threadgroups = (patchSize / 16, patchSize / 16, 1), threadgroup
// = (16, 16, 1). For patchSize = 96, dispatches 6×6 threadgroups.

struct PatchUniform {
    uint patchSize;     // CENTER_PATCH_SIZE_PX
    uint patchOriginX;  // (texWidth  - patchSize) / 2
    uint patchOriginY;  // (texHeight - patchSize) / 2
};

kernel void centerPatchHistogram(texture2d<float, access::read> srcTex     [[texture(0)]],
                                  device   float*               outR        [[buffer(0)]],
                                  device   float*               outG        [[buffer(1)]],
                                  device   float*               outB        [[buffer(2)]],
                                  constant PatchUniform&        u           [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    // Bounds guard inside the patch.
    if (gid.x >= u.patchSize || gid.y >= u.patchSize) {
        return;
    }
    uint2 srcCoord = uint2(u.patchOriginX + gid.x, u.patchOriginY + gid.y);
    if (srcCoord.x >= srcTex.get_width() || srcCoord.y >= srcTex.get_height()) {
        // Patch larger than source — write 0 so the trimmed mean isn't biased
        // by uninitialised memory. (Should not happen for typical capture sizes.)
        uint idx = gid.y * u.patchSize + gid.x;
        outR[idx] = 0.0;
        outG[idx] = 0.0;
        outB[idx] = 0.0;
        return;
    }

    float4 px = srcTex.read(srcCoord);
    uint idx = gid.y * u.patchSize + gid.x;
    outR[idx] = px.r;
    outG[idx] = px.g;
    outB[idx] = px.b;
}
