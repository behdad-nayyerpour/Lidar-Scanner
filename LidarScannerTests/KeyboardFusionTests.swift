import XCTest
import simd
@testable import LidarScanner

/// A flat key surface 15 mm above the desk, seen from above. The old 35 mm truncation
/// pulled those into one torn sheet. The fused result has to stay a single thin surface
/// and must not grow triangles many voxels long.
final class KeyboardFusionTests: XCTestCase {
    func testKeyboardStaysOneSheet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 64
        let height = 48
        let fx: Float = 80
        let fy: Float = 80
        let cx = Float(width) / 2
        let cy = Float(height) / 2
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.0 = SIMD4(1, 0, 0, 0)
        cameraToWorld.columns.1 = SIMD4(0, 0, -1, 0)
        cameraToWorld.columns.2 = SIMD4(0, 1, 0, 0)
        cameraToWorld.columns.3 = SIMD4(0, 0.8, 0, 1)
        let view = simd_inverse(cameraToWorld)
        var depth = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let onKeys = x > 16 && x < 48 && y > 14 && y < 34
                depth[y * width + x] = onKeys ? 0.50 : 0.515
            }
        }
        let image = DepthImage(values: depth, width: width, height: height)
        try KeyframeArchive.writeDepth(image, confidence: [UInt8](repeating: 2, count: depth.count), to: KeyframeArchive.depthURL(in: directory, index: 1))
        let frame = StoredKeyframe(
            index: 1, timestamp: 0, width: width, height: height, depthWidth: width, depthHeight: height,
            fx: fx, fy: fy, cx: cx, cy: cy,
            view: StoredKeyframe.pack(view), transform: StoredKeyframe.pack(cameraToWorld),
            camera: [0, 0.8, 0], meanRed: 128, meanGreen: 128, meanBlue: 128, blur: 100
        )
        try KeyframeArchive.writeManifest([frame], to: directory)
        var settings = FusionSettings.balanced
        settings.voxelMillimeters = 2
        settings.maxRange = 2
        settings.minConfidence = 1
        let mesh = TSDFFusion.fuse(
            directory: directory, frames: [frame], settings: settings,
            objectCenter: nil, objectRadius: 0, signal: nil, progress: nil, useMetal: false
        )
        XCTAssertGreaterThan(mesh.triangleCount, 20)
        let voxel = settings.voxelSize
        var keyHeights: [Float] = []
        for position in mesh.positions where abs(position.x) < 0.04 && abs(position.z) < 0.03 {
            keyHeights.append(position.y)
        }
        XCTAssertGreaterThan(keyHeights.count, 10)
        keyHeights.sort()
        var layers = 1
        for index in 1..<keyHeights.count where keyHeights[index] - keyHeights[index - 1] > voxel * 3 {
            layers += 1
        }
        XCTAssertEqual(layers, 1, "keyboard heights \(keyHeights.first ?? 0)…\(keyHeights.last ?? 0)")
        var longest: Float = 0
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            for edge in [(0, 1), (1, 2), (2, 0)] {
                longest = max(longest, simd_distance(mesh.positions[ids[edge.0]], mesh.positions[ids[edge.1]]))
            }
        }
        XCTAssertLessThan(longest, voxel * 6, "longest edge \(longest) voxel \(voxel)")
    }
}
