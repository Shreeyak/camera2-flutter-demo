#include <metal_stdlib>
using namespace metal;

// Pre-Phase-3 Pass-7 — convert a half-float RGBA texture to an 8-bit BGRA
// IOSurface view. Metal's BGRA8Unorm format handles the byte-order swizzle on
// write; the kernel writes `float4(R, G, B, A)` in source channel order and
// the GPU stores it as B, G, R, A bytes. Clamp to [0, 1] so half-floats above
// nominal range don't wrap into a low 8-bit value.
//
// One dispatch per lane (natural + processed) when
// `OpenConfiguration.lanesEightBit` is true. Tracker lane is not converted.
//
// Reference: docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md.

kernel void rgba16fToBgra8(
    texture2d<float, access::read>   inRGBA  [[texture(0)]],
    texture2d<float, access::write>  outBGRA [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outBGRA.get_width() || gid.y >= outBGRA.get_height()) {
        return;
    }
    float4 c = inRGBA.read(gid);
    c = clamp(c, 0.0, 1.0);
    outBGRA.write(c, gid);
}
