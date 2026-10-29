import ARKit
import AVFoundation
import Combine
import SceneKit
import UIKit
import simd

enum ScanOverlayStyle: Int, CaseIterable, Identifiable {
    case wireAndFill
    case fill
    case hidden

    var id: Int { rawValue }

    var symbol: String {
        switch self {
        case .wireAndFill: return "point.3.connected.trianglepath.dotted"
        case .fill: return "square.fill"
        case .hidden: return "eye.slash"
        }
    }

    var title: String {
        switch self {
        case .wireAndFill: return L10n.overlayBoth
        case .fill: return L10n.overlayFill
        case .hidden: return L10n.overlayOff
        }
    }
}

struct ScanGuidance {
    enum Tone {
        case info
        case good
        case warn
    }

    var message: String
    var tone: Tone
}

final class RoomScanModel: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    let mode: ScanMode
    let sceneView = ARSCNView(frame: .zero)
    private let library: ScanLibrary
    private let keyframes = KeyframeBuffer()
    private var configuration = ARWorldTrackingConfiguration()
    private var sphereNode: SCNNode?
    private var lastPosition: SIMD3<Float>?
    private var lastTimestamp: TimeInterval?
    private var lastUIUpdate: TimeInterval = 0
    private var lastAreaUpdate: TimeInterval = 0
    private var startedAt: Date?
    private var speed: Float = 0
    private var ambient: Float = 1000
    private var trackingMessage: String?

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var cameraDenied = false
    @Published var isProcessing = false
    @Published var processingText = ""
    @Published var colorProgress: Double = 0
    @Published var faceCount = 0
    @Published var surfaceArea: Float = 0
    @Published var tick = 0
    @Published var objectRadius: Float = 0.45
    @Published var hasCenter = false
    @Published var alertMessage: String?
    @Published var savedID: UUID?
    @Published var overlayStyle: ScanOverlayStyle

    private var objectCenter: SIMD3<Float>?
    private var finishSignal: WorkSignal?

    init(mode: ScanMode, library: ScanLibrary) {
        self.mode = mode
        self.library = library
        let stored = UserDefaults.standard.object(forKey: "scanOverlayStyle") as? Int
        self.overlayStyle = ScanOverlayStyle(rawValue: stored ?? ScanOverlayStyle.wireAndFill.rawValue) ?? .wireAndFill
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene = SCNScene()
    }

    var elapsedText: String {
        guard let startedAt, isRecording, !isPaused else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var guidance: ScanGuidance {
        if isPaused { return ScanGuidance(message: L10n.scanGuidancePaused, tone: .info) }
        if let trackingMessage, isRecording {
            return ScanGuidance(message: L10n.scanTracking(trackingMessage), tone: .warn)
        }
        if !isRecording {
            return ScanGuidance(message: mode == .objectLidar ? L10n.scanGuidanceObject : L10n.scanGuidanceReady, tone: .info)
        }
        if speed > 0.55 { return ScanGuidance(message: L10n.scanGuidanceSlow, tone: .warn) }
        if ambient < 280 { return ScanGuidance(message: L10n.scanGuidanceLight, tone: .warn) }
        if surfaceArea < 0.25, let startedAt, Date().timeIntervalSince(startedAt) > 6 {
            return ScanGuidance(message: L10n.scanGuidanceCloser, tone: .info)
        }
        if speed < 0.03 { return ScanGuidance(message: L10n.scanGuidanceMove, tone: .info) }
        return ScanGuidance(message: mode == .objectLidar ? L10n.scanGuidanceObject : L10n.scanGuidanceGood, tone: .good)
    }

    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startSession() }
                    else { self?.cameraDenied = true }
                }
            }
        default:
            cameraDenied = true
        }
    }

    func startRecording() {
        if isPaused { resume() }
        if !isRecording {
            startedAt = Date()
        }
        isRecording = true
        keyframes.setAccepting(true)
        if mode == .objectLidar, objectCenter == nil {
            setCenterFromCrosshair()
        }
        Haptics.tap()
    }

    func pause() {
        sceneView.session.pause()
        isPaused = true
        keyframes.setAccepting(false)
        speed = 0
    }

    func resume() {
        sceneView.session.run(configuration, options: [])
        isPaused = false
        if isRecording { keyframes.setAccepting(true) }
        lastTimestamp = nil
    }

    func restart() {
        keyframes.removeAll()
        isRecording = false
        isPaused = false
        startedAt = nil
        faceCount = 0
        surfaceArea = 0
        speed = 0
        objectCenter = nil
        hasCenter = false
        sphereNode?.removeFromParentNode()
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Haptics.tap()
    }

    func finish() {
        guard isRecording, !isProcessing else { return }
        if mode == .objectLidar, objectCenter == nil {
            setCenterFromCrosshair()
        }
        isProcessing = true
        processingText = L10n.scanSavingGeometry
        colorProgress = 0.04
        let signal = WorkSignal()
        finishSignal = signal
        keyframes.setAccepting(false)
        let mode = self.mode
        Task { @MainActor [weak self] in
            guard let self else { return }
            let name = self.library.defaultName(for: mode)
            let root = self.library.root
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !signal.isCancelled else {
                    self.finishCancelled()
                    return
                }
                let started = CFAbsoluteTimeGetCurrent()
                let extracted = self.extractMesh()
                let frames = self.keyframes.snapshot()
                self.sceneView.session.pause()
                self.isPaused = true
                self.colorProgress = 0.2
                Log.scan.info("extract vertices=\(extracted.positions.count, privacy: .public) triangles=\(extracted.triangleCount, privacy: .public) frames=\(frames.count, privacy: .public) ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.saveGeometry(extracted, frames: frames, mode: mode, name: name, root: root, signal: signal, started: started)
                }
            }
        }
    }

    func cancelFinish() {
        finishSignal?.cancel()
    }

    private func finishCancelled() {
        isProcessing = false
        colorProgress = 0
        finishSignal = nil
        if isPaused {
            resume()
        }
    }

    private func saveGeometry(
        _ extracted: ScanMesh,
        frames: [ColorKeyframe],
        mode: ScanMode,
        name: String,
        root: URL,
        signal: WorkSignal,
        started: CFAbsoluteTime
    ) {
        if signal.isCancelled {
            DispatchQueue.main.async { [weak self] in self?.finishCancelled() }
            return
        }
        let weldStarted = CFAbsoluteTimeGetCurrent()
        let cell: Float = mode == .room ? 0.004 : 0.002
        var mesh = extracted.welded(cellSize: cell)
        mesh.recomputeNormals()
        Log.scan.info("weld vertices=\(mesh.positions.count, privacy: .public) triangles=\(mesh.triangleCount, privacy: .public) ms=\(ScanTiming.milliseconds(since: weldStarted), privacy: .public)")
        guard mesh.triangleCount >= 30 else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
                self?.finishSignal = nil
                self?.alertMessage = L10n.scanNotEnoughBody
                self?.resume()
            }
            return
        }
        if signal.isCancelled {
            DispatchQueue.main.async { [weak self] in self?.finishCancelled() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.colorProgress = 0.55
            self?.processingText = L10n.scanProcessingSave
        }
        do {
            let saved = try GeometryArchive.save(mesh: mesh, frames: frames, mode: mode, name: name, root: root)
            Log.scan.info("finish total ms=\(ScanTiming.milliseconds(since: started), privacy: .public)")
            let previewURL = ScanPaths(directory: root.appendingPathComponent(saved.record.id.uuidString, isDirectory: true)).preview
            DispatchQueue.global(qos: .utility).async {
                let previewStarted = CFAbsoluteTimeGetCurrent()
                try? MeshExporter.usdz(mesh: mesh, baked: nil, to: previewURL, allowBake: false)
                Log.scan.info("preview usdz ms=\(ScanTiming.milliseconds(since: previewStarted), privacy: .public)")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !signal.isCancelled else {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(saved.record.id.uuidString, isDirectory: true))
                    self.finishCancelled()
                    return
                }
                self.library.adopt(record: saved.record, thumbnail: saved.thumbnail)
                self.colorProgress = 1
                self.finishSignal = nil
                self.isProcessing = false
                Haptics.success()
                self.savedID = saved.record.id
            }
        } catch {
            Log.scan.error("Save failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
                self?.finishSignal = nil
                self?.alertMessage = error.localizedDescription
                if self?.isPaused == true { self?.resume() }
            }
        }
    }

    func setCenterFromCrosshair() {
        let bounds = sceneView.bounds
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        if let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let result = sceneView.session.raycast(query).first {
            let translation = result.worldTransform.columns.3
            objectCenter = SIMD3(translation.x, translation.y, translation.z)
        } else if let frame = sceneView.session.currentFrame {
            let transform = frame.camera.transform
            let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            objectCenter = origin + forward * 0.8
        }
        hasCenter = objectCenter != nil
        updateSphere()
        Haptics.tap()
    }

    func updateSphere() {
        sphereNode?.removeFromParentNode()
        guard mode == .objectLidar, let objectCenter else { return }
        let fill = SCNSphere(radius: CGFloat(objectRadius))
        fill.segmentCount = 48
        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.diffuse.contents = UIColor(red: 0.22, green: 0.85, blue: 0.75, alpha: 1)
        fillMaterial.transparency = 0.12
        fillMaterial.isDoubleSided = true
        fillMaterial.writesToDepthBuffer = false
        fill.materials = [fillMaterial]

        let wire = SCNSphere(radius: CGFloat(objectRadius))
        wire.segmentCount = 24
        let wireMaterial = SCNMaterial()
        wireMaterial.lightingModel = .constant
        wireMaterial.diffuse.contents = UIColor(red: 0.55, green: 0.95, blue: 0.88, alpha: 1)
        wireMaterial.fillMode = .lines
        wireMaterial.isDoubleSided = true
        wire.materials = [wireMaterial]

        let node = SCNNode(geometry: fill)
        node.addChildNode(SCNNode(geometry: wire))
        node.simdPosition = objectCenter
        node.name = "bounds"
        sceneView.scene.rootNode.addChildNode(node)
        sphereNode = node
    }

    func stop() {
        keyframes.setAccepting(false)
        sceneView.session.pause()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        configuration = config
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func ingest(position: SIMD3<Float>, light: Float, tracking: String?, timestamp: TimeInterval) {
        ambient = light
        trackingMessage = tracking
        if let lastPosition, let lastTimestamp {
            let dt = timestamp - lastTimestamp
            if dt > 0.016, dt < 0.5 {
                speed = simd_distance(position, lastPosition) / Float(dt)
            }
        }
        lastPosition = position
        lastTimestamp = timestamp
        if timestamp - lastAreaUpdate > 0.8 {
            lastAreaUpdate = timestamp
            refreshCoverage()
        }
        if timestamp - lastUIUpdate > 0.15 {
            lastUIUpdate = timestamp
            tick += 1
        }
    }

    private func refreshCoverage() {
        guard let anchors = sceneView.session.currentFrame?.anchors else { return }
        var faces = 0
        var area: Float = 0
        for case let anchor as ARMeshAnchor in anchors {
            let geometry = anchor.geometry
            faces += geometry.faces.count
            area += Self.area(of: geometry)
        }
        faceCount = faces
        surfaceArea = area
    }

    private func extractMesh() -> ScanMesh {
        guard let anchors = sceneView.session.currentFrame?.anchors else { return ScanMesh() }
        var mesh = ScanMesh()
        for case let anchor as ARMeshAnchor in anchors {
            Self.append(anchor, to: &mesh)
        }
        guard mode == .objectLidar, let center = objectCenter else {
            return mesh
        }
        let limit = objectRadius * 1.05
        return mesh.keepingTriangles { triangle in
            let i0 = Int(mesh.indices[triangle * 3])
            let i1 = Int(mesh.indices[triangle * 3 + 1])
            let i2 = Int(mesh.indices[triangle * 3 + 2])
            guard i0 < mesh.positions.count, i1 < mesh.positions.count, i2 < mesh.positions.count else { return false }
            let centroid = (mesh.positions[i0] + mesh.positions[i1] + mesh.positions[i2]) / 3
            return simd_distance(centroid, center) <= limit
        }
    }

    func setOverlayStyle(_ style: ScanOverlayStyle) {
        overlayStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "scanOverlayStyle")
        sceneView.scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == "meshFill" {
                node.isHidden = style == .hidden
            } else if node.name == "meshWire" {
                node.isHidden = style != .wireAndFill
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.addChildNode(LiveMeshBuilder.node(for: meshAnchor, style: overlayStyle))
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.childNodes.filter { $0.name == "mesh" }.forEach { $0.removeFromParentNode() }
        node.addChildNode(LiveMeshBuilder.node(for: meshAnchor, style: overlayStyle))
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let light = Float(frame.lightEstimate?.ambientIntensity ?? 1000)
        let tracking = Self.trackingText(frame.camera.trackingState)
        let timestamp = frame.timestamp
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        keyframes.consider(frame)
        DispatchQueue.main.async { [weak self] in
            self?.ingest(position: position, light: light, tracking: tracking, timestamp: timestamp)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.alertMessage = error.localizedDescription
        }
    }

    private static func trackingText(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return L10n.trackUnavailable
        case .limited(let reason):
            switch reason {
            case .initializing: return L10n.trackInitializing
            case .excessiveMotion: return L10n.trackMotion
            case .insufficientFeatures: return L10n.trackFeatures
            case .relocalizing: return L10n.trackRelocalizing
            @unknown default: return L10n.trackLimited
            }
        }
    }

    private static func area(of geometry: ARMeshGeometry) -> Float {
        let vertices = geometry.vertices
        let faces = geometry.faces
        let pointer = vertices.buffer.contents()
        let facePointer = faces.buffer.contents()
        var area: Float = 0
        let step = max(1, faces.count / 400)
        for face in stride(from: 0, to: faces.count, by: step) {
            var ids: [SIMD3<Float>] = []
            for corner in 0..<3 {
                let indexOffset = (face * faces.indexCountPerPrimitive + corner) * faces.bytesPerIndex
                let vertexIndex: Int
                if faces.bytesPerIndex == 4 {
                    vertexIndex = Int(facePointer.advanced(by: indexOffset).assumingMemoryBound(to: UInt32.self).pointee)
                } else if faces.bytesPerIndex == 2 {
                    vertexIndex = Int(facePointer.advanced(by: indexOffset).assumingMemoryBound(to: UInt16.self).pointee)
                } else {
                    continue
                }
                let vertex = readFloat3(pointer, offset: vertices.offset, stride: vertices.stride, index: vertexIndex)
                ids.append(vertex)
            }
            if ids.count == 3 {
                area += simd_length(simd_cross(ids[1] - ids[0], ids[2] - ids[0])) * 0.5 * Float(step)
            }
        }
        return area
    }

    private static func append(_ anchor: ARMeshAnchor, to mesh: inout ScanMesh) {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let normals = geometry.normals
        let faces = geometry.faces
        let vertexPointer = vertices.buffer.contents()
        let normalPointer = normals.buffer.contents()
        let facePointer = faces.buffer.contents()
        let base = UInt32(mesh.positions.count)
        let transform = anchor.transform

        for index in 0..<vertices.count {
            let local = readFloat3(vertexPointer, offset: vertices.offset, stride: vertices.stride, index: index)
            let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            mesh.positions.append(SIMD3(world.x, world.y, world.z))
        }
        for index in 0..<normals.count {
            let local = readFloat3(normalPointer, offset: normals.offset, stride: normals.stride, index: index)
            let world = transform * SIMD4<Float>(local.x, local.y, local.z, 0)
            let normal = SIMD3(world.x, world.y, world.z)
            let length = simd_length(normal)
            mesh.normals.append(length > 1e-6 ? normal / length : SIMD3(0, 1, 0))
        }
        if mesh.normals.count < mesh.positions.count {
            mesh.normals.append(contentsOf: repeatElement(SIMD3<Float>(0, 1, 0), count: mesh.positions.count - mesh.normals.count))
        }
        mesh.colors.append(contentsOf: repeatElement(SIMD3<Float>(repeating: 0.72), count: vertices.count))

        var classes = [UInt8](repeating: 0, count: faces.count)
        if let classification = geometry.classification {
            let classPointer = classification.buffer.contents()
            for face in 0..<faces.count {
                let offset = classification.offset + classification.stride * face
                classes[face] = classPointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
            }
        }

        for face in 0..<faces.count {
            var cornerIndices: [UInt32] = []
            for corner in 0..<min(3, faces.indexCountPerPrimitive) {
                let offset = (face * faces.indexCountPerPrimitive + corner) * faces.bytesPerIndex
                let localIndex: UInt32
                if faces.bytesPerIndex == 4 {
                    localIndex = facePointer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
                } else if faces.bytesPerIndex == 2 {
                    localIndex = UInt32(facePointer.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                } else {
                    continue
                }
                cornerIndices.append(base + localIndex)
            }
            guard cornerIndices.count == 3 else { continue }
            mesh.indices.append(contentsOf: cornerIndices)
            mesh.faceClasses.append(classes[face])
        }
    }

    private static func readFloat3(_ pointer: UnsafeMutableRawPointer, offset: Int, stride: Int, index: Int) -> SIMD3<Float> {
        let raw = UnsafeRawPointer(pointer).advanced(by: offset + stride * index)
        return SIMD3(
            raw.loadUnaligned(as: Float.self),
            raw.advanced(by: 4).loadUnaligned(as: Float.self),
            raw.advanced(by: 8).loadUnaligned(as: Float.self)
        )
    }
}

enum LiveMeshBuilder {
    /// Fill plus wireframe share one triangle index buffer. Line mode draws the edges on the GPU, so the overlay does not build a second edge list.
    static func node(for anchor: ARMeshAnchor, style: ScanOverlayStyle) -> SCNNode {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let normals = geometry.normals
        let faces = geometry.faces
        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )
        let normalSource = SCNGeometrySource(
            buffer: normals.buffer,
            vertexFormat: normals.format,
            semantic: .normal,
            vertexCount: normals.count,
            dataOffset: normals.offset,
            dataStride: normals.stride
        )

        let indexCount = faces.count * faces.indexCountPerPrimitive
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        let pointer = faces.buffer.contents()
        for index in 0..<indexCount {
            let offset = faces.bytesPerIndex * index
            if faces.bytesPerIndex == 4 {
                indices.append(pointer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
            } else if faces.bytesPerIndex == 2 {
                indices.append(UInt32(pointer.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee))
            }
        }

        var classes = [UInt8](repeating: 0, count: faces.count)
        if let classification = geometry.classification {
            let classPointer = classification.buffer.contents()
            for face in 0..<min(faces.count, classes.count) {
                let offset = classification.offset + classification.stride * face
                classes[face] = classPointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
            }
        }

        var buckets: [UInt8: [UInt32]] = [:]
        let corners = max(1, faces.indexCountPerPrimitive)
        for face in 0..<faces.count {
            guard corners >= 3 else { continue }
            let start = face * corners
            guard start + 2 < indices.count else { continue }
            buckets[classes[face], default: []].append(contentsOf: [indices[start], indices[start + 1], indices[start + 2]])
        }

        let parent = SCNNode()
        parent.name = "mesh"
        let sources = [vertexSource, normalSource]
        for (raw, faceIndices) in buckets where faceIndices.count >= 3 {
            let indexData = Packed.indexData(faceIndices)
            let primitiveCount = faceIndices.count / 3
            let fillElement = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: primitiveCount,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
            let wireElement = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: primitiveCount,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
            let fillGeometry = SCNGeometry(sources: sources, elements: [fillElement])
            let fillMaterial = SCNMaterial()
            fillMaterial.lightingModel = .constant
            fillMaterial.diffuse.contents = SurfaceClass.uiColor(raw: raw)
            fillMaterial.transparency = 0.34
            fillMaterial.isDoubleSided = true
            fillMaterial.writesToDepthBuffer = true
            fillMaterial.readsFromDepthBuffer = true
            fillGeometry.materials = [fillMaterial]
            let fillNode = SCNNode(geometry: fillGeometry)
            fillNode.name = "meshFill"
            fillNode.renderingOrder = 10
            fillNode.isHidden = style == .hidden

            let wireGeometry = SCNGeometry(sources: sources, elements: [wireElement])
            let wireMaterial = SCNMaterial()
            wireMaterial.lightingModel = .constant
            wireMaterial.diffuse.contents = SurfaceClass.wireUIColor(raw: raw)
            wireMaterial.fillMode = .lines
            wireMaterial.isDoubleSided = true
            wireMaterial.writesToDepthBuffer = false
            wireMaterial.readsFromDepthBuffer = true
            wireGeometry.materials = [wireMaterial]
            let wireNode = SCNNode(geometry: wireGeometry)
            wireNode.name = "meshWire"
            wireNode.renderingOrder = 11
            wireNode.isHidden = style != .wireAndFill

            parent.addChildNode(fillNode)
            parent.addChildNode(wireNode)
        }
        return parent
    }
}
