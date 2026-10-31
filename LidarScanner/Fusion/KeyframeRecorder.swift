import ARKit
import CoreVideo
import UIKit
import simd

/// Writes about one sharp keyframe a second while a scan is running.
/// RGB stays at the sensor resolution (capped at 1920 on the long edge). Depth and confidence stay beside it.
final class KeyframeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.example.lidarscanner.keyframes", qos: .utility)
    private var accepting = false
    private var lastAccepted: TimeInterval = 0
    private var lastTransform = matrix_identity_float4x4
    private var hasPose = false
    private var frames: [StoredKeyframe] = []
    private var directory: URL
    private let maxFrames = 180
    var movingTooFast = false

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func reset() {
        queue.sync {}
        lock.lock()
        frames.removeAll()
        lastAccepted = 0
        hasPose = false
        movingTooFast = false
        let old = directory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)", isDirectory: true)
        lock.unlock()
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setAccepting(_ value: Bool) {
        lock.lock()
        accepting = value
        lock.unlock()
    }

    func consider(_ frame: ARFrame, maxRange: Float) {
        lock.lock()
        let recording = accepting && frames.count < maxFrames
        let previousTime = lastAccepted
        let previous = lastTransform
        let known = hasPose
        lock.unlock()
        guard recording else { return }
        let timestamp = frame.timestamp
        if previousTime > 0, timestamp - previousTime < 0.55 { return }
        guard case .normal = frame.camera.trackingState else { return }

        let transform = frame.camera.transform
        if known {
            let dt = Float(max(0.016, timestamp - previousTime))
            let translation = simd_distance(Self.position(previous), Self.position(transform)) / dt
            let spin = Self.angle(previous, transform) / dt
            if translation > 0.8 || spin > 1.25 {
                lock.lock()
                movingTooFast = true
                lock.unlock()
                return
            }
        }

        let pixelBuffer = frame.capturedImage
        let blur = Self.blurScore(pixelBuffer)
        if blur < 18 { return }
        guard let colorCopy = PixelBufferCopy.copy(pixelBuffer) else { return }
        let depthSource = frame.smoothedSceneDepth ?? frame.sceneDepth
        let depthImage = PixelSampler.depthImage(from: depthSource, maxDimension: 256)
        var confidence = [UInt8]()
        if let depthImage, let map = depthSource?.confidenceMap {
            confidence = Self.copyConfidence(map, width: depthImage.width, height: depthImage.height, sourceWidth: CVPixelBufferGetWidth(depthSource?.depthMap ?? map), sourceHeight: CVPixelBufferGetHeight(depthSource?.depthMap ?? map))
        }
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let view = frame.camera.viewMatrix(for: .landscapeRight)
        lock.lock()
        movingTooFast = false
        lastAccepted = timestamp
        lastTransform = transform
        hasPose = true
        let folder = directory
        let index = frames.count + 1
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            guard let image = PixelSampler.rgbaImage(from: colorCopy, maxDimension: 1920, imageResolution: resolution) else { return }
            guard let jpeg = KeyframeArchive.jpegData(image) else { return }
            let colorURL = KeyframeArchive.colorURL(in: folder, index: index)
            try? FileManager.default.createDirectory(at: colorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? jpeg.write(to: colorURL, options: .atomic)
            if let depthImage {
                try? KeyframeArchive.writeDepth(depthImage, confidence: confidence, to: KeyframeArchive.depthURL(in: folder, index: index))
            }
            let scaleX = Float(image.width) / Float(max(resolution.width, 1))
            let scaleY = Float(image.height) / Float(max(resolution.height, 1))
            let means = Self.means(image)
            let camera = transform.columns.3
            let record = StoredKeyframe(
                index: index,
                timestamp: timestamp,
                width: image.width,
                height: image.height,
                depthWidth: depthImage?.width ?? 0,
                depthHeight: depthImage?.height ?? 0,
                fx: intrinsics.columns.0.x * scaleX,
                fy: intrinsics.columns.1.y * scaleY,
                cx: intrinsics.columns.2.x * scaleX,
                cy: intrinsics.columns.2.y * scaleY,
                view: StoredKeyframe.pack(view),
                transform: StoredKeyframe.pack(transform),
                camera: [camera.x, camera.y, camera.z],
                meanRed: means.x,
                meanGreen: means.y,
                meanBlue: means.z,
                blur: blur
            )
            self.lock.lock()
            self.frames.append(record)
            let snapshot = self.frames
            self.lock.unlock()
            try? KeyframeArchive.writeManifest(snapshot, to: folder)
            _ = maxRange
        }
    }

    /// Gives the caller the folder of frames written so far and starts a fresh one.
    func handoff() -> URL? {
        queue.sync {}
        lock.lock()
        let folder = directory
        let count = frames.count
        frames.removeAll()
        lastAccepted = 0
        hasPose = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)", isDirectory: true)
        let created = directory
        lock.unlock()
        try? FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        return count > 0 ? folder : nil
    }

    func consumeTooFast() -> Bool {
        lock.lock()
        let value = movingTooFast
        movingTooFast = false
        lock.unlock()
        return value
    }

    private static func position(_ transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private static func angle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let forwardA = SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        let forwardB = SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        let dot = min(1, max(-1, simd_dot(simd_normalize(forwardA), simd_normalize(forwardB))))
        return acos(dot)
    }

    private static func blurScore(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 8, height > 8 else { return 0 }
        let yBase: UnsafePointer<UInt8>
        let stride: Int
        if CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            yBase = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            yBase = UnsafePointer(base.assumingMemoryBound(to: UInt8.self))
            stride = CVPixelBufferGetBytesPerRow(buffer)
        } else {
            return 0
        }
        let stepX = max(1, width / 160)
        let stepY = max(1, height / 120)
        var sum: Float = 0
        var sumSquares: Float = 0
        var count: Float = 0
        var y = stepY
        while y < height - stepY {
            var x = stepX
            while x < width - stepX {
                let center = Float(yBase[y * stride + x])
                let lap = Float(yBase[(y - stepY) * stride + x])
                    + Float(yBase[(y + stepY) * stride + x])
                    + Float(yBase[y * stride + (x - stepX)])
                    + Float(yBase[y * stride + (x + stepX)])
                    - 4 * center
                sum += lap
                sumSquares += lap * lap
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 10 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    private static func means(_ image: RGBAImage) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        var count: Float = 0
        let step = max(1, (image.width * image.height) / 4000)
        var index = 0
        while index < image.width * image.height {
            let pixel = index * 4
            if pixel + 2 < image.rgba.count {
                sum += SIMD3(Float(image.rgba[pixel]), Float(image.rgba[pixel + 1]), Float(image.rgba[pixel + 2]))
                count += 1
            }
            index += step
        }
        guard count > 0 else { return SIMD3(repeating: 128) }
        return sum / count
    }

    private static func copyConfidence(_ map: CVPixelBuffer, width: Int, height: Int, sourceWidth: Int, sourceHeight: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(map)
        let mapWidth = CVPixelBufferGetWidth(map)
        let mapHeight = CVPixelBufferGetHeight(map)
        var values = [UInt8](repeating: 0, count: width * height)
        let depthWidth = max(sourceWidth, 1)
        let depthHeight = max(sourceHeight, 1)
        for y in 0..<height {
            let sy = min(mapHeight - 1, y * depthHeight / max(height, 1) * mapHeight / max(depthHeight, 1))
            for x in 0..<width {
                let sx = min(mapWidth - 1, x * depthWidth / max(width, 1) * mapWidth / max(depthWidth, 1))
                values[y * width + x] = pointer[sy * stride + sx]
            }
        }
        return values
    }
}

enum PixelBufferCopy {
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &destination)
        guard status == kCVReturnSuccess, let destination else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let rows = height
            let sourceStride = CVPixelBufferGetBytesPerRow(source)
            let destStride = CVPixelBufferGetBytesPerRow(destination)
            let count = min(sourceStride, destStride)
            for row in 0..<rows {
                memcpy(to.advanced(by: row * destStride), from.advanced(by: row * sourceStride), count)
            }
            return destination
        }
        for plane in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let count = min(sourceStride, destStride)
            for row in 0..<rows {
                memcpy(to.advanced(by: row * destStride), from.advanced(by: row * sourceStride), count)
            }
        }
        return destination
    }
}
