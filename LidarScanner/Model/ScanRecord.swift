import Foundation
import simd

enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case room
    case objectLidar
    case objectPhoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: return L10n.modeRoomLabel
        case .objectLidar: return L10n.modeObjectLidarLabel
        case .objectPhoto: return L10n.modeObjectPhotoLabel
        }
    }

    var defaultName: String {
        switch self {
        case .room: return L10n.defaultRoomName
        case .objectLidar: return L10n.defaultObjectName
        case .objectPhoto: return L10n.defaultPhotoName
        }
    }
}

enum ScanStatus: String, Codable {
    case ready
    case needsReconstruction
}

struct ScanRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var mode: ScanMode
    var status: ScanStatus
    var vertexCount: Int
    var triangleCount: Int
    var surfaceArea: Double
    var boundsMin: [Float]
    var boundsMax: [Float]
    var isProcessed: Bool
    var reconstructionDetail: String?

    var boundsSize: SIMD3<Float> {
        guard boundsMin.count == 3, boundsMax.count == 3 else { return .zero }
        return SIMD3(
            boundsMax[0] - boundsMin[0],
            boundsMax[1] - boundsMin[1],
            boundsMax[2] - boundsMin[2]
        )
    }
}

struct StoredMeasurement: Codable, Identifiable, Equatable {
    var id: UUID
    var a: [Float]
    var b: [Float]

    var start: SIMD3<Float>? { Self.vector(a) }
    var end: SIMD3<Float>? { Self.vector(b) }

    init(id: UUID = UUID(), start: SIMD3<Float>, end: SIMD3<Float>) {
        self.id = id
        self.a = [start.x, start.y, start.z]
        self.b = [end.x, end.y, end.z]
    }

    private static func vector(_ values: [Float]) -> SIMD3<Float>? {
        guard values.count == 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }
}

struct ScanPaths {
    let directory: URL

    var meta: URL { directory.appendingPathComponent("scan.json") }
    var mesh: URL { directory.appendingPathComponent("mesh.ply") }
    var original: URL { directory.appendingPathComponent("mesh.original.ply") }
    var thumbnail: URL { directory.appendingPathComponent("thumbnail.png") }
    var preview: URL { directory.appendingPathComponent("preview.usdz") }
    var capture: URL { directory.appendingPathComponent("capture.usdz") }
    var measurements: URL { directory.appendingPathComponent("measurements.json") }
    var images: URL { directory.appendingPathComponent("Images", isDirectory: true) }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
