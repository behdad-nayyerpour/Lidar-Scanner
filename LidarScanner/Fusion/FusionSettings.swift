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

    var voxelSize: Float { max(0.004, voxelMillimeters / 1000) }
    var truncation: Float { voxelSize * 3.5 }
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
    /// LiDAR depth is about 256×192, so a pixel at 2.5 m is roughly a centimeter. Voxels finer than that only invent streaks.
    static func millimeters(requested: Float, frames: [StoredKeyframe]) -> Float {
        var footprints: [Float] = []
        for frame in frames where frame.depthWidth > 1 && frame.fx > 1 && frame.width > 1 {
            let fxDepth = frame.fx * Float(frame.depthWidth) / Float(frame.width)
            footprints.append(2.5 / fxDepth * 1000)
        }
        let sorted = footprints.sorted()
        let footprint = sorted.isEmpty ? requested : sorted[sorted.count / 2]
        return min(40, max(requested, footprint, 8))
    }
}
