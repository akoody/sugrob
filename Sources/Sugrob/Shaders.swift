let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct U { float2 screen; float time; float pad; };

struct SpriteI { float2 pos; float2 size; float4 uv; float4 color; float rot; float z; float2 pad; };
struct SpriteV { float4 pos [[position]]; float2 uv; float4 color; };

vertex SpriteV spriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant SpriteI *items [[buffer(0)]], constant U &u [[buffer(1)]]) {
    const float2 corners[4] = { float2(-.5,-.5), float2(.5,-.5), float2(-.5,.5), float2(.5,.5) };
    SpriteI i = items[iid];
    float2 q = corners[vid];
    float2 p = q * i.size;
    float c = cos(i.rot), s = sin(i.rot);
    p = float2(p.x * c - p.y * s, p.x * s + p.y * c) + i.pos;
    SpriteV o;
    o.pos = float4(p.x / u.screen.x * 2 - 1, 1 - p.y / u.screen.y * 2, i.z, 1);
    o.uv = mix(i.uv.xy, i.uv.zw, q + .5);
    o.color = i.color;
    return o;
}

fragment float4 spriteFragment(SpriteV in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * in.color;
}

vertex float4 occluderVertex(uint vid [[vertex_id]], constant float4 *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
    float4 p = v[vid];
    return float4(p.x / u.screen.x * 2 - 1, 1 - p.y / u.screen.y * 2, p.z, 1);
}

struct SnowIn { float4 p; float4 q; float4 r; };
struct SnowV { float4 pos [[position]]; float depth; float wx; float h; float shadow; float slope; float tint; };

vertex SnowV snowVertex(uint vid [[vertex_id]], constant SnowIn *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
    SnowIn i = v[vid];
    SnowV o;
    o.pos = float4(i.p.x / u.screen.x * 2 - 1, 1 - i.p.y / u.screen.y * 2, i.p.w, 1);
    o.depth = i.p.z;
    o.wx = i.q.x;
    o.h = i.q.y;
    o.shadow = i.q.z;
    o.slope = i.q.w;
    o.tint = i.r.x;
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Fresh snow: a bright rim at the crest, a slow fall into clean cool shade, and a few sparks.
fragment float4 snowFragment(SnowV in [[stage_in]], constant U &u [[buffer(1)]]) {
    float d = in.depth, h = in.h;
    float presence = smoothstep(0.1, 1.2, h);
    if (presence <= 0.001) discard_fragment();
    float edge = smoothstep(-0.8, 0.5, d);
    float body = 1.0 - smoothstep(h - 0.6, h + 0.6, d);

    float3 c = mix(float3(1.0), float3(0.83, 0.895, 0.98), smoothstep(0.0, 1.0, saturate(d / max(h, 30.0))));
    float lit = clamp(in.slope * 2.2, -1.0, 1.0);
    c += float3(0.04, 0.035, 0.022) * lit * (1.0 - smoothstep(2.0, 26.0, d));
    c = mix(c, float3(1.0), 0.7 * (1.0 - smoothstep(0.0, 3.5, d)));
    c = mix(c, float3(0.76, 0.84, 0.965), in.tint);

    // A handful of small round sparks. They shift whenever the wind moves the snow.
    float2 uv = float2(in.wx, d) / 3.2;
    float2 cell = floor(uv);
    float seed = hash21(cell);
    if (seed > 0.992 && in.tint < 0.5 && d > 2.0) {
        float2 centre = float2(hash21(cell + 7.3), hash21(cell + 19.1)) * 0.5 + 0.25;
        float dotShape = 1.0 - smoothstep(0.1, 0.3, length(fract(uv) - centre));
        c += float3(0.6) * dotShape * pow(sin(u.time * (0.8 + seed * 2.0) + seed * 90.0) * 0.5 + 0.5, 4.0);
    }

    float alpha = 1.0 - in.tint * 0.06;
    float4 snow = float4(saturate(c), 1.0) * alpha * edge * presence * body;
    if (in.shadow > 0.01 && d > h - 0.6) {
        float t = saturate(1.0 - (d - h) / in.shadow);
        snow += float4(0.0, 0.0, 0.0, 1.0) * 0.14 * t * t * presence * (1.0 - body);
    }
    return snow;
}
"""#
