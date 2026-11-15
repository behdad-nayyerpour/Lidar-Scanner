import Foundation
import simd

struct HoleRepairResult: Sendable {
    var mesh: ScanMesh
    var filled: Int
}

extension ScanMesh {
    /// Conservative repair: bounded, planar, convex manifold loops only. Existing
    /// vertices never move. Large gaps and ambiguous boundaries require recapture.
    func repairingSmallHoles(maxDiameter: Float = 0.08, preserveEdges: Bool = true) -> HoleRepairResult {
        struct Edge: Hashable {
            let lo: UInt32
            let hi: UInt32
            init(_ a: UInt32, _ b: UInt32) { lo = min(a, b); hi = max(a, b) }
        }
        struct Use { var count: Int; var a: UInt32; var b: UInt32 }
        struct PositionKey: Hashable { let x: Float; let y: Float; let z: Float }
        // UV unwrapping duplicates vertices on texture seams. Reconnect only
        // exactly coincident positions for topology; never move the geometry.
        var canonical: [PositionKey: UInt32] = [:]
        var remap = [UInt32]()
        remap.reserveCapacity(positions.count)
        for (index, p) in positions.enumerated() {
            let key = PositionKey(x: p.x, y: p.y, z: p.z)
            let representative = canonical[key] ?? UInt32(index)
            canonical[key] = representative
            remap.append(representative)
        }
        var uses: [Edge: Use] = [:]
        for t in 0..<triangleCount {
            let raw = Array(indices[(t * 3)..<(t * 3 + 3)])
            guard raw.allSatisfy({ Int($0) < positions.count }) else { continue }
            let ids = raw.map { remap[Int($0)] }
            guard Set(ids).count == 3 else { continue }
            for i in 0..<3 {
                let a = ids[i], b = ids[(i + 1) % 3], key = Edge(a, b)
                if var use = uses[key] { use.count += 1; uses[key] = use }
                else { uses[key] = Use(count: 1, a: a, b: b) }
            }
        }
        var outgoing: [UInt32: [UInt32]] = [:]
        var incoming: [UInt32: Int] = [:]
        var forbidden = Set<UInt32>()
        for use in uses.values {
            if use.count > 2 { forbidden.insert(use.a); forbidden.insert(use.b) }
            if use.count == 1 {
                outgoing[use.a, default: []].append(use.b)
                incoming[use.b, default: 0] += 1
            }
        }
        var visited = Set<UInt32>()
        var result = self
        if result.faceClasses.count != triangleCount {
            result.faceClasses = Array(repeating: 0, count: triangleCount)
        }
        var filled = 0
        // UVs from the previous topology must never be paired with repaired faces.
        for start in outgoing.keys.sorted() where !visited.contains(start) {
            var loop: [UInt32] = []
            var cursor = start
            var closed = false
            while !visited.contains(cursor), loop.count < 128 {
                visited.insert(cursor)
                guard !forbidden.contains(cursor), incoming[cursor] == 1,
                      let next = outgoing[cursor], next.count == 1 else { break }
                loop.append(cursor)
                cursor = next[0]
                if cursor == start { closed = true; break }
            }
            guard closed, loop.count >= 3 else { continue }
            let points = loop.map { positions[Int($0)] }
            var diameter: Float = 0
            for a in points { for b in points { diameter = max(diameter, simd_distance(a, b)) } }
            guard diameter > 0.001, diameter <= maxDiameter else { continue }
            let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
            var normal = SIMD3<Float>.zero
            for i in points.indices {
                normal += simd_cross(points[i] - center, points[(i + 1) % points.count] - center)
            }
            guard simd_length(normal) > 1e-8 else { continue }
            normal = simd_normalize(normal)
            let tolerance: Float = preserveEdges ? 0.002 : 0.005
            guard points.allSatisfy({ abs(simd_dot($0 - center, normal)) <= tolerance }) else { continue }
            // Convexity plus an angular winding check rejects concave and crossed
            // loops. A fan is valid only when every turn has the same orientation.
            var turnSum: Float = 0
            var convex = true
            for i in points.indices {
                let a = points[i] - points[(i + points.count - 1) % points.count]
                let b = points[(i + 1) % points.count] - points[i]
                guard simd_length(a) > 1e-6, simd_length(b) > 1e-6 else { convex = false; break }
                let turn = atan2(simd_dot(simd_cross(a, b), normal), simd_dot(a, b))
                if turn < -0.0001 { convex = false; break }
                turnSum += turn
            }
            guard convex, abs(turnSum - 2 * .pi) < 0.01 else { continue }
            // Reverse existing boundary winding so shared edges have opposite uses.
            for i in 1..<(loop.count - 1) {
                result.indices.append(contentsOf: [loop[0], loop[i + 1], loop[i]])
                result.faceClasses.append(0)
            }
            filled += 1
        }
        if filled > 0 { result.uvs = [] }
        return HoleRepairResult(mesh: result, filled: filled)
    }
}
