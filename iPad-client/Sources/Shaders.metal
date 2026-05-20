#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertexMain(uint vertexID [[vertex_id]]) {
    // Standard full-screen quad vertices and coordinates
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    const float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentMain(VertexOut in [[stage_in]],
                             texture2d<float> texture [[texture(0)]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);
    return texture.sample(linearSampler, in.texCoord);
}
