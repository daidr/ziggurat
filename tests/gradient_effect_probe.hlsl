// Independent analytic-gradient experiment. This is not a production renderer.
#define D2D_INPUT_COUNT 0
#define D2D_REQUIRES_SCENE_POSITION
#define D2D_ENTRY main
#include "d2d1effecthelpers.hlsli"

cbuffer Configuration : register(b0) {
    float4 frame; // local origin DIP, inverse target scale, kind
    float4 axis; // linear unit vector, radial quadratic coefficients
    float4 radial; // radial linear coefficients
    uint4 control; // count, physical output width, physical output height
    float4 positions[16];
    float4 colors[16]; // premultiplied encoded RGBA
};

D2D_PS_ENTRY(main) {
    float2 local_position = D2DGetScenePosition().xy * frame.z - frame.xy;
    float coordinate = frame.w == 0 ? dot(local_position, axis.xy) : dot(local_position * local_position, axis.zw) + dot(local_position, radial.xy);
    uint upper = 0;
    [unroll] for (uint i = 0; i < 16; ++i) {
        if (i < control.x && (frame.w == 0 ? positions[i].x <= coordinate : coordinate + positions[i].x >= 0)) upper = i + 1;
    }
    if (upper == 0) return colors[0];
    if (upper >= control.x) return colors[control.x - 1];
    uint before = upper - 1;
    float weight;
    if (frame.w == 0) weight = (coordinate - positions[before].x) / (positions[upper].x - positions[before].x);
    else {
        float numerator = coordinate + positions[before].x;
        float lower = positions[before].y;
        float denominator = (sqrt(max(0, numerator + lower * lower)) + lower) * (positions[upper].y - lower);
        weight = denominator > 0 ? numerator / denominator : 0;
    }
    weight = saturate(weight);
    return lerp(colors[before], colors[upper], weight);
}
