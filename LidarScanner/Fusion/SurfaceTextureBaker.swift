import UIKit
import simd

struct SurfaceBakeResult {
    var mesh: ScanMesh
    var image: UIImage
    var coverage: Double
}

/// Rasterizes world positions into a geometry UV atlas, then samples calibrated, depth-verified photos.
/// No photo crop UVs, per-face flat colors, relaxed visibility, or borrowed colors for unseen surfaces.
enum SurfaceTextureBaker {
    private struct View {
        let frame: StoredKeyframe
        let depth: DepthImage
        let confidence: [UInt8]
    }

    static func bake(mesh source: ScanMesh, directory: URL, frames input: [StoredKeyframe], settings: FusionSettings,
                     signal: WorkSignal?, progress: ((Double) -> Void)?) -> SurfaceBakeResult? {
        guard signal?.isCancelled != true, source.triangleCount > 0 else { return nil }
        let views = usableViews(input, directory: directory, limit: settings.preset == "hd" ? 64 : 48)
        guard !views.isEmpty else { return nil }
        let size = min(8192, max(256, settings.textureSize))
        progress?(0.02)
        guard var mesh = SurfaceUVUnwrapper.unwrap(source, resolution: min(size, 2048), signal: signal) else { return nil }
        progress?(0.20)
        let groups = candidateFaces(mesh: mesh, views: views, settings: settings)
        var atlas = AtlasImage(width: size, height: size)
        var weight = [Float16](repeating: 0, count: size * size)
        var bestWeight = [Float16](repeating: 0, count: size * size)
        var occupied = [Bool](repeating: false, count: size * size)
        mesh.colors = Array(repeating: SIMD3(repeating: 0.72), count: mesh.positions.count)
        var vertexWeight = [Float](repeating: 0, count: mesh.positions.count)
        // UV occupancy is independent of whether any photograph observed a surface point.
        for face in 0..<mesh.triangleCount {
            rasterize(mesh: mesh, face: face, size: size) { x, y, _ in occupied[y * size + x] = true }
        }
        var painted = 0
        for (viewIndex, view) in views.enumerated() {
            if signal?.isCancelled == true { return nil }
            guard !groups[viewIndex].isEmpty,
                  let color = KeyframeArchive.loadColor(in: directory, frame: view.frame, maxDimension: 1920) else { continue }
            let meshDepth = FaceVisibility.depthMap(mesh: mesh, frame: view.frame, width: 256)
            for (offset, candidate) in groups[viewIndex].enumerated() {
                if offset & 255 == 0, signal?.isCancelled == true { return nil }
                for corner in 0..<3 {
                    let i = Int(mesh.indices[candidate.face * 3 + corner])
                    if candidate.score > vertexWeight[i],
                       let hit = visible(mesh.positions[i], view: view, settings: settings, meshDepth: meshDepth),
                       let value = sample(color, pixel: hit.pixel, frame: view.frame) {
                        mesh.colors[i] = value
                        vertexWeight[i] = candidate.score
                    }
                }
                rasterize(mesh: mesh, face: candidate.face, size: size) { x, y, world in
                    guard let hit = visible(world, view: view, settings: settings, meshDepth: meshDepth),
                          let sample = sample(color, pixel: hit.pixel, frame: view.frame) else { return }
                    let edge = min(hit.pixel.x / Float(view.frame.width), 1 - hit.pixel.x / Float(view.frame.width),
                                   hit.pixel.y / Float(view.frame.height), 1 - hit.pixel.y / Float(view.frame.height))
                    let w = candidate.score * max(0.02, min(0.25, edge))
                    let i = y * size + x
                    let oldWeight = Float(weight[i])
                    if let old = atlas.get(x, y), oldWeight > 0 {
                        // Reject conflicting colors instead of ghosting an edge across different viewpoints.
                        if simd_distance(old, sample) > 0.25 {
                            if w > Float(bestWeight[i]) {
                                atlas.set(x, y, sample)
                                weight[i] = Float16(w)
                                bestWeight[i] = Float16(w)
                            }
                        } else {
                            atlas.set(x, y, (old * oldWeight + sample * w) / (oldWeight + w))
                            weight[i] = Float16(min(100, oldWeight + w))
                            bestWeight[i] = max(bestWeight[i], Float16(w))
                        }
                    } else {
                        atlas.set(x, y, sample)
                        weight[i] = Float16(w)
                        bestWeight[i] = Float16(w)
                        painted += 1
                    }
                }
            }
            progress?(0.2 + 0.7 * Double(viewIndex + 1) / Double(views.count))
        }
        guard painted > 0, signal?.isCancelled != true else { return nil }
        atlas.padGutters(occupied: occupied, passes: 3)
        if signal?.isCancelled == true { return nil }
        guard let image = atlas.uiImage() else { return nil }
        progress?(1)
        return SurfaceBakeResult(mesh: mesh, image: image, coverage: Double(painted) / Double(max(1, occupied.filter { $0 }.count)))
    }

    private static func usableViews(_ input: [StoredKeyframe], directory: URL, limit: Int) -> [View] {
        let ordered = input.sorted { $0.index < $1.index }
        let valid = ordered.filter {
            $0.width > 1 && $0.height > 1 && $0.fx > 0 && $0.fy > 0 && $0.view.count == 16
                && $0.view.allSatisfy(\.isFinite)
                && FileManager.default.fileExists(atPath: KeyframeArchive.colorURL(in: directory, index: $0.index).path)
        }
        let picks = valid.count <= limit ? valid : (0..<limit).map { valid[$0 * valid.count / limit] }
        return picks.compactMap { frame in
            guard let (depth, confidence) = try? KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: directory, index: frame.index)),
                  depth.width > 1, depth.height > 1 else { return nil }
            return View(frame: frame, depth: depth, confidence: confidence)
        }
    }

    private struct Candidate { let face: Int; let score: Float }

    private static func candidateFaces(mesh: ScanMesh, views: [View], settings: FusionSettings) -> [[Candidate]] {
        var result = [[Candidate]](repeating: [], count: views.count)
        for face in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[face * 3 + $0]) }
            let p = ids.map { mesh.positions[$0] }
            let center = (p[0] + p[1] + p[2]) / 3
            let cross = simd_cross(p[1] - p[0], p[2] - p[0])
            guard simd_length(cross) > 1e-10 else { continue }
            let normal = simd_normalize(cross)
            var scored: [(Int, Float)] = []
            for (index, view) in views.enumerated() {
                let toCamera = view.frame.cameraPosition - center
                let distance = simd_length(toCamera)
                guard distance > 0.05 else { continue }
                let facing = abs(simd_dot(normal, toCamera / distance))
                guard facing > 0.1,
                      ([center] + p).contains(where: { visible($0, view: view, settings: settings, meshDepth: nil) != nil }) else { continue }
                let sharpness = min(2, max(0.25, log2(max(1, view.frame.blur) + 1) / 8))
                let score = sharpness * facing * facing / max(0.1, distance * distance)
                scored.append((index, score))
            }
            scored.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            for (index, score) in scored.prefix(4) { result[index].append(Candidate(face: face, score: score)) }
        }
        return result
    }

    private static func visible(_ world: SIMD3<Float>, view: View, settings: FusionSettings, meshDepth: DepthImage?) -> (pixel: SIMD2<Float>, depth: Float)? {
        let f = view.frame
        guard let hit = CameraProjection.pixel(world: world, viewMatrix: f.viewMatrix, fx: f.fx, fy: f.fy, cx: f.cx, cy: f.cy),
              hit.depth <= settings.maxRange,
              hit.pixel.x >= 0.5, hit.pixel.y >= 0.5,
              hit.pixel.x < Float(f.width) - 0.5, hit.pixel.y < Float(f.height) - 0.5 else { return nil }
        let x = min(view.depth.width - 1, Int(hit.pixel.x * Float(view.depth.width) / Float(f.width)))
        let y = min(view.depth.height - 1, Int(hit.pixel.y * Float(view.depth.height) / Float(f.height)))
        let i = y * view.depth.width + x
        let depth = view.depth.values[i]
        guard depth.isFinite, depth > 0.05, i < view.confidence.count,
              Int(view.confidence[i]) >= settings.minConfidence,
              abs(hit.depth - depth) <= max(0.045, hit.depth * 0.025) else { return nil }
        if let meshDepth {
            let mx = min(meshDepth.width - 1, Int(hit.pixel.x * Float(meshDepth.width) / Float(f.width)))
            let my = min(meshDepth.height - 1, Int(hit.pixel.y * Float(meshDepth.height) / Float(f.height)))
            let front = meshDepth.values[my * meshDepth.width + mx]
            if front > 0.05, hit.depth > front + max(0.02, hit.depth * 0.01) { return nil }
        }
        return hit
    }

    /// Recover the world point using UV barycentrics, then project that point (not affine photo UVs).
    private static func rasterize(mesh: ScanMesh, face: Int, size: Int, visit: (Int, Int, SIMD3<Float>) -> Void) {
        let ids = (0..<3).map { Int(mesh.indices[face * 3 + $0]) }
        let uv = ids.map { SIMD2(mesh.uvs[$0].x * Float(size), (1 - mesh.uvs[$0].y) * Float(size)) }
        let ab = uv[1] - uv[0], ac = uv[2] - uv[0]
        let denominator = ab.x * ac.y - ab.y * ac.x
        guard abs(denominator) > 1e-6 else { return }
        let minX = max(0, Int(floor(uv.map(\.x).min()!)))
        let maxX = min(size - 1, Int(ceil(uv.map(\.x).max()!)))
        let minY = max(0, Int(floor(uv.map(\.y).min()!)))
        let maxY = min(size - 1, Int(ceil(uv.map(\.y).max()!)))
        guard minX <= maxX, minY <= maxY else { return }
        let a = mesh.positions[ids[0]], b = mesh.positions[ids[1]], c = mesh.positions[ids[2]]
        for y in minY...maxY {
            for x in minX...maxX {
                let ap = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - uv[0]
                let u = (ap.x * ac.y - ap.y * ac.x) / denominator
                let v = (ab.x * ap.y - ab.y * ap.x) / denominator
                guard u >= -0.00001, v >= -0.00001, u + v <= 1.00001 else { continue }
                visit(x, y, a + u * (b - a) + v * (c - a))
            }
        }
    }

    private static func sample(_ image: RGBAImage, pixel: SIMD2<Float>, frame: StoredKeyframe) -> SIMD3<Float>? {
        let u = pixel.x * Float(image.width) / Float(frame.width) - 0.5
        let v = pixel.y * Float(image.height) / Float(frame.height) - 0.5
        guard u >= 0, v >= 0, u < Float(image.width - 1), v < Float(image.height - 1) else { return nil }
        let x = Int(u), y = Int(v)
        let tx = u - Float(x), ty = v - Float(y)
        func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * image.width + x) * 4
            return SIMD3(Float(image.rgba[i]), Float(image.rgba[i + 1]), Float(image.rgba[i + 2])) / 255
        }
        return simd_mix(simd_mix(color(x, y), color(x + 1, y), SIMD3(repeating: tx)),
                        simd_mix(color(x, y + 1), color(x + 1, y + 1), SIMD3(repeating: tx)), SIMD3(repeating: ty))
    }
}
