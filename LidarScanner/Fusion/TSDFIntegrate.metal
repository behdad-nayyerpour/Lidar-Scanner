#include <metal_stdlib>
using namespace metal;

struct TSDFParams {
    float4x4 worldToCamera;
    float fx;
    float fy;
    float cx;
    float cy;
    float voxel;
    float trunc;
    float minRange;
    float maxRange;
    float minConfidence;
    float depthWidth;
    float depthHeight;
    float centerX;
    float centerY;
    float centerZ;
    float radius;
};

struct BlockRef {
    int x;
    int y;
    int z;
    int index;
};

struct Voxel {
    float sdf;
    float weight;
};

kernel void integrateTSDF(
    const device BlockRef *blocks [[buffer(0)]],
    device Voxel *voxels [[buffer(1)]],
    constant TSDFParams &params [[buffer(2)]],
    texture2d<float, access::sample> depthTex [[texture(0)]],
    texture2d<float, access::sample> confidenceTex [[texture(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x >= 512) { return; }
    BlockRef block = blocks[gid.y];
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);

    int localX = int(gid.x) % 8;
    int localY = (int(gid.x) / 8) % 8;
    int localZ = int(gid.x) / 64;
    float blockWorld = params.voxel * 8.0;
    float3 world = float3(block.x, block.y, block.z) * blockWorld
        + float3(localX, localY, localZ) * params.voxel
        + params.voxel * 0.5;
    if (params.radius > 0.05) {
        float3 center = float3(params.centerX, params.centerY, params.centerZ);
        if (distance(world, center) > params.radius) { return; }
    }

    float4 camera4 = params.worldToCamera * float4(world, 1.0);
    float3 camera = camera4.xyz;
    float cameraDepth = -camera.z;
    if (cameraDepth < params.minRange || cameraDepth > params.maxRange) { return; }

    // Image +v is down. ARKit camera +Y is up, so camera Y is negated.
    float u = params.fx * (camera.x / cameraDepth) + params.cx;
    float v = params.fy * (-camera.y / cameraDepth) + params.cy;
    if (u < 1.0 || v < 1.0 || u >= params.depthWidth - 1.0 || v >= params.depthHeight - 1.0) { return; }

    float2 uv = float2((u + 0.5) / params.depthWidth, (v + 0.5) / params.depthHeight);
    float surface = depthTex.sample(linear, uv).r;
    if (surface < params.minRange || surface > params.maxRange) { return; }
    float confidence = confidenceTex.sample(nearest, uv).r;

    float depthL = depthTex.sample(nearest, uv - float2(1.0 / params.depthWidth, 0.0)).r;
    float depthR = depthTex.sample(nearest, uv + float2(1.0 / params.depthWidth, 0.0)).r;
    float depthU = depthTex.sample(nearest, uv - float2(0.0, 1.0 / params.depthHeight)).r;
    float depthD = depthTex.sample(nearest, uv + float2(0.0, 1.0 / params.depthHeight)).r;
    float slopeX = abs(depthR - depthL) * 0.5 * params.fx / max(surface, 0.05);
    float slopeY = abs(depthD - depthU) * 0.5 * params.fy / max(surface, 0.05);
    if (confidence < 1.0) { return; }
    float grazing = max(slopeX, slopeY);
    float signedDistance = surface - cameraDepth;
    uint index = uint(block.index) * 512u + gid.x;
    float previous = voxels[index].weight;
    if (signedDistance > params.trunc && previous > 1.0 && voxels[index].sdf < 0.5) { return; }
    if (signedDistance < -params.trunc) { return; }
    float tsdf = clamp(signedDistance / params.trunc, -1.0, 1.0);
    float confScale = confidence >= 2.0 ? 1.0 : 0.3;
    float sampleWeight = min(confScale / max(surface * surface, 0.04), 8.0);
    if (grazing > 3.5) { sampleWeight *= 0.25; }
    float blend = previous + sampleWeight;
    if (previous <= 0.0001) {
        voxels[index].sdf = tsdf;
    } else {
        voxels[index].sdf = (voxels[index].sdf * previous + tsdf * sampleWeight) / blend;
    }
    voxels[index].weight = min(blend, 48.0);
}
