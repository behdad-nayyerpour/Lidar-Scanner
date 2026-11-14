import ARKit
import simd

struct ColorKeyframe: Sendable {
    var rgba: [UInt8]
    var width: Int
    var height: Int
    var viewMatrix: simd_float4x4
    var intrinsics: simd_float3x3
    var cameraPosition: SIMD3<Float>
    var depth: [Float] = []
    var depthWidth: Int = 0
    var depthHeight: Int = 0
    /// Recorded mean-luma correction. Not applied: the camera's sRGB sample is the room color.
    var exposureScale: Float = 1

    static func make(from frame: ARFrame, maxDimension: Int = 320) -> ColorKeyframe? {
        let resolution = frame.camera.imageResolution
        guard let image = PixelSampler.rgbaImage(
            from: frame.capturedImage,
            maxDimension: maxDimension,
            imageResolution: resolution
        ) else {
            return nil
        }
        guard resolution.width > 1, resolution.height > 1 else { return nil }

        let scaleX = Float(image.width) / Float(resolution.width)
        let scaleY = Float(image.height) / Float(resolution.height)
        var intrinsics = frame.camera.intrinsics
        intrinsics.columns.0.x *= scaleX
        intrinsics.columns.1.y *= scaleY
        intrinsics.columns.2.x *= scaleX
        intrinsics.columns.2.y *= scaleY

        let depthImage = PixelSampler.depthImage(from: frame.smoothedSceneDepth ?? frame.sceneDepth, maxDimension: 160)
        let camera = frame.camera.transform.columns.3
        return ColorKeyframe(
            rgba: image.rgba,
            width: image.width,
            height: image.height,
            viewMatrix: frame.camera.viewMatrix(for: .landscapeRight),
            intrinsics: intrinsics,
            cameraPosition: SIMD3(camera.x, camera.y, camera.z),
            depth: depthImage?.values ?? [],
            depthWidth: depthImage?.width ?? 0,
            depthHeight: depthImage?.height ?? 0,
            exposureScale: image.exposureScale
        )
    }

    /// Returns a score and a color when the vertex faces this camera and projects inside the frame.
    func sample(world: SIMD3<Float>, normal: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        let cameraSpace = viewMatrix * SIMD4<Float>(world.x, world.y, world.z, 1)
        // Image +v is down and camera +Y is up, so CameraProjection negates Y.
        guard let projected = CameraProjection.pixel(
            cameraX: cameraSpace.x,
            cameraY: cameraSpace.y,
            cameraZ: cameraSpace.z,
            fx: intrinsics.columns.0.x,
            fy: intrinsics.columns.1.y,
            cx: intrinsics.columns.2.x,
            cy: intrinsics.columns.2.y
        ) else { return nil }
        let u = projected.x
        let v = projected.y
        guard u >= 1, v >= 1, u < Float(width) - 1, v < Float(height) - 1 else { return nil }

        let towardCamera = cameraPosition - world
        let distance = simd_length(towardCamera)
        guard distance > 0.05 else { return nil }
        let normalLength = simd_length(normal)
        let facing: Float
        if normalLength > 0.15 {
            facing = simd_dot(normal / normalLength, towardCamera / distance)
            // Grazing views are noisy, but a strict cutoff left large gray holes.
            guard facing > 0.12 else { return nil }
        } else {
            facing = 0.2
        }
        if let depth = depthAt(u: u, v: v) {
            let vertexDepth = -cameraSpace.z
            // LiDAR and the mesh disagree by several centimeters on the same surface.
            // Only reject when a clearly closer surface occupies this pixel.
            let slack = max(0.15, depth * 0.08)
            if vertexDepth > depth + slack { return nil }
        }

        let score = facing / (0.25 + distance)
        // Keep the camera's sRGB values. A second exposure scale, and a later
        // lighting multiply in the viewer, both wash the room color out.
        return (score, bilinear(u, v))
    }

    private func depthAt(u: Float, v: Float) -> Float? {
        guard depthWidth > 1, depthHeight > 1, depth.count >= depthWidth * depthHeight else { return nil }
        let x = min(depthWidth - 1, max(0, Int(u / Float(width) * Float(depthWidth))))
        let y = min(depthHeight - 1, max(0, Int(v / Float(height) * Float(depthHeight))))
        let sample = depth[y * depthWidth + x]
        return sample > 0.05 ? sample : nil
    }

    /// Visibility of a point from this camera, without a surface normal. Used to pick a few candidate frames per region.
    func coverageScore(world: SIMD3<Float>) -> Float? {
        guard let projected = CameraProjection.pixel(world: world, viewMatrix: viewMatrix, fx: intrinsics.columns.0.x, fy: intrinsics.columns.1.y, cx: intrinsics.columns.2.x, cy: intrinsics.columns.2.y) else { return nil }
        let u = projected.pixel.x
        let v = projected.pixel.y
        guard u >= 1, v >= 1, u < Float(width) - 1, v < Float(height) - 1 else { return nil }
        let distance = simd_distance(cameraPosition, world)
        guard distance > 0.05, distance < 8 else { return nil }
        return 1 / (0.35 + distance)
    }

    private func bilinear(_ u: Float, _ v: Float) -> SIMD3<Float> {
        let x0 = Int(floor(u))
        let y0 = Int(floor(v))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = u - Float(x0)
        let ty = v - Float(y0)
        let c00 = pixel(x0, y0)
        let c10 = pixel(x1, y0)
        let c01 = pixel(x0, y1)
        let c11 = pixel(x1, y1)
        let row0 = c00 + (c10 - c00) * tx
        let row1 = c01 + (c11 - c01) * tx
        return row0 + (row1 - row0) * ty
    }

    private func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let index = (y * width + x) * 4
        guard index + 2 < rgba.count else { return SIMD3(repeating: 0.72) }
        return SIMD3(
            Float(rgba[index]) / 255,
            Float(rgba[index + 1]) / 255,
            Float(rgba[index + 2]) / 255
        )
    }
}
