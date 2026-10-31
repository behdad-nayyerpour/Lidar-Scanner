import SceneKit
import simd
import SwiftUI
import UIKit

struct MeasureLabel: Identifiable {
    let id: UUID
    let point: CGPoint
    let text: String
}

final class ViewerModel: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let sceneView = SCNView()
    @Published var isLoading = true
    @Published var errorText: String?
    @Published var measuring = false
    @Published var shaded = false
    @Published var showClasses = false
    @Published var wireframe = false
    @Published var backdrop: ViewerBackdrop = .dark
    @Published var uncoloredTint: UncoloredTint = .clay
    @Published var customBackdrop = UIColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1)
    @Published var customTint = UIColor(red: 0.77, green: 0.64, blue: 0.52, alpha: 1)
    private var meshIsColored = false
    @Published var labels: [MeasureLabel] = []
    @Published var measurements: [StoredMeasurement] = []
    @Published var triangleCount = 0
    @Published var vertexCount = 0
    @Published var area: Float = 0
    @Published var boundsSize = SIMD3<Float>.zero
    @Published var canProcess = false
    @Published var presentClasses: [UInt8] = []

    private var mesh: ScanMesh?
    private var usingUSDZ = false
    private var draft: SIMD3<Float>?
    private var lastLabelUpdate: TimeInterval = 0
    var onMeasurementsChange: (([StoredMeasurement]) -> Void)?

    var textureImage: UIImage?

    func show(mesh: ScanMesh, colored: Bool, texture: UIImage? = nil) {
        self.mesh = mesh
        textureImage = texture
        meshIsColored = colored || texture != nil
        if colored || texture != nil { shaded = false }
        usingUSDZ = false
        triangleCount = mesh.triangleCount
        vertexCount = mesh.positions.count
        area = mesh.surfaceArea()
        boundsSize = mesh.boundingBox().size
        presentClasses = Array(mesh.classRawValues()).sorted()
        canProcess = true
        install(scene: scene(for: mesh))
    }

    func showUSDZ(_ url: URL) {
        guard let scene = try? SCNScene(url: url, options: nil) else {
            errorText = L10n.viewerProcessUnavailable
            isLoading = false
            return
        }
        usingUSDZ = true
        mesh = nil
        canProcess = false
        showClasses = false
        let box = SceneFraming.bounds(of: scene)
        boundsSize = box.size
        install(scene: scene)
    }

    func rebuildAppearance() {
        guard let mesh, !usingUSDZ else { return }
        install(scene: scene(for: mesh))
    }

    func resetCamera() {
        guard let scene = sceneView.scene, let camera = sceneView.pointOfView else { return }
        SceneFraming.frame(camera, in: scene)
    }

    func clearMeasurements() {
        measurements = []
        draft = nil
        onMeasurementsChange?([])
        rebuildOverlays()
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard measuring, gesture.state == .ended else { return }
        let point = gesture.location(in: sceneView)
        let hits = sceneView.hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        guard let hit = hits.first(where: { acceptable($0.node) }) else { return }
        let world = SIMD3<Float>(hit.simdWorldCoordinates)
        if let start = draft {
            let measurement = StoredMeasurement(start: start, end: world)
            measurements.append(measurement)
            draft = nil
            onMeasurementsChange?(measurements)
            Haptics.tap()
        } else {
            draft = world
            Haptics.tap()
        }
        rebuildOverlays()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard measuring else { return }
        let now = CACurrentMediaTime()
        guard now - lastLabelUpdate > 0.05 else { return }
        lastLabelUpdate = now
        DispatchQueue.main.async { [weak self] in
            self?.refreshLabels()
        }
    }

    var backdropColor: UIColor { backdrop.color(custom: customBackdrop) }
    var uncoloredColor: UIColor { uncoloredTint.color(custom: customTint) }

    private func scene(for mesh: ScanMesh) -> SCNScene {
        let scene = SCNScene()
        if let textureImage, mesh.uvs.count == mesh.positions.count, let geometry = mesh.texturedGeometry(image: textureImage), !showClasses {
            let node = SCNNode(geometry: geometry)
            node.name = "scanMesh"
            if wireframe {
                let lines = mesh.makeGeometry(mode: .vertex, lit: false, wireframe: true, solidColor: wireColor)
                let wire = SCNNode(geometry: lines)
                wire.renderingOrder = 10
                node.addChildNode(wire)
            }
            scene.rootNode.addChildNode(node)
            return scene
        }
        let mode: ViewerColorMode = showClasses ? .classification : .vertex
        let solid = (!meshIsColored && mode == .vertex) ? uncoloredColor : nil
        let surface = mesh.makeGeometry(
            mode: mode,
            lit: solid != nil || (shaded && mode == .vertex),
            wireframe: false,
            solidColor: solid
        )
        let node = SCNNode(geometry: surface)
        node.name = "scanMesh"
        if wireframe {
            let lines = mesh.makeGeometry(mode: mode, lit: false, wireframe: true, solidColor: wireColor)
            let wire = SCNNode(geometry: lines)
            wire.name = "wireOverlay"
            wire.renderingOrder = 10
            wire.simdScale = SIMD3(repeating: 1.003)
            node.addChildNode(wire)
        }
        scene.rootNode.addChildNode(node)
        return scene
    }

    private var wireColor: UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        backdropColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luma = 0.3 * red + 0.59 * green + 0.11 * blue
        return luma > 0.55 ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.92, alpha: 1)
    }

    private func install(scene: SCNScene) {
        SceneFraming.prepare(scene, background: backdropColor, sculpted: !usingUSDZ && !meshIsColored && !showClasses)
        sceneView.backgroundColor = backdropColor
        sceneView.scene = scene
        sceneView.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        sceneView.allowsCameraControl = true
        sceneView.rendersContinuously = true
        isLoading = false
        errorText = nil
        rebuildOverlays()
    }

    private func acceptable(_ node: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let item = current {
            if item.name == "marker" || item.name == "measureLine" || item.name == "light" || item.name == "camera" {
                return false
            }
            current = item.parent
        }
        return true
    }

    private func rebuildOverlays() {
        sceneView.scene?.rootNode.childNodes
            .filter { $0.name == "marker" || $0.name == "measureLine" }
            .forEach { $0.removeFromParentNode() }
        let scale = max(boundsSize.x, max(boundsSize.y, boundsSize.z))
        let radius = max(0.004, scale * 0.008)
        for measurement in measurements {
            guard let start = measurement.start, let end = measurement.end else { continue }
            addMarker(at: start, radius: radius)
            addMarker(at: end, radius: radius)
            addLine(from: start, to: end, radius: radius * 0.28)
        }
        if let draft {
            addMarker(at: draft, radius: radius)
        }
        refreshLabels()
    }

    private func addMarker(at position: SIMD3<Float>, radius: Float) {
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 12
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.15, green: 0.85, blue: 0.75, alpha: 1)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        node.name = "marker"
        sceneView.scene?.rootNode.addChildNode(node)
    }

    private func addLine(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.name = "measureLine"
        node.simdPosition = (start + end) * 0.5
        let direction = delta / length
        let up = SIMD3<Float>(0, 1, 0)
        if simd_length(simd_cross(up, direction)) < 0.001 {
            node.simdOrientation = simd_quatf(angle: direction.y >= 0 ? 0 : .pi, axis: SIMD3(1, 0, 0))
        } else {
            node.simdOrientation = simd_quatf(from: up, to: direction)
        }
        sceneView.scene?.rootNode.addChildNode(node)
    }

    private func refreshLabels() {
        let raw = UserDefaults.standard.string(forKey: "measurementUnit") ?? MeasurementUnit.meters.rawValue
        let unit = MeasurementUnit(rawValue: raw) ?? .meters
        var next: [MeasureLabel] = []
        for measurement in measurements {
            guard let start = measurement.start, let end = measurement.end else { continue }
            let mid = (start + end) * 0.5
            let projected = sceneView.projectPoint(SCNVector3(mid))
            guard projected.z > 0, projected.z < 1 else { continue }
            let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            guard sceneView.bounds.contains(point) else { continue }
            next.append(MeasureLabel(id: measurement.id, point: point, text: unit.formatDistance(simd_distance(start, end))))
        }
        labels = next
    }
}

struct ModelViewer: View {
    let scanID: UUID
    @EnvironmentObject private var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ViewerModel()
    @State private var showProcess = false
    @State private var showExport = false
    @State private var showQuickLook = false
    @State private var showAppearance = false
    @State private var showStats = false
    @State private var showQuality = false
    @State private var offeredQuality = false
    @State private var confirmRevert = false
    @State private var renameText = ""
    @State private var renaming = false
    @State private var alertText: String?

    private var record: ScanRecord? { library.record(scanID) }
    private var quickLookURL: URL? {
        let paths = library.paths(for: scanID)
        if paths.exists(paths.preview) { return paths.preview }
        if paths.exists(paths.capture) { return paths.capture }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ModelSceneView(model: model)
                ForEach(model.labels) { label in
                    Text(label.text)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .position(label.point)
                }
                .allowsHitTesting(false)
                if model.isLoading {
                    ProgressView(L10n.viewerLoading)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.showClasses {
                    classLegend
                }
                if model.measuring {
                    HStack(spacing: 8) {
                        Text(L10n.viewerMeasureHelp)
                        Button(L10n.viewerClear) { model.clearMeasurements() }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                }
            }
            colorBar
            bottomBar
        }
        .background(AppColor.background)
        .navigationTitle(record?.name ?? L10n.appName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: model.shaded) { _, _ in model.rebuildAppearance() }
        .onChange(of: model.showClasses) { _, _ in model.rebuildAppearance() }
        .onChange(of: model.wireframe) { _, _ in model.rebuildAppearance() }
        .onChange(of: library.record(scanID)?.updatedAt) { _, _ in
            Task { await load() }
        }
        .onAppear {
            if !offeredQuality, library.record(scanID)?.hasKeyframes == true, library.record(scanID)?.qualityApplied != true {
                offeredQuality = true
                showQuality = true
            }
            model.measurements = library.measurements(id: scanID)
            model.onMeasurementsChange = { measurements in
                try? library.saveMeasurements(id: scanID, measurements)
            }
        }
        .sheet(isPresented: $showProcess) {
            if let mesh = modelMesh {
                ProcessingSheet(mesh: mesh) { updated in
                    apply(updated)
                }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(scanID: scanID)
        }
        .fullScreenCover(isPresented: $showQuickLook) {
            ARScanPreview(url: quickLookURL, mesh: model.currentMesh, colored: library.record(scanID)?.isColored == true)
        }
        .sheet(isPresented: $showAppearance) {
            ViewerAppearanceSheet(model: model)
        }
        .sheet(isPresented: $showQuality) {
            QualitySheet { settings in
                library.startRefinement(id: scanID, settings: settings)
            }
        }
        .sheet(isPresented: $showStats) { statsSheet }
        .alert(L10n.libraryRename, isPresented: $renaming) {
            TextField(L10n.libraryRenamePrompt, text: $renameText)
            Button(L10n.librarySave) { try? library.rename(scanID, to: renameText) }
            Button(L10n.libraryCancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.viewerRevertTitle, isPresented: $confirmRevert, titleVisibility: .visible) {
            Button(L10n.viewerRevert, role: .destructive) { revert() }
            Button(L10n.libraryCancel, role: .cancel) {}
        } message: {
            Text(L10n.viewerRevertBody)
        }
        .alert(L10n.commonError, isPresented: alertPresented) {
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    private var modelMesh: ScanMesh? { model.currentMesh }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button(L10n.libraryRename, systemImage: "pencil") {
                    renameText = record?.name ?? ""
                    renaming = true
                }
                if record?.isColored == true {
                    Toggle(L10n.viewerLighting, isOn: $model.shaded)
                }
                Toggle(L10n.viewerClasses, isOn: $model.showClasses)
                Toggle(L10n.viewerWire, isOn: $model.wireframe)
                Button(L10n.viewerAppearance, systemImage: "paintpalette") { showAppearance = true }
                if record?.hasKeyframes == true {
                    Button(L10n.qualityRefine, systemImage: "square.stack.3d.up") { showQuality = true }
                    Button(L10n.qualityRetexture, systemImage: "paintbrush.pointed") {
                        var settings = FusionSettings.fast
                        settings.maxRange = 5
                        library.startRefinement(id: scanID, settings: settings)
                    }
                }
                if record?.builtAvailable == true {
                    if record?.showingBuilt == true {
                        Button(L10n.viewerShowGray, systemImage: "cube") {
                            try? library.showOriginalMesh(id: scanID)
                        }
                    } else {
                        Button(L10n.viewerShowBuilt, systemImage: "cube.fill") {
                            try? library.showBuiltMesh(id: scanID)
                        }
                    }
                }
                Button(L10n.viewerReset, systemImage: "viewfinder") { model.resetCamera() }
                Button(L10n.viewerStats, systemImage: "info.circle") { showStats = true }
                if library.paths(for: scanID).exists(library.paths(for: scanID).original) {
                    Button(L10n.viewerRevert, systemImage: "arrow.uturn.backward", role: .destructive) {
                        confirmRevert = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.viewerView)
        }
    }

    @ViewBuilder
    private var colorBar: some View {
        if let job = library.colorJob, job.scanID == scanID {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.message).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AppColor.textSecondary)
                }
                ProgressView(value: job.progress).tint(AppColor.accent)
                Button(L10n.colorCancel) { library.cancelAddingColor() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(AppColor.surface)
        } else if let job = library.refineJob, job.scanID == scanID {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.message).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AppColor.textSecondary)
                }
                ProgressView(value: job.progress).tint(AppColor.accent)
                if !library.buildLog.isEmpty {
                    Text(library.buildLog)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(L10n.colorCancel) { library.cancelRefinement() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(AppColor.surface)
        } else if record?.canAddColor == true {
            Button {
                library.startAddingColor(to: scanID)
            } label: {
                Label(L10n.colorAdd, systemImage: "paintbrush")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.onAccent)
            .background(AppColor.accent)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            barButton(L10n.viewerMeasure, "ruler", active: model.measuring) {
                model.measuring.toggle()
            }
            barButton(L10n.viewerProcess, "slider.horizontal.3", active: false) {
                if model.canProcess { showProcess = true }
                else { alertText = L10n.viewerProcessUnavailable }
            }
            barButton(L10n.viewerQuickLook, "arkit", active: false) {
                showQuickLook = true
            }
            barButton(L10n.viewerExport, "square.and.arrow.up", active: false) {
                showExport = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColor.surface)
    }

    private func barButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(active ? AppColor.onAccent : AppColor.textPrimary)
            .background(active ? AppColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var classLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.presentClasses, id: \.self) { raw in
                    HStack(spacing: 6) {
                        Circle().fill(Color(SurfaceClass.uiColor(raw: raw))).frame(width: 8, height: 8)
                        Text(SurfaceClass.title(raw: raw)).font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(12)
        }
    }

    private var statsSheet: some View {
        NavigationStack {
            List {
                if let record {
                    LabeledContent(L10n.modeRoomLabel, value: record.mode.title)
                    LabeledContent(L10n.viewerStats, value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent(L10n.statVertices, value: model.vertexCount.formatted())
                LabeledContent(L10n.statTriangles, value: model.triangleCount.formatted())
                LabeledContent(L10n.processResultSize, value: (MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "measurementUnit") ?? "") ?? .meters).formatSize(model.boundsSize))
                LabeledContent(L10n.statSize, value: (MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "measurementUnit") ?? "") ?? .meters).formatSize(model.boundsSize))
                LabeledContent(L10n.statArea, value: (MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "measurementUnit") ?? "") ?? .meters).formatArea(model.area))
                LabeledContent(L10n.statVolume, value: (MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "measurementUnit") ?? "") ?? .meters).formatVolume(model.currentMesh?.enclosedVolume() ?? 0))
            }
            .navigationTitle(L10n.viewerStats)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonDone) { showStats = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func load() async {
        let paths = library.paths(for: scanID)
        let record = library.record(scanID)
        let meshURL = paths.mesh
        if record?.isProcessed == false, paths.exists(paths.capture) {
            model.showUSDZ(paths.capture)
            if paths.exists(meshURL), let mesh = try? MeshIO.read(from: meshURL) {
                model.adoptCounts(from: mesh)
            }
            return
        }
        if paths.exists(meshURL) {
            do {
                let mesh = try await Task.detached(priority: .userInitiated) {
                    try MeshIO.read(from: meshURL)
                }.value
                var displayed = mesh
                let textured = record?.showingBuilt == true
                if textured, let uvs = UVFile.read(from: paths.uvs, expected: mesh.positions.count) {
                    displayed.uvs = uvs
                }
                let texture = textured ? UIImage(contentsOfFile: paths.texture.path) : nil
                model.show(mesh: displayed, colored: record?.isColored == true, texture: texture)
            } catch {
                model.errorText = error.localizedDescription
                model.isLoading = false
            }
        } else if paths.exists(paths.preview) {
            model.showUSDZ(paths.preview)
        } else {
            model.errorText = L10n.viewerProcessUnavailable
            model.isLoading = false
        }
    }

    private func apply(_ mesh: ScanMesh) {
        do {
            try library.replaceMesh(id: scanID, mesh: mesh)
            model.show(mesh: mesh, colored: library.record(scanID)?.isColored == true)
        } catch {
            alertText = error.localizedDescription
        }
    }

    private func revert() {
        do {
            try library.revert(id: scanID)
            Task { await load() }
        } catch {
            alertText = error.localizedDescription
        }
    }
}

private struct ModelSceneView: UIViewRepresentable {
    @ObservedObject var model: ViewerModel

    func makeUIView(context: Context) -> SCNView {
        let view = model.sceneView
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = model.backdropColor
        view.allowsCameraControl = true
        let tap = UITapGestureRecognizer(target: model, action: #selector(ViewerModel.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.delegate = model
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.backgroundColor = model.backdropColor
    }
}

extension ViewerModel {
    var currentMesh: ScanMesh? { mesh }

    func adoptCounts(from mesh: ScanMesh) {
        triangleCount = mesh.triangleCount
        vertexCount = mesh.positions.count
        area = mesh.surfaceArea()
        boundsSize = mesh.boundingBox().size
        canProcess = true
        self.mesh = mesh
    }
}

struct ProcessingSheet: View {
    let mesh: ScanMesh
    var onApply: (ScanMesh) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ProcessingSettings()
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(L10n.processSuggested) {
                        settings.smoothEnabled = true
                        settings.smoothIterations = 2
                        settings.removeFloaters = true
                        settings.floaterFraction = 0.005
                        settings.simplifyEnabled = false
                    }
                }
                Section(L10n.processCrop) {
                    Text(L10n.processCropHelp).font(.caption).foregroundStyle(AppColor.textSecondary)
                    cropSlider(L10n.classOther, value: $settings.cropMinX, label: "X min")
                    cropSlider("", value: $settings.cropMaxX, label: "X max")
                    cropSlider("", value: $settings.cropMinY, label: "Y min")
                    cropSlider("", value: $settings.cropMaxY, label: "Y max")
                    cropSlider("", value: $settings.cropMinZ, label: "Z min")
                    cropSlider("", value: $settings.cropMaxZ, label: "Z max")
                    Text("\(L10n.processResultSize): \(previewSize)")
                        .font(.subheadline)
                }
                Section {
                    Toggle(L10n.processSmooth, isOn: $settings.smoothEnabled)
                    Stepper(value: $settings.smoothIterations, in: 1...8) {
                        Text("\(L10n.processIterations): \(settings.smoothIterations)")
                    }
                    .disabled(!settings.smoothEnabled)
                }
                Section {
                    Toggle(L10n.processSimplify, isOn: $settings.simplifyEnabled)
                    Text(L10n.processSimplifyHelp).font(.caption).foregroundStyle(AppColor.textSecondary)
                    Slider(value: $settings.simplifyRatio, in: 0.1...1)
                        .disabled(!settings.simplifyEnabled)
                    Text(L10n.processKeep(Int((settings.simplifyRatio * 100).rounded())))
                        .font(.subheadline)
                }
                Section {
                    Toggle(L10n.processFloaters, isOn: $settings.removeFloaters)
                    Text(L10n.processFloatersHelp).font(.caption).foregroundStyle(AppColor.textSecondary)
                    Slider(value: $settings.floaterFraction, in: 0.001...0.05)
                        .disabled(!settings.removeFloaters)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(AppColor.danger)
                }
            }
            .navigationTitle(L10n.processTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.libraryCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.processApply) { apply() }
                        .disabled(working)
                }
            }
            .overlay {
                if working {
                    ProgressView(L10n.processWorking)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var previewSize: String {
        let box = mesh.boundingBox()
        let size = box.size
        let result = SIMD3(
            size.x * (1 - settings.cropMinX - settings.cropMaxX),
            size.y * (1 - settings.cropMinY - settings.cropMaxY),
            size.z * (1 - settings.cropMinZ - settings.cropMaxZ)
        )
        let unit = MeasurementUnit(rawValue: UserDefaults.standard.string(forKey: "measurementUnit") ?? "") ?? .meters
        return unit.formatSize(result)
    }

    private func cropSlider(_ unused: String, value: Binding<Float>, label: String) -> some View {
        HStack {
            Text(label).frame(width: 52, alignment: .leading).font(.caption)
            Slider(value: value, in: 0...0.45)
        }
    }

    private func apply() {
        working = true
        let source = mesh
        let settings = settings
        DispatchQueue.global(qos: .userInitiated).async {
            let updated = source.processed(settings)
            DispatchQueue.main.async {
                working = false
                if updated.isEmpty || updated.triangleCount < 4 {
                    errorText = L10n.processEmpty
                    return
                }
                onApply(updated)
                dismiss()
            }
        }
    }
}

struct ExportSheet: View {
    let scanID: UUID
    @EnvironmentObject private var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var millimeters = true
    @State private var zUp = true
    @State private var working = false
    @State private var share: SharePayload?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.exportCADUnits) {
                    Picker(L10n.exportSTLUnits, selection: $millimeters) {
                        Text(L10n.exportMillimeters).tag(true)
                        Text(L10n.exportMeters).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle(L10n.exportZUp, isOn: $zUp)
                }
                exportRow(L10n.exportPLY, L10n.exportPLYDetail) { try await exportPLY() }
                exportRow(L10n.exportOBJ, L10n.exportOBJDetail) { try await exportOBJ() }
                exportRow(L10n.exportSTL, L10n.exportSTLDetail) { try await exportSTL() }
                exportRow(L10n.exportDXF, L10n.exportDXFDetail) { try await exportDXF() }
                exportRow(L10n.exportUSDZ, L10n.exportUSDZDetail) { try await exportUSDZ() }
                exportRow(L10n.exportGLB, L10n.exportGLBDetail) { try await exportGLB() }
                if library.paths(for: scanID).exists(library.paths(for: scanID).capture) {
                    exportRow(L10n.exportOriginalUSDZ, L10n.exportOriginalDetail) { try await exportOriginal() }
                }
                exportRow(L10n.exportAll, L10n.exportAllDetail) { try await exportAll() }
                if library.paths(for: scanID).exists(library.paths(for: scanID).frames) {
                    exportRow(L10n.exportAllData, L10n.exportAllDataDetail) { try await exportFrames() }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(AppColor.danger)
                }
            }
            .navigationTitle(L10n.exportTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonClose) { dismiss() }
                }
            }
            .overlay {
                if working {
                    ProgressView(L10n.exportWorking)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .sheet(item: $share) { payload in
                ShareSheet(urls: payload.urls) {
                    try? FileManager.default.removeItem(at: payload.cleanup)
                }
            }
        }
    }

    private func exportRow(_ title: String, _ detail: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            run(action)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(AppColor.textPrimary)
                Text(detail).font(.caption).foregroundStyle(AppColor.textSecondary)
            }
        }
        .disabled(working)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        errorText = nil
        Task {
            do {
                try await action()
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }

    private func loadMesh() async throws -> ScanMesh {
        let paths = library.paths(for: scanID)
        var mesh: ScanMesh
        if let loaded = try library.loadMesh(id: scanID) {
            mesh = loaded
        } else {
            let source = paths.exists(paths.capture) ? paths.capture : paths.preview
            guard paths.exists(source) else { throw ScanError.fileMissing }
            mesh = try USDZExtractor.extract(from: source)
        }
        if let uvs = UVFile.read(from: paths.uvs, expected: mesh.positions.count) {
            mesh.uvs = uvs
        }
        return mesh
    }

    private func atlasImage() -> UIImage? {
        UIImage(contentsOfFile: library.paths(for: scanID).texture.path)
    }

    private func stage(_ name: String, _ data: Data) throws -> SharePayload {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return SharePayload(urls: [url], cleanup: folder)
    }

    private func baseName() -> String {
        FileNames.safe(library.record(scanID)?.name ?? "scan")
    }

    private func exportPLY() async throws {
        let mesh = try await loadMesh()
        share = try stage("\(baseName()).ply", MeshExporter.plyData(mesh: mesh))
    }

    private func exportOBJ() async throws {
        let mesh = try await loadMesh()
        share = try stage("\(baseName())-obj.zip", try MeshExporter.objPackage(mesh: mesh, baseName: baseName(), atlas: atlasImage()))
    }

    private func exportSTL() async throws {
        let mesh = try await loadMesh()
        share = try stage("\(baseName()).stl", MeshExporter.stlData(mesh: mesh, millimeters: millimeters, zUp: zUp))
    }

    private func exportUSDZ() async throws {
        let paths = library.paths(for: scanID)
        if paths.exists(paths.preview) {
            share = try shareCopy(of: paths.preview, name: "\(baseName()).usdz")
            return
        }
        let mesh = try await loadMesh()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(baseName()).usdz")
        try MeshExporter.usdz(mesh: mesh, to: url)
        share = SharePayload(urls: [url], cleanup: folder)
    }

    private func exportOriginal() async throws {
        let url = library.paths(for: scanID).capture
        guard library.paths(for: scanID).exists(url) else { throw ScanError.fileMissing }
        share = try shareCopy(of: url, name: "\(baseName())-original.usdz")
    }

    private func shareCopy(of url: URL, name: String) throws -> SharePayload {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: copy)
        return SharePayload(urls: [copy], cleanup: folder)
    }

    private func exportDXF() async throws {
        let mesh = try await loadMesh()
        share = try stage("\(baseName()).dxf", MeshExporter.dxfData(mesh: mesh, millimeters: millimeters, zUp: zUp))
    }

    private func exportGLB() async throws {
        let mesh = try await loadMesh()
        share = try stage("\(baseName()).glb", try MeshExporter.glbData(mesh: mesh, atlas: atlasImage()))
    }

    private func exportAll() async throws {
        let mesh = try await loadMesh()
        let original = library.paths(for: scanID).capture
        let data = try MeshExporter.allFormatsZip(
            mesh: mesh,
            baseName: baseName(),
            includeOriginalUSDZ: library.paths(for: scanID).exists(original) ? original : nil,
            atlas: atlasImage()
        )
        share = try stage("\(baseName())-all.zip", data)
    }

    private func exportFrames() async throws {
        let directory = library.paths(for: scanID).frames
        share = try stage("\(baseName())-all-data.zip", try KeyframeArchive.allDataZip(in: directory))
    }
}

enum ViewerBackdrop: String, CaseIterable, Identifiable {
    case dark
    case light
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return L10n.backdropDark
        case .light: return L10n.backdropLight
        case .custom: return L10n.backdropCustom
        }
    }

    func color(custom: UIColor) -> UIColor {
        switch self {
        case .dark: return UIColor(red: 0.09, green: 0.11, blue: 0.13, alpha: 1)
        case .light: return UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1)
        case .custom: return custom
        }
    }
}

enum UncoloredTint: String, CaseIterable, Identifiable {
    case clay
    case white
    case slate
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clay: return L10n.tintClay
        case .white: return L10n.tintWhite
        case .slate: return L10n.tintSlate
        case .custom: return L10n.backdropCustom
        }
    }

    func color(custom: UIColor) -> UIColor {
        switch self {
        case .clay: return UIColor(red: 0.78, green: 0.64, blue: 0.50, alpha: 1)
        case .white: return UIColor(red: 0.93, green: 0.93, blue: 0.91, alpha: 1)
        case .slate: return UIColor(red: 0.45, green: 0.52, blue: 0.58, alpha: 1)
        case .custom: return custom
        }
    }
}

struct ViewerAppearanceSheet: View {
    @ObservedObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var backdropPick: Color
    @State private var tintPick: Color

    init(model: ViewerModel) {
        self.model = model
        _backdropPick = State(initialValue: Color(uiColor: model.customBackdrop))
        _tintPick = State(initialValue: Color(uiColor: model.customTint))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.viewerBackground) {
                    Picker(L10n.viewerBackground, selection: $model.backdrop) {
                        ForEach(ViewerBackdrop.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    if model.backdrop == .custom {
                        ColorPicker(L10n.backdropCustom, selection: $backdropPick, supportsOpacity: false)
                    }
                }
                Section(L10n.viewerMeshColor) {
                    Picker(L10n.viewerMeshColor, selection: $model.uncoloredTint) {
                        ForEach(UncoloredTint.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if model.uncoloredTint == .custom {
                        ColorPicker(L10n.viewerMeshColor, selection: $tintPick, supportsOpacity: false)
                    }
                    Text(L10n.viewerMeshColorHelp)
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            .navigationTitle(L10n.viewerAppearance)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonDone) { dismiss() }
                }
            }
            .onChange(of: model.backdrop) { _, _ in model.rebuildAppearance() }
            .onChange(of: model.uncoloredTint) { _, _ in model.rebuildAppearance() }
            .onChange(of: backdropPick) { _, newValue in
                model.customBackdrop = UIColor(newValue)
                model.rebuildAppearance()
            }
            .onChange(of: tintPick) { _, newValue in
                model.customTint = UIColor(newValue)
                model.rebuildAppearance()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
