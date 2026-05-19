//
//  OrbShader.metal
//  pocket-tts-macos
//
//  Port of the Gemini "Slo-Mo AI Fractal Orb" shader from Orb.tsx (GLSL)
//  to Metal Shading Language. Two layers composited in a single pass:
//  1. Plasma raymarcher — sphere SDF with chained-sine fractal noise + beam
//  2. Ice-blue disc — simplex 3D noise edge warp

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared uniform struct (mirrored in OrbView.swift)

struct OrbUniforms {
    float time;
    float intensity;
    float smoothAmp;
    float2 resolution;
};

// MARK: - Vertex

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut orbVertex(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        {-1,-1}, {1,-1}, {-1,1},
        {-1,1},  {1,-1}, {1,1}
    };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = positions[vid] * 2.5;
    return out;
}

// MARK: - Simplex 3D noise (for disc edge warp)

static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0/6.0, 1.0/3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, float3(C.y)));
    float3 x0 = v - i + dot(i, float3(C.x));
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + float3(C.x);
    float3 x2 = x0 - i2 + float3(C.y);
    float3 x3 = x0 - float3(D.y);
    i = mod289(i);
    float4 p = permute(permute(permute(
                i.z + float4(0.0, i1.z, i2.z, 1.0))
              + i.y + float4(0.0, i1.y, i2.y, 1.0))
              + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + float4(ns.y);
    float4 y = y_ * ns.x + float4(ns.y);
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = float4(b0.xz, b0.yw) + float4(s0.xz, s0.yw) * float4(sh.xx, sh.yy);
    float4 a1 = float4(b1.xz, b1.yw) + float4(s1.xz, s1.yw) * float4(sh.zz, sh.ww);
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

// MARK: - Plasma SDF helpers

static float3x3 rotY(float a) {
    float c = cos(a), s = sin(a);
    // GLSL mat3(c,0,s, 0,1,0, -s,0,c) fills columns first →
    // columns are [c,0,-s], [0,1,0], [s,0,c]
    return float3x3(float3(c,0,-s), float3(0,1,0), float3(s,0,c));
}

static float getBeam(float3 p, float time) {
    float beamSDF = length(p.yz) - 0.08;
    float3 q = p * float3(0.4, 2.0, 1.0) + (time * 0.1);
    float noise = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        noise += amp * abs(sin(q.x + sin(q.y + sin(q.z))));
        q *= 1.8;
        amp *= 0.5;
    }
    return beamSDF - noise * 0.08;
}

static float map(float3 p, float time, float intensity) {
    float res = length(p) - 1.1;
    float3 q = p * 1.2 + (time * 0.1);
    float f = 0.0;
    float amp = 0.5 + (intensity * 0.4);
    for (int i = 0; i < 6; i++) {
        q = rotY(time * 0.02) * q;
        f += amp * abs(sin(q.x + sin(q.y + sin(q.z))));
        q *= 1.7;
        amp *= 0.5;
    }
    float orb = res - f * (0.3 + intensity * 0.2);
    return min(orb, getBeam(p, time));
}

// MARK: - Fragment

fragment half4 orbFragment(VertexOut in [[stage_in]],
                           constant OrbUniforms& u [[buffer(0)]]) {
    // P0-O5: letterbox into the shorter dimension so the orb stays circular
    // regardless of window aspect ratio. The Electron port uses a
    // PerspectiveCamera which handles this in the projection matrix; we
    // emulate by shrinking the longer axis.
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv;
    if (aspect > 1.0) {
        uv.x *= aspect;
    } else {
        uv.y /= aspect;
    }

    // Plasma raymarch
    float3 ro = float3(0, 0, 3);
    float3 rd = normalize(float3(uv, -1.8));

    float t = 0.0;
    float3 col = float3(0.0);

    for (int i = 0; i < 50; i++) {
        float3 p = ro + rd * t;
        float d = map(p, u.time, u.intensity);
        if (t > 5.0) break;

        float glow = 0.015 / (0.015 + abs(d));

        float3 purple = float3(0.7, 0.0, 1.0) * glow;
        float3 cyan   = float3(0.2, 0.8, 1.0) * pow(glow, 2.5);
        float3 white  = float3(1.0) * pow(glow, 10.0) * u.intensity;

        col += (purple * 0.12) + (cyan * 0.15) + (white * 0.1);
        t += max(abs(d) * 0.5, 0.02);
    }

    // Use post-letterbox uv for the vignette so falloff stays circular too
    float dist = length(uv);
    col *= smoothstep(1.5, 0.8, dist);

    // Ice-blue disc, composited on top of the plasma.
    // P0-O3: scale with raw smoothAmp * 0.15 to match Electron's geometric
    // disc.scale.setScalar(1.0 + smoothAmp * 0.15).
    // P0-O2: no plasma-brightness attenuation. Electron's disc is a separate
    // alpha-blended draw call and stays visible at audio peaks.
    float DISC_R = 0.834;
    float r = length(uv);
    float theta = atan2(uv.y, uv.x);
    float discTime = u.time * 2.5;
    float n_a = snoise(float3(cos(theta), sin(theta), discTime * 0.165));
    float n_b = snoise(float3(cos(theta)*2.0, sin(theta)*2.0, discTime * 0.110)) * 0.35;
    float warp = (n_a + n_b) * 0.05;
    float effectiveR = DISC_R + warp;
    float discScale = 1.0 + u.smoothAmp * 0.15;
    effectiveR *= discScale;

    if (r < effectiveR) {
        float radial = clamp(r / effectiveR, 0.0, 1.0);
        float edge = pow(radial, 33.0);
        float3 iceBlue  = float3(0.55, 0.85, 1.10);
        float3 bodyTint = float3(0.30, 0.50, 0.85);
        float3 discCol = mix(bodyTint, iceBlue, edge);
        float discAlpha = mix(0.02, 0.95, edge);
        // Standard alpha-over compositing (matches Electron's NormalBlending).
        col = mix(col, discCol, discAlpha);
    }

    return half4(half3(col), 1.0h);
}
