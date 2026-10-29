import Foundation
import simd

struct ScanMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var colors: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var faceClasses: [UInt8] = []

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { triangleCount == 0 || positions.isEmpty }

    func boundingBox() -> AABB {
        guard let first = positions.first else {
            return AABB(min: .zero, max: .zero)
        }
        var minV = first
        var maxV = first
        for position in positions.dropFirst() {
            minV = simd_min(minV, position)
            maxV = simd_max(maxV, position)
        }
        return AABB(min: minV, max: maxV)
    }

    func surfaceArea() -> Float {
        guard positions.count > 2 else { return 0 }
        var area: Float = 0
        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let edgeA = positions[i1] - positions[i0]
            let edgeB = positions[i2] - positions[i0]
            area += simd_length(simd_cross(edgeA, edgeB)) * 0.5
        }
        return area
    }

    mutating func recomputeNormals() {
        var accum = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let normal = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            accum[i0] += normal
            accum[i1] += normal
            accum[i2] += normal
        }
        normals = accum.map { value in
            let length = simd_length(value)
            return length > 1e-8 ? value / length : SIMD3<Float>(0, 1, 0)
        }
    }

    func classRawValues() -> Set<UInt8> {
        Set(faceClasses)
    }

    /// Drops degenerate triangles and unused vertices.
    func compacted() -> ScanMesh {
        guard !positions.isEmpty else { return self }
        var used = [Bool](repeating: false, count: positions.count)
        var keptIndices: [UInt32] = []
        var keptClasses: [UInt8] = []
        keptIndices.reserveCapacity(indices.count)

        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 != i1, i1 != i2, i0 != i2,
                  indicesAreValid(i0, i1, i2) else { continue }
            let area = simd_length(simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0]))
            guard area > 1e-10 else { continue }
            used[i0] = true
            used[i1] = true
            used[i2] = true
            keptIndices.append(contentsOf: [UInt32(i0), UInt32(i1), UInt32(i2)])
            keptClasses.append(triangle < faceClasses.count ? faceClasses[triangle] : 0)
        }

        var remap = [Int](repeating: -1, count: positions.count)
        var newPositions: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newColors: [SIMD3<Float>] = []
        newPositions.reserveCapacity(positions.count)
        for index in 0..<positions.count where used[index] {
            remap[index] = newPositions.count
            newPositions.append(positions[index])
            newNormals.append(index < normals.count ? normals[index] : SIMD3<Float>(0, 1, 0))
            let color = index < colors.count ? colors[index] : SIMD3<Float>(repeating: 0.72)
            newColors.append(simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)))
        }

        var remapped: [UInt32] = []
        remapped.reserveCapacity(keptIndices.count)
        for index in keptIndices {
            remapped.append(UInt32(remap[Int(index)]))
        }

        return ScanMesh(
            positions: newPositions,
            normals: newNormals,
            colors: newColors,
            indices: remapped,
            faceClasses: keptClasses
        )
    }

    private func indicesAreValid(_ i0: Int, _ i1: Int, _ i2: Int) -> Bool {
        i0 >= 0 && i1 >= 0 && i2 >= 0 && i0 < positions.count && i1 < positions.count && i2 < positions.count
    }
}
