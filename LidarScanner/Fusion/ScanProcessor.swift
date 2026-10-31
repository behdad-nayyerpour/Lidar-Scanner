import UIKit
import simd

struct BuildResult {
    var mesh: ScanMesh
    var texture: UIImage?
    var notice: String?
    var replacedGeometry: Bool
}

enum ScanProcessor {
    static func run(
        directory: URL,
        reference: ScanMesh,
        settings input: FusionSettings,
        objectCenter: SIMD3<Float>?,
        objectRadius: Float,
        signal: WorkSignal?,
        progress: ((Double, String) -> Void)?
    ) -> BuildResult {
        progress?(0.02, L10n.qualityWorkingMesh)
        var frames: [StoredKeyframe] = []
        if let loaded = try? KeyframeArchive.readManifest(in: directory) {
            frames = loaded
        }
        var settings = input
        var notice: String?
        var working = reference
        var replaced = false
        if settings.fuse, !frames.isEmpty {
            let millimeters = FusionVoxel.millimeters(requested: settings.voxelMillimeters, frames: frames)
            settings.voxelMillimeters = millimeters
            Log.scan.info("fusion voxel mm=\(millimeters, privacy: .public) frames=\(frames.count, privacy: .public)")
            let fused = TSDFFusion.fuse(
                directory: directory,
                frames: frames,
                settings: settings,
                objectCenter: objectCenter,
                objectRadius: objectRadius,
                signal: signal
            ) { fraction in
                progress?(0.04 + 0.40 * fraction, L10n.qualityWorkingMesh)
            }
            let tolerance = max(0.04, settings.voxelSize * 4)
            let coverage = MeshCoverage.fraction(of: reference, near: fused, tolerance: tolerance)
            Log.scan.info("fusion coverage=\(coverage, privacy: .public) triangles=\(fused.triangleCount, privacy: .public)")
            if fused.triangleCount < 30 || coverage < 0.55 {
                notice = L10n.qualityFellBack
                working = reference
            } else {
                working = fused.removingSmallComponents(minimumAreaFraction: 0.008)
                let beforeFill = MeshCoverage.fraction(of: reference, near: working, tolerance: tolerance)
                working = MeshCoverage.fillingGaps(fused: working, reference: reference, tolerance: tolerance)
                if beforeFill < 0.92 {
                    notice = L10n.qualityFilledGaps
                }
                replaced = true
            }
        }
        if signal?.isCancelled == true {
            return BuildResult(mesh: working, texture: nil, notice: nil, replacedGeometry: replaced)
        }
        progress?(0.48, L10n.qualityWorkingClean)
        if replaced {
            if settings.smoothIterations > 0 {
                working = working.taubinSmoothed(iterations: settings.smoothIterations)
            }
            working = working.simplified(targetTriangles: settings.targetTriangles)
            working.recomputeNormals()
        }
        if signal?.isCancelled == true || frames.isEmpty {
            return BuildResult(mesh: working, texture: nil, notice: notice, replacedGeometry: replaced)
        }
        progress?(0.55, L10n.qualityWorkingTexture)
        guard let textured = AtlasTexturer.texture(
            mesh: working,
            directory: directory,
            frames: frames,
            settings: settings,
            signal: signal,
            progress: { fraction in
                progress?(0.55 + 0.43 * fraction, L10n.qualityWorkingTexture)
            }
        ) else {
            return BuildResult(mesh: working, texture: nil, notice: notice, replacedGeometry: replaced)
        }
        return BuildResult(mesh: textured.mesh, texture: textured.image, notice: notice, replacedGeometry: replaced)
    }
}

enum UVFile {
    static func write(_ uvs: [SIMD2<Float>], to url: URL) throws {
        var data = Data()
        data.appendLE(UInt32(uvs.count))
        for uv in uvs {
            data.appendLE(uv.x.bitPattern)
            data.appendLE(uv.y.bitPattern)
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL, expected: Int) -> [SIMD2<Float>]? {
        guard let data = try? Data(contentsOf: url), data.count >= 4 else { return nil }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard count == expected, data.count >= 4 + count * 8 else { return nil }
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(count)
        var cursor = 4
        for _ in 0..<count {
            guard cursor + 8 <= data.count else { return nil }
            let x = data.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))) }
            let y = data.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))) }
            uvs.append(SIMD2(x, y))
            cursor += 8
        }
        return uvs
    }
}
