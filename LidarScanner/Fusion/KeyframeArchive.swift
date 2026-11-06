import Foundation
import simd
import UIKit

struct StoredKeyframe: Codable, Equatable {
    var index: Int
    var timestamp: Double
    var width: Int
    var height: Int
    var depthWidth: Int
    var depthHeight: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var view: [Float]
    var transform: [Float]
    var camera: [Float]
    var meanRed: Float
    var meanGreen: Float
    var meanBlue: Float
    var blur: Float

    var viewMatrix: simd_float4x4 { Self.matrix(view) }
    /// Inverse of the landscapeRight view matrix. `transform` is the device-orientation pose and is not the inverse of that view when the phone is portrait, so geometry must not use it.
    var cameraToWorld: simd_float4x4 { simd_inverse(viewMatrix) }
    var cameraPosition: SIMD3<Float> {
        let column = cameraToWorld.columns.3
        return SIMD3(column.x, column.y, column.z)
    }

    static func matrix(_ values: [Float]) -> simd_float4x4 {
        var columns: [SIMD4<Float>] = []
        for column in 0..<4 {
            let base = column * 4
            guard base + 3 < values.count else { return matrix_identity_float4x4 }
            columns.append(SIMD4(values[base], values[base + 1], values[base + 2], values[base + 3]))
        }
        return simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }

    static func pack(_ matrix: simd_float4x4) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(16)
        for column in 0..<4 {
            for row in 0..<4 {
                values.append(matrix[column][row])
            }
        }
        return values
    }
}

struct KeyframeManifest: Codable {
    var frames: [StoredKeyframe]
}

enum KeyframeArchive {
    static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    static func colorURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent("color", isDirectory: true).appendingPathComponent(fileName(index, "jpg"))
    }

    static func depthURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent("depth", isDirectory: true).appendingPathComponent(fileName(index, "bin"))
    }

    static func writeManifest(_ frames: [StoredKeyframe], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(KeyframeManifest(frames: frames))
        try data.write(to: manifestURL(in: directory), options: .atomic)
    }

    static func readManifest(in directory: URL) throws -> [StoredKeyframe] {
        let data = try Data(contentsOf: manifestURL(in: directory))
        let frames = try JSONCoding.decoder.decode(KeyframeManifest.self, from: data).frames
        // Old recorder versions could reuse an index while the image writer was busy.
        // The file belongs to the last writer, so keep only that writer's camera pose.
        var latest: [Int: StoredKeyframe] = [:]
        for frame in frames { latest[frame.index] = frame }
        return latest.values.sorted { $0.timestamp < $1.timestamp }
    }

    static func writeDepth(_ depth: DepthImage, confidence: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        data.append(contentsOf: [0x4C, 0x44, 0x50, 0x48])
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(depth.width))
        data.appendLE(UInt16(depth.height))
        for value in depth.values {
            data.appendLE(value.bitPattern)
        }
        let count = depth.width * depth.height
        if confidence.count >= count {
            data.append(contentsOf: confidence.prefix(count))
        } else {
            data.append(contentsOf: [UInt8](repeating: 2, count: count))
        }
        try data.write(to: url, options: .atomic)
    }

    static func readDepth(at url: URL) throws -> (DepthImage, [UInt8]) {
        let data = try Data(contentsOf: url)
        guard data.count >= 10, data[0] == 0x4C, data[1] == 0x44, data[2] == 0x50, data[3] == 0x48 else {
            throw ScanError.unreadableMesh
        }
        var cursor = 4
        let version = try readUInt16(data, &cursor)
        guard version == 1 else { throw ScanError.unreadableMesh }
        let width = Int(try readUInt16(data, &cursor))
        let height = Int(try readUInt16(data, &cursor))
        let count = width * height
        guard width > 0, height > 0, cursor + count * 4 <= data.count else { throw ScanError.unreadableMesh }
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readFloat(data, &cursor))
        }
        var confidence = [UInt8](repeating: 2, count: count)
        if cursor + count <= data.count {
            confidence = [UInt8](data[cursor..<(cursor + count)])
        }
        return (DepthImage(values: values, width: width, height: height), confidence)
    }

    /// JPEG bytes for an image whose first row is the top of the sensor picture (v = 0).
    static func jpegData(_ image: RGBAImage, quality: CGFloat = 0.82) -> Data? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    static func loadColor(in directory: URL, frame: StoredKeyframe, maxDimension: Int) -> RGBAImage? {
        let url = colorURL(in: directory, index: frame.index)
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else { return nil }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }
        let scale = min(1, Float(maxDimension) / Float(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Float(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: info.rawValue
        ) else { return nil }
        // Row 0 of this buffer is the top of the JPEG, which is camera v = 0. Do not flip it.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = Float(width) / Float(frame.width)
        let scaleY = Float(height) / Float(frame.height)
        return RGBAImage(rgba: rgba, width: width, height: height, exposureScale: 1, fx: frame.fx * scaleX, fy: frame.fy * scaleY, cx: frame.cx * scaleX, cy: frame.cy * scaleY)
    }

    static func allDataZip(in directory: URL) throws -> Data {
        let frames = try readManifest(in: directory)
        var files: [(String, Data)] = []
        if let manifest = try? Data(contentsOf: manifestURL(in: directory)) {
            files.append(("manifest.json", manifest))
        }
        for frame in frames {
            let color = colorURL(in: directory, index: frame.index)
            if let data = try? Data(contentsOf: color) {
                files.append(("color/\(fileName(frame.index, "jpg"))", data))
            }
            let depthURL = depthURL(in: directory, index: frame.index)
            if let (depth, confidence) = try? readDepth(at: depthURL) {
                if let png = png16(depth) {
                    files.append(("depth/\(fileName(frame.index, "png"))", png))
                }
                if let png = png8(confidence, width: depth.width, height: depth.height) {
                    files.append(("confidence/\(fileName(frame.index, "png"))", png))
                }
            }
        }
        guard !files.isEmpty else { throw ScanError.fileMissing }
        return try ZipWriter.store(files: files)
    }

    private static func fileName(_ index: Int, _ ext: String) -> String {
        String(format: "%06d.%@", index, ext)
    }

    private static func png16(_ depth: DepthImage) -> Data? {
        var pixels = [UInt16](repeating: 0, count: depth.values.count)
        for (index, value) in depth.values.enumerated() where value.isFinite && value > 0 {
            pixels[index] = UInt16(min(65535, max(0, value * 1000)).rounded())
        }
        return pixels.withUnsafeBytes { raw in
            guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
            let info = CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
            guard let image = CGImage(
                width: depth.width,
                height: depth.height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: depth.width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: info,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { return nil }
            return UIImage(cgImage: image).pngData()
        }
    }

    private static func png8(_ values: [UInt8], width: Int, height: Int) -> Data? {
        guard values.count >= width * height else { return nil }
        let scaled = values.prefix(width * height).map { pixel -> UInt8 in
            pixel >= 2 ? 255 : (pixel == 1 ? 160 : 40)
        }
        return scaled.withUnsafeBytes { raw in
            guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
            guard let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else { return nil }
            return UIImage(cgImage: image).pngData()
        }
    }
}

private func cgImage(from image: RGBAImage) -> CGImage? {
    let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    let data = Data(image.rgba) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

private func readUInt16(_ data: Data, _ cursor: inout Int) throws -> UInt16 {
    guard cursor + 2 <= data.count else { throw ScanError.unreadableMesh }
    let value = data.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self)
    }
    cursor += 2
    return UInt16(littleEndian: value)
}

private func readFloat(_ data: Data, _ cursor: inout Int) throws -> Float {
    guard cursor + 4 <= data.count else { throw ScanError.unreadableMesh }
    let bits = data.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
    }
    cursor += 4
    return Float(bitPattern: UInt32(littleEndian: bits))
}
