import Foundation

struct FusionSettings: Codable, Equatable {
    var preset: String
    var voxelMillimeters: Float
    var maxRange: Float
    var minConfidence: Int
    var smoothIterations: Int
    var targetTriangles: Int
    var textureSize: Int
    var fuse: Bool

    var voxelSize: Float { max(0.0015, voxelMillimeters / 1000) }
    var truncation: Float { voxelSize * 2.5 }
    var confidenceFloor: Float { Float(min(2, max(0, minConfidence))) }

    var estimate: String {
        switch preset {
        case "fast": return L10n.qualityEstimateFast
        case "hd": return L10n.qualityEstimateHD
        default: return L10n.qualityEstimateBalanced
        }
    }

    static let fast = FusionSettings(
        preset: "fast",
        voxelMillimeters: 20,
        maxRange: 3,
        minConfidence: 2,
        smoothIterations: 1,
        targetTriangles: 120_000,
        textureSize: 2048,
        fuse: false
    )

    static let balanced = FusionSettings(
        preset: "balanced",
        voxelMillimeters: 10,
        maxRange: 3,
        minConfidence: 2,
        smoothIterations: 4,
        targetTriangles: 48_000,
        textureSize: 2048,
        fuse: true
    )

    static let hd = FusionSettings(
        preset: "hd",
        voxelMillimeters: 10,
        maxRange: 3,
        minConfidence: 2,
        smoothIterations: 4,
        targetTriangles: 80_000,
        textureSize: 4096,
        fuse: true
    )

    static func custom(voxelMillimeters: Float, maxRange: Float, minConfidence: Int, smoothIterations: Int, targetTriangles: Int, textureSize: Int) -> FusionSettings {
        FusionSettings(
            preset: "custom",
            voxelMillimeters: voxelMillimeters,
            maxRange: maxRange,
            minConfidence: minConfidence,
            smoothIterations: smoothIterations,
            targetTriangles: targetTriangles,
            textureSize: textureSize,
            fuse: true
        )
    }
}

enum FusionVoxel {
    /// Voxel size follows the depth pixel at the distance actually scanned. A desk at 0.4 m is about 2 mm.
    static func millimeters(requested: Float, frames: [StoredKeyframe], range: Float) -> Float {
        var footprints: [Float] = []
        let distance = min(3, max(0.25, range))
        for frame in frames where frame.depthWidth > 1 && frame.fx > 1 && frame.width > 1 {
            let fxDepth = frame.fx * Float(frame.depthWidth) / Float(frame.width)
            guard fxDepth > 1 else { continue }
            footprints.append(distance / fxDepth * 1000)
        }
        let sorted = footprints.sorted()
        let footprint = sorted.isEmpty ? requested : sorted[sorted.count / 2]
        return min(15, max(1.5, min(requested, footprint)))
    }

    static func medianDepth(directory: URL, frames: [StoredKeyframe]) -> Float {
        var samples: [Float] = []
        let stride = max(1, frames.count / 12)
        for (offset, frame) in frames.enumerated() where offset % stride == 0 && frame.depthWidth > 1 {
            guard let loaded = try? KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: directory, index: frame.index)) else { continue }
            let step = max(1, loaded.0.values.count / 400)
            var index = 0
            while index < loaded.0.values.count {
                let value = loaded.0.values[index]
                if value > 0.2, value < 5 { samples.append(value) }
                index += step
            }
        }
        guard !samples.isEmpty else { return 0.6 }
        samples.sort()
        // The near subject, not the far floor, sets the voxel. A desk at 0.4 m stays near 2 mm.
        return samples[samples.count / 4]
    }

    /// A 2 mm desk must not spend the volume on a floor several meters away.
    static func integrationRange(subject: Float, requested: Float) -> Float {
        min(requested, max(1.2, subject * 3))
    }
}
