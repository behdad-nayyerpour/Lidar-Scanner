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
    uint32_t *sourceVertices;
} NMMesh;

typedef int (*NMShouldCancel)(void *context);

/// Builds one non-overlapping geometry UV atlas. Cancellation is a thread-safe query.
int NMBuildSurfaceAtlas(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, int resolution, NMShouldCancel shouldCancel, void *context, NMMesh *outMesh);

/// Quadric simplification with meshoptimizer (MIT). Positions are tightly packed xyz.
/// Returns 0 on success.
int NMSimplify(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, uint32_t targetIndexCount, float maxError, NMMesh *outMesh);

void NMFreeMesh(NMMesh *mesh);

#ifdef __cplusplus
}
#endif
