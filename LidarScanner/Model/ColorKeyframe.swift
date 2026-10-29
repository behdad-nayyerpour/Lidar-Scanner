import ARKit
import simd

struct ColorKeyframe: Sendable {
    var rgba: [UInt8]
    var width: Int
    var height: Int
    var viewMatrix: simd_float4x4
    var intrinsics: simd_float3x3
    var cameraPosition: SIMD3<Float>

    static func make(from frame: ARFrame, maxDimension: Int = 256) -> ColorKeyframe? {
        guard let image = PixelSampler.rgbaImage(from: frame.capturedImage, maxDimension: maxDimension) else {
            return nil
        }
        let sourceWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let sourceHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scaleX = Float(image.width) / sourceWidth
        let scaleY = Float(image.height) / sourceHeight
        var intrinsics = frame.camera.intrinsics
        intrinsics.columns.0.x *= scaleX
        intrinsics.columns.1.y *= scaleY
        intrinsics.columns.2.x *= scaleX
        intrinsics.columns.2.y *= scaleY

        let camera = frame.camera.transform.columns.3
        return ColorKeyframe(
            rgba: image.rgba,
            width: image.width,
            height: image.height,
            viewMatrix: frame.camera.viewMatrix(for: .landscapeRight),
            intrinsics: intrinsics,
            cameraPosition: SIMD3(camera.x, camera.y, camera.z)
        )
    }

    /// Returns a score and a color when the vertex faces this camera and projects inside the frame.
    func sample(world: SIMD3<Float>, normal: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        let cameraSpace = viewMatrix * SIMD4<Float>(world.x, world.y, world.z, 1)
        // ARKit cameras look down -Z. Points in front have a negative camera-space Z.
        guard cameraSpace.z < -0.05 else { return nil }
        let inverseDepth = -1 / cameraSpace.z
        let x = cameraSpace.x * inverseDepth
        let y = cameraSpace.y * inverseDepth
        let u = intrinsics.columns.0.x * x + intrinsics.columns.2.x
        let v = intrinsics.columns.1.y * y + intrinsics.columns.2.y
        guard u >= 1, v >= 1, u < Float(width) - 1, v < Float(height) - 1 else { return nil }

        let towardCamera = cameraPosition - world
        let distance = simd_length(towardCamera)
        guard distance > 0.05 else { return nil }
        let facing = simd_dot(normal, towardCamera / distance)
        guard facing > 0.2 else { return nil }

        let score = facing / (0.35 + distance)
        return (score, bilinear(u, v))
    }

    /// Visibility of a point from this camera, without a surface normal. Used to pick a few candidate frames per region.
    func coverageScore(world: SIMD3<Float>) -> Float? {
        let cameraSpace = viewMatrix * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard cameraSpace.z < -0.05 else { return nil }
        let inverseDepth = -1 / cameraSpace.z
        let x = cameraSpace.x * inverseDepth
        let y = cameraSpace.y * inverseDepth
        let u = intrinsics.columns.0.x * x + intrinsics.columns.2.x
        let v = intrinsics.columns.1.y * y + intrinsics.columns.2.y
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

/// Thread-safe keyframe ring. The ARSession callback and the finish path both touch it.
final class KeyframeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ColorKeyframe] = []
    private var poses: [simd_float4x4] = []
    private var accepting = false
    private let limit: Int

    init(limit: Int = 16) {
        self.limit = limit
    }

    func setAccepting(_ value: Bool) {
        lock.lock()
        accepting = value
        lock.unlock()
    }

    func consider(_ frame: ARFrame) {
        let transform = frame.camera.transform
        lock.lock()
        let shouldCapture = accepting && (frames.isEmpty || movedEnough(from: poses.last ?? transform, to: transform))
        lock.unlock()
        guard shouldCapture, let keyframe = ColorKeyframe.make(from: frame) else { return }

        lock.lock()
        defer { lock.unlock() }
        if frames.count < limit {
            frames.append(keyframe)
            poses.append(transform)
            return
        }
        guard let index = replacementIndex(for: transform) else { return }
        frames[index] = keyframe
        poses[index] = transform
    }

    func snapshot() -> [ColorKeyframe] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
        poses.removeAll()
    }

    private func movedEnough(from: simd_float4x4, to: simd_float4x4) -> Bool {
        let translation = simd_distance(Self.position(from), Self.position(to))
        let rotation = Self.angle(from, to)
        return translation > 0.18 || rotation > 0.18
    }

    private func replacementIndex(for transform: simd_float4x4) -> Int? {
        let candidate = Self.position(transform)
        var nearest = Float.greatestFiniteMagnitude
        for pose in poses {
            nearest = min(nearest, simd_distance(candidate, Self.position(pose)))
        }
        guard nearest > 0.30 else { return nil }

        var mostRedundant = 0
        var smallestGap = Float.greatestFiniteMagnitude
        for index in poses.indices {
            var gap = Float.greatestFiniteMagnitude
            for other in poses.indices where other != index {
                gap = min(gap, simd_distance(Self.position(poses[index]), Self.position(poses[other])))
            }
            if gap < smallestGap {
                smallestGap = gap
                mostRedundant = index
            }
        }
        return mostRedundant
    }

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let forwardA = simd_normalize(SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let forwardB = simd_normalize(SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let dot = min(1, max(-1, simd_dot(forwardA, forwardB)))
        return acos(dot)
    }
}
