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
        var usedVertex: [Int] = []
        var seen = Set<Int>()
        for index in fused.indices {
            let vertex = Int(index)
            guard vertex < fused.positions.count, seen.insert(vertex).inserted else { continue }
            used.append(fused.positions[vertex])
            usedVertex.append(vertex)
        }
        let index = PointIndex(points: used, cell: max(tolerance, 0.01))
        var mesh = fused
        for triangle in 0..<reference.triangleCount {
            let i0 = Int(reference.indices[triangle * 3])
            let i1 = Int(reference.indices[triangle * 3 + 1])
            let i2 = Int(reference.indices[triangle * 3 + 2])
            guard i0 < reference.positions.count, i1 < reference.positions.count, i2 < reference.positions.count else { continue }
            let a = reference.positions[i0]
            let b = reference.positions[i1]
            let c = reference.positions[i2]
            let center = (a + b + c) / 3
            // A parallel sheet a centimeter off the fused surface is not a hole. Only an opening
            // whose center is farther than `tolerance` gets filled, and rim vertices snap onto the fused mesh.
            if index.distance(to: center) <= tolerance { continue }
            let geometric = simd_cross(b - a, c - a)
            let authored = i0 < reference.normals.count ? reference.normals[i0] : geometric
            let flip = simd_length(authored) > 1e-4 && simd_dot(geometric, authored) < 0
            let corners = flip ? [a, c, b] : [a, b, c]
            var ids: [UInt32] = []
            for corner in corners {
                if let hit = index.nearest(corner, within: tolerance), hit < usedVertex.count {
                    ids.append(UInt32(usedVertex[hit]))
                } else {
                    mesh.positions.append(corner)
                    ids.append(UInt32(mesh.positions.count - 1))
                }
            }
            if Set(ids).count < 3 { continue }
            mesh.indices.append(contentsOf: ids)
        }
        mesh.recomputeNormals()
        return mesh.welded(cellSize: max(tolerance * 0.25, 0.004)).compacted()
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

    func nearest(_ point: SIMD3<Float>, within radius: Float) -> Int? {
        let origin = key(point)
        let reach = max(1, Int(ceil(radius / cell)))
        var best = Float.greatestFiniteMagnitude
        var hit: Int?
        for z in -reach...reach {
            for y in -reach...reach {
                for x in -reach...reach {
                    let bucket = SIMD3<Int32>(origin.x + Int32(x), origin.y + Int32(y), origin.z + Int32(z))
                    guard let indices = buckets[bucket] else { continue }
                    for index in indices {
                        let distance = simd_distance(points[index], point)
                        if distance < best {
                            best = distance
                            hit = index
                        }
                    }
                }
            }
        }
        guard let hit, best <= radius else { return nil }
        return hit
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
