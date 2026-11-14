import UIKit
import simd

/// Image rows are top-down. Stored surface/OBJ UVs are bottom-up; conversion lives here and in Packed.
struct AtlasImage {
    let width: Int
    let height: Int
    var rgba: [UInt8]
    var covered: [Bool]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        rgba = Array(repeating: 184, count: width * height * 4)
        covered = Array(repeating: false, count: width * height)
        for i in 0..<(width * height) { rgba[i * 4 + 3] = 255 }
    }

    mutating func set(_ x: Int, _ y: Int, _ color: SIMD3<Float>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * width + x
        for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, max(0, color[c] * 255)).rounded()) }
        covered[i] = true
    }

    func sample(_ uv: SIMD2<Float>) -> SIMD3<Float>? {
        let x = min(width - 1, max(0, Int(floor(uv.x * Float(width)))))
        let y = min(height - 1, max(0, Int(floor((1 - uv.y) * Float(height)))))
        return get(x, y)
    }

    func get(_ x: Int, _ y: Int) -> SIMD3<Float>? {
        guard x >= 0, y >= 0, x < width, y < height, covered[y * width + x] else { return nil }
        let i = (y * width + x) * 4
        return SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255
    }

    /// Extend only into chart gutters. An unseen point on actual geometry remains explicitly neutral.
    mutating func padGutters(occupied: [Bool], passes: Int) {
        guard occupied.count == covered.count else { return }
        for _ in 0..<passes {
            var next = self
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    if occupied[i] || covered[i] { continue }
                    var sum = SIMD3<Float>.zero
                    var count: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if let c = get(x + dx, y + dy) { sum += c; count += 1 }
                        }
                    }
                    if count > 0 { next.set(x, y, sum / count) }
                }
            }
            self = next
        }
    }

    func uiImage() -> UIImage? {
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
