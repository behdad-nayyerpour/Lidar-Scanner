#include <metal_stdlib>
using namespace metal;

struct VisibilityOut {
    float4 position [[position]];
    float cameraDepth;
};

vertex VisibilityOut visibilityVertex(
    uint vid [[vertex_id]],
    const device float *positions [[buffer(0)]],
    const device uint *indices [[buffer(1)]],
    constant float4x4 &view [[buffer(2)]],
    constant float *camera [[buffer(3)]]
) {
    uint index = indices[vid];
    float3 world = float3(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2]);
    float4 cam = view * float4(world, 1.0);
    float depth = max(-cam.z, 0.001);
    float fx = camera[0];
    float fy = camera[1];
    float cx = camera[2];
    float cy = camera[3];
    float width = camera[4];
    float height = camera[5];
    float maxRange = camera[6];
    float u = fx * (cam.x / depth) + cx;
    float v = fy * (-cam.y / depth) + cy;
    VisibilityOut out;
    out.position = float4(u / width * 2.0 - 1.0, 1.0 - v / height * 2.0, depth / maxRange, 1.0);
    out.cameraDepth = depth;
    return out;
}

fragment float visibilityFragment(VisibilityOut in [[stage_in]]) {
    return in.cameraDepth;
}
