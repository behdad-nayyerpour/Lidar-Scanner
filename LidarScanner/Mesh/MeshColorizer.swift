import Foundation
import simd

struct ColorizeOutcome: Sendable {
    var partial: Bool
    var coloredVertices: Int
}

enum MeshColorizer {
    /// Colors vertices from the few camera frames that can see each region of the mesh.
    /// Stops if `signal` is cancelled or the time budget runs out, leaving remaining vertices gray.
    static func colorize(
        _ mesh: inout ScanMesh,
        keyframes: [ColorKeyframe],
        signal: WorkSignal?,
        progress: ((Double) -> Void)? = nil
    ) -> ColorizeOutcome {
        let started = CFAbsoluteTimeGetCurrent()
        let count = mesh.positions.count
        if mesh.colors.count != count {
            mesh.colors = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0.72), count: count)
        }
        guard !keyframes.isEmpty, count > 0 else {
            progress?(1)
            Log.scan.info("colorize skipped empty ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
            return ColorizeOutcome(partial: false, coloredVertices: 0)
        }
        if mesh.normals.count != count {
            mesh.recomputeNormals()
        }

        let box = mesh.boundingBox()
        let extent = max(box.size.x, max(box.size.y, box.size.z))
        let cell = max(0.25, extent / 36)
        let origin = box.min
        var buckets: [CellKey: [Int]] = [:]
        buckets.reserveCapacity(min(count, 20_000))
        for index in 0..<count {
            let position = mesh.positions[index]
            let key = CellKey(
                x: Int32(floor((position.x - origin.x) / cell)),
                y: Int32(floor((position.y - origin.y) / cell)),
                z: Int32(floor((position.z - origin.z) / cell))
            )
            buckets[key, default: []].append(index)
        }

        var colored = 0
        var processed = 0
        var lastReport = 0
        var partial = false
        let deadline = started + 45
        for (key, indices) in buckets {
            if signal?.isCancelled == true || CFAbsoluteTimeGetCurrent() > deadline {
                partial = true
                break
            }
            let center = SIMD3<Float>(
                origin.x + (Float(key.x) + 0.5) * cell,
                origin.y + (Float(key.y) + 0.5) * cell,
                origin.z + (Float(key.z) + 0.5) * cell
            )
            let candidates = candidateFrames(for: center, keyframes: keyframes)
            for index in indices {
                if let color = blendedColor(
                    position: mesh.positions[index],
                    normal: mesh.normals[index],
                    candidates: candidates,
                    keyframes: keyframes
                ) {
                    mesh.colors[index] = color
                    colored += 1
                }
                processed += 1
            }
            if processed - lastReport > 12_000 {
                lastReport = processed
                progress?(Double(processed) / Double(count))
            }
        }
        progress?(1)
        Log.scan.info("colorize vertices=\(count, privacy: .public) frames=\(keyframes.count, privacy: .public) cells=\(buckets.count, privacy: .public) colored=\(colored, privacy: .public) partial=\(partial, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
        return ColorizeOutcome(partial: partial, coloredVertices: colored)
    }

    private struct CellKey: Hashable {
        var x: Int32
        var y: Int32
        var z: Int32
    }

    private static func candidateFrames(for center: SIMD3<Float>, keyframes: [ColorKeyframe]) -> [Int] {
        var best: [(Int, Float)] = []
        for (index, frame) in keyframes.enumerated() {
            guard let score = frame.coverageScore(world: center) else { continue }
            if best.count < 3 {
                best.append((index, score))
                best.sort { $0.1 > $1.1 }
            } else if score > best[2].1 {
                best[2] = (index, score)
                best.sort { $0.1 > $1.1 }
            }
        }
        return best.map(\.0)
    }

    private static func blendedColor(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        candidates: [Int],
        keyframes: [ColorKeyframe]
    ) -> SIMD3<Float>? {
        var firstScore: Float = -1
        var firstColor = SIMD3<Float>.zero
        var secondScore: Float = -1
        var secondColor = SIMD3<Float>.zero
        for index in candidates {
            guard let sample = keyframes[index].sample(world: position, normal: normal) else { continue }
            if sample.0 > firstScore {
                secondScore = firstScore
                secondColor = firstColor
                firstScore = sample.0
                firstColor = sample.1
            } else if sample.0 > secondScore {
                secondScore = sample.0
                secondColor = sample.1
            }
        }
        guard firstScore > 0 else { return nil }
        if secondScore > 0 {
            let weight = firstScore + secondScore
            return (firstColor * firstScore + secondColor * secondScore) / weight
        }
        return firstColor
    }
}
