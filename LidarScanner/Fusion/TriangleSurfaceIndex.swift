import simd

/// Bounding-volume hierarchy for exact point-to-triangle proximity queries.
struct TriangleSurfaceIndex {
    private struct Triangle {
        var a: SIMD3<Float>; var b: SIMD3<Float>; var c: SIMD3<Float>
        var min: SIMD3<Float> { simd_min(a, simd_min(b, c)) }
        var max: SIMD3<Float> { simd_max(a, simd_max(b, c)) }
        var center: SIMD3<Float> { (a + b + c) / 3 }
    }
    private struct Node {
        var min: SIMD3<Float>; var max: SIMD3<Float>
        var left: Int; var right: Int; var start: Int; var end: Int
    }
    private var triangles: [Triangle] = []
    private var order: [Int] = []
    private var nodes: [Node] = []

    init(mesh: ScanMesh) {
        for i in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[3 * i + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let t = Triangle(a: mesh.positions[ids[0]], b: mesh.positions[ids[1]], c: mesh.positions[ids[2]])
            guard t.a.x.isFinite, t.a.y.isFinite, t.a.z.isFinite,
                  t.b.x.isFinite, t.b.y.isFinite, t.b.z.isFinite,
                  t.c.x.isFinite, t.c.y.isFinite, t.c.z.isFinite,
                  simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20 else { continue }
            triangles.append(t)
        }
        order = Array(triangles.indices)
        if !order.isEmpty { _ = build(0, order.count) }
    }

    private mutating func build(_ start: Int, _ end: Int) -> Int {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var cmin = lo, cmax = hi
        for i in start..<end {
            let triangle = triangles[order[i]]
            lo = simd_min(lo, triangle.min); hi = simd_max(hi, triangle.max)
            cmin = simd_min(cmin, triangle.center); cmax = simd_max(cmax, triangle.center)
        }
        let id = nodes.count
        nodes.append(Node(min: lo, max: hi, left: -1, right: -1, start: start, end: end))
        if end - start > 8 {
            let extent = cmax - cmin
            let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
            let sorted = order[start..<end].sorted { triangles[$0].center[axis] < triangles[$1].center[axis] }
            order.replaceSubrange(start..<end, with: sorted)
            let mid = (start + end) / 2
            let left = build(start, mid), right = build(mid, end)
            nodes[id].left = left; nodes[id].right = right
        }
        return id
    }

    func containsSurface(near point: SIMD3<Float>, tolerance: Float) -> Bool {
        guard !nodes.isEmpty, tolerance >= 0 else { return false }
        let radius2 = tolerance * tolerance
        var stack = [0]
        while let id = stack.popLast() {
            let node = nodes[id]
            let delta = simd_max(simd_max(node.min - point, point - node.max), .zero)
            if simd_length_squared(delta) > radius2 { continue }
            if node.left >= 0 { stack.append(node.left); stack.append(node.right); continue }
            for i in node.start..<node.end {
                let t = triangles[order[i]]
                if Self.distanceSquared(point, t.a, t.b, t.c) <= radius2 { return true }
            }
        }
        return false
    }

    private static func distanceSquared(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }
        let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return simd_length_squared(p - (a + ab * (d1 / (d1 - d3)))) }
        let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return simd_length_squared(p - (a + ac * (d2 / (d2 - d6)))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0 {
            return simd_length_squared(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))))
        }
        let denom = 1 / (va + vb + vc)
        return simd_length_squared(p - (a + ab * (vb * denom) + ac * (vc * denom)))
    }
}
