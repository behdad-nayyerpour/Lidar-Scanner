import simd

enum MeshCoverage {
    /// Fraction of reference triangle centers that sit within `tolerance` of some candidate vertex.
    static func fraction(of reference: ScanMesh, near candidate: ScanMesh, tolerance: Float) -> Float {
        let points = centers(of: reference, limit: 5000)
        guard !points.isEmpty else { return 1 }
        guard !candidate.positions.isEmpty else { return 0 }
        let index = PointIndex(points: candidate.positions, cell: max(tolerance, 0.01))
        var hits = 0
        for point in points where index.distance(to: point) <= tolerance {
            hits += 1
        }
        return Float(hits) / Float(points.count)
    }

    /// Keeps fused triangles and adds reference triangles the fusion never covered.
    static func fillingGaps(fused: ScanMesh, reference: ScanMesh, tolerance: Float) -> ScanMesh {
        guard !reference.positions.isEmpty else { return fused }
        guard !fused.positions.isEmpty else { return reference }
        var used: [SIMD3<Float>] = []
        var seen = Set<Int>()
        for index in fused.indices {
            let vertex = Int(index)
            guard vertex < fused.positions.count, seen.insert(vertex).inserted else { continue }
            used.append(fused.positions[vertex])
        }
        let index = PointIndex(points: used, cell: max(tolerance, 0.01))
        var mesh = fused
        for triangle in 0..<reference.triangleCount {
            let i0 = Int(reference.indices[triangle * 3])
            let i1 = Int(reference.indices[triangle * 3 + 1])
            let i2 = Int(reference.indices[triangle * 3 + 2])
            guard i0 < reference.positions.count, i1 < reference.positions.count, i2 < reference.positions.count else { continue }
            let center = (reference.positions[i0] + reference.positions[i1] + reference.positions[i2]) / 3
            if index.distance(to: center) <= tolerance { continue }
            let start = UInt32(mesh.positions.count)
            mesh.positions.append(reference.positions[i0])
            mesh.positions.append(reference.positions[i1])
            mesh.positions.append(reference.positions[i2])
            mesh.indices.append(contentsOf: [start, start + 1, start + 2])
        }
        mesh.recomputeNormals()
        return mesh.compacted()
    }

    private static func centers(of mesh: ScanMesh, limit: Int) -> [SIMD3<Float>] {
        let step = max(1, mesh.triangleCount / max(limit, 1))
        var points: [SIMD3<Float>] = []
        var triangle = 0
        while triangle < mesh.triangleCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            if i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count {
                points.append((mesh.positions[i0] + mesh.positions[i1] + mesh.positions[i2]) / 3)
            }
            triangle += step
        }
        return points
    }
}

private struct PointIndex {
    let cell: Float
    let points: [SIMD3<Float>]
    var buckets: [SIMD3<Int32>: [Int]] = [:]

    init(points: [SIMD3<Float>], cell: Float) {
        self.cell = cell
        self.points = points
        for (index, point) in points.enumerated() {
            buckets[key(point), default: []].append(index)
        }
    }

    func distance(to point: SIMD3<Float>) -> Float {
        let origin = key(point)
        var best = Float.greatestFiniteMagnitude
        for z in -1...1 {
            for y in -1...1 {
                for x in -1...1 {
                    let bucket = SIMD3<Int32>(origin.x + Int32(x), origin.y + Int32(y), origin.z + Int32(z))
                    guard let indices = buckets[bucket] else { continue }
                    for index in indices {
                        best = min(best, simd_distance(points[index], point))
                    }
                }
            }
        }
        return best
    }

    private func key(_ point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(
            Int32(floor(point.x / cell)),
            Int32(floor(point.y / cell)),
            Int32(floor(point.z / cell))
        )
    }
}
