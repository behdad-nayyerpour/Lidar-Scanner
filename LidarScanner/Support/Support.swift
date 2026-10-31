import Foundation
import simd
import UIKit
import os

enum Log {
    static let scan = Logger(subsystem: "com.example.lidarscanner", category: "scan")
    static let photo = Logger(subsystem: "com.example.lidarscanner", category: "photo")
    static let export = Logger(subsystem: "com.example.lidarscanner", category: "export")
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

enum ScanError: LocalizedError {
    case emptyMesh
    case unreadableMesh
    case exportFailed(String)
    case reconstructionFailed(String)
    case noImages
    case notEnoughGeometry
    case processingRemovedMesh
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .emptyMesh:
            return L10n.scanNotEnoughBody
        case .unreadableMesh:
            return L10n.viewerProcessUnavailable
        case .exportFailed(let message):
            return message
        case .reconstructionFailed(let message):
            return message
        case .noImages:
            return L10n.reconMissing
        case .notEnoughGeometry:
            return L10n.scanNotEnoughBody
        case .processingRemovedMesh:
            return L10n.processEmpty
        case .fileMissing:
            return L10n.exportFailed
        }
    }
}

struct AABB: Sendable, Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> { max - min }
    var center: SIMD3<Float> { (min + max) * 0.5 }
    var isValid: Bool { min.x <= max.x && min.y <= max.y && min.z <= max.z }

    func contains(_ p: SIMD3<Float>) -> Bool {
        p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x <= max.x && p.y <= max.y && p.z <= max.z
    }
}

enum Packed {
    static func float3Data(_ values: [SIMD3<Float>]) -> Data {
        var data = Data(count: values.count * 12)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = base
            for value in values {
                cursor.storeBytes(of: value.x, as: Float.self)
                cursor = cursor.advanced(by: 4)
                cursor.storeBytes(of: value.y, as: Float.self)
                cursor = cursor.advanced(by: 4)
                cursor.storeBytes(of: value.z, as: Float.self)
                cursor = cursor.advanced(by: 4)
            }
        }
        return data
    }

    static func float2Data(_ values: [SIMD2<Float>]) -> Data {
        var data = Data(count: values.count * 8)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = base
            for value in values {
                cursor.storeBytes(of: value.x, as: Float.self)
                cursor = cursor.advanced(by: 4)
                cursor.storeBytes(of: value.y, as: Float.self)
                cursor = cursor.advanced(by: 4)
            }
        }
        return data
    }

    static func indexData(_ indices: [UInt32]) -> Data {
        indices.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

enum MeasurementUnit: String, CaseIterable, Identifiable {
    case meters
    case centimeters
    case feet
    case inches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meters: return L10n.unitMeters
        case .centimeters: return L10n.unitCentimeters
        case .feet: return L10n.unitFeet
        case .inches: return L10n.unitInches
        }
    }

    func formatDistance(_ meters: Float) -> String {
        switch self {
        case .meters:
            return String(format: "%.2f m", meters)
        case .centimeters:
            return String(format: "%.1f cm", meters * 100)
        case .feet:
            return String(format: "%.2f ft", meters * 3.2808399)
        case .inches:
            return String(format: "%.1f in", meters * 39.3700787)
        }
    }

    func formatVolume(_ cubicMeters: Float) -> String {
        switch self {
        case .meters, .centimeters:
            return String(format: "%.3f m³", cubicMeters)
        case .feet, .inches:
            return String(format: "%.2f ft³", cubicMeters * 35.3146667)
        }
    }

    func formatArea(_ squareMeters: Float) -> String {
        switch self {
        case .meters, .centimeters:
            return String(format: "%.2f m²", squareMeters)
        case .feet, .inches:
            return String(format: "%.1f ft²", squareMeters * 10.7639104)
        }
    }

    func formatSize(_ meters: SIMD3<Float>) -> String {
        let x = formatDistance(meters.x)
        let y = formatDistance(meters.y)
        let z = formatDistance(meters.z)
        return "\(x) × \(y) × \(z)"
    }
}

enum ZipWriter {
    static func store(files: [(String, Data)]) throws -> Data {
        var locals = Data()
        var central = Data()
        var entries: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []

        for file in files {
            let name = Data(file.0.utf8)
            let crc = crc32(file.1)
            let size = UInt32(file.1.count)
            let offset = UInt32(locals.count)
            entries.append((name, crc, size, offset))

            locals.appendLE(UInt32(0x04034b50))
            locals.appendLE(UInt16(20))
            locals.appendLE(UInt16(0))
            locals.appendLE(UInt16(0))
            locals.appendLE(UInt16(0))
            locals.appendLE(UInt16(0))
            locals.appendLE(crc)
            locals.appendLE(size)
            locals.appendLE(size)
            locals.appendLE(UInt16(name.count))
            locals.appendLE(UInt16(0))
            locals.append(name)
            locals.append(file.1)
        }

        let centralStart = UInt32(locals.count)
        for entry in entries {
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(entry.crc)
            central.appendLE(entry.size)
            central.appendLE(entry.size)
            central.appendLE(UInt16(entry.name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(entry.offset)
            central.append(entry.name)
        }

        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(entries.count))
        eocd.appendLE(UInt16(entries.count))
        eocd.appendLE(UInt32(central.count))
        eocd.appendLE(centralStart)
        eocd.appendLE(UInt16(0))

        var archive = Data()
        archive.append(locals)
        archive.append(central)
        archive.append(eocd)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var c = UInt32(index)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

enum FileNames {
    static func safe(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "scan" : String(cleaned.prefix(80))
    }
}
