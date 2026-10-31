#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t vertexCount;
    uint32_t indexCount;
    int atlasWidth;
    int atlasHeight;
    float *positions;
    float *uvs;
    uint32_t *indices;
} NMMesh;

typedef void (*NMReport)(int percent, void *context);

/// Builds a per-face UV atlas with xatlas (MIT). Positions are tightly packed xyz.
/// `cancelFlag` and `report` may be NULL. Returns 0 on success.
int NMBuildAtlas(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, int resolution, volatile int *cancelFlag, NMReport report, void *context, NMMesh *outMesh);

/// Quadric simplification with meshoptimizer (MIT). Positions are tightly packed xyz.
/// Returns 0 on success.
int NMSimplify(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, uint32_t targetIndexCount, NMMesh *outMesh);

void NMFreeMesh(NMMesh *mesh);

#ifdef __cplusplus
}
#endif
