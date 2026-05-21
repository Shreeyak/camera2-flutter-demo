#include <metal_stdlib>
using namespace metal;

// BT.601 full-range YCbCr 4:2:0 → RGBA16F conversion, with true sub-region crop.
//
// P2a true crop: the output texture IS the crop-region size. The host sets a
// CropUniform once at pipeline construction carrying the crop origin (in sensor
// pixels). Each output pixel `gid` reads the source at `gid + cropOrigin`, so
// the kernel copies a 1:1 sub-region of the sensor (no zoom, no masking). When
// uncropped, origin is (0,0) and outTex dims equal the sensor dims — identical
// to the Stage-01 baseline. `width`/`height` in CropUniform are now unused by
// the shader (the output texture's own dims bound the dispatch); the struct
// layout is preserved to match the Swift `CropUniform` host side.

struct CropUniform {
    uint originX;
    uint originY;
    uint width;
    uint height;
};

kernel void yuvToRgba(texture2d<float, access::read>  yTex    [[texture(0)]],
                      texture2d<float, access::read>  cbcrTex [[texture(1)]],
                      texture2d<float, access::write> outTex  [[texture(2)]],
                      constant CropUniform&           crop    [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    // Texture-bounds guard — extra threads dispatched to fill a tile may exceed
    // the output (crop-region) texture size.
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
        return;
    }

    // Map the output pixel to its source pixel in the full sensor frame.
    uint2 src = uint2(gid.x + crop.originX, gid.y + crop.originY);

    // Sample luma — full-range: Y already in [0, 1].
    float Y = yTex.read(src).r;

    // Sample chroma — 4:2:0: chroma plane is half-resolution in both dimensions.
    float2 UV = cbcrTex.read(uint2(src.x / 2, src.y / 2)).rg;

    // Center chroma around 0 (UV values from .rg8Unorm are [0, 1]).
    float Cb = UV.x - 0.5;
    float Cr = UV.y - 0.5;

    // BT.601 full-range matrix.
    float R = Y + 1.402   * Cr;
    float G = Y - 0.344136 * Cb - 0.714136 * Cr;
    float B = Y + 1.772   * Cb;

    outTex.write(float4(R, G, B, 1.0), gid);
}
