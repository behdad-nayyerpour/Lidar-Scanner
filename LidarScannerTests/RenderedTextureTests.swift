import XCTest
import SceneKit
import Metal
import UIKit
@testable import LidarScanner

final class RenderedTextureTests: XCTestCase {
    @MainActor
    func testSceneKitDisplaysStoredAtlasInTheCorrectQuadrants() throws {
        let mesh = quad()
        let atlas = image()
        try check(render(geometry: XCTUnwrap(mesh.texturedGeometry(image: atlas))), name: "Direct atlas")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let textureURL = folder.appendingPathComponent("texture.jpg")
        try XCTUnwrap(atlas.jpegData(compressionQuality: 0.86)).write(to: textureURL)
        let stored = try XCTUnwrap(UIImage(contentsOfFile: textureURL.path))
        try check(render(geometry: XCTUnwrap(mesh.texturedGeometry(image: stored))), name: "Stored JPEG atlas")

        let viewer = ViewerModel()
        viewer.show(mesh: mesh, colored: true, texture: stored)
        try check(render(scene: XCTUnwrap(viewer.sceneView.scene)), name: "App viewer atlas")

        let usdz = folder.appendingPathComponent("model.usdz")
        try MeshExporter.usdzTextured(mesh: mesh, image: stored, to: usdz)
        try check(render(scene: SCNScene(url: usdz)), name: "USDZ round trip atlas")
    }

    func testLegacyBakedAtlasUsesTheSameSceneKitConversion() throws {
        let mesh = quad()
        let cg = try XCTUnwrap(image().cgImage)
        let pixels = try XCTUnwrap(cg.dataProvider?.data) as Data
        let baked = BakedTexture(positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs,
                                indices: mesh.indices, rgba: [UInt8](pixels), size: 64)
        let geometry = try XCTUnwrap(baked.makeTexturedGeometry())
        geometry.firstMaterial?.lightingModel = .constant
        try check(render(geometry: geometry), name: "Legacy color atlas")
    }

    private func quad() -> ScanMesh {
        var mesh = ScanMesh()
        mesh.positions = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        mesh.normals = Array(repeating: SIMD3(0, 0, 1), count: 4)
        mesh.indices = [0, 1, 2, 0, 2, 3]
        mesh.uvs = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        return mesh
    }

    private func image() -> UIImage {
        var atlas = AtlasImage(width: 64, height: 64)
        for y in 0..<64 {
            for x in 0..<64 {
                let color: SIMD3<Float> = y < 32
                    ? (x < 32 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0))
                    : (x < 32 ? SIMD3(0, 0, 1) : SIMD3(1, 1, 0))
                atlas.set(x, y, color)
            }
        }
        return atlas.uiImage()!
    }

    private func render(geometry: SCNGeometry) throws -> UIImage {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return try render(scene: scene)
    }

    private func render(scene: SCNScene) throws -> UIImage {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1
        camera.position = SCNVector3(0, 0, 2)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128), antialiasingMode: .none)
    }

    private func check(_ rendered: UIImage, name: String) throws {
        let attachment = XCTAttachment(image: rendered)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let cg = try XCTUnwrap(rendered.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let probes: [(Int, Int, SIMD3<Float>)] = [
            (32, 32, SIMD3(1, 0, 0)), (96, 32, SIMD3(0, 1, 0)),
            (32, 96, SIMD3(0, 0, 1)), (96, 96, SIMD3(1, 1, 0))
        ]
        for (x, y, expected) in probes {
            let offset = (y * cg.width + x) * 4
            let actual = SIMD3(Float(bytes[offset]), Float(bytes[offset + 1]), Float(bytes[offset + 2])) / 255
            XCTAssertLessThan(simd_distance(actual, expected), 0.15, "\(name) at (\(x),\(y)): \(actual), expected \(expected)")
        }
    }
}
