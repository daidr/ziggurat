// Explicit two-pass byte Gaussian. No sampling state, edge clamp or implicit
// interpolation. The BGRA8 source is loaded and rounded to exact byte values.
Texture2D<float4> source : register(t0);
cbuffer Filter : register(b0) {
    uint width, height, radius, vertical;
    uint4 packed_weights[65];
};
float4 vertex(uint id : SV_VertexID) : SV_Position {
    return float4(id == 2 ? 3 : -1, id == 1 ? -3 : 1, 0, 1);
}
float4 pixel(float4 position : SV_Position) : SV_Target {
    int2 at = int2(position.xy);
    uint4 total = 0;
    [loop] for (int tap = -(int)radius; tap <= (int)radius; tap++) {
        int2 sample_at = at + (vertical ? int2(0, tap) : int2(tap, 0));
        if (sample_at.x >= 0 && sample_at.y >= 0 && sample_at.x < (int)width && sample_at.y < (int)height) {
            uint index = (uint)(tap + (int)radius);
            uint coefficient = packed_weights[index >> 2][index & 3];
            uint4 bytes = (uint4)round(source.Load(int3(sample_at, 0)) * 255);
            total += bytes * coefficient;
        }
    }
    return (float4)((total + 8388608) >> 24) / 255;
}
