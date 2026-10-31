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
        if !fuse { return L10n.qualityEstimateFast }
        if voxelMillimeters <= 6 { return L10n.qualityEstimateHD }
        return L10n.qualityEstimateBalanced
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
        targetTriangles: 180_000,
        textureSize: 2048,
        fuse: true
    )

    static let hd = FusionSettings(
        preset: "hd",
        voxelMillimeters: 5,
        maxRange: 3,
        minConfidence: 2,
        smoothIterations: 6,
        targetTriangles: 320_000,
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
