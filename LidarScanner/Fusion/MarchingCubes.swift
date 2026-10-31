import Foundation
import simd

enum MarchingCubes {
    private static let corners: [SIMD3<Int>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)
    ]
    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]

    static func extract(
        pointer: UnsafeMutablePointer<TSDFVoxel>,
        origins: [(Int32, Int32, Int32)],
        lookup: ((Int32, Int32, Int32)) -> Int?,
        voxel: Float,
        blockSize: Int
    ) -> ScanMesh {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func sample(_ gx: Int, _ gy: Int, _ gz: Int) -> (Float, Float) {
            let bx = floorDiv(gx, blockSize)
            let by = floorDiv(gy, blockSize)
            let bz = floorDiv(gz, blockSize)
            let lx = gx - bx * blockSize
            let ly = gy - by * blockSize
            let lz = gz - bz * blockSize
            guard let block = lookup((Int32(bx), Int32(by), Int32(bz))) else { return (1, 0) }
            let voxelIndex = block * 512 + lz * 64 + ly * 8 + lx
            let value = pointer[voxelIndex]
            if value.weight < 0.15 { return (1, 0) }
            return (value.sdf, value.weight)
        }

        for origin in origins {
            let baseX = Int(origin.0) * blockSize
            let baseY = Int(origin.1) * blockSize
            let baseZ = Int(origin.2) * blockSize
            for z in 0..<(blockSize - 0) {
                for y in 0..<blockSize {
                    for x in 0..<blockSize {
                        // The last cell in a block reads the next voxel, which may live in a neighbor block.
                        var sdf = [Float](repeating: 1, count: 8)
                        var weight: Float = 0
                        var cube = 0
                        for corner in 0..<8 {
                            let offset = corners[corner]
                            let sample = sample(baseX + x + offset.x, baseY + y + offset.y, baseZ + z + offset.z)
                            sdf[corner] = sample.0
                            weight += sample.1
                            if sample.0 < 0 { cube |= 1 << corner }
                        }
                        guard weight > 0.15, cube != 0, cube != 255 else { continue }
                        guard cube < MarchingCubesTables.edgeTable.count else { continue }
                        var edgeVertex = [Int](repeating: -1, count: 12)
                        let mask = MarchingCubesTables.edgeTable[cube]
                        if mask == 0 { continue }
                        for edge in 0..<12 where mask & UInt16(1 << edge) != 0 {
                            let pair = edges[edge]
                            let a = corners[pair.0]
                            let b = corners[pair.1]
                            let va = sdf[pair.0]
                            let vb = sdf[pair.1]
                            var t: Float = 0.5
                            let span = va - vb
                            if abs(span) > 1e-6 { t = va / span }
                            t = min(1, max(0, t))
                            let position = SIMD3<Float>(
                                Float(baseX + x) + Float(a.x) + t * Float(b.x - a.x),
                                Float(baseY + y) + Float(a.y) + t * Float(b.y - a.y),
                                Float(baseZ + z) + Float(a.z) + t * Float(b.z - a.z)
                            ) * voxel
                            edgeVertex[edge] = positions.count
                            positions.append(position)
                        }
                        let row = MarchingCubesTables.triTable[cube]
                        var cursor = 0
                        while cursor + 2 < row.count {
                            let e0 = row[cursor]
                            let e1 = row[cursor + 1]
                            let e2 = row[cursor + 2]
                            cursor += 3
                            guard e0 >= 0, e1 >= 0, e2 >= 0, e0 < 12, e1 < 12, e2 < 12 else { continue }
                            let i0 = edgeVertex[e0]
                            let i1 = edgeVertex[e1]
                            let i2 = edgeVertex[e2]
                            guard i0 >= 0, i1 >= 0, i2 >= 0 else { continue }
                            indices.append(UInt32(i0))
                            indices.append(UInt32(i1))
                            indices.append(UInt32(i2))
                        }
                    }
                }
            }
        }
        var mesh = ScanMesh(positions: positions, indices: indices)
        mesh = mesh.welded(cellSize: voxel * 0.35)
        mesh.recomputeNormals()
        return mesh.compacted()
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        if remainder != 0 && value < 0 { return quotient - 1 }
        return quotient
    }
}
