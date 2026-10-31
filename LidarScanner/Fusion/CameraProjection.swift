import simd

/// Projects ARKit camera space onto the captured image.
/// The sensor image origin is the top-left and +v points down. `viewMatrix` camera space has +Y up,
/// so camera Y is negated. This matches `ARCamera.projectPoint` for `.landscapeRight` at `imageResolution`.
enum CameraProjection {
    static func pixel(cameraX: Float, cameraY: Float, cameraZ: Float, fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD2<Float>? {
        guard cameraZ < -0.05 else { return nil }
        let depth = -cameraZ
        guard depth > 0.05 else { return nil }
        let u = fx * (cameraX / depth) + cx
        let v = fy * (-cameraY / depth) + cy
        return SIMD2(u, v)
    }

    static func pixel(world: SIMD3<Float>, viewMatrix: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float) -> (pixel: SIMD2<Float>, depth: Float)? {
        let camera = viewMatrix * SIMD4(world.x, world.y, world.z, 1)
        guard let pixel = pixel(cameraX: camera.x, cameraY: camera.y, cameraZ: camera.z, fx: fx, fy: fy, cx: cx, cy: cy) else {
            return nil
        }
        return (pixel, -camera.z)
    }

    static func worldPoint(u: Float, v: Float, depth: Float, fx: Float, fy: Float, cx: Float, cy: Float, cameraToWorld: simd_float4x4) -> SIMD3<Float> {
        let x = (u - cx) / max(fx, 1e-4) * depth
        let y = -(v - cy) / max(fy, 1e-4) * depth
        let world = cameraToWorld * SIMD4(x, y, -depth, 1)
        return SIMD3(world.x, world.y, world.z)
    }
}
