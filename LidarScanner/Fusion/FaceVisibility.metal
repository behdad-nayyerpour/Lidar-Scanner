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
    float depth = -cam.z;
    float fx = camera[0];
    float fy = camera[1];
    float cx = camera[2];
    float cy = camera[3];
    float width = camera[4];
    float height = camera[5];
    float maxRange = camera[6];
    VisibilityOut out;
    // Preserve camera depth in clip W. W=1 would linearly interpolate depth in screen space,
    // giving the wrong occlusion depth on tilted triangles.
    float nearRange = 0.05;
    float a = maxRange / (maxRange - nearRange);
    float b = -maxRange * nearRange / (maxRange - nearRange);
    out.position = float4(2.0 * fx * cam.x / width + (2.0 * cx / width - 1.0) * depth,
                          2.0 * fy * cam.y / height + (1.0 - 2.0 * cy / height) * depth,
                          a * depth + b, depth);
    out.cameraDepth = depth;
    return out;
}

fragment float visibilityFragment(VisibilityOut in [[stage_in]]) {
    return in.cameraDepth;
}
