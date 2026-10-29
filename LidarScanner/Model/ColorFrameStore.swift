import Foundation
import simd

enum ColorFrameStore {
    static let maxFrames = 24
    static let maxDimension = 320
    static let maxBytes = 14_000_000
    private static let magic: UInt32 = 0x4643534C // "LSCF" little endian bytes L S C F if we write ASCII... we'll write the four chars explicitly.

    static func write(_ frames: [ColorKeyframe], to url: URL) throws {
        var prepared = frames.prefix(maxFrames).map { downsample($0, maxDimension: maxDimension) }
        while totalBytes(prepared) > maxBytes, prepared.count > 1 {
            prepared.removeLast()
        }
        guard !prepared.isEmpty, totalBytes(prepared) <= maxBytes else { return }

        var data = Data()
        data.append(contentsOf: [0x4C, 0x53, 0x43, 0x46]) // LSCF
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(prepared.count))
        for frame in prepared {
            guard frame.width > 0, frame.height > 0, frame.width <= 512, frame.height <= 512 else { continue }
            let expected = frame.width * frame.height * 4
            guard frame.rgba.count >= expected else { continue }
            data.appendLE(UInt16(frame.width))
            data.appendLE(UInt16(frame.height))
            data.appendLE(UInt16(frame.depthWidth))
            data.appendLE(UInt16(frame.depthHeight))
            data.append(frame.cameraPosition)
            append(frame.viewMatrix, to: &data)
            append(frame.intrinsics, to: &data)
            data.appendLE(frame.exposureScale.bitPattern)
            data.append(contentsOf: frame.rgba.prefix(expected))
            let depthCount = frame.depthWidth * frame.depthHeight
            if depthCount > 0, frame.depth.count >= depthCount {
                for value in frame.depth.prefix(depthCount) {
                    data.appendLE(value.bitPattern)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [ColorKeyframe] {
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else { throw ScanError.unreadableMesh }
        guard data[0] == 0x4C, data[1] == 0x53, data[2] == 0x43, data[3] == 0x46 else { throw ScanError.unreadableMesh }
        var cursor = 4
        let version = try data.readUInt16(&cursor)
        guard version == 1 || version == 2 else { throw ScanError.unreadableMesh }
        let count = Int(try data.readUInt16(&cursor))
        guard count >= 0, count <= maxFrames else { throw ScanError.unreadableMesh }
        var frames: [ColorKeyframe] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            let width = Int(try data.readUInt16(&cursor))
            let height = Int(try data.readUInt16(&cursor))
            guard width > 0, height > 0, width <= 512, height <= 512 else { throw ScanError.unreadableMesh }
            var depthWidth = 0
            var depthHeight = 0
            if version == 2 {
                depthWidth = Int(try data.readUInt16(&cursor))
                depthHeight = Int(try data.readUInt16(&cursor))
                guard depthWidth >= 0, depthHeight >= 0, depthWidth <= 512, depthHeight <= 512 else { throw ScanError.unreadableMesh }
            }
            let camera = try data.readFloat3(&cursor)
            let view = try readMatrix4(&cursor, data)
            let intrinsics = try readMatrix3(&cursor, data)
            let exposure: Float
            if version == 2 {
                exposure = try data.readFloat(cursor: &cursor)
            } else {
                exposure = 1
            }
            let byteCount = width * height * 4
            guard cursor + byteCount <= data.count else { throw ScanError.unreadableMesh }
            let rgba = [UInt8](data[cursor..<(cursor + byteCount)])
            cursor += byteCount
            var depth: [Float] = []
            let depthCount = depthWidth * depthHeight
            if depthCount > 0 {
                guard cursor + depthCount * 4 <= data.count else { throw ScanError.unreadableMesh }
                depth.reserveCapacity(depthCount)
                for _ in 0..<depthCount {
                    depth.append(try data.readFloat(cursor: &cursor))
                }
            }
            frames.append(ColorKeyframe(
                rgba: rgba,
                width: width,
                height: height,
                viewMatrix: view,
                intrinsics: intrinsics,
                cameraPosition: camera,
                depth: depth,
                depthWidth: depthWidth,
                depthHeight: depthHeight,
                exposureScale: exposure.isFinite ? exposure : 1
            ))
        }
        return frames
    }

    static func downsample(_ frame: ColorKeyframe, maxDimension: Int) -> ColorKeyframe {
        let longest = max(frame.width, frame.height)
        guard longest > maxDimension, frame.width > 0, frame.height > 0 else { return frame }
        let scale = Float(maxDimension) / Float(longest)
        let width = max(1, Int((Float(frame.width) * scale).rounded()))
        let height = max(1, Int((Float(frame.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let sourceY = min(frame.height - 1, y * frame.height / height)
            for x in 0..<width {
                let sourceX = min(frame.width - 1, x * frame.width / width)
                let source = (sourceY * frame.width + sourceX) * 4
                let dest = (y * width + x) * 4
                guard source + 2 < frame.rgba.count else { continue }
                rgba[dest] = frame.rgba[source]
                rgba[dest + 1] = frame.rgba[source + 1]
                rgba[dest + 2] = frame.rgba[source + 2]
                rgba[dest + 3] = 255
            }
        }
        let scaleX = Float(width) / Float(frame.width)
        let scaleY = Float(height) / Float(frame.height)
        var intrinsics = frame.intrinsics
        intrinsics.columns.0.x *= scaleX
        intrinsics.columns.1.y *= scaleY
        intrinsics.columns.2.x *= scaleX
        intrinsics.columns.2.y *= scaleY
        return ColorKeyframe(
            rgba: rgba,
            width: width,
            height: height,
            viewMatrix: frame.viewMatrix,
            intrinsics: intrinsics,
            cameraPosition: frame.cameraPosition,
            depth: frame.depth,
            depthWidth: frame.depthWidth,
            depthHeight: frame.depthHeight,
            exposureScale: frame.exposureScale
        )
    }

    private static func totalBytes(_ frames: [ColorKeyframe]) -> Int {
        frames.reduce(0) { $0 + ($1.width * $1.height * 4) }
    }

    private static func append(_ matrix: simd_float4x4, to data: inout Data) {
        for column in 0..<4 {
            for row in 0..<4 {
                data.appendLE(matrix[column][row].bitPattern)
            }
        }
    }

    private static func append(_ matrix: simd_float3x3, to data: inout Data) {
        for column in 0..<3 {
            for row in 0..<3 {
                data.appendLE(matrix[column][row].bitPattern)
            }
        }
    }

    private static func readMatrix4(_ cursor: inout Int, _ data: Data) throws -> simd_float4x4 {
        var columns: [SIMD4<Float>] = []
        for _ in 0..<4 {
            let x = try data.readFloat(cursor: &cursor)
            let y = try data.readFloat(cursor: &cursor)
            let z = try data.readFloat(cursor: &cursor)
            let w = try data.readFloat(cursor: &cursor)
            columns.append(SIMD4(x, y, z, w))
        }
        return simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }

    private static func readMatrix3(_ cursor: inout Int, _ data: Data) throws -> simd_float3x3 {
        var columns: [SIMD3<Float>] = []
        for _ in 0..<3 {
            let x = try data.readFloat(cursor: &cursor)
            let y = try data.readFloat(cursor: &cursor)
            let z = try data.readFloat(cursor: &cursor)
            columns.append(SIMD3(x, y, z))
        }
        return simd_float3x3(columns: (columns[0], columns[1], columns[2]))
    }
}

final class WorkSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum ScanTiming {
    static func milliseconds(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

private extension Data {
    mutating func append(_ vector: SIMD3<Float>) {
        appendLE(vector.x.bitPattern)
        appendLE(vector.y.bitPattern)
        appendLE(vector.z.bitPattern)
    }

    func readUInt16(_ cursor: inout Int) throws -> UInt16 {
        guard cursor + 2 <= count else { throw ScanError.unreadableMesh }
        let value = withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt16.self)
        }
        cursor += 2
        return UInt16(littleEndian: value)
    }

    func readFloat(cursor: inout Int) throws -> Float {
        guard cursor + 4 <= count else { throw ScanError.unreadableMesh }
        let bits = withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        }
        cursor += 4
        return Float(bitPattern: UInt32(littleEndian: bits))
    }

    func readFloat3(_ cursor: inout Int) throws -> SIMD3<Float> {
        SIMD3(try readFloat(cursor: &cursor), try readFloat(cursor: &cursor), try readFloat(cursor: &cursor))
    }
}
