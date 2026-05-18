#include <metal_stdlib>
using namespace metal;

// Stage 06 — Pass 4 tracker downsample. Samples `processedTex` with bilinear
// filtering into an aspect-preserved, even-pixel-rounded `trackerTex` whose
// height is constants.md#TRACKER_HEIGHT_PX. Width is decided on the host and
// passed through the output texture's own dimensions — the kernel just maps
// gid → normalized coords → sample.

kernel void trackerDownsample(texture2d<float, access::sample>  inTex  [[texture(0)]],
                              texture2d<float, access::write>   outTex [[texture(1)]],
                              sampler                           s      [[sampler(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }
    float2 uv = float2(
        (float(gid.x) + 0.5) / float(outTex.get_width()),
        (float(gid.y) + 0.5) / float(outTex.get_height())
    );
    float4 c = inTex.sample(s, uv);
    outTex.write(c, gid);
}
