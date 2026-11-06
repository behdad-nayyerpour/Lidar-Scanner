import XCTest
import simd
@testable import LidarScanner

/// The 18-frame desk scan. The keyboard has to stay one sheet, and triangles on it
/// stay within a few voxels instead of stretching into feathers.
final class DeskScanFusionTests: XCTestCase {
    func testKeyboardIsOneSheetWithShortEdges() throws {
        let bundle = Bundle(for: DeskScanFusionTests.self)
        let candidates = [
            bundle.url(forResource: "DeskScan", withExtension: nil),
            bundle.resourceURL?.appendingPathComponent("DeskScan"),
            bundle.bundleURL.appendingPathComponent("DeskScan")
        ]
        guard let folder = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }) else {
            XCTFail("Desk scan fixture is missing")
            return
        }
        let frames = try KeyframeArchive.readManifest(in: folder)
        XCTAssertEqual(frames.count, 18)
        var settings = FusionSettings.balanced
        let range = FusionVoxel.medianDepth(directory: folder, frames: frames)
        settings.voxelMillimeters = FusionVoxel.millimeters(requested: settings.voxelMillimeters, frames: frames, range: range)
        settings.maxRange = FusionVoxel.integrationRange(subject: range, requested: settings.maxRange)
        settings.minConfidence = 1
        var mesh = TSDFFusion.fuse(
            directory: folder,
            frames: frames,
            settings: settings,
            objectCenter: nil,
            objectRadius: 0,
            signal: nil,
            progress: nil,
            useMetal: false
        )
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        let keyMin = SIMD3<Float>(0.03, -0.26, -0.29)
        let keyMax = SIMD3<Float>(0.47, -0.22, -0.09)
        var heights: [Float] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for position in mesh.positions {
            low = SIMD3(min(low.x, position.x), min(low.y, position.y), min(low.z, position.z))
            high = SIMD3(max(high.x, position.x), max(high.y, position.y), max(high.z, position.z))
            if inside(position, min: keyMin, max: keyMax) { heights.append(position.y) }
        }
        XCTAssertGreaterThan(heights.count, 50, "keyboard empty inside \(keyMin) \(keyMax); mesh \(low) \(high) voxel \(settings.voxelMillimeters)")
        mesh = mesh.simplified(targetTriangles: settings.targetTriangles, maxError: max(settings.voxelSize, 0.002))
        heights.removeAll(keepingCapacity: true)
        for position in mesh.positions where inside(position, min: keyMin, max: keyMax) {
            heights.append(position.y)
        }
        XCTAssertGreaterThan(heights.count, 50, "keyboard removed by simplification")
        guard heights.count > 50 else { return }
        heights.sort()
        let gap = settings.voxelSize * 3
        var layers = 1
        for index in 1..<heights.count where heights[index] - heights[index - 1] > gap {
            layers += 1
        }
        XCTAssertEqual(layers, 1, "keyboard heights \(heights.first ?? 0)…\(heights.last ?? 0) voxel \(settings.voxelSize)")

        var longest: Float = 0
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let corners = ids.map { mesh.positions[$0] }
            let midpoint = (corners[0] + corners[1] + corners[2]) / 3
            guard inside(midpoint, min: keyMin, max: keyMax) else { continue }
            for edge in [(0, 1), (1, 2), (2, 0)] {
                longest = max(longest, simd_distance(corners[edge.0], corners[edge.1]))
            }
        }
        XCTAssertGreaterThan(longest, 0)
        XCTAssertLessThan(longest, settings.voxelSize * 8, "longest keyboard edge \(longest)")
    }

    private func inside(_ point: SIMD3<Float>, min lower: SIMD3<Float>, max upper: SIMD3<Float>) -> Bool {
        point.x >= lower.x && point.y >= lower.y && point.z >= lower.z &&
            point.x <= upper.x && point.y <= upper.y && point.z <= upper.z
    }
}
