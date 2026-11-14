import XCTest
import SceneKit
import Metal
@testable import LidarScanner

/// An oblique plane deliberately uses only two large triangles. Flat face colors and affine photo
/// UVs cannot pass the interior probes. The same baked result is tested through persistence and GPU rendering.
final class SurfaceBakingTests: XCTestCase {
    private func fixture(occludedStripe: Bool = false) throws -> (URL, ScanMesh, StoredKeyframe) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let size = 128
        var photo = AtlasImage(width: size, height: size)
        var depth = [Float]()
        for y in 0..<size {
            for x in 0..<size {
                photo.set(x, y, SIMD3((Float(x) + 0.5) / 128, (Float(y) + 0.5) / 128, (x / 16 + y / 16) % 2 == 0 ? 0.2 : 0.8))
                let rayX = (Float(x) + 0.5 - 64) / 70
                let d: Float = occludedStripe && (60...68).contains(x) ? 0.5 : 1.5 / (1 - rayX * (5 / Float(9)))
                depth.append(d)
            }
        }
        let image = try XCTUnwrap(photo.uiImage())
        let colorURL = KeyframeArchive.colorURL(in: directory, index: 1)
        try FileManager.default.createDirectory(at: colorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: colorURL)
        try KeyframeArchive.writeDepth(DepthImage(values: depth, width: size, height: size),
                                       confidence: Array(repeating: 2, count: size * size),
                                       to: KeyframeArchive.depthURL(in: directory, index: 1))
        let identity = StoredKeyframe.pack(matrix_identity_float4x4)
        let frame = StoredKeyframe(index: 1, timestamp: 1, width: size, height: size, depthWidth: size, depthHeight: size,
                                   fx: 70, fy: 70, cx: 64, cy: 64, view: identity, transform: identity, camera: [0, 0, 0],
                                   meanRed: 128, meanGreen: 128, meanBlue: 128, blur: 100)
        var mesh = ScanMesh()
        mesh.positions = [SIMD3(-0.9, -0.6, -1), SIMD3(0.9, -0.6, -2), SIMD3(0.9, 0.6, -2), SIMD3(-0.9, 0.6, -1)]
        mesh.indices = [0, 1, 2, 0, 2, 3]
        mesh.recomputeNormals()
        return (directory, mesh, frame)
    }

    private func bake(_ fixture: (URL, ScanMesh, StoredKeyframe)) throws -> SurfaceBakeResult {
        var settings = FusionSettings.fast
        settings.textureSize = 512
        return try XCTUnwrap(AtlasTexturer.texture(mesh: fixture.1, directory: fixture.0, frames: [fixture.2],
                                                  settings: settings, signal: nil, progress: nil))
    }

    func testPerspectiveCorrectTextureVariesInsideLargeTriangles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.0) }
        let result = try bake(f)
        for p in [SIMD3<Float>(-0.6, 0.2, -7 / 6), SIMD3<Float>(0.4, -0.2, -31 / 18), SIMD3<Float>(0, 0.3, -1.5)] {
            let hit = try XCTUnwrap(CameraProjection.pixel(world: p, viewMatrix: matrix_identity_float4x4, fx: 70, fy: 70, cx: 64, cy: 64))
            let color = try pixel(result.image, uv: uv(at: p, mesh: result.mesh))
            XCTAssertEqual(color.x, hit.pixel.x / 128, accuracy: 0.035)
            XCTAssertEqual(color.y, hit.pixel.y / 128, accuracy: 0.035)
        }
        XCTAssertGreaterThan(result.coverage, 0.9)
    }

    func testOccludedPixelsStayNeutralInsteadOfBorrowingBackgroundPhoto() throws {
        let f = try fixture(occludedStripe: true)
        defer { try? FileManager.default.removeItem(at: f.0) }
        let result = try bake(f)
        let color = try pixel(result.image, uv: uv(at: SIMD3(0, 0, -1.5), mesh: result.mesh))
        XCTAssertLessThan(simd_distance(color, SIMD3(repeating: 0.72)), 0.03)
        XCTAssertLessThan(result.coverage, 0.99)
        XCTAssertGreaterThan(result.coverage, 0.5)
    }

    func testMeshVisibilityDepthIsPerspectiveCorrectOnObliqueTriangles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.0) }
        let map = try XCTUnwrap(FaceVisibility.depthMap(mesh: f.1, frame: f.2, width: 128))
        for x in [32, 64, 88] {
            let rayX = (Float(x) + 0.5 - 64) / 70
            let expected = 1.5 / (1 - rayX * (5 / Float(9)))
            XCTAssertEqual(map.values[64 * 128 + x], expected, accuracy: 0.01)
        }
    }

    func testSingleAssetBindsUVsAndLosslessPixelsAndRejectsCorruption() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.0) }
        let result = try bake(f)
        let data = try SurfaceAsset.encode(mesh: result.mesh, image: result.image)
        let restored = try SurfaceAsset.decode(data)
        XCTAssertEqual(restored.mesh.positions, result.mesh.positions)
        XCTAssertEqual(restored.mesh.indices, result.mesh.indices)
        XCTAssertEqual(restored.mesh.uvs, result.mesh.uvs)
        let p = SIMD3<Float>(-0.4, 0.2, -23 / 18)
        let original = try pixel(result.image, uv: uv(at: p, mesh: result.mesh))
        let decoded = try pixel(XCTUnwrap(restored.texture), uv: uv(at: p, mesh: restored.mesh))
        XCTAssertLessThan(simd_distance(original, decoded), 0.001)
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        payload["image"] = Data([0, 1, 2])
        let broken = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        XCTAssertThrowsError(try SurfaceAsset.decode(broken))
    }

    @MainActor
    func testBakedSavedSurfaceRendersAtOriginalCameraPixels() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.0) }
        let baked = try bake(f)
        let restored = try SurfaceAsset.decode(SurfaceAsset.encode(mesh: baked.mesh, image: baked.image))
        let viewer = ViewerModel()
        viewer.show(mesh: restored.mesh, colored: true, texture: restored.texture)
        let scene = try XCTUnwrap(viewer.sceneView.scene)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = CGFloat(2 * atan(128 / Float(140)) * 180 / .pi)
        camera.camera?.projectionDirection = .vertical
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128), antialiasingMode: .none)
        let attachment = XCTAttachment(image: image)
        attachment.name = "World-space bake after package reload in app viewer"
        attachment.lifetime = .keepAlways
        add(attachment)
        for (x, y) in [(32, 64), (64, 52), (88, 64)] {
            let color = try pixel(image, uv: SIMD2((Float(x) + 0.5) / 128, 1 - (Float(y) + 0.5) / 128))
            XCTAssertEqual(color.x, (Float(x) + 0.5) / 128, accuracy: 0.06)
            XCTAssertEqual(color.y, (Float(y) + 0.5) / 128, accuracy: 0.06)
        }
    }

    private func uv(at p: SIMD3<Float>, mesh: ScanMesh) throws -> SIMD2<Float> {
        for face in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[face * 3 + $0]) }
            let a = mesh.positions[ids[0]], b = mesh.positions[ids[1]], c = mesh.positions[ids[2]]
            let v0 = b - a, v1 = c - a, v2 = p - a
            let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1)
            let denom = d00 * d11 - d01 * d01
            let u = (d11 * simd_dot(v2, v0) - d01 * simd_dot(v2, v1)) / denom
            let v = (d00 * simd_dot(v2, v1) - d01 * simd_dot(v2, v0)) / denom
            if u >= 0, v >= 0, u + v <= 1 {
                return mesh.uvs[ids[0]] + u * (mesh.uvs[ids[1]] - mesh.uvs[ids[0]]) + v * (mesh.uvs[ids[2]] - mesh.uvs[ids[0]])
            }
        }
        throw ScanError.unreadableMesh
    }

    private func pixel(_ image: UIImage, uv: SIMD2<Float>) throws -> SIMD3<Float> {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let x = min(cg.width - 1, max(0, Int(uv.x * Float(cg.width))))
        let y = min(cg.height - 1, max(0, Int((1 - uv.y) * Float(cg.height))))
        let i = (y * cg.width + x) * 4
        return SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
    }
}
