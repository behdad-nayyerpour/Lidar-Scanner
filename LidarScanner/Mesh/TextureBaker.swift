import CoreGraphics
import simd
import UIKit

struct BakedTexture: Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    var rgba: [UInt8]
    var size: Int

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    func cgImage() -> CGImage? {
        guard size > 0, rgba.count >= size * size * 4 else { return nil }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

enum TextureBaker {
    /// Packs each triangle into its own atlas cell and bakes vertex colors into that cell.
    /// UVs use the SceneKit / OBJ convention: V = 0 at the bottom of the image.
    static func bake(_ mesh: ScanMesh) -> BakedTexture? {
        let faceCount = mesh.triangleCount
        guard faceCount > 0, let layout = layout(for: faceCount) else { return nil }

        let size = layout.size
        let cell = layout.cell
        let cols = layout.cols
        let step = cell + 2
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(faceCount * 3)
        normals.reserveCapacity(faceCount * 3)
        uvs.reserveCapacity(faceCount * 3)
        indices.reserveCapacity(faceCount * 3)

        for triangle in 0..<faceCount {
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { continue }

            let column = triangle % cols
            let row = triangle / cols
            let originX = column * step
            let originY = row * step
            guard originX + step <= size, originY + step <= size else { continue }

            let p0 = SIMD2<Float>(Float(originX + 1), Float(originY + 1))
            let p1 = SIMD2<Float>(Float(originX + cell), Float(originY + 1))
            let p2 = SIMD2<Float>(Float(originX + 1), Float(originY + cell))
            let c0 = color(mesh, i0)
            let c1 = color(mesh, i1)
            let c2 = color(mesh, i2)
            rasterize(p0, c0, p1, c1, p2, c2, tileX: originX, tileY: originY, tileSize: step, size: size, rgba: &rgba)
            seed(SIMD2(Float(originX + cell / 2), Float(originY + cell / 2)), color: (c0 + c1 + c2) / 3, size: size, rgba: &rgba)
            dilate(tileX: originX, tileY: originY, tileSize: step, size: size, rgba: &rgba)

            let base = UInt32(positions.count)
            let corners = [i0, i1, i2]
            let pixels = [p0, p1, p2]
            for corner in 0..<3 {
                let vertex = corners[corner]
                positions.append(mesh.positions[vertex])
                normals.append(vertex < mesh.normals.count ? mesh.normals[vertex] : SIMD3<Float>(0, 1, 0))
                let pixel = pixels[corner]
                uvs.append(SIMD2((pixel.x + 0.5) / Float(size), 1 - (pixel.y + 0.5) / Float(size)))
            }
            indices.append(contentsOf: [base, base + 1, base + 2])
        }

        guard !indices.isEmpty else { return nil }
        return BakedTexture(positions: positions, normals: normals, uvs: uvs, indices: indices, rgba: rgba, size: size)
    }

    private static func color(_ mesh: ScanMesh, _ index: Int) -> SIMD3<Float> {
        guard index < mesh.colors.count else { return SIMD3(repeating: 0.72) }
        return simd_clamp(mesh.colors[index], .zero, SIMD3(repeating: 1))
    }

    private static func layout(for faceCount: Int) -> (size: Int, cell: Int, cols: Int)? {
        var best: (size: Int, cell: Int, cols: Int, score: Int)?
        for size in [1024, 2048, 4096] {
            for cell in [8, 6, 4, 3, 2] {
                let cols = size / (cell + 2)
                guard cols > 0, cols * cols >= faceCount else { continue }
                let score = cell * 10_000 - size
                if best == nil || score > best!.score {
                    best = (size, cell, cols, score)
                }
            }
        }
        return best.map { ($0.size, $0.cell, $0.cols) }
    }

    private static func rasterize(
        _ p0: SIMD2<Float>, _ c0: SIMD3<Float>,
        _ p1: SIMD2<Float>, _ c1: SIMD3<Float>,
        _ p2: SIMD2<Float>, _ c2: SIMD3<Float>,
        tileX: Int, tileY: Int, tileSize: Int, size: Int, rgba: inout [UInt8]
    ) {
        let area = edge(p0, p1, p2)
        guard abs(area) > 1e-4 else { return }
        let minX = max(tileX, Int(floor(min(p0.x, min(p1.x, p2.x)))))
        let maxX = min(tileX + tileSize - 1, Int(ceil(max(p0.x, max(p1.x, p2.x)))))
        let minY = max(tileY, Int(floor(min(p0.y, min(p1.y, p2.y)))))
        let maxY = min(tileY + tileSize - 1, Int(ceil(max(p0.y, max(p1.y, p2.y)))))
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let point = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(p1, p2, point)
                let w1 = edge(p2, p0, point)
                let w2 = edge(p0, p1, point)
                let inside = (w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0)
                guard inside else { continue }
                let color = c0 * (w0 / area) + c1 * (w1 / area) + c2 * (w2 / area)
                write(x, y, color, size: size, rgba: &rgba)
            }
        }
    }

    private static func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)
    }

    private static func seed(_ pixel: SIMD2<Float>, color: SIMD3<Float>, size: Int, rgba: inout [UInt8]) {
        let x = min(size - 1, max(0, Int(pixel.x)))
        let y = min(size - 1, max(0, Int(pixel.y)))
        write(x, y, color, size: size, rgba: &rgba)
    }

    private static func dilate(tileX: Int, tileY: Int, tileSize: Int, size: Int, rgba: inout [UInt8]) {
        let maxX = min(size - 1, tileX + tileSize - 1)
        let maxY = min(size - 1, tileY + tileSize - 1)
        for _ in 0..<2 {
            var copy = rgba
            for y in tileY...maxY {
                for x in tileX...maxX {
                    let index = (y * size + x) * 4
                    guard rgba[index + 3] == 0 else { continue }
                    let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    for (nx, ny) in neighbors where nx >= tileX && ny >= tileY && nx <= maxX && ny <= maxY {
                        let source = (ny * size + nx) * 4
                        if rgba[source + 3] != 0 {
                            copy[index] = rgba[source]
                            copy[index + 1] = rgba[source + 1]
                            copy[index + 2] = rgba[source + 2]
                            copy[index + 3] = 255
                            break
                        }
                    }
                }
            }
            rgba = copy
        }
    }

    private static func write(_ x: Int, _ y: Int, _ color: SIMD3<Float>, size: Int, rgba: inout [UInt8]) {
        guard x >= 0, y >= 0, x < size, y < size else { return }
        let index = (y * size + x) * 4
        rgba[index] = UInt8((min(1, max(0, color.x)) * 255).rounded())
        rgba[index + 1] = UInt8((min(1, max(0, color.y)) * 255).rounded())
        rgba[index + 2] = UInt8((min(1, max(0, color.z)) * 255).rounded())
        rgba[index + 3] = 255
    }
}
