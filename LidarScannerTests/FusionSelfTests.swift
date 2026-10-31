import XCTest
import simd
@testable import LidarScanner

final class FusionSelfTests: XCTestCase {
    func testLandscapeRightProjectionMatchesHandComputedPixels() {
        let fx: Float = 100
        let fy: Float = 100
        let cx: Float = 50
        let cy: Float = 40
        let view = matrix_identity_float4x4
        let above = SIMD3<Float>(0, 0.5, -2)
        let hit = CameraProjection.pixel(world: above, viewMatrix: view, fx: fx, fy: fy, cx: cx, cy: cy)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.pixel.x ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(hit?.pixel.y ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(hit?.depth ?? -1, 2, accuracy: 0.001)
        XCTAssertLessThan(hit?.pixel.y ?? 99, cy)

        let back = CameraProjection.worldPoint(u: 50, v: 15, depth: 2, fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: view)
        XCTAssertEqual(back.x, above.x, accuracy: 0.001)
        XCTAssertEqual(back.y, above.y, accuracy: 0.001)
        XCTAssertEqual(back.z, above.z, accuracy: 0.001)
    }

    func testDepthBinRoundTripKeepsMetersAndConfidence() throws {
        let depth = DepthImage(values: [0, 1.25, 3.5, 0.4], width: 2, height: 2)
        let confidence: [UInt8] = [0, 2, 1, 2]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
        try KeyframeArchive.writeDepth(depth, confidence: confidence, to: url)
        let (read, readConfidence) = try KeyframeArchive.readDepth(at: url)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(read.width, 2)
        XCTAssertEqual(read.values[1], 1.25, accuracy: 0.0001)
        XCTAssertEqual(read.values[2], 3.5, accuracy: 0.0001)
        XCTAssertEqual(readConfidence, confidence)
    }

    func testCameraPoseForFusionIsTheLandscapeViewInverse() {
        var frame = sampleFrame(view: matrix_identity_float4x4)
        frame.transform = StoredKeyframe.pack(rotation90(frame.viewMatrix))
        let origin = frame.cameraToWorld.columns.3
        XCTAssertEqual(origin.x, 0, accuracy: 1e-4)
        XCTAssertEqual(origin.y, 0, accuracy: 1e-4)
        XCTAssertEqual(origin.z, 0, accuracy: 1e-4)
        let column0 = frame.cameraToWorld.columns.0
        XCTAssertEqual(column0.x, 1, accuracy: 1e-3)
        XCTAssertEqual(column0.y, 0, accuracy: 1e-3)
    }

    func testBoxRoomFusionStaysOnTheWallsAndCoversThem() throws {
        let boxMin = SIMD3<Float>(0, 0, 0)
        let boxMax = SIMD3<Float>(4, 2.4, 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let poses = [
            camera(position: SIMD3(2, 1.2, 1.2), look: SIMD3(0, 0, 1)),
            camera(position: SIMD3(2, 1.2, 2.8), look: SIMD3(0, 0, -1)),
            camera(position: SIMD3(1.2, 1.2, 2), look: SIMD3(1, 0, 0)),
            camera(position: SIMD3(2.8, 1.2, 2), look: SIMD3(-1, 0, 0)),
            camera(position: SIMD3(2, 1.6, 2), look: SIMD3(0, -0.85, 0.2)),
            camera(position: SIMD3(2, 1.0, 2), look: SIMD3(0, 0.85, 0.2))
        ]
        var frames: [StoredKeyframe] = []
        for (index, pose) in poses.enumerated() {
            let colorWidth = 320
            let colorHeight = 240
            let depthWidth = 160
            let depthHeight = 120
            let fx: Float = 260
            let fy: Float = 260
            let cx = Float(colorWidth) / 2
            let cy = Float(colorHeight) / 2
            let depth = renderBox(
                view: pose.view,
                cameraToWorld: pose.cameraToWorld,
                width: depthWidth,
                height: depthHeight,
                fx: fx * Float(depthWidth) / Float(colorWidth),
                fy: fy * Float(depthHeight) / Float(colorHeight),
                cx: cx * Float(depthWidth) / Float(colorWidth),
                cy: cy * Float(depthHeight) / Float(colorHeight),
                boxMin: boxMin,
                boxMax: boxMax
            )
            var frame = sampleFrame(view: pose.view)
            frame.index = index + 1
            frame.width = colorWidth
            frame.height = colorHeight
            frame.depthWidth = depthWidth
            frame.depthHeight = depthHeight
            frame.fx = fx
            frame.fy = fy
            frame.cx = cx
            frame.cy = cy
            frame.transform = StoredKeyframe.pack(rotation90(pose.view))
            frames.append(frame)
            try KeyframeArchive.writeDepth(depth, confidence: [UInt8](repeating: 2, count: depth.values.count), to: KeyframeArchive.depthURL(in: directory, index: frame.index))
        }
        try KeyframeArchive.writeManifest(frames, to: directory)

        var settings = FusionSettings.balanced
        settings.voxelMillimeters = 20
        settings.maxRange = 5
        settings.minConfidence = 2
        let mesh = TSDFFusion.fuse(
            directory: directory,
            frames: frames,
            settings: settings,
            objectCenter: nil,
            objectRadius: 0,
            signal: nil,
            progress: nil,
            useMetal: false
        )
        XCTAssertGreaterThan(mesh.triangleCount, 100)
        var offSurface = 0
        for position in mesh.positions {
            let distance = distanceToBox(position, min: boxMin, max: boxMax)
            if distance > 0.05 { offSurface += 1 }
        }
        XCTAssertLessThan(Float(offSurface) / Float(mesh.positions.count), 0.03)

        let reference = boxMesh(min: boxMin, max: boxMax)
        let coverage = MeshCoverage.fraction(of: reference, near: mesh, tolerance: 0.06)
        XCTAssertGreaterThan(coverage, 0.8)

        var holed = mesh
        holed.indices.removeLast(min(holed.indices.count / 2, holed.indices.count))
        let repaired = MeshCoverage.fillingGaps(fused: holed, reference: reference, tolerance: 0.06)
        let repairedCoverage = MeshCoverage.fraction(of: reference, near: repaired, tolerance: 0.06)
        XCTAssertGreaterThan(repairedCoverage, 0.9)
    }

    private func sampleFrame(view: simd_float4x4) -> StoredKeyframe {
        StoredKeyframe(
            index: 1,
            timestamp: 0,
            width: 4,
            height: 4,
            depthWidth: 4,
            depthHeight: 4,
            fx: 1,
            fy: 1,
            cx: 2,
            cy: 2,
            view: StoredKeyframe.pack(view),
            transform: StoredKeyframe.pack(matrix_identity_float4x4),
            camera: [0, 0, 0],
            meanRed: 128,
            meanGreen: 128,
            meanBlue: 128,
            blur: 100
        )
    }

    private func rotation90(_ view: simd_float4x4) -> simd_float4x4 {
        var rotated = view
        let x = rotated.columns.0
        rotated.columns.0 = rotated.columns.1
        rotated.columns.1 = -x
        return rotated
    }

    private func camera(position: SIMD3<Float>, look: SIMD3<Float>) -> (view: simd_float4x4, cameraToWorld: simd_float4x4) {
        let look = simd_normalize(look)
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, look))
        let correctedUp = simd_normalize(simd_cross(look, right))
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.0 = SIMD4(right.x, right.y, right.z, 0)
        cameraToWorld.columns.1 = SIMD4(correctedUp.x, correctedUp.y, correctedUp.z, 0)
        cameraToWorld.columns.2 = SIMD4(-look.x, -look.y, -look.z, 0)
        cameraToWorld.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return (simd_inverse(cameraToWorld), cameraToWorld)
    }

    private func renderBox(
        view: simd_float4x4,
        cameraToWorld: simd_float4x4,
        width: Int,
        height: Int,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        boxMin: SIMD3<Float>,
        boxMax: SIMD3<Float>
    ) -> DepthImage {
        let origin = SIMD3<Float>(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let far = CameraProjection.worldPoint(
                    u: (Float(x) + 0.5) / 1,
                    v: (Float(y) + 0.5) / 1,
                    depth: 1,
                    fx: fx,
                    fy: fy,
                    cx: cx,
                    cy: cy,
                    cameraToWorld: cameraToWorld
                )
                let direction = simd_normalize(far - origin)
                guard let hit = rayBox(origin: origin, direction: direction, boxMin: boxMin, boxMax: boxMax) else { continue }
                let camera = view * SIMD4(hit.x, hit.y, hit.z, 1)
                values[y * width + x] = -camera.z
            }
        }
        return DepthImage(values: values, width: width, height: height)
    }

    private func rayBox(origin: SIMD3<Float>, direction: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> SIMD3<Float>? {
        var tMin: Float = -1_000
        var tMax: Float = 1_000
        for axis in 0..<3 {
            let originAxis = origin[axis]
            let directionAxis = direction[axis]
            if abs(directionAxis) < 1e-6 {
                if originAxis < boxMin[axis] || originAxis > boxMax[axis] { return nil }
                continue
            }
            var t1 = (boxMin[axis] - originAxis) / directionAxis
            var t2 = (boxMax[axis] - originAxis) / directionAxis
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        guard tMax > 0.05 else { return nil }
        let t = tMin > 0.05 ? tMin : tMax
        return origin + direction * t
    }

    private func distanceToBox(_ point: SIMD3<Float>, min boxMin: SIMD3<Float>, max boxMax: SIMD3<Float>) -> Float {
        let clamped = simd_min(simd_max(point, boxMin), boxMax)
        let outside = simd_distance(point, clamped)
        if outside > 1e-4 { return outside }
        let faces = [
            abs(point.x - boxMin.x), abs(point.x - boxMax.x),
            abs(point.y - boxMin.y), abs(point.y - boxMax.y),
            abs(point.z - boxMin.z), abs(point.z - boxMax.z)
        ]
        return faces.min() ?? 0
    }

    private func boxMesh(min boxMin: SIMD3<Float>, max boxMax: SIMD3<Float>) -> ScanMesh {
        let corners = [
            SIMD3(boxMin.x, boxMin.y, boxMin.z), SIMD3(boxMax.x, boxMin.y, boxMin.z),
            SIMD3(boxMin.x, boxMax.y, boxMin.z), SIMD3(boxMax.x, boxMax.y, boxMin.z),
            SIMD3(boxMin.x, boxMin.y, boxMax.z), SIMD3(boxMax.x, boxMin.y, boxMax.z),
            SIMD3(boxMin.x, boxMax.y, boxMax.z), SIMD3(boxMax.x, boxMax.y, boxMax.z)
        ]
        let quads: [(Int, Int, Int, Int)] = [
            (0, 1, 3, 2), (4, 6, 7, 5), (0, 2, 6, 4), (1, 5, 7, 3), (0, 4, 5, 1), (2, 3, 7, 6)
        ]
        var mesh = ScanMesh()
        mesh.positions = corners
        for quad in quads {
            mesh.indices.append(contentsOf: [UInt32(quad.0), UInt32(quad.1), UInt32(quad.2), UInt32(quad.0), UInt32(quad.2), UInt32(quad.3)])
        }
        return mesh
    }
}
