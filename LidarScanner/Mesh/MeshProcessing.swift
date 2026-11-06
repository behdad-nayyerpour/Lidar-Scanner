import Foundation
import simd

struct ProcessingSettings: Equatable {
    var cropMinX: Float = 0
    var cropMaxX: Float = 0
    var cropMinY: Float = 0
    var cropMaxY: Float = 0
    var cropMinZ: Float = 0
    var cropMaxZ: Float = 0
    var smoothEnabled = false
    var smoothIterations = 3
    var simplifyEnabled = false
    var simplifyRatio: Float = 0.5
    var removeFloaters = false
    var floaterFraction: Float = 0.005

    var crops: Bool {
        cropMinX > 0.001 || cropMaxX > 0.001 || cropMinY > 0.001 || cropMaxY > 0.001 || cropMinZ > 0.001 || cropMaxZ > 0.001
    }
}

extension ScanMesh {
    func processed(_ settings: ProcessingSettings) -> ScanMesh {
        var mesh = self
        if settings.crops {
            let box = boundingBox()
            let size = box.size
            let cropped = AABB(
                min: box.min + SIMD3(size.x * settings.cropMinX, size.y * settings.cropMinY, size.z * settings.cropMinZ),
                max: box.max - SIMD3(size.x * settings.cropMaxX, size.y * settings.cropMaxY, size.z * settings.cropMaxZ)
            )
            guard cropped.isValid else { return ScanMesh() }
            mesh = mesh.clipped(to: cropped)
        }
        if settings.removeFloaters {
            mesh = mesh.removingSmallComponents(minimumAreaFraction: settings.floaterFraction)
        }
        if settings.smoothEnabled {
            mesh = mesh.smoothed(iterations: settings.smoothIterations, lambda: 0.45)
        }
        if settings.simplifyEnabled {
            mesh = mesh.decimated(targetRatio: settings.simplifyRatio)
        }
        if settings.removeFloaters {
            mesh = mesh.removingSmallComponents(minimumAreaFraction: settings.floaterFraction)
        }
        mesh.recomputeNormals()
        return mesh.compacted()
    }

    func keepingTriangles(where predicate: (Int) -> Bool) -> ScanMesh {
        var mesh = self
        var newIndices: [UInt32] = []
        var newClasses: [UInt8] = []
        for triangle in 0..<triangleCount where predicate(triangle) {
            newIndices.append(indices[triangle * 3])
            newIndices.append(indices[triangle * 3 + 1])
            newIndices.append(indices[triangle * 3 + 2])
            newClasses.append(triangle < faceClasses.count ? faceClasses[triangle] : 0)
        }
        mesh.indices = newIndices
        mesh.faceClasses = newClasses
        return mesh.compacted()
    }

    func clipped(to box: AABB) -> ScanMesh {
        guard box.isValid else { return ScanMesh() }
        let planes = [
            ClipPlane(normal: SIMD3(1, 0, 0), constant: box.min.x),
            ClipPlane(normal: SIMD3(-1, 0, 0), constant: -box.max.x),
            ClipPlane(normal: SIMD3(0, 1, 0), constant: box.min.y),
            ClipPlane(normal: SIMD3(0, -1, 0), constant: -box.max.y),
            ClipPlane(normal: SIMD3(0, 0, 1), constant: box.min.z),
            ClipPlane(normal: SIMD3(0, 0, -1), constant: -box.max.z)
        ]

        var outPositions: [SIMD3<Float>] = []
        var outNormals: [SIMD3<Float>] = []
        var outColors: [SIMD3<Float>] = []
        var outIndices: [UInt32] = []
        var outClasses: [UInt8] = []

        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let corners = [corner(i0, fallbackClass: triangle), corner(i1, fallbackClass: triangle), corner(i2, fallbackClass: triangle)]
            if corners.allSatisfy({ box.contains($0.position) }) {
                appendTriangle(corners[0], corners[1], corners[2], to: &outPositions, &outNormals, &outColors, &outIndices, &outClasses)
                continue
            }
            if completelyOutside(corners, box: box) { continue }

            var polygon = corners
            for plane in planes {
                polygon = plane.clip(polygon)
                if polygon.count < 3 { break }
            }
            guard polygon.count >= 3 else { continue }
            for index in 1..<(polygon.count - 1) {
                appendTriangle(polygon[0], polygon[index], polygon[index + 1], to: &outPositions, &outNormals, &outColors, &outIndices, &outClasses)
            }
        }

        return ScanMesh(
            positions: outPositions,
            normals: outNormals,
            colors: outColors,
            indices: outIndices,
            faceClasses: outClasses
        ).compacted()
    }

    func taubinSmoothed(iterations: Int) -> ScanMesh {
        var mesh = self
        let steps = min(12, max(0, iterations))
        for _ in 0..<steps {
            mesh = mesh.smoothed(iterations: 1, lambda: 0.45)
            mesh = mesh.smoothed(iterations: 1, lambda: -0.48)
        }
        mesh.recomputeNormals()
        return mesh
    }

    func simplified(targetTriangles: Int, maxError: Float = 0.02) -> ScanMesh {
        guard targetTriangles > 50, triangleCount > targetTriangles + 20 else { return self }
        var packed: [Float] = []
        packed.reserveCapacity(positions.count * 3)
        for position in positions {
            packed.append(position.x)
            packed.append(position.y)
            packed.append(position.z)
        }
        var native = NMMesh()
        let code: Int32 = packed.withUnsafeBufferPointer { positions in
            indices.withUnsafeBufferPointer { indices in
                NMSimplify(positions.baseAddress, UInt32(self.positions.count), indices.baseAddress, UInt32(self.indices.count), UInt32(targetTriangles * 3), maxError, &native)
            }
        }
        defer { NMFreeMesh(&native) }
        guard code == 0, native.vertexCount > 0, native.indexCount >= 3, let positions = native.positions, let indices = native.indices else {
            return decimated(targetRatio: Float(targetTriangles) / Float(max(triangleCount, 1))).withoutSlivers(minAltitude: maxError)
        }
        var mesh = ScanMesh()
        for index in 0..<Int(native.vertexCount) {
            mesh.positions.append(SIMD3(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2]))
        }
        for index in 0..<Int(native.indexCount) {
            mesh.indices.append(indices[index])
        }
        mesh.recomputeNormals()
        return mesh.withoutSlivers(minAltitude: maxError).compacted()
    }

    /// Drops long needles left on a flat surface. A wide triangle on the keyboard stays.
    func withoutSlivers(minAltitude: Float) -> ScanMesh {
        guard triangleCount > 0 else { return self }
        let limit = max(minAltitude, 0.002)
        var kept: [UInt32] = []
        kept.reserveCapacity(indices.count)
        for triangle in 0..<triangleCount {
            let ids = (0..<3).map { indices[triangle * 3 + $0] }
            guard ids.allSatisfy({ Int($0) < positions.count }) else { continue }
            let corners = ids.map { positions[Int($0)] }
            var edge: Float = 0
            for pair in [(0, 1), (1, 2), (2, 0)] {
                edge = max(edge, simd_distance(corners[pair.0], corners[pair.1]))
            }
            let area = simd_length(simd_cross(corners[1] - corners[0], corners[2] - corners[0])) * 0.5
            let altitude = edge > 1e-6 ? (2 * area / edge) : 0
            if edge > 0.02, altitude < limit { continue }
            kept.append(contentsOf: ids)
        }
        var mesh = self
        mesh.indices = kept
        return mesh
    }

    func smoothed(iterations: Int, lambda: Float) -> ScanMesh {
        let steps = min(12, max(0, iterations))
        guard steps > 0, positions.count > 2 else { return self }
        let adjacency = neighborLists()
        var current = positions
        let blend = min(0.9, max(-0.9, lambda))
        for _ in 0..<steps {
            var next = current
            for index in current.indices {
                let neighbors = adjacency[index]
                guard !neighbors.isEmpty else { continue }
                var average = SIMD3<Float>.zero
                for neighbor in neighbors {
                    average += current[neighbor]
                }
                average /= Float(neighbors.count)
                next[index] = current[index] * (1 - blend) + average * blend
            }
            current = next
        }
        var mesh = self
        mesh.positions = current
        return mesh
    }

    func decimated(targetRatio: Float) -> ScanMesh {
        let ratio = min(1, max(0.05, targetRatio))
        guard ratio < 0.98, triangleCount > 40 else { return self }
        let box = boundingBox()
        let extent = max(box.size.x, max(box.size.y, box.size.z))
        guard extent > 1e-5 else { return self }
        let targetVertices = max(16, Int(Float(positions.count) * ratio))
        let grid = max(2, Int(sqrt(Double(targetVertices))))
        let cell = max(extent / Float(grid), 1e-5)
        return clustered(cellSize: cell)
    }

    func welded(cellSize: Float) -> ScanMesh {
        guard cellSize > 0, positions.count > 1 else { return self }
        return clustered(cellSize: cellSize)
    }

    func removingSmallComponents(minimumAreaFraction: Float) -> ScanMesh {
        guard triangleCount > 1 else { return self }
        var parent = Array(0..<triangleCount)
        var rank = [Int](repeating: 0, count: triangleCount)

        func find(_ value: Int) -> Int {
            var node = value
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }
        func union(_ a: Int, _ b: Int) {
            var rootA = find(a)
            var rootB = find(b)
            guard rootA != rootB else { return }
            if rank[rootA] < rank[rootB] { swap(&rootA, &rootB) }
            parent[rootB] = rootA
            if rank[rootA] == rank[rootB] { rank[rootA] += 1 }
        }

        var vertexFaces = [[Int]](repeating: [], count: positions.count)
        for triangle in 0..<triangleCount {
            for corner in 0..<3 {
                let index = Int(indices[triangle * 3 + corner])
                guard index < positions.count else { continue }
                vertexFaces[index].append(triangle)
            }
        }
        for faces in vertexFaces {
            guard let first = faces.first else { continue }
            for face in faces.dropFirst() {
                union(first, face)
            }
        }

        var areaByRoot: [Int: Float] = [:]
        var trianglesByRoot: [Int: [Int]] = [:]
        for triangle in 0..<triangleCount {
            let root = find(triangle)
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let area = simd_length(simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])) * 0.5
            areaByRoot[root, default: 0] += area
            trianglesByRoot[root, default: []].append(triangle)
        }
        let total = areaByRoot.values.reduce(0, +)
        guard total > 0 else { return self }
        let cutoff = total * min(0.2, max(0, minimumAreaFraction))
        let largest = areaByRoot.max { $0.value < $1.value }?.key
        var keep = Set<Int>()
        for (root, area) in areaByRoot where area >= cutoff || root == largest {
            keep.formUnion(trianglesByRoot[root] ?? [])
        }
        return keepingTriangles { keep.contains($0) }
    }

    private func clustered(cellSize: Float) -> ScanMesh {
        struct GridKey: Hashable {
            var x: Int32
            var y: Int32
            var z: Int32
        }

        let origin = boundingBox().min
        let inverse = 1 / cellSize
        var sums: [GridKey: SIMD3<Float>] = [:]
        var normalSums: [GridKey: SIMD3<Float>] = [:]
        var colorSums: [GridKey: SIMD3<Float>] = [:]
        var counts: [GridKey: Int] = [:]
        var keys = [GridKey]()
        keys.reserveCapacity(positions.count)

        for index in positions.indices {
            let position = positions[index]
            let key = GridKey(
                x: Int32(floor((position.x - origin.x) * inverse)),
                y: Int32(floor((position.y - origin.y) * inverse)),
                z: Int32(floor((position.z - origin.z) * inverse))
            )
            keys.append(key)
            sums[key, default: .zero] += position
            normalSums[key, default: .zero] += index < normals.count ? normals[index] : .zero
            colorSums[key, default: .zero] += index < colors.count ? colors[index] : SIMD3<Float>(repeating: 0.72)
            counts[key, default: 0] += 1
        }

        var keyToIndex: [GridKey: Int] = [:]
        var newPositions: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newColors: [SIMD3<Float>] = []
        for (key, count) in counts {
            let scale = 1 / Float(count)
            keyToIndex[key] = newPositions.count
            newPositions.append(sums[key, default: .zero] * scale)
            let normal = normalSums[key, default: .zero] * scale
            let length = simd_length(normal)
            newNormals.append(length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0))
            newColors.append(colorSums[key, default: .zero] * scale)
        }

        var remap = [Int](repeating: 0, count: positions.count)
        for index in keys.indices {
            remap[index] = keyToIndex[keys[index]] ?? 0
        }

        var newIndices: [UInt32] = []
        var newClasses: [UInt8] = []
        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < remap.count, i1 < remap.count, i2 < remap.count else { continue }
            let a = UInt32(remap[i0])
            let b = UInt32(remap[i1])
            let c = UInt32(remap[i2])
            guard a != b, b != c, a != c else { continue }
            newIndices.append(contentsOf: [a, b, c])
            newClasses.append(triangle < faceClasses.count ? faceClasses[triangle] : 0)
        }

        var mesh = ScanMesh(
            positions: newPositions,
            normals: newNormals,
            colors: newColors,
            indices: newIndices,
            faceClasses: newClasses
        )
        mesh.recomputeNormals()
        return mesh.compacted()
    }

    private func neighborLists() -> [[Int]] {
        var adjacency = [[Int]](repeating: [], count: positions.count)
        for triangle in 0..<triangleCount {
            let i0 = Int(indices[triangle * 3])
            let i1 = Int(indices[triangle * 3 + 1])
            let i2 = Int(indices[triangle * 3 + 2])
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            adjacency[i0].append(contentsOf: [i1, i2])
            adjacency[i1].append(contentsOf: [i0, i2])
            adjacency[i2].append(contentsOf: [i0, i1])
        }
        for index in adjacency.indices {
            let sorted = adjacency[index].sorted()
            var unique: [Int] = []
            for value in sorted where unique.last != value && value != index {
                unique.append(value)
            }
            adjacency[index] = unique
        }
        return adjacency
    }

    private struct Corner {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var color: SIMD3<Float>
        var classification: UInt8
    }

    private struct ClipPlane {
        var normal: SIMD3<Float>
        var constant: Float

        func inside(_ position: SIMD3<Float>) -> Bool {
            simd_dot(normal, position) >= constant - 1e-6
        }

        func clip(_ polygon: [Corner]) -> [Corner] {
            guard !polygon.isEmpty else { return [] }
            var output: [Corner] = []
            var previous = polygon[polygon.count - 1]
            var previousInside = inside(previous.position)
            for current in polygon {
                let currentInside = inside(current.position)
                if currentInside {
                    if !previousInside {
                        output.append(intersection(previous, current))
                    }
                    output.append(current)
                } else if previousInside {
                    output.append(intersection(previous, current))
                }
                previous = current
                previousInside = currentInside
            }
            return output
        }

        private func intersection(_ a: Corner, _ b: Corner) -> Corner {
            let da = simd_dot(normal, a.position) - constant
            let db = simd_dot(normal, b.position) - constant
            let denominator = da - db
            let t = abs(denominator) < 1e-8 ? Float(0) : min(1, max(0, da / denominator))
            return Corner(
                position: a.position + (b.position - a.position) * t,
                normal: a.normal + (b.normal - a.normal) * t,
                color: a.color + (b.color - a.color) * t,
                classification: a.classification
            )
        }
    }

    private func corner(_ index: Int, fallbackClass triangle: Int) -> Corner {
        Corner(
            position: positions[index],
            normal: index < normals.count ? normals[index] : SIMD3<Float>(0, 1, 0),
            color: index < colors.count ? colors[index] : SIMD3<Float>(repeating: 0.72),
            classification: triangle < faceClasses.count ? faceClasses[triangle] : 0
        )
    }

    private func completelyOutside(_ corners: [Corner], box: AABB) -> Bool {
        func outside(_ axis: (Corner) -> Float, below: Float?, above: Float?) -> Bool {
            if let below, corners.allSatisfy({ axis($0) < below }) { return true }
            if let above, corners.allSatisfy({ axis($0) > above }) { return true }
            return false
        }
        if outside({ $0.position.x }, below: box.min.x, above: box.max.x) { return true }
        if outside({ $0.position.y }, below: box.min.y, above: box.max.y) { return true }
        if outside({ $0.position.z }, below: box.min.z, above: box.max.z) { return true }
        return false
    }

    private func appendTriangle(
        _ a: Corner,
        _ b: Corner,
        _ c: Corner,
        to positions: inout [SIMD3<Float>],
        _ normals: inout [SIMD3<Float>],
        _ colors: inout [SIMD3<Float>],
        _ indices: inout [UInt32],
        _ classes: inout [UInt8]
    ) {
        let area = simd_length(simd_cross(b.position - a.position, c.position - a.position))
        guard area > 1e-10 else { return }
        let base = UInt32(positions.count)
        for corner in [a, b, c] {
            positions.append(corner.position)
            normals.append(corner.normal)
            colors.append(corner.color)
        }
        indices.append(contentsOf: [base, base + 1, base + 2])
        classes.append(a.classification)
    }
}
