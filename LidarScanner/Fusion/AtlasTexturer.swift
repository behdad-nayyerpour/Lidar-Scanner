import UIKit
import simd

private final class AtlasTick: @unchecked Sendable {
    var onPercent: ((Int) -> Void)?
    var cancelFlag: Int32 = 0
}

private let atlasReport: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { percent, user in
    guard let user else { return }
    Unmanaged<AtlasTick>.fromOpaque(user).takeUnretainedValue().onPercent?(Int(percent))
}

enum AtlasTexturer {
    static func texture(
        mesh source: ScanMesh,
        directory: URL,
        frames allFrames: [StoredKeyframe],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)?,
        reference: ScanMesh? = nil,
        fillTolerance: Float = 0.05
    ) -> (mesh: ScanMesh, image: UIImage)? {
        guard source.triangleCount > 8, !allFrames.isEmpty else { return nil }
        if signal?.isCancelled == true { return nil }
        // One chart per triangle is cheap. The cap only exists so a 300k capture still finishes;
        // gap fill runs after it, or the decimator would open the holes we just closed.
        let faceCap = settings.preset == "hd" ? 120_000 : 80_000
        var prepared = source
        if prepared.triangleCount > faceCap {
            progress?(0.02)
            let started = CFAbsoluteTimeGetCurrent()
            prepared = prepared.simplified(targetTriangles: faceCap)
            Log.scan.info("texture decimate faces=\(prepared.triangleCount, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
            if let reference {
                prepared = MeshCoverage.fillingGaps(fused: prepared, reference: reference, tolerance: fillTolerance)
            }
        }
        // Older archives contain depth-only records. Never select a pose without its own photo.
        let photoFrames = allFrames.filter {
            FileManager.default.fileExists(atPath: KeyframeArchive.colorURL(in: directory, index: $0.index).path)
        }
        guard !photoFrames.isEmpty else { return nil }
        let frames = spreadFrames(photoFrames, limit: settings.preset == "hd" ? 64 : 48)
        progress?(0.08)
        let chosen = bestViewPerFace(mesh: prepared, directory: directory, frames: frames, settings: settings, signal: signal) { fraction in
            progress?(0.08 + 0.42 * fraction)
        }
        progress?(0.52)
        guard let built = photoAtlas(mesh: prepared, directory: directory, frames: frames, chosen: chosen, settings: settings) else {
            return nil
        }
        progress?(0.94)
        var mesh = built.mesh
        paintVertexColors(&mesh, image: built.atlas)
        guard let image = built.atlas.uiImage() else { return nil }
        progress?(1)
        return (mesh, image)
    }

    /// One photo crop per view. Every triangle of that view shares the crop, and the crop is the real photo, not a flat color.
    private static func photoAtlas(
        mesh: ScanMesh,
        directory: URL,
        frames: [StoredKeyframe],
        chosen: [Int],
        settings: FusionSettings
    ) -> (mesh: ScanMesh, atlas: AtlasImage)? {
        let used = Array(Set(chosen.filter { $0 >= 0 })).sorted()
        var colors: [Int: RGBAImage] = [:]
        for index in used {
            guard index < frames.count, let image = KeyframeArchive.loadColor(in: directory, frame: frames[index], maxDimension: 1600) else { continue }
            colors[index] = image
        }
        guard !colors.isEmpty else { return nil }
        var bounds: [Int: Bounds] = [:]
        var projected = [[SIMD2<Float>]](repeating: [], count: mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount {
            let frameIndex = triangle < chosen.count ? chosen[triangle] : -1
            guard frameIndex >= 0, let color = colors[frameIndex], frameIndex < frames.count else { continue }
            let frame = frames[frameIndex]
            let scaleX = Float(color.width) / Float(max(frame.width, 1))
            let scaleY = Float(color.height) / Float(max(frame.height, 1))
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            var pixels: [SIMD2<Float>] = []
            var box = bounds[frameIndex] ?? Bounds()
            var ok = true
            for id in ids {
                guard let hit = CameraProjection.pixel(
                    world: mesh.positions[id],
                    viewMatrix: frame.viewMatrix,
                    fx: frame.fx * scaleX,
                    fy: frame.fy * scaleY,
                    cx: frame.cx * scaleX,
                    cy: frame.cy * scaleY
                ) else { ok = false; break }
                let pixel = SIMD2(min(Float(color.width - 1), max(0, hit.pixel.x)), min(Float(color.height - 1), max(0, hit.pixel.y)))
                pixels.append(pixel)
                box.add(pixel)
            }
            if ok, pixels.count == 3 {
                projected[triangle] = pixels
                bounds[frameIndex] = box
            }
        }
        if colors.count != used.count { return nil }
        let atlasSize = max(256, settings.textureSize)
        let charts = packCharts(bounds, colors: colors, atlas: atlasSize)
        var atlas = AtlasImage(width: atlasSize, height: atlasSize)
        for chart in charts {
            guard let color = colors[chart.frame] else { continue }
            blit(color, into: &atlas, chart: chart)
        }
        var out = ScanMesh()
        out.positions.reserveCapacity(mesh.triangleCount * 3)
        out.normals.reserveCapacity(mesh.triangleCount * 3)
        out.uvs.reserveCapacity(mesh.triangleCount * 3)
        out.indices.reserveCapacity(mesh.triangleCount * 3)
        // Reserve a neutral texel for unseen faces, rather than sampling an unrelated photo.
        atlas.set(0, atlasSize - 1, SIMD3(repeating: 0.72))
        let chartByFrame = Dictionary(uniqueKeysWithValues: charts.map { ($0.frame, $0) })
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.count == 3, ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let frameIndex = triangle < chosen.count ? chosen[triangle] : -1
            let pixels = projected[triangle]
            let chart = chartByFrame[frameIndex]
            let start = UInt32(out.positions.count)
            out.faceClasses.append(triangle < mesh.faceClasses.count ? mesh.faceClasses[triangle] : 0)
            for corner in 0..<3 {
                let index = ids[corner]
                out.positions.append(mesh.positions[index])
                out.normals.append(index < mesh.normals.count ? mesh.normals[index] : .zero)
                if let chart, pixels.count == 3 {
                    let pixel = pixels[corner]
                    let ax = Float(chart.x) + (pixel.x - chart.minU) / chart.spanU * Float(max(chart.width - 1, 1))
                    let ay = Float(chart.y) + (pixel.y - chart.minV) / chart.spanV * Float(max(chart.height - 1, 1))
                    out.uvs.append(SIMD2(ax / Float(atlasSize - 1), 1 - ay / Float(atlasSize - 1)))
                } else {
                    out.uvs.append(.zero)
                }
                out.indices.append(start + UInt32(corner))
            }
        }
        guard out.triangleCount > 0 else { return nil }
        return (out, atlas)
    }

    private struct PhotoChart {
        var frame: Int
        var minU: Float
        var minV: Float
        var spanU: Float
        var spanV: Float
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private struct Bounds {
        var minU = Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude
        var maxU = -Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude
        mutating func add(_ pixel: SIMD2<Float>) {
            minU = min(minU, pixel.x)
            minV = min(minV, pixel.y)
            maxU = max(maxU, pixel.x)
            maxV = max(maxV, pixel.y)
        }
    }

    private struct ChartItem {
        var frame: Int
        var minU: Float
        var minV: Float
        var spanU: Float
        var spanV: Float
    }

    private static func packCharts(_ bounds: [Int: Bounds], colors: [Int: RGBAImage], atlas: Int) -> [PhotoChart] {
        let items: [ChartItem] = bounds.compactMap { frame, box in
            guard let color = colors[frame] else { return nil }
            let minU = max(0, box.minU - 2)
            let minV = max(0, box.minV - 2)
            let maxU = min(Float(color.width - 1), box.maxU + 2)
            let maxV = min(Float(color.height - 1), box.maxV + 2)
            return ChartItem(frame: frame, minU: minU, minV: minV, spanU: max(1, maxU - minU), spanV: max(1, maxV - minV))
        }.sorted { $0.spanU * $0.spanV > $1.spanU * $1.spanV }
        guard !items.isEmpty else { return [] }
        var low: Float = 0.02
        var high: Float = 1
        var best: [PhotoChart] = []
        for _ in 0..<14 {
            let scale = (low + high) / 2
            if let placed = shelf(items, scale: scale, atlas: atlas) {
                best = placed
                low = scale
            } else {
                high = scale
            }
        }
        return best.isEmpty ? (shelf(items, scale: 0.02, atlas: atlas) ?? []) : best
    }

    private static func shelf(_ items: [ChartItem], scale: Float, atlas: Int) -> [PhotoChart]? {
        let gap = 4
        var x = gap
        var y = gap
        var rowHeight = 0
        var placed: [PhotoChart] = []
        for item in items {
            let width = max(2, Int((item.spanU * scale).rounded(.up)))
            let height = max(2, Int((item.spanV * scale).rounded(.up)))
            if x + width + gap > atlas {
                x = gap
                y += rowHeight + gap
                rowHeight = 0
            }
            if y + height + gap > atlas { return nil }
            placed.append(PhotoChart(frame: item.frame, minU: item.minU, minV: item.minV, spanU: item.spanU, spanV: item.spanV, x: x, y: y, width: width, height: height))
            x += width + gap
            rowHeight = max(rowHeight, height)
        }
        return placed
    }

    private static func blit(_ color: RGBAImage, into atlas: inout AtlasImage, chart: PhotoChart) {
        for y in -1...chart.height {
            for x in -1...chart.width {
                let u = chart.minU + Float(min(chart.width - 1, max(0, x))) / Float(max(chart.width - 1, 1)) * chart.spanU
                let v = chart.minV + Float(min(chart.height - 1, max(0, y))) / Float(max(chart.height - 1, 1)) * chart.spanV
                let sample = bilinear(color, min(u, Float(color.width - 1) - 0.01), min(v, Float(color.height - 1) - 0.01))
                    ?? nearestPixel(color, u, v)
                atlas.set(chart.x + x, chart.y + y, sample)
            }
        }
    }

    private static func nearestPixel(_ image: RGBAImage, _ u: Float, _ v: Float) -> SIMD3<Float> {
        let x = min(image.width - 1, max(0, Int(u.rounded())))
        let y = min(image.height - 1, max(0, Int(v.rounded())))
        let index = (y * image.width + x) * 4
        guard index + 2 < image.rgba.count else { return SIMD3(repeating: 0.72) }
        return SIMD3(Float(image.rgba[index]) / 255, Float(image.rgba[index + 1]) / 255, Float(image.rgba[index + 2]) / 255)
    }

    /// Keeps frames that actually see different parts of the room, not the sharpest duplicates.
    private static func spreadFrames(_ frames: [StoredKeyframe], limit: Int) -> [StoredKeyframe] {
        let ranked = frames.sorted { $0.blur > $1.blur }
        var kept: [StoredKeyframe] = []
        for frame in ranked {
            if kept.count >= limit { break }
            let far = kept.allSatisfy { existing in
                simd_distance(existing.cameraPosition, frame.cameraPosition) > 0.35
                    || angleBetween(existing, frame) > 0.45
            }
            if kept.isEmpty || far { kept.append(frame) }
        }
        if kept.count < min(12, frames.count) {
            return Array(ranked.prefix(min(limit, frames.count)))
        }
        return kept
    }

    private static func angleBetween(_ a: StoredKeyframe, _ b: StoredKeyframe) -> Float {
        let forwardA = SIMD3<Float>(-a.cameraToWorld.columns.2.x, -a.cameraToWorld.columns.2.y, -a.cameraToWorld.columns.2.z)
        let forwardB = SIMD3<Float>(-b.cameraToWorld.columns.2.x, -b.cameraToWorld.columns.2.y, -b.cameraToWorld.columns.2.z)
        let length = simd_length(forwardA) * simd_length(forwardB)
        guard length > 1e-4 else { return 0 }
        return acos(min(1, max(-1, simd_dot(forwardA, forwardB) / length)))
    }

    /// Each face keeps the one photo that sees it best. No chart voting, so a wall cannot inherit the floor's picture.
    private static func bestViewPerFace(
        mesh: ScanMesh,
        directory: URL,
        frames: [StoredKeyframe],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)?
    ) -> [Int] {
        let depths: [DepthImage?] = frames.map { frame in
            guard let loaded = try? KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: directory, index: frame.index)) else {
                return nil
            }
            return loaded.0
        }
        var chosen = [Int](repeating: -1, count: mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount {
            if triangle & 255 == 0 {
                if signal?.isCancelled == true { break }
                progress?(Double(triangle) / Double(max(mesh.triangleCount, 1)))
            }
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let points = ids.map { mesh.positions[$0] }
            let centroid = (points[0] + points[1] + points[2]) / 3
            let stored = ids.reduce(SIMD3<Float>.zero) { partial, index in
                partial + (index < mesh.normals.count ? mesh.normals[index] : .zero)
            }
            let geometric = faceNormal(points)
            let normal = simd_length(stored) > 0.5 ? simd_normalize(stored) : geometric
            chosen[triangle] = pickView(points: points, centroid: centroid, normal: normal, frames: frames, depths: depths, settings: settings, relaxed: false)
                ?? pickView(points: points, centroid: centroid, normal: normal, frames: frames, depths: depths, settings: settings, relaxed: true)
                ?? pickView(points: points, centroid: centroid, normal: -normal, frames: frames, depths: depths, settings: settings, relaxed: true)
                ?? -1
        }
        return chosen
    }

    private static func pickView(
        points: [SIMD3<Float>],
        centroid: SIMD3<Float>,
        normal: SIMD3<Float>,
        frames: [StoredKeyframe],
        depths: [DepthImage?],
        settings: FusionSettings,
        relaxed: Bool
    ) -> Int? {
        var best: Int?
        var bestScore: Float = 0
        for (frameIndex, frame) in frames.enumerated() {
            let depth = frameIndex < depths.count ? depths[frameIndex] : nil
            guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, lidar: depth, settings: settings, relaxed: relaxed) else { continue }
            if score > bestScore {
                bestScore = score
                best = frameIndex
            }
        }
        return best
    }

    /// One photo per 35 cm patch. Scoring patches, not every face against every frame, is what keeps a room build under a minute.
    private static func chooseViews(
        mesh: ScanMesh,
        frames: [StoredKeyframe],
        settings: FusionSettings,
        signal: WorkSignal?,
        progress: ((Double) -> Void)?
    ) -> [Int] {
        var chosen = [Int](repeating: -1, count: mesh.triangleCount)
        var maps: [DepthImage?] = []
        maps.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            if signal?.isCancelled == true { return chosen }
            maps.append(FaceVisibility.depthMap(mesh: mesh, frame: frame))
            progress?(0.35 * Double(index + 1) / Double(max(frames.count, 1)))
        }
        let cell: Float = 0.35
        var groups: [SIMD3<Int32>: [Int]] = [:]
        for triangle in 0..<mesh.triangleCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }
            let center = (mesh.positions[i0] + mesh.positions[i1] + mesh.positions[i2]) / 3
            let key = SIMD3<Int32>(Int32(floor(center.x / cell)), Int32(floor(center.y / cell)), Int32(floor(center.z / cell)))
            groups[key, default: []].append(triangle)
        }
        let keys = Array(groups.keys)
        for (offset, key) in keys.enumerated() {
            if offset & 31 == 0 {
                if signal?.isCancelled == true { break }
                progress?(Double(offset) / Double(max(keys.count, 1)))
            }
            guard let triangles = groups[key], let triangle = triangles.first else { continue }
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            let points = [mesh.positions[i0], mesh.positions[i1], mesh.positions[i2]]
            let normal = triangle < mesh.normals.count ? mesh.normals[i0] : SIMD3<Float>(0, 1, 0)
            let centroid = (points[0] + points[1] + points[2]) / 3
            var best = -1
            var bestScore: Float = 0
            for (frameIndex, frame) in frames.enumerated() {
                if frameIndex < maps.count, let map = maps[frameIndex], hidden(centroid, frame: frame, map: map) { continue }
                guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, lidar: nil, settings: settings, relaxed: false) else { continue }
                if score > bestScore {
                    bestScore = score
                    best = frameIndex
                }
            }
            if best < 0 {
                for (frameIndex, frame) in frames.enumerated() {
                    guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, lidar: nil, settings: settings, relaxed: true) else { continue }
                    if score > bestScore {
                        bestScore = score
                        best = frameIndex
                    }
                }
            }
            for item in triangles { chosen[item] = best }
        }
        return chosen
    }

    private static func hidden(_ point: SIMD3<Float>, frame: StoredKeyframe, map: DepthImage) -> Bool {
        let scaleX = Float(map.width) / Float(max(frame.width, 1))
        let scaleY = Float(map.height) / Float(max(frame.height, 1))
        guard let hit = CameraProjection.pixel(
            world: point,
            viewMatrix: frame.viewMatrix,
            fx: frame.fx * scaleX,
            fy: frame.fy * scaleY,
            cx: frame.cx * scaleX,
            cy: frame.cy * scaleY
        ) else { return true }
        let x = min(map.width - 1, max(0, Int(hit.pixel.x)))
        let y = min(map.height - 1, max(0, Int(hit.pixel.y)))
        let nearest = map.values[y * map.width + x]
        guard nearest > 0.05 else { return false }
        return hit.depth > nearest + max(0.08, hit.depth * 0.08)
    }

    private static func decimatedFrames(_ frames: [StoredKeyframe], limit: Int) -> [StoredKeyframe] {
        guard frames.count > limit else { return frames }
        let sorted = frames.sorted { $0.blur > $1.blur }
        let kept = sorted.prefix(limit)
        return frames.filter { frame in kept.contains(where: { $0.index == frame.index }) }
    }

    private static func unwrap(_ mesh: ScanMesh, resolution: Int, signal: WorkSignal?, progress: ((Double) -> Void)?) -> ScanMesh {
        var packed: [Float] = []
        packed.reserveCapacity(mesh.positions.count * 3)
        for position in mesh.positions {
            packed.append(position.x)
            packed.append(position.y)
            packed.append(position.z)
        }
        let tick = AtlasTick()
        tick.onPercent = { percent in
            if signal?.isCancelled == true { tick.cancelFlag = 1 }
            progress?(Double(percent) / 100)
        }
        var native = NMMesh()
        let context = Unmanaged.passUnretained(tick).toOpaque()
        let code: Int32 = packed.withUnsafeBufferPointer { positions in
            mesh.indices.withUnsafeBufferPointer { indices in
                NMBuildAtlas(positions.baseAddress, UInt32(mesh.positions.count), indices.baseAddress, UInt32(mesh.indices.count), Int32(resolution), &tick.cancelFlag, atlasReport, context, &native)
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

    /// One non-overlapping chart per triangle. UV v = 1 is the top of the atlas, matching SceneKit and the paint path.
    private static func gridUnwrap(_ mesh: ScanMesh) -> ScanMesh {
        let grid = max(1, Int(ceil(sqrt(Double(mesh.triangleCount)))))
        var result = ScanMesh()
        result.positions.reserveCapacity(mesh.triangleCount * 3)
        result.normals.reserveCapacity(mesh.triangleCount * 3)
        result.uvs.reserveCapacity(mesh.triangleCount * 3)
        result.indices.reserveCapacity(mesh.triangleCount * 3)
        for triangle in 0..<mesh.triangleCount {
            let column = triangle % grid
            let row = triangle / grid
            // Gutter is wide enough that a 1px dilate cannot bleed into the next chart, even at 80k faces.
            let inset: Float = 0.22
            let top = 1 - (Float(row) + inset) / Float(grid)
            let bottom = 1 - (Float(row + 1) - inset) / Float(grid)
            let corners = [
                SIMD2((Float(column) + inset) / Float(grid), bottom),
                SIMD2((Float(column + 1) - inset) / Float(grid), bottom),
                SIMD2((Float(column) + 0.5) / Float(grid), top)
            ]
            let start = UInt32(result.positions.count)
            for corner in 0..<3 {
                let index = Int(mesh.indices[triangle * 3 + corner])
                let position = index < mesh.positions.count ? mesh.positions[index] : .zero
                let normal = index < mesh.normals.count ? mesh.normals[index] : SIMD3<Float>.zero
                result.positions.append(position)
                result.normals.append(normal)
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
                guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, lidar: nil, settings: settings, relaxed: false) else { continue }
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
                    guard let score = scoreFace(points: points, centroid: centroid, normal: normal, frame: frame, lidar: nil, settings: settings, relaxed: true) else { continue }
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
        lidar: DepthImage?,
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
        let length = simd_length(normal)
        guard length > 1e-4 else { return nil }
        let facing = simd_dot(normal / length, toward / distance)
        let minimumFacing: Float = relaxed ? 0.05 : 0.2
        guard facing > minimumFacing else { return nil }
        if lidarOccludes(pixel: centerPixel, depth: depth, frame: frame, lidar: lidar, relaxed: relaxed) { return nil }
        var area: Float = 0
        var projected: [SIMD2<Float>] = []
        for point in points {
            guard let hit = CameraProjection.pixel(world: point, viewMatrix: frame.viewMatrix, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else { return nil }
            guard hit.pixel.x >= 1, hit.pixel.y >= 1,
                  hit.pixel.x < Float(frame.width - 1), hit.pixel.y < Float(frame.height - 1) else { return nil }
            if lidarOccludes(pixel: hit.pixel, depth: hit.depth, frame: frame, lidar: lidar, relaxed: relaxed) { return nil }
            projected.append(hit.pixel)
        }
        if projected.count == 3 {
            area = abs((projected[1].x - projected[0].x) * (projected[2].y - projected[0].y) - (projected[2].x - projected[0].x) * (projected[1].y - projected[0].y)) * 0.5
        }
        guard area > 0.15 else { return nil }
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
        image.dilate(passes: 1)
        return image
    }

    /// LiDAR depth is in the same landscape frame as the photo. Reject a view only when something is clearly in front.
    private static func lidarOccludes(pixel: SIMD2<Float>, depth: Float, frame: StoredKeyframe, lidar: DepthImage?, relaxed: Bool) -> Bool {
        guard let lidar, lidar.width > 1, lidar.height > 1, frame.width > 1, frame.height > 1 else { return false }
        let x = min(lidar.width - 1, max(0, Int(pixel.x * Float(lidar.width) / Float(frame.width))))
        let y = min(lidar.height - 1, max(0, Int(pixel.y * Float(lidar.height) / Float(frame.height))))
        let nearest = lidar.values[y * lidar.width + x]
        guard nearest.isFinite, nearest > 0.05 else { return true }
        let slack = max(relaxed ? 0.10 : 0.05, depth * (relaxed ? 0.04 : 0.025))
        // Agreement must be symmetric: a foreground face must not borrow a background photo either.
        return abs(depth - nearest) > slack
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
        let centroid = (world[0] + world[1] + world[2]) / 3
        guard let projected = CameraProjection.pixel(
            world: centroid,
            viewMatrix: frame.viewMatrix,
            fx: frame.fx * scaleX,
            fy: frame.fy * scaleY,
            cx: frame.cx * scaleX,
            cy: frame.cy * scaleY
        ), let sample = bilinear(color, projected.pixel.x, projected.pixel.y) else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(pixels[1], pixels[2], p)
                let w1 = edge(pixels[2], pixels[0], p)
                let w2 = edge(pixels[0], pixels[1], p)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                if inside { image.set(x, y, sample) }
            }
        }
    }

    /// Faces no photo could see take the color of the nearest similarly facing face, so the atlas has no white holes.
    private static func fillUncovered(mesh: ScanMesh, image: AtlasImage, chosen: [Int]) -> AtlasImage {
        var image = image
        struct Painted {
            var center: SIMD3<Float>
            var normal: SIMD3<Float>
            var color: SIMD3<Float>
        }
        var painted: [Painted] = []
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        let cell: Float = 0.35
        for triangle in 0..<mesh.triangleCount where triangle < chosen.count && chosen[triangle] >= 0 {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.uvs.count }) else { continue }
            let uv = (mesh.uvs[ids[0]] + mesh.uvs[ids[1]] + mesh.uvs[ids[2]]) / 3
            guard let color = image.sample(uv) else { continue }
            let center = (mesh.positions[ids[0]] + mesh.positions[ids[1]] + mesh.positions[ids[2]]) / 3
            let normal = faceNormal(ids.map { mesh.positions[$0] })
            let key = SIMD3<Int32>(Int32(floor(center.x / cell)), Int32(floor(center.y / cell)), Int32(floor(center.z / cell)))
            buckets[key, default: []].append(painted.count)
            painted.append(Painted(center: center, normal: normal, color: color))
        }
        guard !painted.isEmpty else { return image }
        for triangle in 0..<mesh.triangleCount where triangle >= chosen.count || chosen[triangle] < 0 {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count && $0 < mesh.uvs.count }) else { continue }
            let center = (mesh.positions[ids[0]] + mesh.positions[ids[1]] + mesh.positions[ids[2]]) / 3
            let normal = faceNormal(ids.map { mesh.positions[$0] })
            let origin = SIMD3<Int32>(Int32(floor(center.x / cell)), Int32(floor(center.y / cell)), Int32(floor(center.z / cell)))
            var best: SIMD3<Float>?
            var bestDistance = Float.greatestFiniteMagnitude
            for z in -1...1 {
                for y in -1...1 {
                    for x in -1...1 {
                        guard let hits = buckets[SIMD3(origin.x + Int32(x), origin.y + Int32(y), origin.z + Int32(z))] else { continue }
                        for hit in hits {
                            let candidate = painted[hit]
                            guard simd_dot(candidate.normal, normal) > 0.7 else { continue }
                            let distance = simd_distance(candidate.center, center)
                            if distance < bestDistance {
                                bestDistance = distance
                                best = candidate.color
                            }
                        }
                    }
                }
            }
            guard let color = best, bestDistance < 0.45 else { continue }
            let pixels = ids.map { SIMD2(mesh.uvs[$0].x * Float(image.width - 1), (1 - mesh.uvs[$0].y) * Float(image.height - 1)) }
            paintSolid(&image, pixels: pixels, color: color)
        }
        return image
    }

    private static func paintSolid(_ image: inout AtlasImage, pixels: [SIMD2<Float>], color: SIMD3<Float>) {
        guard pixels.count == 3 else { return }
        let minX = max(0, Int(floor(min(pixels[0].x, min(pixels[1].x, pixels[2].x)))))
        let maxX = min(image.width - 1, Int(ceil(max(pixels[0].x, max(pixels[1].x, pixels[2].x)))))
        let minY = max(0, Int(floor(min(pixels[0].y, min(pixels[1].y, pixels[2].y)))))
        let maxY = min(image.height - 1, Int(ceil(max(pixels[0].y, max(pixels[1].y, pixels[2].y)))))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY {
            for x in minX...maxX where image.get(x, y) == nil {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(pixels[1], pixels[2], p)
                let w1 = edge(pixels[2], pixels[0], p)
                let w2 = edge(pixels[0], pixels[1], p)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                if inside { image.set(x, y, color) }
            }
        }
    }

    private static func paintVertexColors(_ mesh: inout ScanMesh, image: AtlasImage) {
        mesh.colors = Array(repeating: SIMD3(repeating: 0.72), count: mesh.positions.count)
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.uvs.count && $0 < mesh.colors.count }) else { continue }
            let uv = (mesh.uvs[ids[0]] + mesh.uvs[ids[1]] + mesh.uvs[ids[2]]) / 3
            guard let sample = image.sample(uv) ?? image.sampleNearby(uv) else { continue }
            for id in ids { mesh.colors[id] = sample }
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

    /// `uv.y == 1` is the top row of this image. SceneKit uses the same origin.
    func sample(_ uv: SIMD2<Float>) -> SIMD3<Float>? {
        let x = Int((uv.x * Float(width - 1)).rounded())
        let y = Int(((1 - uv.y) * Float(height - 1)).rounded())
        return get(x, y)
    }

    func sampleNearby(_ uv: SIMD2<Float>) -> SIMD3<Float>? {
        let x = Int((uv.x * Float(width - 1)).rounded())
        let y = Int(((1 - uv.y) * Float(height - 1)).rounded())
        for radius in 1...3 {
            for oy in -radius...radius {
                for ox in -radius...radius {
                    if let color = get(x + ox, y + oy) { return color }
                }
            }
        }
        return nil
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
