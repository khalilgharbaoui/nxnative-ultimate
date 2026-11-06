// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
// mode.x (nvn_mtl.m present_mode) says how the source is encoded: 0 as stored (and the game's HDR10 window for the PQ layer);
// 1 an HDR10 source (the game's RGB10A2 window: SMPTE ST 2084 code values in BT.2020 primaries) for an SDR target, where mode.y is the paper white in nits; 2 a gamma-coded BT.709 (sRGB) source for the PQ layer (RGB10A2 in BT.2100 PQ, DM_HDR): fs encodes it as HDR10 at the paper white;
// 3 a float source (linear BT.709) for the PQ layer, encoded the same way (untested: no local game presents a float window); 4 the HDR10 window for the PQ layer without metadata,
// rolled off above mode.z nits into mode.w nits (hle_vi.c dm_hdr_rolloff). mode.z and mode.w are unused otherwise.
struct Crop { float4 rect; float4 edge; float4 mode; };
// Linear BT.709 and BT.2020 (ITU-R BT.2087; each row sums to 1, so white stays white). Metal's float3x3 takes its columns.
constant float3x3 kRec709To2020 = float3x3(float3(0.627404, 0.069097, 0.016391), float3(0.329283, 0.919540, 0.088013), float3(0.043313, 0.011362, 0.895595));
constant float3x3 kRec2020To709 = float3x3(float3(1.660491, -0.124550, -0.018151), float3(-0.587641, 1.132900, -0.100579), float3(-0.072850, -0.008349, 1.118730));
static inline float3 present_srgb_to_linear(float3 c) {
    float3 lo = c * (1.0 / 12.92);
    float3 hi = pow((c + 0.055) * (1.0 / 1.055), float3(2.4));
    return select(hi, lo, c <= 0.04045);
}
static inline float3 present_linear_to_srgb(float3 l) {
    float3 lo = l * 12.92;
    float3 hi = 1.055 * pow(l, float3(1.0 / 2.4)) - 0.055;
    return select(hi, lo, l <= 0.0031308);
}
// SMPTE ST 2084 EOTF: code value e to absolute luminance (10000 nits = 1.0), divided by the paper white so that 1.0 is the display's SDR white and values above it are headroom
static inline float3 present_pq_to_linear(float3 e, float paper) {
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 ep = pow(max(e, float3(0.0)), float3(1.0 / m2));
    float3 num = max(ep - c1, float3(0.0));
    float3 den = max(c2 - c3 * ep, float3(1e-6));
    return 10000.0 * pow(num / den, float3(1.0 / m1)) / paper;
}
// SMPTE ST 2084 inverse EOTF: linear light where 1.0 is the paper white, to code values (10000 nits = 1.0). pow() gets a positive base (the library is built with fast math)
static inline float3 present_linear_to_pq(float3 l, float paper) {
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float3 ym = pow(max(l * (paper / 10000.0), float3(1e-30)), float3(m1));
    return pow((c1 + c2 * ym) / (1.0 + c3 * ym), float3(m2));
}
// A highlight brought to SDR white as an SDR screen shows it: the largest channel goes to 1.0 and the others scale with it, so the hue holds (a screenshot of an HDR frame)
static inline float3 present_to_sdr_white(float3 c0) {
    float3 c = clamp(c0, -65504.0, 65504.0);   // finite: an infinite channel would give inf * 0 below
    float m = max(max(c.r, c.g), c.b);
    return m > 1.0 ? c * (1.0 / m) : c;
}
// Every target. The PQ HDR layer (RGB10A2 in BT.2100 PQ): the game's HDR10 window as it is (mode 0), an SDR or float source encoded as HDR10 at the paper white
// (modes 2, 3). The SDR drawable (gamma-coded 8-bit, BT.709; a screenshot): an HDR10 source at its paper white, its highlights brought to SDR white with their hue
// (present_to_sdr_white), then converted to BT.709; a colour outside BT.709 is clipped
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float4 v = t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    if (c.mode.x > 3.5) {   // the PQ layer without metadata: the game's HDR10 window, its pixels above the knee (mode.z, nits) compressed into the screen's peak (mode.w)
        float3 n = present_pq_to_linear(v.rgb, 1.0); float m = max(max(n.r, n.g), n.b), k = c.mode.z, pk = c.mode.w;
        if (m > k) n *= (k + (pk - k) * (1.0 - exp(-(m - k) / (pk - k)))) / m;   // slope 1 at the knee, towards the peak; the brightest channel sets it, so the hue is kept
        v.rgb = present_linear_to_pq(n, 1.0);
    } else
    if (c.mode.x > 2.5) v.rgb = present_linear_to_pq(kRec709To2020 * clamp(v.rgb, 0.0, 65504.0), c.mode.y);     // the PQ layer: a float source (linear BT.709) as HDR10 at the paper white
    else if (c.mode.x > 1.5) v.rgb = present_linear_to_pq(kRec709To2020 * present_srgb_to_linear(v.rgb), c.mode.y);   // the PQ layer: an SDR source as HDR10 at the paper white
    else if (c.mode.x > 0.5) v.rgb = present_linear_to_srgb(saturate(kRec2020To709 * present_to_sdr_white(present_pq_to_linear(v.rgb, c.mode.y))));
    return v;
}
// FSR 1 draws the picture as stored (mode.x 0): a picture the pass converts for its target (the HDR layer, an HDR10 window into SDR) takes fs (nvn_mtl.m present_encode_m4)
// Edge adaptive spatial upsampling (DM_PRESENT_UPSCALE=fsr): AMD FidelityFX Super Resolution 1.0's EASU (MIT licence, Copyright (c) 2021 Advanced Micro Devices, Inc.),
// in one pass straight into the drawable, in half precision as FSR's own FsrEasuH. 12 texels around the output pixel's position in the source; the local edge direction and length (from the luma of the 2x2 nearest
// texels' crosses) shape a Lanczos-like kernel that is stretched along the edge, and the result is clamped to the 2x2 nearest texels' range so it cannot ring. Cheaper than
// MetalFX's spatial scaler: no copy of the input, no output texture, one draw
static half easu_luma(half3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }
static void easu_set(thread half2 &dir, thread half &len, half w, half lA, half lB, half lC, half lD, half lE) {
  half dc = lD - lC, cb = lC - lB;
  half lenX = 1.0h / max(max(abs(dc), abs(cb)), 1.0h / 16384.0h);
  half dirX = lD - lB; dir.x += dirX * w;
  lenX = saturate(abs(dirX) * lenX); len += lenX * lenX * w;
  half ec = lE - lC, ca = lC - lA;
  half lenY = 1.0h / max(max(abs(ec), abs(ca)), 1.0h / 16384.0h);
  half dirY = lE - lA; dir.y += dirY * w;
  lenY = saturate(abs(dirY) * lenY); len += lenY * lenY * w;
}
static void easu_tap(thread half3 &aC, thread half &aW, half2 off, half2 dir, half2 len, half lob, half clp, half3 c) {
  half2 v = half2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;
  half d2 = min(dot(v, v), clp);
  half wB = 0.4h * d2 - 1.0h, wA = lob * d2 - 1.0h;
  wB *= wB; wA *= wA;
  wB = 1.5625h * wB - 0.5625h;
  half w = wB * wA;
  aC += c * w; aW += w;
}
fragment float4 easu(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
  float2 d = 1.0 / float2(t.get_width(), t.get_height());   // one source texel in uv
  float2 uv = in.uv * c.rect.zw + c.rect.xy;             // where this output pixel's centre falls in the source
  float2 pq = uv / d - 0.5, fp = floor(pq); half2 pp = half2(pq - fp);    // texel f (the 2x2's top left) and the position within the 2x2
  int2 q = int2(fp), lo0 = int2(c.edge.xy / d), hi0 = int2(c.edge.zw / d);   // texel reads (no filtering), clamped to the valid rectangle's texels
  #define T(x, y) half3(t.read(uint2(clamp(q + int2(x, y), lo0, hi0))).rgb)
  half3 b = T(0, -1), cc = T(1, -1), e = T(-1, 0), f = T(0, 0), g = T(1, 0), h = T(2, 0);
  half3 i = T(-1, 1), j = T(0, 1), k = T(1, 1), l = T(2, 1), n = T(0, 2), o = T(1, 2);
  #undef T
  half bL = easu_luma(b), cL = easu_luma(cc), eL = easu_luma(e), fL = easu_luma(f), gL = easu_luma(g), hL = easu_luma(h);
  half iL = easu_luma(i), jL = easu_luma(j), kL = easu_luma(k), lL = easu_luma(l), nL = easu_luma(n), oL = easu_luma(o);
  half2 dir = 0; half len = 0;
  easu_set(dir, len, (1 - pp.x) * (1 - pp.y), bL, eL, fL, gL, jL);
  easu_set(dir, len, pp.x * (1 - pp.y), cL, fL, gL, hL, kL);
  easu_set(dir, len, (1 - pp.x) * pp.y, fL, iL, jL, kL, nL);
  easu_set(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);
  half dirR = dot(dir, dir); bool zro = dirR < 1.0h / 16384.0h;
  dirR = zro ? 1 : rsqrt(dirR); dir.x = zro ? 1 : dir.x; dir *= dirR;
  len = len * 0.5; len *= len;
  half stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));
  half2 len2 = half2(1.0h + (stretch - 1.0h) * len, 1.0h - 0.5h * len);
  half lob = 0.5h + (0.21h - 0.5h) * len, clp = 1.0h / lob;
  half3 aC = 0; half aW = 0;
  easu_tap(aC, aW, half2( 0, -1) - pp, dir, len2, lob, clp, b);
  easu_tap(aC, aW, half2( 1, -1) - pp, dir, len2, lob, clp, cc);
  easu_tap(aC, aW, half2(-1,  1) - pp, dir, len2, lob, clp, i);
  easu_tap(aC, aW, half2( 0,  1) - pp, dir, len2, lob, clp, j);
  easu_tap(aC, aW, half2( 0,  0) - pp, dir, len2, lob, clp, f);
  easu_tap(aC, aW, half2(-1,  0) - pp, dir, len2, lob, clp, e);
  easu_tap(aC, aW, half2( 1,  1) - pp, dir, len2, lob, clp, k);
  easu_tap(aC, aW, half2( 2,  1) - pp, dir, len2, lob, clp, l);
  easu_tap(aC, aW, half2( 2,  0) - pp, dir, len2, lob, clp, h);
  easu_tap(aC, aW, half2( 1,  0) - pp, dir, len2, lob, clp, g);
  easu_tap(aC, aW, half2( 1,  2) - pp, dir, len2, lob, clp, o);
  easu_tap(aC, aW, half2( 0,  2) - pp, dir, len2, lob, clp, n);
  half3 lo = min(min(f, g), min(j, k)), hi = max(max(f, g), max(j, k));
  return float4(float3(clamp(aC / aW, lo, hi)), 1);
}
