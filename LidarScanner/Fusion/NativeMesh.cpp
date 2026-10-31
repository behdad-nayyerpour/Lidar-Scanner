#include "NativeMesh.h"

#include "meshoptimizer.h"
#include "xatlas.h"

#include <stdlib.h>
#include <string.h>

static bool atlasProgress(xatlas::ProgressCategory, int, void *user) {
    if (user == nullptr) { return true; }
    return *static_cast<volatile int *>(user) == 0;
}

static void clearMesh(NMMesh *mesh) {
    if (mesh == nullptr) { return; }
    free(mesh->positions);
    free(mesh->uvs);
    free(mesh->indices);
    memset(mesh, 0, sizeof(NMMesh));
}

int NMBuildAtlas(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, int resolution, volatile int *cancelFlag, NMMesh *outMesh) {
    if (outMesh == nullptr || positions == nullptr || indices == nullptr || vertexCount == 0 || indexCount < 3 || indexCount % 3 != 0) {
        return 1;
    }
    memset(outMesh, 0, sizeof(NMMesh));
    xatlas::Atlas *atlas = xatlas::Create();
    if (atlas == nullptr) { return 2; }
    xatlas::SetProgressCallback(atlas, atlasProgress, cancelFlag);

    xatlas::MeshDecl decl;
    decl.vertexCount = vertexCount;
    decl.vertexPositionData = positions;
    decl.vertexPositionStride = sizeof(float) * 3;
    decl.indexData = indices;
    decl.indexCount = indexCount;
    decl.indexFormat = xatlas::IndexFormat::UInt32;

    xatlas::AddMeshError err = xatlas::AddMesh(atlas, decl);
    if (err != xatlas::AddMeshError::Success) {
        xatlas::Destroy(atlas);
        return 3;
    }

    xatlas::ChartOptions charts;
    charts.maxIterations = 1;
    xatlas::PackOptions pack;
    pack.resolution = static_cast<uint32_t>(resolution > 0 ? resolution : 2048);
    pack.padding = 2;
    pack.bilinear = true;
    pack.texelsPerUnit = 0;
    pack.bruteForce = false;
    pack.createImage = false;
    xatlas::Generate(atlas, charts, pack);
    if (cancelFlag != nullptr && *cancelFlag != 0) {
        xatlas::Destroy(atlas);
        return 4;
    }
    if (atlas->meshCount < 1 || atlas->width == 0 || atlas->height == 0) {
        xatlas::Destroy(atlas);
        return 5;
    }
    const xatlas::Mesh &mesh = atlas->meshes[0];
    if (mesh.vertexCount == 0 || mesh.indexCount < 3) {
        xatlas::Destroy(atlas);
        return 6;
    }

    outMesh->vertexCount = mesh.vertexCount;
    outMesh->indexCount = mesh.indexCount;
    outMesh->atlasWidth = static_cast<int>(atlas->width);
    outMesh->atlasHeight = static_cast<int>(atlas->height);
    outMesh->positions = static_cast<float *>(malloc(sizeof(float) * mesh.vertexCount * 3));
    outMesh->uvs = static_cast<float *>(malloc(sizeof(float) * mesh.vertexCount * 2));
    outMesh->indices = static_cast<uint32_t *>(malloc(sizeof(uint32_t) * mesh.indexCount));
    if (outMesh->positions == nullptr || outMesh->uvs == nullptr || outMesh->indices == nullptr) {
        clearMesh(outMesh);
        xatlas::Destroy(atlas);
        return 7;
    }
    const float invW = 1.0f / static_cast<float>(atlas->width);
    const float invH = 1.0f / static_cast<float>(atlas->height);
    for (uint32_t i = 0; i < mesh.vertexCount; i++) {
        const xatlas::Vertex &vertex = mesh.vertexArray[i];
        const uint32_t source = vertex.xref < vertexCount ? vertex.xref : 0;
        outMesh->positions[i * 3] = positions[source * 3];
        outMesh->positions[i * 3 + 1] = positions[source * 3 + 1];
        outMesh->positions[i * 3 + 2] = positions[source * 3 + 2];
        outMesh->uvs[i * 2] = vertex.uv[0] * invW;
        outMesh->uvs[i * 2 + 1] = vertex.uv[1] * invH;
    }
    memcpy(outMesh->indices, mesh.indexArray, sizeof(uint32_t) * mesh.indexCount);
    xatlas::Destroy(atlas);
    return 0;
}

int NMSimplify(const float *positions, uint32_t vertexCount, const uint32_t *indices, uint32_t indexCount, uint32_t targetIndexCount, NMMesh *outMesh) {
    if (outMesh == nullptr || positions == nullptr || indices == nullptr || vertexCount == 0 || indexCount < 3) {
        return 1;
    }
    memset(outMesh, 0, sizeof(NMMesh));
    uint32_t *simplified = static_cast<uint32_t *>(malloc(sizeof(uint32_t) * indexCount));
    if (simplified == nullptr) { return 2; }
    const size_t written = meshopt_simplify(
        simplified,
        indices,
        indexCount,
        positions,
        vertexCount,
        sizeof(float) * 3,
        targetIndexCount,
        0.02f,
        0,
        nullptr
    );
    if (written < 3 || written % 3 != 0) {
        free(simplified);
        return 3;
    }

    int *remap = static_cast<int *>(malloc(sizeof(int) * vertexCount));
    if (remap == nullptr) {
        free(simplified);
        return 2;
    }
    for (uint32_t i = 0; i < vertexCount; i++) { remap[i] = -1; }
    uint32_t unique = 0;
    for (size_t i = 0; i < written; i++) {
        const uint32_t source = simplified[i];
        if (source >= vertexCount) { continue; }
        if (remap[source] < 0) { remap[source] = static_cast<int>(unique++); }
    }
    outMesh->vertexCount = unique;
    outMesh->indexCount = static_cast<uint32_t>(written);
    outMesh->positions = static_cast<float *>(malloc(sizeof(float) * unique * 3));
    outMesh->indices = static_cast<uint32_t *>(malloc(sizeof(uint32_t) * written));
    if (outMesh->positions == nullptr || outMesh->indices == nullptr) {
        free(remap);
        free(simplified);
        clearMesh(outMesh);
        return 2;
    }
    for (uint32_t source = 0; source < vertexCount; source++) {
        const int dest = remap[source];
        if (dest < 0) { continue; }
        outMesh->positions[dest * 3] = positions[source * 3];
        outMesh->positions[dest * 3 + 1] = positions[source * 3 + 1];
        outMesh->positions[dest * 3 + 2] = positions[source * 3 + 2];
    }
    for (size_t i = 0; i < written; i++) {
        const uint32_t source = simplified[i];
        outMesh->indices[i] = source < vertexCount && remap[source] >= 0 ? static_cast<uint32_t>(remap[source]) : 0;
    }
    free(remap);
    free(simplified);
    return 0;
}

void NMFreeMesh(NMMesh *mesh) {
    clearMesh(mesh);
}
