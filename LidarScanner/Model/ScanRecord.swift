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
    var hasColorFrames: Bool
    var isColored: Bool

    var canAddColor: Bool { hasColorFrames && !isColored }

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        mode: ScanMode,
        status: ScanStatus,
        vertexCount: Int,
        triangleCount: Int,
        surfaceArea: Double,
        boundsMin: [Float],
        boundsMax: [Float],
        isProcessed: Bool,
        reconstructionDetail: String? = nil,
        hasColorFrames: Bool = false,
        isColored: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mode = mode
        self.status = status
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.surfaceArea = surfaceArea
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.isProcessed = isProcessed
        self.reconstructionDetail = reconstructionDetail
        self.hasColorFrames = hasColorFrames
        self.isColored = isColored
    }

    var boundsSize: SIMD3<Float> {
        guard boundsMin.count == 3, boundsMax.count == 3 else { return .zero }
        return SIMD3(
            boundsMax[0] - boundsMin[0],
            boundsMax[1] - boundsMin[1],
            boundsMax[2] - boundsMin[2]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, mode, status
        case vertexCount, triangleCount, surfaceArea, boundsMin, boundsMax
        case isProcessed, reconstructionDetail, hasColorFrames, isColored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        mode = try container.decode(ScanMode.self, forKey: .mode)
        status = try container.decode(ScanStatus.self, forKey: .status)
        vertexCount = try container.decode(Int.self, forKey: .vertexCount)
        triangleCount = try container.decode(Int.self, forKey: .triangleCount)
        surfaceArea = try container.decode(Double.self, forKey: .surfaceArea)
        boundsMin = try container.decode([Float].self, forKey: .boundsMin)
        boundsMax = try container.decode([Float].self, forKey: .boundsMax)
        isProcessed = try container.decode(Bool.self, forKey: .isProcessed)
        reconstructionDetail = try container.decodeIfPresent(String.self, forKey: .reconstructionDetail)
        hasColorFrames = try container.decodeIfPresent(Bool.self, forKey: .hasColorFrames) ?? false
        isColored = try container.decodeIfPresent(Bool.self, forKey: .isColored) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(mode, forKey: .mode)
        try container.encode(status, forKey: .status)
        try container.encode(vertexCount, forKey: .vertexCount)
        try container.encode(triangleCount, forKey: .triangleCount)
        try container.encode(surfaceArea, forKey: .surfaceArea)
        try container.encode(boundsMin, forKey: .boundsMin)
        try container.encode(boundsMax, forKey: .boundsMax)
        try container.encode(isProcessed, forKey: .isProcessed)
        try container.encodeIfPresent(reconstructionDetail, forKey: .reconstructionDetail)
        try container.encode(hasColorFrames, forKey: .hasColorFrames)
        try container.encode(isColored, forKey: .isColored)
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
    var colorFrames: URL { directory.appendingPathComponent("colorframes.bin") }
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
