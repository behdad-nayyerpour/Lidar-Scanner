import Combine
import Metal
import SceneKit
import UIKit

@MainActor
final class ScanLibrary: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]

    let root: URL
    private let fileManager = FileManager.default

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Scans", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [ScanRecord] = []
        var images: [UUID: UIImage] = [:]
        for folder in folders {
            let paths = ScanPaths(directory: folder)
            guard let data = try? Data(contentsOf: paths.meta),
                  let record = try? JSONCoding.decoder.decode(ScanRecord.self, from: data) else { continue }
            loaded.append(record)
            if let image = UIImage(contentsOfFile: paths.thumbnail.path) {
                images[record.id] = image
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        records = loaded
        thumbnails = images
    }

    func record(_ id: UUID) -> ScanRecord? {
        records.first { $0.id == id }
    }

    func paths(for id: UUID) -> ScanPaths {
        ScanPaths(directory: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func defaultName(for mode: ScanMode, date: Date = Date()) -> String {
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        return "\(mode.defaultName) \(stamp)"
    }

    func rename(_ id: UUID, to name: String) throws {
        guard var record = record(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record.name = trimmed
        record.updatedAt = Date()
        try write(record)
    }

    func delete(_ id: UUID) throws {
        let directory = paths(for: id).directory
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        records.removeAll { $0.id == id }
        thumbnails[id] = nil
    }

    @discardableResult
    func createPhotoPlaceholder(id: UUID) throws -> ScanRecord {
        let paths = paths(for: id)
        try fileManager.createDirectory(at: paths.images, withIntermediateDirectories: true)
        let now = Date()
        let record = ScanRecord(
            id: id,
            name: defaultName(for: .objectPhoto, date: now),
            createdAt: now,
            updatedAt: now,
            mode: .objectPhoto,
            status: .needsReconstruction,
            vertexCount: 0,
            triangleCount: 0,
            surfaceArea: 0,
            boundsMin: [0, 0, 0],
            boundsMax: [0, 0, 0],
            isProcessed: false,
            reconstructionDetail: nil
        )
        try write(record)
        return record
    }

    func saveLiDAR(mesh: ScanMesh, ply: Data, baked: BakedTexture?, mode: ScanMode) throws -> ScanRecord {
        let id = UUID()
        let paths = paths(for: id)
        try fileManager.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try ply.write(to: paths.mesh, options: .atomic)
        try ply.write(to: paths.original, options: .atomic)
        try? MeshExporter.usdz(mesh: mesh, baked: baked, to: paths.preview)
        if let image = ThumbnailRenderer.image(mesh: mesh) {
            try? image.pngData()?.write(to: paths.thumbnail, options: .atomic)
            thumbnails[id] = image
        }
        let now = Date()
        let bounds = mesh.boundingBox()
        let record = ScanRecord(
            id: id,
            name: defaultName(for: mode, date: now),
            createdAt: now,
            updatedAt: now,
            mode: mode,
            status: .ready,
            vertexCount: mesh.positions.count,
            triangleCount: mesh.triangleCount,
            surfaceArea: Double(mesh.surfaceArea()),
            boundsMin: [bounds.min.x, bounds.min.y, bounds.min.z],
            boundsMax: [bounds.max.x, bounds.max.y, bounds.max.z],
            isProcessed: false,
            reconstructionDetail: nil
        )
        try write(record)
        return record
    }

    func completePhoto(id: UUID, mesh: ScanMesh?, detail: String) throws {
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        if let mesh, !mesh.isEmpty {
            let ply = MeshIO.encode(mesh)
            try ply.write(to: paths.mesh, options: .atomic)
            try ply.write(to: paths.original, options: .atomic)
            record.vertexCount = mesh.positions.count
            record.triangleCount = mesh.triangleCount
            record.surfaceArea = Double(mesh.surfaceArea())
            let bounds = mesh.boundingBox()
            record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
            record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
            if let image = ThumbnailRenderer.image(mesh: mesh) {
                try? image.pngData()?.write(to: paths.thumbnail, options: .atomic)
                thumbnails[id] = image
            }
        } else if let image = ThumbnailRenderer.image(usdz: paths.capture) {
            try? image.pngData()?.write(to: paths.thumbnail, options: .atomic)
            thumbnails[id] = image
        }
        if paths.exists(paths.capture) {
            if paths.exists(paths.preview) {
                try? fileManager.removeItem(at: paths.preview)
            }
            try? fileManager.copyItem(at: paths.capture, to: paths.preview)
        }
        record.status = .ready
        record.isProcessed = false
        record.reconstructionDetail = detail
        record.updatedAt = Date()
        try write(record)
    }

    func replaceMesh(id: UUID, mesh: ScanMesh) throws {
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        if !paths.exists(paths.original), paths.exists(paths.mesh) {
            try fileManager.copyItem(at: paths.mesh, to: paths.original)
        }
        let ply = MeshIO.encode(mesh)
        try ply.write(to: paths.mesh, options: .atomic)
        try? MeshExporter.usdz(mesh: mesh, baked: TextureBaker.bake(mesh), to: paths.preview)
        if let image = ThumbnailRenderer.image(mesh: mesh) {
            try? image.pngData()?.write(to: paths.thumbnail, options: .atomic)
            thumbnails[id] = image
        }
        let bounds = mesh.boundingBox()
        record.vertexCount = mesh.positions.count
        record.triangleCount = mesh.triangleCount
        record.surfaceArea = Double(mesh.surfaceArea())
        record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
        record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        record.isProcessed = true
        record.updatedAt = Date()
        try write(record)
    }

    func revert(id: UUID) throws {
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        guard paths.exists(paths.original) else { return }
        let mesh = try MeshIO.read(from: paths.original)
        let ply = try Data(contentsOf: paths.original)
        try ply.write(to: paths.mesh, options: .atomic)
        if paths.exists(paths.capture) {
            if paths.exists(paths.preview) { try? fileManager.removeItem(at: paths.preview) }
            try? fileManager.copyItem(at: paths.capture, to: paths.preview)
        } else {
            try? MeshExporter.usdz(mesh: mesh, baked: TextureBaker.bake(mesh), to: paths.preview)
        }
        if let image = ThumbnailRenderer.image(mesh: mesh) {
            try? image.pngData()?.write(to: paths.thumbnail, options: .atomic)
            thumbnails[id] = image
        }
        let bounds = mesh.boundingBox()
        record.vertexCount = mesh.positions.count
        record.triangleCount = mesh.triangleCount
        record.surfaceArea = Double(mesh.surfaceArea())
        record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
        record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        record.isProcessed = false
        record.updatedAt = Date()
        try write(record)
    }

    func loadMesh(id: UUID) throws -> ScanMesh? {
        let paths = paths(for: id)
        guard paths.exists(paths.mesh) else { return nil }
        return try MeshIO.read(from: paths.mesh)
    }

    func measurements(id: UUID) -> [StoredMeasurement] {
        let url = paths(for: id).measurements
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoding.decoder.decode([StoredMeasurement].self, from: data)) ?? []
    }

    func saveMeasurements(id: UUID, _ measurements: [StoredMeasurement]) throws {
        let data = try JSONCoding.encoder.encode(measurements)
        try data.write(to: paths(for: id).measurements, options: .atomic)
    }

    func imageCount(id: UUID) -> Int {
        let folder = paths(for: id).images
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["heic", "heif", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.count
    }

    private func write(_ record: ScanRecord) throws {
        let paths = paths(for: record.id)
        try fileManager.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(record)
        try data.write(to: paths.meta, options: .atomic)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.createdAt > $1.createdAt }
    }
}

enum ThumbnailRenderer {
    @MainActor
    static func image(mesh: ScanMesh) -> UIImage? {
        let scene = SCNScene()
        let node = SCNNode(geometry: mesh.makeGeometry(mode: .vertex, lit: false, wireframe: false))
        node.name = "scanMesh"
        scene.rootNode.addChildNode(node)
        return render(scene)
    }

    @MainActor
    static func image(usdz: URL) -> UIImage? {
        guard let scene = try? SCNScene(url: usdz, options: nil) else { return nil }
        return render(scene)
    }

    @MainActor
    private static func render(_ scene: SCNScene) -> UIImage? {
        SceneFraming.prepare(scene, background: UIColor(red: 0.90, green: 0.92, blue: 0.94, alpha: 1))
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 360, height: 360), antialiasingMode: .multisampling2X)
        return image.size.width > 0 ? image : nil
    }
}
