import Combine
import Metal
import SceneKit
import UIKit

@MainActor
final class ScanLibrary: ObservableObject {
    @Published private(set) var records: [ScanRecord] = []
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    @Published var colorJob: ColorJob?
    @Published var refineJob: ColorJob?
    @Published var buildLog = ""
    @Published var colorNotice: String?

    private var colorSignal = WorkSignal()
    private var colorGeneration = 0
    private var refineSignal = WorkSignal()
    private var refineGeneration = 0

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
        if colorJob?.scanID == id {
            cancelAddingColor(notify: false)
        }
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
        if colorJob?.scanID == id { cancelAddingColor(notify: false) }
        if refineJob?.scanID == id { cancelRefinement(notify: false) }
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        if !paths.exists(paths.original), paths.exists(paths.mesh) {
            try fileManager.copyItem(at: paths.mesh, to: paths.original)
        }
        let ply = MeshIO.encode(mesh)
        try ply.write(to: paths.mesh, options: .atomic)
        try? fileManager.removeItem(at: paths.uvs)
        try? fileManager.removeItem(at: paths.texture)
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
        if colorJob?.scanID == id { cancelAddingColor(notify: false) }
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

    func adopt(record: ScanRecord, thumbnail: UIImage?) {
        if let thumbnail {
            thumbnails[record.id] = thumbnail
        }
        try? write(record)
    }

    func startAddingColor(to id: UUID) {
        guard colorJob == nil, refineJob == nil else {
            colorNotice = L10n.colorBusy
            return
        }
        guard let record = record(id), record.canAddColor else {
            colorNotice = L10n.colorUnavailable
            return
        }
        let generation = colorGeneration
        let signal = WorkSignal()
        colorSignal = signal
        colorJob = ColorJob(scanID: id, progress: 0.02, message: L10n.colorWorking)
        let meshURL = paths(for: id).mesh
        let framesURL = paths(for: id).colorFrames
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            do {
                var mesh = try MeshIO.read(from: meshURL)
                let frames = try ColorFrameStore.read(from: framesURL)
                Log.scan.info("addColor start vertices=\(mesh.positions.count, privacy: .public) triangles=\(mesh.triangleCount, privacy: .public) frames=\(frames.count, privacy: .public)")
                let outcome = MeshColorizer.colorize(&mesh, keyframes: frames, signal: signal) { fraction in
                    Task { @MainActor [weak self] in
                        self?.updateColorProgress(0.05 + 0.7 * fraction, id: id, generation: generation)
                    }
                }
                if signal.isCancelled {
                    Task { @MainActor [weak self] in self?.finishColorCancelled(generation: generation) }
                    return
                }
                let plyStarted = CFAbsoluteTimeGetCurrent()
                let ply = MeshIO.encode(mesh)
                Log.scan.info("addColor ply ms=\(ScanTiming.milliseconds(since: plyStarted), privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.updateColorProgress(0.8, id: id, generation: generation)
                }
                let previewStarted = CFAbsoluteTimeGetCurrent()
                let baked = TextureBaker.bake(mesh, shouldStop: { signal.isCancelled })
                var previewData: Data?
                if !signal.isCancelled {
                    let previewFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("usdz")
                    if let baked {
                        try? MeshExporter.usdz(mesh: mesh, baked: baked, to: previewFile, allowBake: false)
                    } else {
                        try? MeshExporter.usdz(mesh: mesh, baked: nil, to: previewFile, allowBake: false)
                    }
                    previewData = try? Data(contentsOf: previewFile)
                    try? FileManager.default.removeItem(at: previewFile)
                }
                let thumbnail = signal.isCancelled ? nil : ThumbnailRenderer.image(mesh: mesh)
                Log.scan.info("addColor preview ms=\(ScanTiming.milliseconds(since: previewStarted), privacy: .public) total ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
                let png = thumbnail?.pngData()
                Task { @MainActor [weak self] in
                    if signal.isCancelled {
                        self?.finishColorCancelled(generation: generation)
                        return
                    }
                    self?.commitColor(
                        id: id,
                        generation: generation,
                        mesh: mesh,
                        ply: ply,
                        previewData: previewData,
                        thumbnail: thumbnail,
                        thumbnailData: png,
                        partial: outcome.partial,
                        coloredVertices: outcome.coloredVertices
                    )
                }
            } catch {
                Log.scan.error("addColor failed \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.failColor(generation: generation, message: L10n.colorFailed)
                }
            }
        }
    }

    func cancelAddingColor(notify: Bool = true) {
        colorSignal.cancel()
        colorGeneration += 1
        colorJob = nil
        if notify {
            colorNotice = L10n.colorCancelled
        }
    }

    private func updateColorProgress(_ progress: Double, id: UUID, generation: Int) {
        guard generation == colorGeneration, colorJob?.scanID == id else { return }
        colorJob?.progress = progress
        colorJob?.message = L10n.colorWorking
    }

    private func finishColorCancelled(generation: Int) {
        guard generation == colorGeneration else { return }
        colorJob = nil
        colorNotice = L10n.colorCancelled
    }

    private func failColor(generation: Int, message: String) {
        guard generation == colorGeneration else { return }
        colorJob = nil
        colorNotice = message
    }

    private func commitColor(
        id: UUID,
        generation: Int,
        mesh: ScanMesh,
        ply: Data,
        previewData: Data?,
        thumbnail: UIImage?,
        thumbnailData: Data?,
        partial: Bool,
        coloredVertices: Int
    ) {
        guard generation == colorGeneration, var record = record(id) else { return }
        let paths = paths(for: id)
        do {
            try ply.write(to: paths.mesh, options: .atomic)
        } catch {
            colorJob = nil
            colorNotice = L10n.colorFailed
            return
        }
        if let previewData {
            try? previewData.write(to: paths.preview, options: .atomic)
        }
        if let thumbnailData {
            try? thumbnailData.write(to: paths.thumbnail, options: .atomic)
        }
        if let thumbnail {
            thumbnails[id] = thumbnail
        }
        let bounds = mesh.boundingBox()
        record.vertexCount = mesh.positions.count
        record.triangleCount = mesh.triangleCount
        record.surfaceArea = Double(mesh.surfaceArea())
        record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
        record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        record.isColored = coloredVertices > 0
        record.updatedAt = Date()
        try? write(record)
        colorJob = nil
        if coloredVertices == 0 {
            colorNotice = L10n.colorFailed
        } else if partial {
            colorNotice = L10n.colorPartial
        }
    }

    func startRefinement(id: UUID, settings: FusionSettings) {
        guard refineJob == nil, colorJob == nil else {
            colorNotice = L10n.colorBusy
            return
        }
        guard let record = record(id), record.hasKeyframes else {
            colorNotice = L10n.qualityNeedsFrames
            return
        }
        let generation = refineGeneration
        let signal = WorkSignal()
        refineSignal = signal
        refineJob = ColorJob(scanID: id, progress: 0.02, message: settings.estimate)
        buildLog = ""
        let started = CFAbsoluteTimeGetCurrent()
        var lastStage = ""
        let paths = paths(for: id)
        let meshURL = paths.exists(paths.original) ? paths.original : paths.mesh
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
            let jpeg = result.texture?.jpegData(compressionQuality: 0.86)
            let thumbnail = result.texture == nil
                ? ThumbnailRenderer.image(mesh: result.mesh, solidColor: UIColor(red: 0.78, green: 0.64, blue: 0.50, alpha: 1))
                : ThumbnailRenderer.image(mesh: result.mesh)
            Task { @MainActor [weak self] in
                self?.commitRefinement(
                    id: id,
                    generation: generation,
                    mesh: result.mesh,
                    ply: ply,
                    texture: jpeg,
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
        texture: Data?,
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
        record.isColored = texture != nil && mesh.uvs.count == mesh.positions.count
        record.qualityApplied = true
        record.isProcessed = true
        record.builtAvailable = true
        record.showingBuilt = true
        record.updatedAt = Date()
        do {
            let uvData = record.isColored ? UVFile.encode(mesh.uvs) : nil
            try ScanArtifactTransaction.replace([
                (paths.built, ply), (paths.mesh, ply),
                (paths.uvs, uvData), (paths.texture, record.isColored ? texture : nil),
                (paths.preview, previewData), (paths.thumbnail, thumbnail?.pngData()),
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
        if colorJob?.scanID == id { cancelAddingColor(notify: false) }
        if refineJob?.scanID == id { cancelRefinement(notify: false) }
        guard var record = record(id) else { return }
        let paths = paths(for: id)
        let source = built ? paths.built : paths.original
        guard paths.exists(source) else { return }
        let data = try Data(contentsOf: source)
        try data.write(to: paths.mesh, options: .atomic)
        record.isColored = built && paths.exists(paths.texture)
        if let mesh = try? MeshIO.read(from: paths.mesh) {
            let bounds = mesh.boundingBox()
            record.vertexCount = mesh.positions.count
            record.triangleCount = mesh.triangleCount
            record.surfaceArea = Double(mesh.surfaceArea())
            record.boundsMin = [bounds.min.x, bounds.min.y, bounds.min.z]
            record.boundsMax = [bounds.max.x, bounds.max.y, bounds.max.z]
        }
        record.showingBuilt = built
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
