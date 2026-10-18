// Analytic window-space gradients; no lookup texture or paint-time compilation.
#define D2D_INPUT_COUNT 0
#define D2D_REQUIRES_SCENE_POSITION
#define D2D_ENTRY main
#include "d2d1effecthelpers.hlsli"

cbuffer Configuration : register(b0) {
    float4 frame; // local origin DIP, inverse scale, kind
    float4 axis; // linear unit vector, radial coefficients, or conic angle/sign
    float4 radial; // radial linear coefficients
    uint4 control; // stop count
    int4 output_bounds; // physical pixel bounds
    float4 shape; // local outer bounds
    float4 contour; // outer radius, inside stroke width
    float4 positions[16]; // linear projected stops or radial residual/offset
    float4 colors[16]; // premultiplied encoded RGBA
};

float rounded_distance(float2 position, float4 bounds, float radius) {
    float2 half_size = bounds.zw * 0.5;
    float2 q = abs(position - bounds.xy - half_size) - half_size + radius;
    return length(max(q, 0)) + min(max(q.x, q.y), 0) - radius;
}

float coverage(float2 position) {
    float margin = frame.z * 0.7071067811865476;
    float outer = rounded_distance(position, shape, contour.x);
    if (outer > margin) return 0;
    bool hole = contour.y > 0 && shape.z > 2 * contour.y && shape.w > 2 * contour.y;
    float4 inner_bounds = float4(shape.xy + contour.y, shape.zw - 2 * contour.y);
    float inner_radius = max(0, contour.x - contour.y);
    float inner = hole ? rounded_distance(position, inner_bounds, inner_radius) : 3.4e38;
    if (inner < -margin) return 0;
    if (outer < -margin && inner > margin) return 1;
    uint count = 0;
    [unroll] for (uint y = 0; y < 4; ++y) {
        [unroll] for (uint x = 0; x < 4; ++x) {
            float2 sample_position = position + (float2(x, y) * 0.25 - 0.375) * frame.z;
            if (rounded_distance(sample_position, shape, contour.x) <= 0 &&
                (!hole || rounded_distance(sample_position, inner_bounds, inner_radius) >= 0)) ++count;
        }
    }
    return count / 16.0;
}

#ifdef ZG_INTERPOLATION
float4 original_stop(uint index) {
    uint rg = (uint)positions[index].z;
    uint ba = (uint)positions[index].w;
    float4 value = float4(rg >> 8, rg & 255, ba >> 8, ba & 255) / 255.0;
    return float4(value.rgb * value.a, value.a);
}
float3 linear_from_lab(float3 value) {
    float l = value.x + 0.3963377774 * value.y + 0.2158037573 * value.z;
    float m = value.x - 0.1055613458 * value.y - 0.0638541728 * value.z;
    float s = value.x - 0.0894841775 * value.y - 1.2914855480 * value.z;
    float ll = l * l * l;
    float mm = m * m * m;
    float ss = s * s * s;
    return float3(4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
                  -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
                  -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss);
}
float4 encoded_sample(float4 value) {
    // A zero stop contributes no hidden color. No epsilon discards tiny alpha.
    if (value.a <= 0) return 0;
    float3 rgb = value.rgb / value.a;
    if (control.y == 2) rgb = linear_from_lab(rgb);
    rgb = saturate(rgb);
    float3 low = rgb * 12.92;
    float3 high = 1.055 * pow(rgb, 1.0 / 2.4) - 0.055;
    return float4(rgb.x <= 0.0031308 ? low.x : high.x,
                  rgb.y <= 0.0031308 ? low.y : high.y,
                  rgb.z <= 0.0031308 ? low.z : high.z, 1) * value.a;
}
#endif

D2D_PS_ENTRY(main) {
#ifdef ZG_INTERPOLATION
    float2 position = (floor(D2DGetScenePosition().xy) + 0.5) * frame.z - frame.xy;
#else
    float2 position = D2DGetScenePosition().xy * frame.z - frame.xy;
#endif
    float mask = coverage(position);
    if (mask == 0) return 0;
    float coordinate;
    [branch] if (frame.w == 2) {
        // Scene-position interpolation may be a few ulps below a pixel center,
        // including on an offscreen target. The source raster is a physical
        // pixel grid; recover that exact center before testing the singularity.
        float2 conic_position = floor(D2DGetScenePosition().xy) + 0.5 - frame.xy;
        // Explicit center avoids the undefined atan2(0,0). Periodic endpoint
        // colors and separated stops are required by the owner preflight.
        if (conic_position.x == 0 && conic_position.y == 0) coordinate = 0;
        else {
            float turns = (atan2(conic_position.y, conic_position.x) - axis.x) * (axis.y * 0.15915494309189533577);
            coordinate = frac(turns);
            coordinate = min(coordinate, asfloat(0x3f7fffff));
        }
    } else coordinate = frame.w == 0 ? dot(position, axis.xy) : dot(position * position, axis.zw) + dot(position, radial.xy);
    uint upper = 0;
    [unroll] for (uint i = 0; i < 16; ++i) {
        if (i < control.x && (frame.w == 1 ? coordinate + positions[i].x >= 0 : positions[i].x <= coordinate)) upper = i + 1;
    }
#ifdef ZG_INTERPOLATION
    if (upper == 0) return original_stop(0) * mask;
    if (upper >= control.x) return original_stop(control.x - 1) * mask;
#else
    if (upper == 0) return colors[0] * mask;
    if (upper >= control.x) return colors[control.x - 1] * mask;
#endif
    uint before = upper - 1;
    float weight;
    if (frame.w != 1) weight = (coordinate - positions[before].x) / (positions[upper].x - positions[before].x);
    else {
        // q-s*s, evaluated in local coordinates, avoids subtracting nearby
        // normalized radii before a hard or arbitrarily steep transition.
        float numerator = coordinate + positions[before].x;
        float lower = positions[before].y;
        float denominator = (sqrt(max(0, numerator + lower * lower)) + lower) * (positions[upper].y - lower);
        weight = denominator > 0 ? numerator / denominator : 0;
    }
#ifdef ZG_INTERPOLATION
    if (weight <= 0) return original_stop(before) * mask;
    if (weight >= 1) return original_stop(upper) * mask;
    return encoded_sample(lerp(colors[before], colors[upper], weight)) * mask;
#else
    return lerp(colors[before], colors[upper], saturate(weight)) * mask;
#endif
}
