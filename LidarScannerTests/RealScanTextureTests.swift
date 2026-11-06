import XCTest
import simd
@testable import LidarScanner

/// A few frames from a real phone scan. Baking must sample the photos, not paint one flat color per triangle.
final class RealScanTextureTests: XCTestCase {
    func testDepthOnlyPoseCannotStealPhotoSelection() throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("RealScan")
        let frames = try KeyframeArchive.readManifest(in: folder)
        let frame = try XCTUnwrap(frames.first)
        let depth = try KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: folder, index: frame.index)).0
        let mesh = depthMesh(depth: depth, frame: frame, step: 8)
        var phantom = frame
        phantom.index = 999999
        phantom.blur = 1_000_000
        var settings = FusionSettings.fast
        settings.textureSize = 512
        settings.maxRange = 8
        let baseline = try XCTUnwrap(AtlasTexturer.texture(mesh: mesh, directory: folder, frames: [frame], settings: settings, signal: nil, progress: nil))
        let actual = try XCTUnwrap(AtlasTexturer.texture(mesh: mesh, directory: folder, frames: [phantom, frame], settings: settings, signal: nil, progress: nil))
        XCTAssertEqual(actual.mesh.uvs, baseline.mesh.uvs)
        XCTAssertEqual(actual.image.pngData(), baseline.image.pngData())
        XCTAssertNil(AtlasTexturer.texture(mesh: mesh, directory: folder, frames: [phantom], settings: settings, signal: nil, progress: nil))
    }

    func testLegacyRepeatedIndicesUseTheLastWritersPose() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("RealScan")
        var original = try XCTUnwrap(KeyframeArchive.readManifest(in: fixture).first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = original
        original.timestamp += 1
        original.view[12] += 0.5
        try KeyframeArchive.writeManifest([old, original], to: folder)
        XCTAssertEqual(try KeyframeArchive.readManifest(in: folder), [original])
    }

    func testRealFramesStayPhotoConsistent() throws {
        let bundle = Bundle(for: RealScanTextureTests.self)
        let candidates = [
            bundle.url(forResource: "RealScan", withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("RealScan"),
            bundle.bundleURL.appendingPathComponent("RealScan")
        ]
        guard let folder = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }) else {
            XCTFail("Real scan fixture is missing")
            return
        }
        let frames = try KeyframeArchive.readManifest(in: folder)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let frame = frames[0]
        let loaded = try KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: folder, index: frame.index))
        let mesh = depthMesh(depth: loaded.0, frame: frame, step: 4)
        XCTAssertGreaterThan(mesh.triangleCount, 200)
        var settings = FusionSettings.fast
        settings.textureSize = 1024
        settings.maxRange = 8
        guard let textured = AtlasTexturer.texture(
            mesh: mesh,
            directory: folder,
            frames: frames,
            settings: settings,
            signal: nil,
            progress: nil
        ) else {
            XCTFail("Texturing returned nothing")
            return
        }
        var photos: [(StoredKeyframe, RGBAImage)] = []
        for candidate in frames {
            if let image = KeyframeArchive.loadColor(in: folder, frame: candidate, maxDimension: 1600) {
                photos.append((candidate, image))
            }
        }
        XCTAssertFalse(photos.isEmpty)
        guard let atlas = atlasPixels(textured.image) else {
            XCTFail("Atlas image has no pixels")
            return
        }
        var checked = 0
        var matched = 0
        let result = textured.mesh
        let strideStep = max(1, result.triangleCount / 200)
        var triangle = 0
        while triangle < result.triangleCount {
            let ids = (0..<3).map { Int(result.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < result.positions.count && $0 < result.uvs.count }) else {
                triangle += strideStep
                continue
            }
            for id in ids {
                guard let texel = atlas.pixel(result.uvs[id]) else { continue }
                var best = Float.greatestFiniteMagnitude
                for (candidate, image) in photos {
                    let scaleX = Float(image.width) / Float(max(candidate.width, 1))
                    let scaleY = Float(image.height) / Float(max(candidate.height, 1))
                    guard let hit = CameraProjection.pixel(
                        world: result.positions[id],
                        viewMatrix: candidate.viewMatrix,
                        fx: candidate.fx * scaleX,
                        fy: candidate.fy * scaleY,
                        cx: candidate.cx * scaleX,
                        cy: candidate.cy * scaleY
                    ), hit.pixel.x >= 1, hit.pixel.y >= 1, hit.pixel.x < Float(image.width - 1), hit.pixel.y < Float(image.height - 1) else { continue }
                    let x = Int(hit.pixel.x)
                    let y = Int(hit.pixel.y)
                    let pixel = (y * image.width + x) * 4
                    guard pixel + 2 < image.rgba.count else { continue }
                    let photo = SIMD3(Float(image.rgba[pixel]) / 255, Float(image.rgba[pixel + 1]) / 255, Float(image.rgba[pixel + 2]) / 255)
                    best = min(best, simd_distance(texel, photo))
                }
                if best < 100 {
                    checked += 1
                    if best < 0.2 { matched += 1 }
                }
            }
            triangle += strideStep
        }
        XCTAssertGreaterThan(checked, 80)
        XCTAssertGreaterThan(Float(matched) / Float(checked), 0.8, "\(matched) of \(checked) atlas texels matched a real photo")
    }

    private func atlasPixels(_ image: UIImage) -> (rgba: [UInt8], width: Int, height: Int, pixel: (SIMD2<Float>) -> SIMD3<Float>?)? {
        guard let cgImage = image.cgImage, let provider = cgImage.dataProvider?.data else { return nil }
        let data = provider as Data
        let width = cgImage.width
        let height = cgImage.height
        let rowBytes = cgImage.bytesPerRow
        guard data.count >= rowBytes * height else { return nil }
        let rgba = [UInt8](data)
        return (rgba, width, height, { uv in
            let x = min(width - 1, max(0, Int((uv.x * Float(width - 1)).rounded())))
            let y = min(height - 1, max(0, Int(((1 - uv.y) * Float(height - 1)).rounded())))
            let pixel = y * rowBytes + x * 4
            guard pixel + 2 < rgba.count else { return nil }
            return SIMD3(Float(rgba[pixel]) / 255, Float(rgba[pixel + 1]) / 255, Float(rgba[pixel + 2]) / 255)
        })
    }

    /// Depth row 0 is image v = 0. The normal faces the camera that measured it.
    private func depthMesh(depth: DepthImage, frame: StoredKeyframe, step: Int) -> ScanMesh {
        var mesh = ScanMesh()
        let width = depth.width
        let height = depth.height
        let camera = frame.cameraPosition
        let columns = (width + step - 1) / step
        let rows = (height + step - 1) / step
        func position(_ column: Int, _ row: Int) -> SIMD3<Float>? {
            let x = min(width - 1, column * step)
            let y = min(height - 1, row * step)
            let z = depth.values[y * width + x]
            guard z > 0.2, z < 8 else { return nil }
            let fx = frame.fx * Float(width) / Float(frame.width)
            let fy = frame.fy * Float(height) / Float(frame.height)
            let cx = frame.cx * Float(width) / Float(frame.width)
            let cy = frame.cy * Float(height) / Float(frame.height)
            return CameraProjection.worldPoint(u: Float(x) + 0.5, v: Float(y) + 0.5, depth: z, fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: frame.cameraToWorld)
        }
        var ids = Array(repeating: -1, count: columns * rows)
        func add(_ column: Int, _ row: Int) -> Int {
            let slot = row * columns + column
            if ids[slot] >= 0 { return ids[slot] }
            guard let point = position(column, row) else { return -1 }
            ids[slot] = mesh.positions.count
            mesh.positions.append(point)
            mesh.normals.append(SIMD3(0, 1, 0))
            return ids[slot]
        }
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = add(column, row)
                let b = add(column + 1, row)
                let c = add(column + 1, row + 1)
                let d = add(column, row + 1)
                guard a >= 0, b >= 0, c >= 0, d >= 0 else { continue }
                let zs = [mesh.positions[a], mesh.positions[b], mesh.positions[c], mesh.positions[d]].map { simd_distance($0, camera) }
                guard zs.max()! - zs.min()! < 0.15 else { continue }
                var first = (a, b, c)
                var second = (a, c, d)
                let normal = simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
                if simd_dot(normal, camera - mesh.positions[a]) < 0 {
                    first = (a, c, b)
                    second = (a, d, c)
                }
                mesh.indices.append(contentsOf: [UInt32(first.0), UInt32(first.1), UInt32(first.2), UInt32(second.0), UInt32(second.1), UInt32(second.2)])
            }
        }
        mesh.recomputeNormals()
        for index in mesh.normals.indices where index < mesh.positions.count {
            if simd_dot(mesh.normals[index], camera - mesh.positions[index]) < 0 {
                mesh.normals[index] = -mesh.normals[index]
            }
        }
        return mesh
    }
}
