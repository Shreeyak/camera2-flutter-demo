#include <metal_stdlib>
using namespace metal;

// BT.709 video-range RGB → YCbCr coefficients.
// Y  in  [16..235], CbCr in [16..240].
constant float  kR_Y  = 0.183;
constant float  kG_Y  = 0.614;
constant float  kB_Y  = 0.062;
constant float  kR_Cb = -0.101;
constant float  kG_Cb = -0.338;
constant float  kB_Cb =  0.439;
constant float  kR_Cr =  0.439;
constant float  kG_Cr = -0.399;
constant float  kB_Cr = -0.040;

/// Pass 5 — RGBA16F processed texture → NV12 planes (Y full-res, CbCr 2x2 downsampled).
/// Dispatched over the CbCr grid (chromaW = width/2, chromaH = height/2); each invocation
/// writes the 2x2 Y block and a single CbCr pixel by averaging the 2x2 RGB neighborhood.
kernel void rgba16fToNV12(
    texture2d<float, access::read>   inRGBA     [[ texture(0) ]],
    texture2d<float, access::write>  yPlane     [[ texture(1) ]],
    texture2d<float, access::write>  cbcrPlane  [[ texture(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    const uint x0 = gid.x * 2;
    const uint y0 = gid.y * 2;
    if (x0 + 1 >= inRGBA.get_width() || y0 + 1 >= inRGBA.get_height()) return;

    float4 p00 = inRGBA.read(uint2(x0,     y0));
    float4 p10 = inRGBA.read(uint2(x0 + 1, y0));
    float4 p01 = inRGBA.read(uint2(x0,     y0 + 1));
    float4 p11 = inRGBA.read(uint2(x0 + 1, y0 + 1));

    auto toY = [](float3 rgb) {
        float y = kR_Y * rgb.r + kG_Y * rgb.g + kB_Y * rgb.b + 16.0/255.0;
        return clamp(y, 16.0/255.0, 235.0/255.0);
    };
    yPlane.write(float4(toY(p00.rgb), 0, 0, 0), uint2(x0,     y0));
    yPlane.write(float4(toY(p10.rgb), 0, 0, 0), uint2(x0 + 1, y0));
    yPlane.write(float4(toY(p01.rgb), 0, 0, 0), uint2(x0,     y0 + 1));
    yPlane.write(float4(toY(p11.rgb), 0, 0, 0), uint2(x0 + 1, y0 + 1));

    float3 avg = 0.25 * (p00.rgb + p10.rgb + p01.rgb + p11.rgb);
    float cb = kR_Cb * avg.r + kG_Cb * avg.g + kB_Cb * avg.b + 128.0/255.0;
    float cr = kR_Cr * avg.r + kG_Cr * avg.g + kB_Cr * avg.b + 128.0/255.0;
    cb = clamp(cb, 16.0/255.0, 240.0/255.0);
    cr = clamp(cr, 16.0/255.0, 240.0/255.0);
    // CbCr is rg8Unorm — .r = Cb, .g = Cr.
    cbcrPlane.write(float4(cb, cr, 0, 0), gid);
}
