import UIKit
import simd

enum ScanProcessor {
    static func run(
        directory: URL,
        mesh: ScanMesh,
        settings: FusionSettings,
        objectCenter: SIMD3<Float>?,
        objectRadius: Float,
        signal: WorkSignal?,
        progress: ((Double, String) -> Void)?
    ) -> (mesh: ScanMesh, texture: UIImage?) {
        progress?(0.02, L10n.qualityWorkingMesh)
        var frames: [StoredKeyframe] = []
        if let loaded = try? KeyframeArchive.readManifest(in: directory) {
            frames = loaded
        }
        var working = mesh
        if settings.fuse, !frames.isEmpty {
            let fused = TSDFFusion.fuse(
                directory: directory,
                frames: frames,
                settings: settings,
                objectCenter: objectCenter,
                objectRadius: objectRadius,
                signal: signal
            ) { fraction in
                progress?(0.05 + 0.45 * fraction, L10n.qualityWorkingMesh)
            }
            if fused.triangleCount > 30 {
                working = fused
            }
        }
        if signal?.isCancelled == true { return (working, nil) }
        progress?(0.52, L10n.qualityWorkingClean)
        working = working.removingSmallComponents(minimumAreaFraction: 0.008)
        if settings.smoothIterations > 0 {
            working = working.taubinSmoothed(iterations: settings.smoothIterations)
        }
        working = working.simplified(targetTriangles: settings.targetTriangles)
        working.recomputeNormals()
        if signal?.isCancelled == true || frames.isEmpty { return (working, nil) }
        progress?(0.62, L10n.qualityWorkingTexture)
        guard let textured = AtlasTexturer.texture(
            mesh: working,
            directory: directory,
            frames: frames,
            settings: settings,
            signal: signal,
            progress: { fraction in
                progress?(0.62 + 0.36 * fraction, L10n.qualityWorkingTexture)
            }
        ) else {
            return (working, nil)
        }
        return (textured.mesh, textured.image)
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
