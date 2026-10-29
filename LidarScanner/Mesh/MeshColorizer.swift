import Foundation
import simd

enum MeshColorizer {
    static func colorize(_ mesh: inout ScanMesh, keyframes: [ColorKeyframe], progress: ((Double) -> Void)? = nil) {
        let count = mesh.positions.count
        if mesh.colors.count != count {
            mesh.colors = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0.72), count: count)
        }
        guard !keyframes.isEmpty, count > 0 else {
            progress?(1)
            return
        }
        if mesh.normals.count != count {
            mesh.recomputeNormals()
        }

        for index in 0..<count {
            let position = mesh.positions[index]
            let normal = mesh.normals[index]
            var best: [(Float, SIMD3<Float>)] = []
            best.reserveCapacity(3)
            for frame in keyframes {
                guard let sample = frame.sample(world: position, normal: normal) else { continue }
                if best.count < 3 {
                    best.append(sample)
                    best.sort { $0.0 > $1.0 }
                } else if sample.0 > best[2].0 {
                    best[2] = sample
                    best.sort { $0.0 > $1.0 }
                }
            }
            if !best.isEmpty {
                var color = SIMD3<Float>.zero
                var weight: Float = 0
                for sample in best {
                    let sampleWeight = max(sample.0, 0.001)
                    color += sample.1 * sampleWeight
                    weight += sampleWeight
                }
                mesh.colors[index] = color / weight
            }
            if index % 8192 == 0 {
                progress?(Double(index) / Double(count))
            }
        }
        progress?(1)
    }
}
