/// The waiting screen's moving heat map, and the impact that clears it when the Mac connects.
/// Compiled on the device when the app starts. It has no UIKit in it, so Tools/shadercheck can
/// render the same effect on the Mac for checking.
let waitingShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float aspect;
    float impact;   // normalised transition progress, negative while idle
    float warmth;   // 0: black stop while disconnected, 1: amber stop while connected
    float effect;   // 0: impact reveal, +/-1: directional sweep, 2: return to waiting
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut waitingVertex(uint id [[vertex_id]]) {
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(corners[id], 0, 1);
    out.uv = (corners[id] + 1) * 0.5;
    return out;
}

// The existing warm palette, with a smaller, softer amber accent and more pink/coral.
static float3 heat(float value, float warmth) {
    float3 c0 = mix(float3(0.0), float3(1.000, 0.600, 0.025), warmth);
    const float3 c1 = float3(1.000, 0.450, 0.015);
    const float3 c2 = float3(1.000, 0.180, 0.388);
    const float3 c3 = float3(1.000, 0.353, 0.122);
    float v = fract(value);
    float3 a, b;
    float f;
    if (v < 0.10) { a = c0; b = c1; f = v / 0.10; }
    else if (v < 0.40) { a = c1; b = c2; f = (v - 0.10) / 0.30; }
    else if (v < 0.84) { a = c2; b = c3; f = (v - 0.40) / 0.44; }
    else { a = c3; b = c0; f = (v - 0.84) / 0.16; }
    // Continuous slope and curvature at every stop, including the loop seam.
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float3 color = mix(a, b, f);
    // A broad black region while waiting, with soft shoulders into the warm colours.
    // Fade this mask away with the connection blend, keeping the connected palette intact.
    float distanceFromBlack = min(v, 1.0 - v);
    float waitingLight = smoothstep(0.22, 0.38, distanceFromBlack);
    return color * mix(waitingLight, 1.0, warmth);
}

// Slow overlapping waves, each one bending the next, so it rolls instead of sliding.
static float field(float2 p, float t) {
    float2 q = p * 1.5;
    q += 0.38 * sin(q.yx * 2.1 + float2(t * 0.31, t * 0.23 + 1.7));
    q += 0.22 * sin(q.yx * 3.7 + float2(-t * 0.27, t * 0.19 + 4.1));
    float wave = sin(q.x * 2.3 + t * 0.37)
               + sin(q.y * 3.1 - t * 0.29)
               + sin((q.x + q.y) * 1.7 + t * 0.21);
    return wave / 3.0;
}

fragment float4 waitingFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = (in.uv - 0.5) * float2(u.aspect, 1.0);
    float value = field(p, u.time) * 0.62 + u.time * 0.012;
    float3 color = heat(value, u.warmth);

    // Soft contour shading, which is what makes it read as a heat map and not a plain gradient.
    float bands = 0.5 + 0.5 * cos(field(p, u.time) * 10.0);
    color *= 0.97 + 0.03 * bands;

    if (u.impact < 0.0) {
        // Fine, stationary grain gives the gradient texture without flickering.
        float noise = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        float grain = (noise - 0.5) * 0.045;
        float grainMask = smoothstep(0.0, 0.15, max(color.r, max(color.g, color.b)));
        return float4(clamp(color + grain * grainMask, 0.0, 1.0), 1.0);
    }

    if (abs(u.effect) == 1.0) {
        float progress = clamp(u.impact, 0.0, 1.0);
        float x = u.effect > 0.0 ? in.uv.x : 1.0 - in.uv.x;
        // A flowing leading edge covers every pixel by halfway; the trailing edge then clears it.
        float bend = 0.035 * sin(in.uv.y * 6.0 + u.time * 0.8);
        float cover = smoothstep(x - 0.06, x + 0.06, mix(-0.12, 1.12, smoothstep(0.0, 0.46, progress)) + bend);
        float clear = smoothstep(x - 0.06, x + 0.06, mix(-0.12, 1.12, smoothstep(0.54, 1.0, progress)) + bend);
        float alpha = cover * (1.0 - clear);
        float rim = 4.0 * alpha * (1.0 - alpha);
        return float4(min(color + float3(0.16, 0.08, 0.02) * rim, 1.0) * alpha, alpha);
    }

    if (u.effect == 2.0) {
        float progress = smoothstep(0.0, 1.0, clamp(u.impact, 0.0, 1.0));
        float radius = length(float2(u.aspect, 1.0)) * 0.5;
        float edge = progress * (radius + 0.08) - length(p);
        float alpha = smoothstep(-0.04, 0.04, edge);
        // Exact transparent and opaque endpoints, including the centre and corners.
        alpha *= smoothstep(0.0, 0.08, u.impact);
        return float4(color * alpha, alpha);
    }

    float r = length(p);
    float angle = atan2(p.y, p.x);
    float corner = length(float2(u.aspect, 1.0)) * 0.5;

    // Impact: the whole screen dips for a moment and a white-hot point hits at the centre.
    float hit = exp(-u.impact * 11.0);
    color *= 1.0 - 0.28 * smoothstep(0.0, 0.05, u.impact) * hit;
    float core = exp(-r * r * 26.0) * exp(-u.impact * 7.0);

    // Then a hole tears outward to the corners. It starts fast and slows slightly at the end.
    // The front's last position comes from the corner distance, plus the edge's largest wobble (0.03)
    // and how far the rim reaches behind it (0.11), so no edge is left in view when it finishes.
    const float duration = 1.0;
    float progress = clamp(u.impact / duration, 0.0, 1.0);
    float eased = 1.0 - pow(1.0 - progress, 1.8);
    float front = eased * (corner + 0.14);
    float rough = 0.016 * sin(angle * 3.0 + u.time * 1.3)
                + 0.009 * sin(angle * 5.0 - u.time * 1.9)
                + 0.005 * sin(angle * 11.0 + u.time * 2.3);
    float edge = r + rough - front;

    // Colour piles up against the moving edge, pushed outward by it.
    color = mix(color, heat(value + edge * 0.9, u.warmth), exp(-max(edge, 0.0) * 5.0));

    float keep = smoothstep(-0.026, 0.026, edge);
    float rim = exp(-pow(edge / 0.03, 2.0)) * (1.0 - progress * 0.55);
    float glow = exp(-max(edge, 0.0) * 9.0) * 0.45 * (1.0 - progress);
    float3 lit = color + float3(1.0, 0.44, 0.30) * (rim * 0.55 + glow * 0.7) + float3(1.0, 0.82, 0.80) * core;
    float alpha = clamp(keep + rim * 0.85 + core, 0.0, 1.0);

    // Everything fades in the last moments, in case a corner edge is still in view.
    float finish = 1.0 - smoothstep(0.86, 1.0, progress);
    alpha *= finish;

    // A tiny stable dither avoids visible 8-bit colour steps on the phone display.
    float noise = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);
    return float4(clamp(lit + (noise - 0.5) / 255.0, 0.0, 1.0) * alpha, alpha);
}
"""
