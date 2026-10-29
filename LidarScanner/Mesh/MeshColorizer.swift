import Foundation
import simd

struct ColorizeOutcome: Sendable {
    var partial: Bool
    var coloredVertices: Int
}

enum MeshColorizer {
    /// Colors each vertex from the one camera frame that sees it best.
    /// A depth buffer of this mesh stops a hidden surface from taking the color in front of it.
    /// Stops if `signal` is cancelled or the time budget runs out, leaving remaining vertices gray.
    static func colorize(
        _ mesh: inout ScanMesh,
        keyframes: [ColorKeyframe],
        signal: WorkSignal?,
        progress: ((Double) -> Void)? = nil
    ) -> ColorizeOutcome {
        let started = CFAbsoluteTimeGetCurrent()
        let count = mesh.positions.count
        if mesh.colors.count != count {
            mesh.colors = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0.72), count: count)
        }
        guard !keyframes.isEmpty, count > 0 else {
            progress?(1)
            Log.scan.info("colorize skipped empty ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
            return ColorizeOutcome(partial: false, coloredVertices: 0)
        }
        if mesh.normals.count != count {
            mesh.recomputeNormals()
        }

        var colored = 0
        var partial = false
        let deadline = started + 90
        var buffers: [MeshDepthBuffer] = []
        buffers.reserveCapacity(keyframes.count)
        for (frameIndex, frame) in keyframes.enumerated() {
            if signal?.isCancelled == true || CFAbsoluteTimeGetCurrent() > deadline {
                partial = true
                break
            }
            buffers.append(MeshDepthBuffer.rasterize(mesh: mesh, frame: frame))
            progress?(0.15 * Double(frameIndex + 1) / Double(max(keyframes.count, 1)))
        }
        Log.scan.info("colorize depth buffers=\(buffers.count, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")

        var painted = [Bool](repeating: false, count: count)
        if signal?.isCancelled != true {
            for index in 0..<count {
                if index & 4095 == 0 {
                    if signal?.isCancelled == true || CFAbsoluteTimeGetCurrent() > deadline {
                        partial = true
                        break
                    }
                    progress?(0.15 + 0.8 * Double(index) / Double(count))
                }
                let position = mesh.positions[index]
                let normal = mesh.normals[index]
                let normalLength = simd_length(normal)
                var bestScore: Float = 0
                var bestColor = SIMD3<Float>.zero
                for (frameIndex, frame) in keyframes.enumerated() {
                    let toward = frame.cameraPosition - position
                    let distance = simd_length(toward)
                    if distance < 0.05 || distance > 8 { continue }
                    if normalLength > 0.15, simd_dot(normal, toward) < 0.12 * normalLength * distance { continue }
                    if frameIndex < buffers.count, buffers[frameIndex].occludes(world: position, frame: frame) { continue }
                    guard let sample = frame.sample(world: position, normal: normal) else { continue }
                    if sample.0 > bestScore {
                        bestScore = sample.0
                        bestColor = sample.1
                    }
                }
                if bestScore > 0 {
                    mesh.colors[index] = bestColor
                    painted[index] = true
                    colored += 1
                }
            }
        }
        if !partial {
            colored += fillSmallHoles(&mesh, painted: painted)
        }
        progress?(1)
        Log.scan.info("colorize vertices=\(count, privacy: .public) frames=\(keyframes.count, privacy: .public) colored=\(colored, privacy: .public) partial=\(partial, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
        return ColorizeOutcome(partial: partial, coloredVertices: colored)
    }

    /// Copies color across a vertex that every camera missed when its neighbors were colored.
    /// One ring only, so a hidden surface stays gray instead of inheriting the room.
    private static func fillSmallHoles(_ mesh: inout ScanMesh, painted: [Bool]) -> Int {
        let count = mesh.positions.count
        var sum = [SIMD3<Float>](repeating: .zero, count: count)
        var hits = [Int](repeating: 0, count: count)
        let triangles = mesh.triangleCount
        for triangle in 0..<triangles {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < count, i1 < count, i2 < count else { continue }
            contribute(from: i0, to: i1, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
            contribute(from: i1, to: i0, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
            contribute(from: i1, to: i2, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
            contribute(from: i2, to: i1, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
            contribute(from: i2, to: i0, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
            contribute(from: i0, to: i2, mesh: mesh, painted: painted, sum: &sum, hits: &hits)
        }
        var filled = 0
        for index in 0..<count where !painted[index] && hits[index] >= 2 {
            mesh.colors[index] = sum[index] / Float(hits[index])
            filled += 1
        }
        return filled
    }

    private static func contribute(
        from: Int,
        to: Int,
        mesh: ScanMesh,
        painted: [Bool],
        sum: inout [SIMD3<Float>],
        hits: inout [Int]
    ) {
        guard painted[from], !painted[to] else { return }
        sum[to] += mesh.colors[from]
        hits[to] += 1
    }
}

/// Low-resolution camera-space depth of this mesh. A vertex behind a closer triangle
/// must not take that triangle's photo color.
private struct MeshDepthBuffer {
    var width: Int
    var height: Int
    var values: [Float]

    static func rasterize(mesh: ScanMesh, frame: ColorKeyframe) -> MeshDepthBuffer {
        let width = 64
        let height = max(1, width * max(frame.height, 1) / max(frame.width, 1))
        var buffer = MeshDepthBuffer(width: width, height: height, values: [Float](repeating: .greatestFiniteMagnitude, count: width * height))
        let scaleX = Float(width) / Float(max(frame.width, 1))
        let scaleY = Float(height) / Float(max(frame.height, 1))
        let triangles = mesh.triangleCount
        for triangle in 0..<triangles {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
            let a = mesh.positions[i0]
            let b = mesh.positions[i1]
            let c = mesh.positions[i2]
            let facing = simd_dot(simd_cross(b - a, c - a), frame.cameraPosition - a)
            if facing <= 0 { continue }
            guard let p0 = project(a, frame: frame, scaleX: scaleX, scaleY: scaleY),
                  let p1 = project(b, frame: frame, scaleX: scaleX, scaleY: scaleY),
                  let p2 = project(c, frame: frame, scaleX: scaleX, scaleY: scaleY) else { continue }
            buffer.paint(p0, p1, p2)
        }
        return buffer
    }

    func occludes(world: SIMD3<Float>, frame: ColorKeyframe) -> Bool {
        let scaleX = Float(width) / Float(max(frame.width, 1))
        let scaleY = Float(height) / Float(max(frame.height, 1))
        guard let point = Self.project(world, frame: frame, scaleX: scaleX, scaleY: scaleY) else { return false }
        let x = min(width - 1, max(0, Int(point.x)))
        let y = min(height - 1, max(0, Int(point.y)))
        let nearest = values[y * width + x]
        guard nearest < 1e8 else { return false }
        let slack = max(0.08, point.z * 0.05)
        return point.z > nearest + slack
    }

    private mutating func paint(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let minX = max(0, Int(min(a.x, min(b.x, c.x))))
        let maxX = min(width - 1, Int(max(a.x, max(b.x, c.x))))
        let minY = max(0, Int(min(a.y, min(b.y, c.y))))
        let maxY = min(height - 1, Int(max(a.y, max(b.y, c.y))))
        guard minX <= maxX, minY <= maxY else { return }
        let area = edge(a, b, c)
        if abs(area) < 0.01 || (maxX - minX) + (maxY - minY) <= 1 {
            write(Int((a.x + b.x + c.x) / 3), Int((a.y + b.y + c.y) / 3), min(a.z, min(b.z, c.z)))
            return
        }
        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(b, c, p)
                let w1 = edge(c, a, p)
                let w2 = edge(a, b, p)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                if !inside { continue }
                let sum = w0 + w1 + w2
                if abs(sum) < 1e-5 { continue }
                let depth = (w0 * a.z + w1 * b.z + w2 * c.z) / sum
                write(x, y, depth)
            }
        }
    }

    private mutating func write(_ x: Int, _ y: Int, _ depth: Float) {
        guard x >= 0, y >= 0, x < width, y < height, depth > 0.05 else { return }
        let index = y * width + x
        if depth < values[index] {
            values[index] = depth
        }
    }

    private func edge(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)
    }

    private func edge(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD2<Float>) -> Float {
        (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)
    }

    /// Same projection as `ColorKeyframe.sample`: ARKit looks down -Z, image Y follows the intrinsics.
    private static func project(_ world: SIMD3<Float>, frame: ColorKeyframe, scaleX: Float, scaleY: Float) -> SIMD3<Float>? {
        let cameraSpace = frame.viewMatrix * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard cameraSpace.z < -0.05 else { return nil }
        let inverseDepth = -1 / cameraSpace.z
        let x = cameraSpace.x * inverseDepth
        let y = cameraSpace.y * inverseDepth
        let u = frame.intrinsics.columns.0.x * x + frame.intrinsics.columns.2.x
        let v = frame.intrinsics.columns.1.y * y + frame.intrinsics.columns.2.y
        guard u >= 0, v >= 0, u < Float(frame.width), v < Float(frame.height) else { return nil }
        return SIMD3(u * scaleX, v * scaleY, -cameraSpace.z)
    }
}
