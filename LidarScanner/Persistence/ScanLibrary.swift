import Combine
import Metal
import SceneKit
import UIKit

@MainActor
final class ScanLibrary: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published var refineJob: ColorJob?
    @Published var buildLog = ""
    @Published var colorNotice: String?

    private var refineSignal = WorkSignal()
    private var refineGeneration = 0

    let root: URL
    private let fileManager = FileManager.default

    init(root directory: URL? = nil) {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = directory ?? documents.appendingPathComponent("Scans", isDirectory: true)
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
        if refineJob?.scanID == id {
            cancelRefinement(notify: false)
        }
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
        try? MeshExporter.usdz(mesh: mesh, baked: baked, to: paths.preview, allowBake: baked != nil)
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
        if refineJob?.scanID == id { cancelRefinement(notify: false) }
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        if !paths.exists(paths.original), paths.exists(paths.mesh) {
            try fileManager.copyItem(at: paths.mesh, to: paths.original)
        }
        let ply = MeshIO.encode(mesh)
        try ply.write(to: paths.mesh, options: .atomic)
        // Atlas sidecars belong to the saved Built version. Edited meshes do not use them.
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
        record.showingBuilt = false
        record.updatedAt = Date()
        try write(record)
    }

    func revert(id: UUID) throws {
        if refineJob?.scanID == id { cancelRefinement(notify: false) }
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
            try? MeshExporter.usdz(mesh: mesh, baked: nil, to: paths.preview, allowBake: false)
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
        record.isColored = false
        record.showingBuilt = false
        record.updatedAt = Date()
        try write(record)
    }

    func loadMesh(id: UUID) throws -> ScanMesh? {
        let paths = paths(for: id)
        guard paths.exists(paths.mesh) else { return nil }
        return try SurfaceAsset.load(paths: paths, showingBuilt: record(id)?.showingBuilt == true).mesh
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

    func adopt(record: ScanRecord, thumbnail: UIImage?) {
        if let thumbnail {
            thumbnails[record.id] = thumbnail
        }
        try? write(record)
    }

    /// Geometry edits create an independent capture. Never reuse an atlas after
    /// topology changes, and never mutate the source scan or its original files.
    func saveRepairCopy(sourceID: UUID, mesh: ScanMesh) async throws -> UUID {
        guard let source = record(sourceID) else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID()
        let destination = paths(for: id)
        let sourcePaths = paths(for: sourceID)
        let newRecord = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.directory, withIntermediateDirectories: true)
            do {
                var repaired = mesh
                repaired.uvs = []
                let data = MeshIO.encode(repaired)
                try data.write(to: destination.mesh, options: .atomic)
                try data.write(to: destination.original, options: .atomic)
                // Frames remain self-contained so Add Color can bake the NEW
                // geometry. The previous texture bundle is deliberately excluded.
                if sourcePaths.exists(sourcePaths.frames) {
                    try fm.copyItem(at: sourcePaths.frames, to: destination.frames)
                }
                try MeshExporter.usdz(mesh: repaired, baked: nil, to: destination.preview, allowBake: false)
                if let image = ThumbnailRenderer.image(mesh: repaired), let png = image.pngData() {
                    try png.write(to: destination.thumbnail, options: .atomic)
                }
                var record = source
                record.id = id
                record.name = source.name + " · Repaired"
                record.createdAt = Date()
                record.updatedAt = record.createdAt
                record.vertexCount = repaired.positions.count
                record.triangleCount = repaired.triangleCount
                record.surfaceArea = Double(repaired.surfaceArea())
                let bounds = repaired.boundingBox()
                record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
                record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
                record.isProcessed = true
                record.isColored = false
                record.hasColorFrames = false
                record.hasKeyframes = destination.exists(destination.frames)
                record.builtAvailable = false
                record.showingBuilt = false
                record.qualityApplied = false
                // Metadata last: an incomplete copy is never shown in the library.
                try JSONCoding.encoder.encode(record).write(to: destination.meta, options: .atomic)
                return record
            } catch {
                try? fm.removeItem(at: destination.directory)
                throw error
            }
        }.value
        try write(newRecord)
        thumbnails[id] = UIImage(contentsOfFile: destination.thumbnail.path)
        return id
    }

    func startAddingColor(to id: UUID) {
        guard record(id)?.hasKeyframes == true else {
            colorNotice = L10n.colorUnavailable
            return
        }
        startRefinement(id: id, settings: .fast)
    }

    func startRefinement(id: UUID, settings: FusionSettings) {
        guard refineJob == nil else {
            colorNotice = L10n.colorBusy
            return
        }
        guard let record = record(id), record.hasKeyframes else {
            colorNotice = L10n.qualityNeedsFrames
            return
        }
        refineGeneration += 1
        let generation = refineGeneration
        let signal = WorkSignal()
        refineSignal = signal
        refineJob = ColorJob(scanID: id, progress: 0.02, message: settings.estimate)
        buildLog = ""
        let started = CFAbsoluteTimeGetCurrent()
        var lastStage = ""
        let paths = paths(for: id)
        // Texture-only builds keep the currently selected/cropped geometry.
        let meshURL = settings.fuse && paths.exists(paths.original) ? paths.original : paths.mesh
        let framesURL = paths.frames
        let center = record.objectCenter.flatMap { values -> SIMD3<Float>? in
            guard values.count == 3 else { return nil }
            return SIMD3(values[0], values[1], values[2])
        }
        let radius = record.objectRadius ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = (try? MeshIO.read(from: meshURL)) ?? ScanMesh()
            let result = ScanProcessor.run(
                directory: framesURL,
                reference: source,
                settings: settings,
                objectCenter: center,
                objectRadius: radius,
                signal: signal
            ) { fraction, message in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.refineGeneration else { return }
                    self.refineJob?.progress = fraction
                    self.refineJob?.message = message
                    if message != lastStage {
                        lastStage = message
                        let seconds = Int(CFAbsoluteTimeGetCurrent() - started)
                        self.buildLog += "\(seconds)s  \(message)\n"
                    }
                }
            }
            guard !signal.isCancelled else { return }
            if result.textureFailed {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.refineGeneration else { return }
                    self.refineJob = nil
                    self.colorNotice = L10n.colorFailed
                }
                return
            }
            guard !result.mesh.isEmpty else {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.refineGeneration else { return }
                    self.refineJob = nil
                    self.colorNotice = L10n.colorFailed
                }
                return
            }
            let previewFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("usdz")
            defer { try? FileManager.default.removeItem(at: previewFile) }
            do {
                if let image = result.texture {
                    try MeshExporter.usdzTextured(mesh: result.mesh, image: image, to: previewFile)
                } else {
                    try MeshExporter.usdz(mesh: result.mesh, baked: nil, to: previewFile, allowBake: false)
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.refineGeneration else { return }
                    self.refineJob = nil
                    self.colorNotice = L10n.colorFailed
                }
                return
            }
            let previewData = try? Data(contentsOf: previewFile)
            let ply = MeshIO.encode(result.mesh)
            let surfaceData: Data?
            do {
                surfaceData = try result.texture.map { try SurfaceAsset.encode(mesh: result.mesh, image: $0) }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.refineGeneration else { return }
                    self.refineJob = nil
                    self.colorNotice = L10n.colorFailed
                }
                return
            }
            let thumbnail = result.texture == nil
                ? ThumbnailRenderer.image(mesh: result.mesh, solidColor: UIColor(red: 0.78, green: 0.64, blue: 0.50, alpha: 1))
                : ThumbnailRenderer.image(mesh: result.mesh)
            Task { @MainActor [weak self] in
                self?.commitRefinement(
                    id: id,
                    generation: generation,
                    mesh: result.mesh,
                    ply: ply,
                    surfaceData: surfaceData,
                    previewData: previewData,
                    thumbnail: thumbnail,
                    cancelled: signal.isCancelled,
                    notice: result.notice
                )
            }
        }
    }

    func cancelRefinement(notify: Bool = true) {
        refineSignal.cancel()
        refineGeneration += 1
        refineJob = nil
        if notify { colorNotice = L10n.colorCancelled }
    }

    private func commitRefinement(
        id: UUID,
        generation: Int,
        mesh: ScanMesh,
        ply: Data,
        surfaceData: Data?,
        previewData: Data?,
        thumbnail: UIImage?,
        cancelled: Bool,
        notice: String?
    ) {
        guard generation == refineGeneration, var record = record(id) else { return }
        if cancelled {
            refineJob = nil
            colorNotice = L10n.colorCancelled
            return
        }
        let paths = paths(for: id)
        let bounds = mesh.boundingBox()
        record.vertexCount = mesh.positions.count
        record.triangleCount = mesh.triangleCount
        record.surfaceArea = Double(mesh.surfaceArea())
        record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
        record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        record.isColored = surfaceData != nil
        record.qualityApplied = true
        record.isProcessed = true
        record.builtAvailable = true
        record.showingBuilt = true
        record.updatedAt = Date()
        do {
            try ScanArtifactTransaction.replace([
                (paths.built, ply), (paths.mesh, ply),
                (paths.surfaceAsset, surfaceData), (paths.uvs, nil), (paths.texture, nil),
                (paths.preview, previewData), (paths.thumbnail, thumbnail?.pngData()),
                (paths.builtPreview, previewData),
                (paths.meta, try JSONCoding.encoder.encode(record))
            ])
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
            thumbnails[id] = thumbnail
        } catch {
            refineJob = nil
            colorNotice = L10n.colorFailed
            return
        }
        refineJob = nil
        if let notice { colorNotice = notice }
    }

    func showOriginalMesh(id: UUID) throws {
        try activate(id: id, built: false)
    }

    func showBuiltMesh(id: UUID) throws {
        try activate(id: id, built: true)
    }

    private func activate(id: UUID, built: Bool) throws {
        if refineJob?.scanID == id { cancelRefinement(notify: false) }
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        let source = built ? paths.built : paths.original
        guard paths.exists(source) else { return }
        let data = try Data(contentsOf: source)
        try data.write(to: paths.mesh, options: .atomic)
        record.isColored = built && paths.exists(paths.surfaceAsset)
        if let mesh = try? MeshIO.read(from: paths.mesh) {
            let bounds = mesh.boundingBox()
            record.vertexCount = mesh.positions.count
            record.triangleCount = mesh.triangleCount
            record.surfaceArea = Double(mesh.surfaceArea())
            record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
            record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        }
        record.showingBuilt = built
        record.isProcessed = built
        record.updatedAt = Date()
        try write(record)
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

struct ColorJob: Equatable {
    var scanID: UUID
    var progress: Double
    var message: String
}

enum GeometryArchive {
    static func save(
        mesh: ScanMesh,
        frames: [ColorKeyframe],
        mode: ScanMode,
        name: String,
        root: URL,
        keyframeDirectory: URL?,
        objectCenter: SIMD3<Float>?,
        objectRadius: Float
    ) throws -> (record: ScanRecord, thumbnail: UIImage?) {
        let started = CFAbsoluteTimeGetCurrent()
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let paths = ScanPaths(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: directory) }
        }
        let ply = MeshIO.encode(mesh)
        try ply.write(to: paths.mesh, options: .atomic)
        try ply.write(to: paths.original, options: .atomic)
        var storedFrames = false
        if !frames.isEmpty {
            do {
                try ColorFrameStore.write(frames, to: paths.colorFrames)
                storedFrames = FileManager.default.fileExists(atPath: paths.colorFrames.path)
            } catch {
                Log.scan.error("color frame save failed \(error.localizedDescription, privacy: .public)")
            }
        }
        let clay = UIColor(red: 0.78, green: 0.64, blue: 0.50, alpha: 1)
        let thumbnail = ThumbnailRenderer.image(mesh: mesh, solidColor: clay)
        if let data = thumbnail?.pngData() {
            try? data.write(to: paths.thumbnail, options: .atomic)
        }
        var storedKeyframes = false
        if let keyframeDirectory, FileManager.default.fileExists(atPath: KeyframeArchive.manifestURL(in: keyframeDirectory).path) {
            if FileManager.default.fileExists(atPath: paths.frames.path) {
                try? FileManager.default.removeItem(at: paths.frames)
            }
            try FileManager.default.copyItem(at: keyframeDirectory, to: paths.frames)
            storedKeyframes = FileManager.default.fileExists(atPath: KeyframeArchive.manifestURL(in: paths.frames).path)
        }
        let now = Date()
        let bounds = mesh.boundingBox()
        let record = ScanRecord(
            id: id,
            name: name,
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
            hasColorFrames: storedFrames,
            isColored: false,
            hasKeyframes: storedKeyframes,
            qualityApplied: false,
            objectCenter: objectCenter.map { [$0.x, $0.y, $0.z] },
            objectRadius: objectRadius > 0 ? objectRadius : nil
        )
        let meta = try JSONCoding.encoder.encode(record)
        try meta.write(to: paths.meta, options: .atomic)
        committed = true
        Log.scan.info("geometrySave vertices=\(mesh.positions.count, privacy: .public) triangles=\(mesh.triangleCount, privacy: .public) frames=\(frames.count, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
        return (record, thumbnail)
    }
}

enum ThumbnailRenderer {
    static func image(mesh: ScanMesh, solidColor: UIColor? = nil) -> UIImage? {
        let scene = SCNScene()
        let node = SCNNode(geometry: mesh.makeGeometry(mode: .vertex, lit: solidColor != nil, wireframe: false, solidColor: solidColor))
        node.name = "scanMesh"
        scene.rootNode.addChildNode(node)
        return render(scene, sculpted: solidColor != nil)
    }

    static func image(usdz: URL) -> UIImage? {
        guard let scene = try? SCNScene(url: usdz, options: nil) else { return nil }
        return render(scene, sculpted: false)
    }

    private static func render(_ scene: SCNScene, sculpted: Bool) -> UIImage? {
        SceneFraming.prepare(scene, background: UIColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 1), sculpted: sculpted)
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 360, height: 360), antialiasingMode: .multisampling2X)
        return image.size.width > 0 ? image : nil
    }
}
