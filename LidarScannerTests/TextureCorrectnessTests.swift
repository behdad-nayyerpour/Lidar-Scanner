import XCTest
import simd
@testable import LidarScanner

/// A room with a different color on each wall, saved through the JPEG path the scanner uses.
/// Texturing has to put those colors back on the matching faces. A vertical flip paints the
/// upper color onto the lower half of the wall, so this fails if the photo is upside down.
final class TextureCorrectnessTests: XCTestCase {
    func testJPEGKeepsTheTopRowAtVZero() throws {
        var image = RGBAImage(rgba: [UInt8](repeating: 0, count: 8 * 6 * 4), width: 8, height: 6, exposureScale: 1)
        for x in 0..<8 {
            image.rgba[(0 * 8 + x) * 4] = 255
            image.rgba[(5 * 8 + x) * 4 + 1] = 255
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let jpeg = KeyframeArchive.jpegData(image, quality: 0.95) else {
            XCTFail("JPEG was not written")
            return
        }
        let url = KeyframeArchive.colorURL(in: directory, index: 1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url)
        let frame = StoredKeyframe(
            index: 1, timestamp: 0, width: 8, height: 6, depthWidth: 0, depthHeight: 0,
            fx: 16, fy: 12, cx: 4, cy: 3, view: StoredKeyframe.pack(matrix_identity_float4x4),
            transform: StoredKeyframe.pack(matrix_identity_float4x4), camera: [0, 0, 0],
            meanRed: 128, meanGreen: 128, meanBlue: 128, blur: 100
        )
        guard let loaded = KeyframeArchive.loadColor(in: directory, frame: frame, maxDimension: 64) else {
            XCTFail("JPEG did not load")
            return
        }
        XCTAssertGreaterThan(loaded.rgba[0], 200, "Top-left pixel must stay red")
        XCTAssertGreaterThan(loaded.rgba[((loaded.height - 1) * loaded.width) * 4 + 1], 200, "Bottom row must stay green")
        guard let scaled = KeyframeArchive.loadColor(in: directory, frame: frame, maxDimension: 4) else {
            XCTFail("Scaled JPEG did not load")
            return
        }
        XCTAssertEqual(scaled.width, 4)
        XCTAssertEqual(scaled.fx, 8, accuracy: 0.01, "Intrinsics must scale with the stored photo")
        XCTAssertEqual(scaled.fy, 6, accuracy: 0.01)
        XCTAssertEqual(scaled.cx, 2, accuracy: 0.01)
        XCTAssertEqual(scaled.cy, 1.5, accuracy: 0.01)
    }

    func testEachWallKeepsItsOwnColor() throws {
        let boxMin = SIMD3<Float>(0, 0, 0)
        let boxMax = SIMD3<Float>(2, 2, 2)
        let mesh = coloredRoomMesh(min: boxMin, max: boxMax)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shots: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 1, 1), SIMD3(1, 0, 0)),
            (SIMD3(1, 1, 1), SIMD3(-1, 0, 0)),
            (SIMD3(1, 1, 1), SIMD3(0, 0, 1)),
            (SIMD3(1, 1, 1), SIMD3(0, 0, -1)),
            (SIMD3(1, 1.55, 1), SIMD3(0, -1, 0))
        ]
        var frames: [StoredKeyframe] = []
        var firstPicture: RGBAImage?
        let width = 160
        let height = 120
        let fx: Float = 48
        let fy: Float = 48
        let cx = Float(width) / 2
        let cy = Float(height) / 2
        for (index, shot) in shots.enumerated() {
            let pose = camera(position: shot.0, look: shot.1)
            let picture = renderRoom(
                cameraToWorld: pose.cameraToWorld,
                width: width,
                height: height,
                fx: fx,
                fy: fy,
                cx: cx,
                cy: cy,
                boxMin: boxMin,
                boxMax: boxMax
            )
            if index == 0 { firstPicture = picture }
            guard let jpeg = KeyframeArchive.jpegData(picture, quality: 0.95) else {
                XCTFail("Photo \(index) was not encoded")
                return
            }
            let colorURL = KeyframeArchive.colorURL(in: directory, index: index + 1)
            try FileManager.default.createDirectory(at: colorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: colorURL)
            let depthSize = (width: width / 2, height: height / 2)
            let depth = renderDepth(
                view: pose.view,
                cameraToWorld: pose.cameraToWorld,
                width: depthSize.width,
                height: depthSize.height,
                fx: fx * Float(depthSize.width) / Float(width),
                fy: fy * Float(depthSize.height) / Float(height),
                cx: cx * Float(depthSize.width) / Float(width),
                cy: cy * Float(depthSize.height) / Float(height),
                boxMin: boxMin,
                boxMax: boxMax
            )
            try KeyframeArchive.writeDepth(depth, confidence: [UInt8](repeating: 2, count: depth.values.count), to: KeyframeArchive.depthURL(in: directory, index: index + 1))
            frames.append(StoredKeyframe(
                index: index + 1,
                timestamp: Double(index),
                width: width,
                height: height,
                depthWidth: depthSize.width,
                depthHeight: depthSize.height,
                fx: fx,
                fy: fy,
                cx: cx,
                cy: cy,
                view: StoredKeyframe.pack(pose.view),
                transform: StoredKeyframe.pack(rotation90(pose.view)),
                camera: [9, 9, 9],
                meanRed: 128,
                meanGreen: 128,
                meanBlue: 128,
                blur: 200
            ))
        }
        try KeyframeArchive.writeManifest(frames, to: directory)
        if let picture = firstPicture {
            let row = 31
            let column = 80
            let pixel = (row * picture.width + column) * 4
            let pose = camera(position: SIMD3(1, 1, 1), look: SIMD3(1, 0, 0))
            let far = CameraProjection.worldPoint(u: Float(column) + 0.5, v: Float(row) + 0.5, depth: 1, fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: pose.cameraToWorld)
            let origin = SIMD3<Float>(pose.cameraToWorld.columns.3.x, pose.cameraToWorld.columns.3.y, pose.cameraToWorld.columns.3.z)
            let hit = rayBox(origin: origin, direction: simd_normalize(far - origin), boxMin: boxMin, boxMax: boxMax)
            XCTAssertGreaterThan(
                Int(picture.rgba[pixel]),
                200,
                String(format: "raw render row %d is (%d,%d,%d), far=(%.2f,%.2f,%.2f) hit=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f)", row, picture.rgba[pixel], picture.rgba[pixel + 1], picture.rgba[pixel + 2], far.x, far.y, far.z, hit?.x ?? -9, hit?.y ?? -9, hit?.z ?? -9, pose.cameraToWorld.columns.1.x, pose.cameraToWorld.columns.1.y, pose.cameraToWorld.columns.1.z)
            )
        }
        try assertPhotoSample(directory: directory, frame: frames[0], world: SIMD3(2, 1.6, 1), expected: SIMD3(1, 0, 0), label: "upper +X wall")
        try assertPhotoSample(directory: directory, frame: frames[0], world: SIMD3(2, 0.4, 1), expected: SIMD3(0, 0, 1), label: "lower +X wall")
        var settings = FusionSettings.fast
        settings.textureSize = 512
        settings.maxRange = 8
        guard let textured = AtlasTexturer.texture(
            mesh: mesh,
            directory: directory,
            frames: frames,
            settings: settings,
            signal: nil,
            progress: nil
        ) else {
            XCTFail("Texturing returned nothing")
            return
        }
        var correct = 0
        var checked = 0
        var missing = 0
        var examples: [String] = []
        let result = textured.mesh
        for triangle in 0..<result.triangleCount {
            let ids = (0..<3).map { Int(result.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < result.positions.count && $0 < result.colors.count && $0 < result.normals.count }) else { continue }
            let center = (result.positions[ids[0]] + result.positions[ids[1]] + result.positions[ids[2]]) / 3
            let normal = (result.normals[ids[0]] + result.normals[ids[1]] + result.normals[ids[2]]) / 3
            guard visible(center, normal: normal, frames: frames), stableColor(at: center, min: boxMin, max: boxMax) else { continue }
            guard let expected = surfaceColor(at: center, min: boxMin, max: boxMax) else { continue }
            let color = (result.colors[ids[0]] + result.colors[ids[1]] + result.colors[ids[2]]) / 3
            checked += 1
            if matches(color, expected) {
                correct += 1
            } else if examples.count < 8 {
                examples.append(String(format: "(%.2f,%.2f,%.2f) got (%.2f,%.2f,%.2f) want (%.2f,%.2f,%.2f)", center.x, center.y, center.z, color.x, color.y, color.z, expected.x, expected.y, expected.z))
            }
            if color.x > 0.92 && color.y > 0.92 && color.z > 0.92 { missing += 1 }
            if simd_distance(color, SIMD3(repeating: 0.72)) < 0.06 { missing += 1 }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertGreaterThan(Float(correct) / Float(max(checked, 1)), 0.95, "\(correct) of \(checked) visible faces matched their wall. \(examples.joined(separator: " | "))")
        XCTAssertLessThan(Float(missing) / Float(max(checked, 1)), 0.05)

        let uv = result.uvs[0]
        let obj = try MeshExporter.objPackage(mesh: result, baseName: "room", atlas: textured.image)
        let objLine = String(format: "vt %.6f %.6f", uv.x, uv.y)
        XCTAssertNotNil(obj.range(of: Data(objLine.utf8)), "OBJ keeps the stored UV, with v = 0 at the bottom")
        let glb = try MeshExporter.glbData(mesh: result, atlas: textured.image)
        let exported = try XCTUnwrap(firstGLBTexcoord(in: glb))
        XCTAssertEqual(exported.x, uv.x, accuracy: 0.0001)
        XCTAssertEqual(exported.y, 1 - uv.y, accuracy: 0.0001, "glTF v = 0 is the top of the atlas")

        let pixels = try XCTUnwrap(topOriginPixels(textured.image))
        let ids = (0..<3).map { Int(result.indices[$0]) }
        guard ids.allSatisfy({ $0 < result.uvs.count && $0 < result.colors.count }) else {
            XCTFail("First face has no UV")
            return
        }
        let faceUV = (result.uvs[ids[0]] + result.uvs[ids[1]] + result.uvs[ids[2]]) / 3
        let x = Int((faceUV.x * Float(pixels.width - 1)).rounded())
        let y = Int(((1 - faceUV.y) * Float(pixels.height - 1)).rounded())
        let pixel = (y * pixels.width + x) * 4
        let sampled = SIMD3(Float(pixels.rgba[pixel]) / 255, Float(pixels.rgba[pixel + 1]) / 255, Float(pixels.rgba[pixel + 2]) / 255)
        XCTAssertLessThan(simd_distance(sampled, result.colors[ids[0]]), 0.08, "Viewer UV v = 1 reads the top of the texture")
    }

    func testGapFillRestoresAHoleAfterSmoothing() {
        let full = fineWall()
        var holey = full
        var kept: [UInt32] = []
        for triangle in 0..<full.triangleCount {
            let ids = (0..<3).map { Int(full.indices[triangle * 3 + $0]) }
            let center = (full.positions[ids[0]] + full.positions[ids[1]] + full.positions[ids[2]]) / 3
            if inHole(center) { continue }
            kept.append(contentsOf: ids.map { UInt32($0) })
        }
        holey.indices = kept
        // A stray triangle in the hole used to convince the centroid test that the hole was covered.
        let stray = holey.positions.count
        holey.positions.append(SIMD3(0, 1, 1))
        holey.positions.append(SIMD3(0, 1.02, 1))
        holey.positions.append(SIMD3(0, 1, 1.02))
        holey.indices.append(contentsOf: [UInt32(stray), UInt32(stray + 1), UInt32(stray + 2)])

        let hole = triangles(full, where: inHole)
        XCTAssertLessThan(area(holey, where: inHole), area(hole, where: { _ in true }) * 0.2)
        let directly = MeshCoverage.fillingGaps(fused: holey, reference: full, tolerance: 0.04)
        let deep = area(full, where: deepHole)
        XCTAssertGreaterThan(deep, 0.01)
        XCTAssertGreaterThan(area(directly, where: deepHole), deep * 0.9)
        let closed = ScanProcessor.closeGaps(in: holey, reference: full, settings: .balanced, tolerance: 0.04)
        XCTAssertGreaterThan(area(closed.mesh, where: deepHole), deep * 0.9)
    }

    private func inHole(_ center: SIMD3<Float>) -> Bool {
        simd_distance(SIMD2(center.y, center.z), SIMD2(1, 1)) < 0.28 && abs(center.x) < 0.02
    }

    /// Inside the hole, clear of the stray triangle and of the fused rim.
    private func deepHole(_ center: SIMD3<Float>) -> Bool {
        let radius = simd_distance(SIMD2(center.y, center.z), SIMD2(1, 1))
        return radius > 0.08 && radius < 0.18 && abs(center.x) < 0.02
    }

    private func fineWall() -> ScanMesh {
        var mesh = ScanMesh()
        let divisions = 40
        let normal = SIMD3<Float>(1, 0, 0)
        for y in 0...divisions {
            for z in 0...divisions {
                mesh.positions.append(SIMD3(0, Float(y) / Float(divisions) * 2, Float(z) / Float(divisions) * 2))
                mesh.normals.append(normal)
            }
        }
        let stride = divisions + 1
        for y in 0..<divisions {
            for z in 0..<divisions {
                let i0 = y * stride + z
                let i1 = i0 + 1
                let i2 = i0 + stride
                let i3 = i2 + 1
                mesh.indices.append(contentsOf: [UInt32(i0), UInt32(i1), UInt32(i3), UInt32(i0), UInt32(i3), UInt32(i2)])
            }
        }
        return mesh
    }

    private func triangles(_ mesh: ScanMesh, where include: (SIMD3<Float>) -> Bool) -> ScanMesh {
        var copy = mesh
        var indices: [UInt32] = []
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            let center = (mesh.positions[ids[0]] + mesh.positions[ids[1]] + mesh.positions[ids[2]]) / 3
            if include(center) {
                indices.append(contentsOf: ids.map { UInt32($0) })
            }
        }
        copy.indices = indices
        return copy
    }

    private func area(_ mesh: ScanMesh, where include: (SIMD3<Float>) -> Bool) -> Float {
        var total: Float = 0
        for triangle in 0..<mesh.triangleCount {
            let ids = (0..<3).map { Int(mesh.indices[triangle * 3 + $0]) }
            guard ids.allSatisfy({ $0 < mesh.positions.count }) else { continue }
            let a = mesh.positions[ids[0]]
            let b = mesh.positions[ids[1]]
            let c = mesh.positions[ids[2]]
            let center = (a + b + c) / 3
            if include(center) {
                total += simd_length(simd_cross(b - a, c - a)) * 0.5
            }
        }
        return total
    }

    private func assertPhotoSample(directory: URL, frame: StoredKeyframe, world: SIMD3<Float>, expected: SIMD3<Float>, label: String) throws {
        guard let loaded = KeyframeArchive.loadColor(in: directory, frame: frame, maxDimension: 1600) else {
            XCTFail("\(label) photo did not load")
            return
        }
        guard let hit = CameraProjection.pixel(world: world, viewMatrix: frame.viewMatrix, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else {
            XCTFail("\(label) did not project")
            return
        }
        let x = min(loaded.width - 1, max(0, Int(hit.pixel.x.rounded())))
        let y = min(loaded.height - 1, max(0, Int(hit.pixel.y.rounded())))
        let pixel = (y * loaded.width + x) * 4
        let rgb = SIMD3(Float(loaded.rgba[pixel]) / 255, Float(loaded.rgba[pixel + 1]) / 255, Float(loaded.rgba[pixel + 2]) / 255)
        XCTAssertLessThan(
            simd_distance(rgb, expected),
            0.34,
            String(format: "%@ u=%.1f v=%.1f depth=%.2f rgb=(%.2f,%.2f,%.2f) image=%dx%d", label, hit.pixel.x, hit.pixel.y, hit.depth, rgb.x, rgb.y, rgb.z, loaded.width, loaded.height)
        )
    }

    private func matches(_ color: SIMD3<Float>, _ expected: SIMD3<Float>) -> Bool {
        simd_distance(color, expected) < 0.34
    }

    private func stableColor(at point: SIMD3<Float>, min boxMin: SIMD3<Float>, max boxMax: SIMD3<Float>) -> Bool {
        if abs(point.y - boxMin.y) < 0.08 {
            let scale: Float = 0.5
            let dx = abs(point.x / scale - round(point.x / scale))
            let dz = abs(point.z / scale - round(point.z / scale))
            return min(dx, 1 - dx) > 0.2 && min(dz, 1 - dz) > 0.2
        }
        if abs(point.y - 1) < 0.12 { return false }
        if abs(point.y - boxMax.y) < 0.05 { return false }
        return true
    }

    private func surfaceColor(at point: SIMD3<Float>, min boxMin: SIMD3<Float>, max boxMax: SIMD3<Float>) -> SIMD3<Float>? {
        let upper = point.y >= 1
        let faces: [(Float, SIMD3<Float>)] = [
            (abs(point.x - boxMax.x), upper ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)),
            (abs(point.x - boxMin.x), upper ? SIMD3(0, 1, 0) : SIMD3(1, 1, 0)),
            (abs(point.z - boxMax.z), upper ? SIMD3(1, 0, 1) : SIMD3(0, 0.75, 0.8)),
            (abs(point.z - boxMin.z), upper ? SIMD3(1, 0.45, 0) : SIMD3(0.45, 0.2, 0.75)),
            (abs(point.y - boxMin.y), floorColor(point)),
            (abs(point.y - boxMax.y), SIMD3(0.35, 0.35, 0.35))
        ]
        return faces.min(by: { $0.0 < $1.0 })?.1
    }

    private func floorColor(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let check = (Int(floor(point.x / 0.5)) + Int(floor(point.z / 0.5))) % 2 == 0
        return check ? SIMD3(0.15, 0.28, 0.62) : SIMD3(0.62, 0.78, 0.3)
    }

    private func visible(_ point: SIMD3<Float>, normal: SIMD3<Float>, frames: [StoredKeyframe]) -> Bool {
        let length = simd_length(normal)
        guard length > 1e-4 else { return false }
        let direction = normal / length
        for frame in frames {
            let toward = frame.cameraPosition - point
            let distance = simd_length(toward)
            guard distance > 0.05, simd_dot(direction, toward / distance) > 0.35 else { continue }
            guard let hit = CameraProjection.pixel(world: point, viewMatrix: frame.viewMatrix, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy) else { continue }
            if hit.pixel.x > 3, hit.pixel.y > 3, hit.pixel.x < Float(frame.width) - 3, hit.pixel.y < Float(frame.height) - 3, hit.depth < 8 {
                return true
            }
        }
        return false
    }

    private func coloredRoomMesh(min boxMin: SIMD3<Float>, max boxMax: SIMD3<Float>) -> ScanMesh {
        var mesh = ScanMesh()
        func add(_ origin: SIMD3<Float>, _ edgeU: SIMD3<Float>, _ edgeV: SIMD3<Float>, _ normal: SIMD3<Float>, _ nu: Int, _ nv: Int) {
            let base = mesh.positions.count
            for y in 0...nv {
                for x in 0...nu {
                    mesh.positions.append(origin + edgeU * (Float(x) / Float(nu)) + edgeV * (Float(y) / Float(nv)))
                    mesh.normals.append(normal)
                }
            }
            let stride = nu + 1
            for y in 0..<nv {
                for x in 0..<nu {
                    let i0 = base + y * stride + x
                    let i1 = i0 + 1
                    let i2 = i0 + stride
                    let i3 = i2 + 1
                    mesh.indices.append(contentsOf: [UInt32(i0), UInt32(i1), UInt32(i3), UInt32(i0), UInt32(i3), UInt32(i2)])
                }
            }
        }
        let size = boxMax - boxMin
        add(SIMD3(boxMax.x, boxMin.y, boxMin.z), SIMD3(0, size.y, 0), SIMD3(0, 0, size.z), SIMD3(-1, 0, 0), 4, 4)
        add(boxMin, SIMD3(0, size.y, 0), SIMD3(0, 0, size.z), SIMD3(1, 0, 0), 4, 4)
        add(SIMD3(boxMin.x, boxMin.y, boxMax.z), SIMD3(size.x, 0, 0), SIMD3(0, size.y, 0), SIMD3(0, 0, -1), 4, 4)
        add(boxMin, SIMD3(size.x, 0, 0), SIMD3(0, size.y, 0), SIMD3(0, 0, 1), 4, 4)
        add(boxMin, SIMD3(size.x, 0, 0), SIMD3(0, 0, size.z), SIMD3(0, 1, 0), 4, 4)
        add(SIMD3(boxMin.x, boxMax.y, boxMin.z), SIMD3(size.x, 0, 0), SIMD3(0, 0, size.z), SIMD3(0, -1, 0), 2, 2)
        return mesh
    }

    private func renderRoom(
        cameraToWorld: simd_float4x4,
        width: Int,
        height: Int,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        boxMin: SIMD3<Float>,
        boxMax: SIMD3<Float>
    ) -> RGBAImage {
        let origin = SIMD3<Float>(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let far = CameraProjection.worldPoint(u: Float(x) + 0.5, v: Float(y) + 0.5, depth: 1, fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: cameraToWorld)
                let direction = simd_normalize(far - origin)
                guard let hit = rayBox(origin: origin, direction: direction, boxMin: boxMin, boxMax: boxMax),
                      let color = surfaceColor(at: hit, min: boxMin, max: boxMax) else { continue }
                let pixel = (y * width + x) * 4
                rgba[pixel] = UInt8((color.x * 255).rounded())
                rgba[pixel + 1] = UInt8((color.y * 255).rounded())
                rgba[pixel + 2] = UInt8((color.z * 255).rounded())
                rgba[pixel + 3] = 255
            }
        }
        return RGBAImage(rgba: rgba, width: width, height: height, exposureScale: 1)
    }

    private func renderDepth(
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
                let far = CameraProjection.worldPoint(u: Float(x) + 0.5, v: Float(y) + 0.5, depth: 1, fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: cameraToWorld)
                let direction = simd_normalize(far - origin)
                guard let hit = rayBox(origin: origin, direction: direction, boxMin: boxMin, boxMax: boxMax) else { continue }
                let camera = view * SIMD4(hit.x, hit.y, hit.z, 1)
                values[y * width + x] = max(0, -camera.z)
            }
        }
        return DepthImage(values: values, width: width, height: height)
    }

    private func camera(position: SIMD3<Float>, look: SIMD3<Float>) -> (view: simd_float4x4, cameraToWorld: simd_float4x4) {
        let look = simd_normalize(look)
        let up = abs(look.y) > 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, look))
        let correctedUp = simd_normalize(simd_cross(look, right))
        var cameraToWorld = matrix_identity_float4x4
        cameraToWorld.columns.0 = SIMD4(right.x, right.y, right.z, 0)
        cameraToWorld.columns.1 = SIMD4(correctedUp.x, correctedUp.y, correctedUp.z, 0)
        cameraToWorld.columns.2 = SIMD4(-look.x, -look.y, -look.z, 0)
        cameraToWorld.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return (simd_inverse(cameraToWorld), cameraToWorld)
    }

    private func rotation90(_ view: simd_float4x4) -> simd_float4x4 {
        var rotated = view
        let x = rotated.columns.0
        rotated.columns.0 = rotated.columns.1
        rotated.columns.1 = -x
        return rotated
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

    private func firstGLBTexcoord(in data: Data) -> SIMD2<Float>? {
        guard data.count > 28 else { return nil }
        let jsonLength = Int(readUInt32(data, 12))
        let jsonStart = 20
        guard jsonStart + jsonLength + 8 <= data.count else { return nil }
        let json = data.subdata(in: jsonStart..<(jsonStart + jsonLength))
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let meshes = object["meshes"] as? [[String: Any]],
              let primitives = meshes.first?["primitives"] as? [[String: Any]],
              let attributes = primitives.first?["attributes"] as? [String: Any],
              let texIndex = intValue(attributes["TEXCOORD_0"]),
              let accessors = object["accessors"] as? [[String: Any]],
              let views = object["bufferViews"] as? [[String: Any]],
              texIndex < accessors.count,
              let viewIndex = intValue(accessors[texIndex]["bufferView"]),
              viewIndex < views.count,
              let byteOffset = intValue(views[viewIndex]["byteOffset"]) else { return nil }
        let binStart = jsonStart + jsonLength + 8
        let base = binStart + byteOffset
        guard base + 8 <= data.count else { return nil }
        let x = readFloat(data, base)
        let y = readFloat(data, base + 4)
        return SIMD2(x, y)
    }

    private func topOriginPixels(_ image: UIImage) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage, let provider = cgImage.dataProvider?.data else { return nil }
        let data = provider as Data
        let width = cgImage.width
        let height = cgImage.height
        guard data.count >= width * height * 4 else { return nil }
        return ([UInt8](data), width, height)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private func readFloat(_ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, offset))
    }
}
