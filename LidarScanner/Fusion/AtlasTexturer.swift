import UIKit
import simd

enum AtlasTexturer {
    static func texture(
        mesh source: ScanMesh,
        directory: URL,
        frames allFrames: [StoredKeyframe],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)?
    ) -> (mesh: ScanMesh, image: UIImage)? {
        guard source.triangleCount > 8, !allFrames.isEmpty else { return nil }
        if signal?.isCancelled == true { return nil }
        let frames = decimatedFrames(allFrames, limit: 72)
        progress?(0.05)
        var mesh = unwrap(source, resolution: settings.textureSize)
        guard mesh.uvs.count == mesh.positions.count, mesh.triangleCount > 0 else { return nil }
        mesh.recomputeNormals()
        progress?(0.15)
        let chosen = selectViews(mesh: mesh, directory: directory, frames: frames, settings: settings, signal: signal) { fraction in
            progress?(0.15 + 0.35 * fraction)
        }
        progress?(0.55)
        guard var atlas = rasterize(mesh: mesh, directory: directory, frames: frames, chosen: chosen, settings: settings, signal: signal, progress: { fraction in
            progress?(0.7 + 0.25 * fraction)
        }) else {
            return nil
        }
        atlas = fillUncovered(mesh: mesh, image: atlas, chosen: chosen)
        progress?(0.92)
        paintVertexColors(&mesh, image: atlas)
        guard let image = atlas.uiImage() else { return nil }
        progress?(1)
        return (mesh, image)
    }

    private static func decimatedFrames(_ frames: [StoredKeyframe], limit: Int) -> [StoredKeyframe] {
        guard frames.count > limit else { return frames }
        let sorted = frames.sorted { $0.blur > $1.blur }
        let kept = sorted.prefix(limit)
        return frames.filter { frame in kept.contains(where: { $0.index == frame.index }) }
    }

    private static func unwrap(_ mesh: ScanMesh, resolution: Int) -> ScanMesh {
        var packed: [Float] = []
        packed.reserveCapacity(mesh.positions.count * 3)
        for position in mesh.positions {
            packed.append(position.x)
            packed.append(position.y)
            packed.append(position.z)
        }
        var native = NMMesh()
        let code: Int32 = packed.withUnsafeBufferPointer { positions in
            mesh.indices.withUnsafeBufferPointer { indices in
                NMBuildAtlas(positions.baseAddress, UInt32(mesh.positions.count), indices.baseAddress, UInt32(mesh.indices.count), Int32(resolution), nil, &native)
            }
        }
        defer { NMFreeMesh(&native) }
        if code == 0, native.vertexCount > 0, native.indexCount >= 3, let positions = native.positions, let uvs = native.uvs, let indices = native.indices {
            var result = ScanMesh()
            result.positions.reserveCapacity(Int(native.vertexCount))
            result.uvs.reserveCapacity(Int(native.vertexCount))
            for index in 0..<Int(native.vertexCount) {
                result.positions.append(SIMD3(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2]))
                result.uvs.append(SIMD2(uvs[index * 2], 1 - uvs[index * 2 + 1]))
            }
            result.indices.reserveCapacity(Int(native.indexCount))
            for index in 0..<Int(native.indexCount) {
                result.indices.append(indices[index])
            }
            return result
        }
        return gridUnwrap(mesh)
    }

    private static func gridUnwrap(_ mesh: ScanMesh) -> ScanMesh {
        let grid = max(1, Int(ceil(sqrt(Double(mesh.triangleCount)))))
        var result = ScanMesh()
        for triangle in 0..<mesh.triangleCount {
            let column = triangle % grid
            let row = triangle / grid
            let pad = 0.18 / Float(grid)
            let top = 1 - (Float(row) + pad) / Float(grid)
            let bottom = 1 - (Float(row + 1) - pad) / Float(grid)
            let corners = [
                SIMD2((Float(column) + pad) / Float(grid), bottom),
                SIMD2((Float(column + 1) - pad) / Float(grid), bottom),
                SIMD2((Float(column) + 0.5) / Float(grid), top)
            ]
            let start = UInt32(result.positions.count)
            for corner in 0..<3 {
                let index = Int(mesh.indices[triangle * 3 + corner])
                guard index < mesh.positions.count else { continue }
                result.positions.append(mesh.positions[index])
                result.uvs.append(corners[corner])
                result.indices.append(start + UInt32(corner))
            }
        }
        return result
    }

    private static func selectViews(
        mesh: ScanMesh,
        directory: URL,
        frames: [StoredKeyframe],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)? = nil
    ) -> [Int] {
        var buffers: [MeshDepthImage] = []
        buffers.reserveCapacity(frames.count)
        for frame in frames {
            if signal?.isCancelled == true { break }
            buffers.append(MeshDepthImage.rasterize(mesh: mesh, frame: frame))
        }
        var chosen = [Int](repeating: -1, count: mesh.triangleCount)
        var top: [[(Int, Float)]] = Array(repeating: [], count: mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount {
            if triangle & 2047 == 0 {
                if signal?.isCancelled == true { break }
                progress?(Double(triangle) / Double(max(mesh.triangleCount, 1)))
            }
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let points = ids.map { mesh.positions[$0] }
            let normal = triangle < mesh.normals.count ? mesh.normals[ids[0]] : faceNormal(points)
            let centroid = (points[0] + points[1] + points[2]) / 3
            var bestFrame = -1
            var bestScore: Float = 0
            for (frameIndex, frame) in frames.enumerated() {
                guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, buffer: frameIndex < buffers.count ? buffers[frameIndex] : nil, settings: settings, relaxed: false) else { continue }
                if score > bestScore {
                    bestScore = score
                    bestFrame = frameIndex
                }
                if top[triangle].count < 3 {
                    top[triangle].append((frameIndex, score))
                } else if let worst = top[triangle].enumerated().min(by: { $0.element.1 < $1.element.1 }), score > worst.element.1 {
                    top[triangle][worst.offset] = (frameIndex, score)
                }
            }
            if bestFrame < 0 {
                for (frameIndex, frame) in frames.enumerated() {
                    guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, buffer: frameIndex < buffers.count ? buffers[frameIndex] : nil, settings: settings, relaxed: true) else { continue }
                    if score > bestScore {
                        bestScore = score
                        bestFrame = frameIndex
                    }
                }
            }
            chosen[triangle] = bestFrame
        }
        chosen = voteByRegion(mesh: mesh, chosen: chosen, top: top, cell: 0.3)
        let neighbors = faceNeighbors(mesh)
        for _ in 0..<6 {
            var next = chosen
            for triangle in 0..<mesh.triangleCount {
                var counts: [Int: Int] = [:]
                for neighbor in neighbors[triangle] where chosen[neighbor] >= 0 {
                    counts[chosen[neighbor], default: 0] += 1
                }
                guard let popular = counts.max(by: { $0.value < $1.value }), popular.value >= 2 else { continue }
                let own = top[triangle].first { $0.0 == chosen[triangle] }?.1 ?? 0
                let alternative = top[triangle].first { $0.0 == popular.key }?.1 ?? 0
                if alternative > own * 0.3 { next[triangle] = popular.key }
            }
            chosen = next
        }
        return chosen
    }

    /// Faces in the same patch of the room share one photo, so the atlas is not a confetti of single triangles.
    private static func voteByRegion(mesh: ScanMesh, chosen: [Int], top: [[(Int, Float)]], cell: Float) -> [Int] {
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        for triangle in 0..<mesh.triangleCount where triangle < chosen.count && chosen[triangle] >= 0 {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
            let center = (mesh.positions[i0] + mesh.positions[i1] + mesh.positions[i2]) / 3
            let key = SIMD3<Int32>(Int32(floor(center.x / cell)), Int32(floor(center.y / cell)), Int32(floor(center.z / cell)))
            buckets[key, default: []].append(triangle)
        }
        var result = chosen
        for triangles in buckets.values {
            var counts: [Int: Int] = [:]
            for triangle in triangles {
                counts[chosen[triangle], default: 0] += 1
            }
            guard let popular = counts.max(by: { $0.value < $1.value }) else { continue }
            for triangle in triangles {
                let own = top[triangle].first { $0.0 == chosen[triangle] }?.1 ?? 0
                let alternative = top[triangle].first { $0.0 == popular.key }?.1 ?? 0
                if alternative > own * 0.2 { result[triangle] = popular.key }
            }
        }
        return result
    }

    private static func scoreFace(
        points: [SIMD3<Float>],
        centroid: SIMD3<Float>,
        normal: SIMD3<Float>,
        frame: StoredKeyframe,
        buffer: MeshDepthImage?,
        settings: FusionSettings,
        relaxed: Bool
    ) -> Float? {
        let camera = frame.viewMatrix * SIMD4(centroid.x, centroid.y, centroid.z, 1)
        guard let centerPixel = CameraProjection.pixel(cameraX: camera.x, cameraY: camera.y, cameraZ: camera.z, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else { return nil }
        let depth = -camera.z
        let maxDistance = relaxed ? settings.maxRange * 1.35 : settings.maxRange
        guard depth > 0.3, depth < maxDistance else { return nil }
        guard centerPixel.x >= 1, centerPixel.y >= 1, centerPixel.x < Float(frame.width) - 1, centerPixel.y < Float(frame.height) - 1 else { return nil }
        let toward = frame.cameraPosition - centroid
        let distance = simd_length(toward)
        guard distance > 0.05 else { return nil }
        let facing = simd_dot(simd_normalize(normal), toward / distance)
        let minimumFacing: Float = relaxed ? 0.05 : 0.2
        guard facing > minimumFacing else { return nil }
        if let buffer, buffer.occludes(pixel: centerPixel, depth: depth, frame: frame, slackScale: relaxed ? 2 : 1) { return nil }
        var area: Float = 0
        var projected: [SIMD2<Float>] = []
        for point in points {
            guard let hit = CameraProjection.pixel(world: point, viewMatrix: frame.viewMatrix, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else { return nil }
            projected.append(hit.pixel)
        }
        if projected.count == 3 {
            area = abs((projected[1].x - projected[0].x) * (projected[2].y - projected[0].y) - (projected[2].x - projected[0].x) * (projected[1].y - projected[0].y)) * 0.5
        }
        guard area > (relaxed ? 0.2 : 1.5) else { return nil }
        let sharpness = max(frame.blur, 1)
        return sharpness * sqrt(area) * facing / (0.35 + distance)
    }

    private static func rasterize(
        mesh: ScanMesh,
        directory: URL,
        frames: [StoredKeyframe],
        chosen: [Int],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)? = nil
    ) -> AtlasImage? {
        let size = max(256, settings.textureSize)
        var image = AtlasImage(width: size, height: size)
        let targetRed = median(frames.map(\.meanRed))
        let targetGreen = median(frames.map(\.meanGreen))
        let targetBlue = median(frames.map(\.meanBlue))
        let used = Set(chosen.filter { $0 >= 0 })
        var cache: [Int: RGBAImage] = [:]
        for frameIndex in used.sorted() {
            if signal?.isCancelled == true { return image }
            let frame = frames[frameIndex]
            guard var color = KeyframeArchive.loadColor(in: directory, frame: frame, maxDimension: 1600) else { continue }
            let gain = SIMD3(
                clampGain(targetRed / max(frame.meanRed, 1)),
                clampGain(targetGreen / max(frame.meanGreen, 1)),
                clampGain(targetBlue / max(frame.meanBlue, 1))
            )
            color = scaled(color, gain: gain)
            cache[frameIndex] = color
        }
        for triangle in 0..<mesh.triangleCount {
            if triangle & 4095 == 0 {
                progress?(Double(triangle) / Double(max(mesh.triangleCount, 1)))
            }
            let frameIndex = triangle < chosen.count ? chosen[triangle] : -1
            guard frameIndex >= 0, let color = cache[frameIndex] else { continue }
            let frame = frames[frameIndex]
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.uvs.count }) else { continue }
            paintTriangle(
                image: &image,
                world: ids.map { mesh.positions[$0] },
                uv: ids.map { mesh.uvs[$0] },
                frame: frame,
                color: color
            )
        }
        image.dilate(passes: 8)
        return image
    }

    private static func paintTriangle(image: inout AtlasImage, world: [SIMD3<Float>], uv: [SIMD2<Float>], frame: StoredKeyframe, color: RGBAImage) {
        let scaleX = Float(color.width) / Float(max(frame.width, 1))
        let scaleY = Float(color.height) / Float(max(frame.height, 1))
        let pixels = uv.map { SIMD2($0.x * Float(image.width - 1), (1 - $0.y) * Float(image.height - 1)) }
        let minX = max(0, Int(floor(min(pixels[0].x, min(pixels[1].x, pixels[2].x)))))
        let maxX = min(image.width - 1, Int(ceil(max(pixels[0].x, max(pixels[1].x, pixels[2].x)))))
        let minY = max(0, Int(floor(min(pixels[0].y, min(pixels[1].y, pixels[2].y)))))
        let maxY = min(image.height - 1, Int(ceil(max(pixels[0].y, max(pixels[1].y, pixels[2].y)))))
        guard minX <= maxX, minY <= maxY else { return }
        var depths: [Float] = []
        for point in world {
            let camera = frame.viewMatrix * SIMD4(point.x, point.y, point.z, 1)
            depths.append(max(0.05, -camera.z))
        }
        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(pixels[1], pixels[2], p)
                let w1 = edge(pixels[2], pixels[0], p)
                let w2 = edge(pixels[0], pixels[1], p)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                if !inside { continue }
                let sum = w0 + w1 + w2
                if abs(sum) < 1e-5 { continue }
                let b0 = w0 / sum
                let b1 = w1 / sum
                let b2 = w2 / sum
                let inverse = b0 / depths[0] + b1 / depths[1] + b2 / depths[2]
                guard inverse > 1e-6 else { continue }
                let c0 = (b0 / depths[0]) / inverse
                let c1 = (b1 / depths[1]) / inverse
                let c2 = (b2 / depths[2]) / inverse
                let worldPoint = world[0] * c0 + world[1] * c1 + world[2] * c2
                guard let projected = CameraProjection.pixel(world: worldPoint, viewMatrix: frame.viewMatrix, fx: frame.fx * scaleX, fy: frame.fy * scaleY, cx: frame.cx * scaleX, cy: frame.cy * scaleY) else { continue }
                guard let sample = bilinear(color, projected.pixel.x, projected.pixel.y) else { continue }
                image.set(x, y, sample)
            }
        }
    }

    private static func fillUncovered(mesh: ScanMesh, image: AtlasImage, chosen: [Int]) -> AtlasImage {
        var image = image
        var averages = [SIMD3<Float>?](repeating: nil, count: mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount where triangle < chosen.count && chosen[triangle] >= 0 {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.uvs.count }) else { continue }
            let uv = (mesh.uvs[ids[0]] + mesh.uvs[ids[1]] + mesh.uvs[ids[2]]) / 3
            let x = Int(uv.x * Float(image.width - 1))
            let y = Int((1 - uv.y) * Float(image.height - 1))
            if let sample = image.get(x, y) { averages[triangle] = sample }
        }
        let neighbors = faceNeighbors(mesh)
        for _ in 0..<8 {
            var next = averages
            for triangle in 0..<mesh.triangleCount where averages[triangle] == nil {
                var sum = SIMD3<Float>.zero
                var count: Float = 0
                for neighbor in neighbors[triangle] {
                    if let color = averages[neighbor] {
                        sum += color
                        count += 1
                    }
                }
                if count > 0 { next[triangle] = sum / count }
            }
            averages = next
        }
        for triangle in 0..<mesh.triangleCount {
            guard chosen[triangle] < 0, let color = averages[triangle] else { continue }
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.uvs.count && $0 < mesh.positions.count }) else { continue }
            let pixels = ids.map { SIMD2(mesh.uvs[$0].x * Float(image.width - 1), (1 - mesh.uvs[$0].y) * Float(image.height - 1)) }
            let minX = max(0, Int(floor(min(pixels[0].x, min(pixels[1].x, pixels[2].x)))))
            let maxX = min(image.width - 1, Int(ceil(max(pixels[0].x, max(pixels[1].x, pixels[2].x)))))
            let minY = max(0, Int(floor(min(pixels[0].y, min(pixels[1].y, pixels[2].y)))))
            let maxY = min(image.height - 1, Int(ceil(max(pixels[0].y, max(pixels[1].y, pixels[2].y)))))
            for y in minY...maxY {
                for x in minX...maxX {
                    if image.get(x, y) == nil { image.set(x, y, color) }
                }
            }
        }
        image.levelSeams(mesh: mesh)
        return image
    }

    private static func paintVertexColors(_ mesh: inout ScanMesh, image: AtlasImage) {
        mesh.colors = Array(repeating: SIMD3(repeating: 0.72), count: mesh.positions.count)
        for index in 0..<mesh.positions.count where index < mesh.uvs.count {
            let x = Int(mesh.uvs[index].x * Float(image.width - 1))
            let y = Int((1 - mesh.uvs[index].y) * Float(image.height - 1))
            if let sample = image.get(x, y) { mesh.colors[index] = sample }
        }
    }

    private static func faceNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        let normal = simd_cross(points[1] - points[0], points[2] - points[0])
        let length = simd_length(normal)
        return length > 1e-8 ? normal / length : SIMD3(0, 1, 0)
    }

    private static func faceNeighbors(_ mesh: ScanMesh) -> [[Int]] {
        var faces: [[Int]] = Array(repeating: [], count: mesh.triangleCount)
        var edges: [UInt64: Int] = [:]
        for triangle in 0..<mesh.triangleCount {
            for corner in 0..<3 {
                let a = UInt64(mesh.indices[triangle * 3 + corner])
                let b = UInt64(mesh.indices[triangle * 3 + (corner + 1) % 3])
                let key = min(a, b) << 32 | max(a, b)
                if let other = edges[key], other != triangle {
                    faces[triangle].append(other)
                    faces[other].append(triangle)
                } else {
                    edges[key] = triangle
                }
            }
        }
        return faces
    }

    private static func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)
    }

    private static func bilinear(_ image: RGBAImage, _ u: Float, _ v: Float) -> SIMD3<Float>? {
        guard u >= 0, v >= 0, u < Float(image.width - 1), v < Float(image.height - 1) else { return nil }
        let x0 = Int(floor(u))
        let y0 = Int(floor(v))
        let x1 = min(image.width - 1, x0 + 1)
        let y1 = min(image.height - 1, y0 + 1)
        let tx = u - Float(x0)
        let ty = v - Float(y0)
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let index = (y * image.width + x) * 4
            guard index + 2 < image.rgba.count else { return SIMD3(repeating: 0.7) }
            return SIMD3(Float(image.rgba[index]) / 255, Float(image.rgba[index + 1]) / 255, Float(image.rgba[index + 2]) / 255)
        }
        let row0 = pixel(x0, y0) + (pixel(x1, y0) - pixel(x0, y0)) * tx
        let row1 = pixel(x0, y1) + (pixel(x1, y1) - pixel(x0, y1)) * tx
        return row0 + (row1 - row0) * ty
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.filter { $0 > 1 }.sorted()
        guard !sorted.isEmpty else { return 128 }
        return sorted[sorted.count / 2]
    }

    private static func clampGain(_ value: Float) -> Float {
        min(1.35, max(0.75, value))
    }

    private static func scaled(_ image: RGBAImage, gain: SIMD3<Float>) -> RGBAImage {
        var copy = image
        var index = 0
        while index + 2 < copy.rgba.count {
            copy.rgba[index] = UInt8(min(255, max(0, Float(copy.rgba[index]) * gain.x)).rounded())
            copy.rgba[index + 1] = UInt8(min(255, max(0, Float(copy.rgba[index + 1]) * gain.y)).rounded())
            copy.rgba[index + 2] = UInt8(min(255, max(0, Float(copy.rgba[index + 2]) * gain.z)).rounded())
            index += 4
        }
        return copy
    }
}

struct AtlasImage {
    var width: Int
    var height: Int
    var rgba: [UInt8]
    var covered: [Bool]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        covered = [Bool](repeating: false, count: width * height)
    }

    mutating func set(_ x: Int, _ y: Int, _ color: SIMD3<Float>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let index = y * width + x
        let pixel = index * 4
        rgba[pixel] = UInt8(min(255, max(0, color.x * 255)).rounded())
        rgba[pixel + 1] = UInt8(min(255, max(0, color.y * 255)).rounded())
        rgba[pixel + 2] = UInt8(min(255, max(0, color.z * 255)).rounded())
        rgba[pixel + 3] = 255
        covered[index] = true
    }

    func get(_ x: Int, _ y: Int) -> SIMD3<Float>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = y * width + x
        guard covered[index] else { return nil }
        let pixel = index * 4
        return SIMD3(Float(rgba[pixel]) / 255, Float(rgba[pixel + 1]) / 255, Float(rgba[pixel + 2]) / 255)
    }

    mutating func dilate(passes: Int) {
        for _ in 0..<passes {
            var nextCovered = covered
            var next = rgba
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if covered[index] { continue }
                    var sum = SIMD3<Float>.zero
                    var count: Float = 0
                    for oy in -1...1 {
                        for ox in -1...1 where ox != 0 || oy != 0 {
                            let nx = x + ox
                            let ny = y + oy
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let neighbor = ny * width + nx
                            guard covered[neighbor] else { continue }
                            let pixel = neighbor * 4
                            sum += SIMD3(Float(rgba[pixel]), Float(rgba[pixel + 1]), Float(rgba[pixel + 2]))
                            count += 1
                        }
                    }
                    if count > 0 {
                        let pixel = index * 4
                        next[pixel] = UInt8((sum.x / count).rounded())
                        next[pixel + 1] = UInt8((sum.y / count).rounded())
                        next[pixel + 2] = UInt8((sum.z / count).rounded())
                        next[pixel + 3] = 255
                        nextCovered[index] = true
                    }
                }
            }
            rgba = next
            covered = nextCovered
        }
    }

    mutating func levelSeams(mesh: ScanMesh) {
        guard mesh.triangleCount > 0 else { return }
        var average = [SIMD3<Float>?](repeating: nil, count: mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.uvs.count }) else { continue }
            let uv = (mesh.uvs[ids[0]] + mesh.uvs[ids[1]] + mesh.uvs[ids[2]]) / 3
            average[triangle] = get(Int(uv.x * Float(width - 1)), Int((1 - uv.y) * Float(height - 1)))
        }
        var shift = [SIMD3<Float>](repeating: .zero, count: mesh.triangleCount)
        var edges: [UInt64: Int] = [:]
        for triangle in 0..<mesh.triangleCount {
            for corner in 0..<3 {
                let a = UInt64(mesh.indices[triangle * 3 + corner])
                let b = UInt64(mesh.indices[triangle * 3 + (corner + 1) % 3])
                let key = min(a, b) << 32 | max(a, b)
                if let other = edges[key], let left = average[triangle], let right = average[other] {
                    let delta = (right - left) * 0.25
                    shift[triangle] += delta
                    shift[other] -= delta
                } else {
                    edges[key] = triangle
                }
            }
        }
        for triangle in 0..<mesh.triangleCount where simd_length(shift[triangle]) > 0.004 {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.uvs.count }) else { continue }
            let pixels = ids.map { SIMD2(mesh.uvs[$0].x * Float(width - 1), (1 - mesh.uvs[$0].y) * Float(height - 1)) }
            let minX = max(0, Int(floor(min(pixels[0].x, min(pixels[1].x, pixels[2].x)))))
            let maxX = min(width - 1, Int(ceil(max(pixels[0].x, max(pixels[1].x, pixels[2].x)))))
            let minY = max(0, Int(floor(min(pixels[0].y, min(pixels[1].y, pixels[2].y)))))
            let maxY = min(height - 1, Int(ceil(max(pixels[0].y, max(pixels[1].y, pixels[2].y)))))
            for y in minY...maxY {
                for x in minX...maxX {
                    guard var color = get(x, y) else { continue }
                    color = simd_clamp(color + shift[triangle], .zero, SIMD3(repeating: 1))
                    set(x, y, color)
                }
            }
        }
    }

    func uiImage() -> UIImage? {
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct MeshDepthImage {
    var width: Int
    var height: Int
    var values: [Float]

    static func rasterize(mesh: ScanMesh, frame: StoredKeyframe) -> MeshDepthImage {
        let width = 160
        let height = max(1, width * max(frame.height, 1) / max(frame.width, 1))
        var image = MeshDepthImage(width: width, height: height, values: [Float](repeating: .greatestFiniteMagnitude, count: width * height))
        let scaleX = Float(width) / Float(max(frame.width, 1))
        let scaleY = Float(height) / Float(max(frame.height, 1))
        for triangle in 0..<mesh.triangleCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
            let a = mesh.positions[i0]
            let b = mesh.positions[i1]
            let c = mesh.positions[i2]
            if simd_dot(simd_cross(b - a, c - a), frame.cameraPosition - a) <= 0 { continue }
            guard let p0 = project(a, frame: frame, scaleX: scaleX, scaleY: scaleY),
                  let p1 = project(b, frame: frame, scaleX: scaleX, scaleY: scaleY),
                  let p2 = project(c, frame: frame, scaleX: scaleX, scaleY: scaleY) else { continue }
            image.paint(p0, p1, p2)
        }
        return image
    }

    func occludes(pixel: SIMD2<Float>, depth: Float, frame: StoredKeyframe, slackScale: Float) -> Bool {
        let x = min(width - 1, max(0, Int(pixel.x / Float(max(frame.width, 1)) * Float(width))))
        let y = min(height - 1, max(0, Int(pixel.y / Float(max(frame.height, 1)) * Float(height))))
        let nearest = values[y * width + x]
        guard nearest < 1e8 else { return false }
        let slack = max(0.06, depth * 0.05) * slackScale
        return depth > nearest + slack
    }

    private mutating func paint(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        let minX = max(0, Int(min(a.x, min(b.x, c.x))))
        let maxX = min(width - 1, Int(max(a.x, max(b.x, c.x))))
        let minY = max(0, Int(min(a.y, min(b.y, c.y))))
        let maxY = min(height - 1, Int(max(a.y, max(b.y, c.y))))
        guard minX <= maxX, minY <= maxY else { return }
        if (maxX - minX) + (maxY - minY) <= 1 {
            write(Int((a.x + b.x + c.x) / 3), Int((a.y + b.y + c.y) / 3), min(a.z, min(b.z, c.z)))
            return
        }
        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = (p.x - b.x) * (c.y - b.y) - (p.y - b.y) * (c.x - b.x)
                let w1 = (p.x - c.x) * (a.y - c.y) - (p.y - c.y) * (a.x - c.x)
                let w2 = (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                if !inside { continue }
                let sum = w0 + w1 + w2
                if abs(sum) < 1e-5 { continue }
                write(x, y, (w0 * a.z + w1 * b.z + w2 * c.z) / sum)
            }
        }
    }

    private mutating func write(_ x: Int, _ y: Int, _ depth: Float) {
        guard x >= 0, y >= 0, x < width, y < height, depth > 0.05 else { return }
        let index = y * width + x
        if depth < values[index] { values[index] = depth }
    }

    private static func project(_ world: SIMD3<Float>, frame: StoredKeyframe, scaleX: Float, scaleY: Float) -> SIMD3<Float>? {
        guard let hit = CameraProjection.pixel(world: world, viewMatrix: frame.viewMatrix, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else { return nil }
        guard hit.pixel.x >= 0, hit.pixel.y >= 0, hit.pixel.x < Float(frame.width), hit.pixel.y < Float(frame.height) else { return nil }
        return SIMD3(hit.pixel.x * scaleX, hit.pixel.y * scaleY, hit.depth)
    }
}
