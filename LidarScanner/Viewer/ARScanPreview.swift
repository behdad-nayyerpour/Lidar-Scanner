import ARKit
import RealityKit
import SwiftUI
import UIKit

struct ARScanPreview: View {
    let url: URL?
    let mesh: ScanMesh?
    let colored: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ARScanContainer(url: url, mesh: mesh, colored: colored, failed: $failed)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Label(L10n.arClose, systemImage: "xmark")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.arClose)
                if failed {
                    Text(L10n.arFailed)
                        .font(.subheadline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text(L10n.arHint)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

private struct ARScanContainer: UIViewRepresentable {
    let url: URL?
    let mesh: ScanMesh?
    let colored: Bool
    @Binding var failed: Bool

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        view.session.run(configuration)
        view.session.delegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, mesh: mesh, colored: colored, failed: $failed)
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let url: URL?
        let mesh: ScanMesh?
        let colored: Bool
        var failed: Binding<Bool>
        weak var view: ARView?
        private var placed = false
        private var model: Entity?

        init(url: URL?, mesh: ScanMesh?, colored: Bool, failed: Binding<Bool>) {
            self.url = url
            self.mesh = mesh
            self.colored = colored
            self.failed = failed
        }

        func attach(to view: ARView) {
            self.view = view
            Task { @MainActor in
                do {
                    let entity = try self.loadEntity()
                    self.prepare(entity)
                    self.model = entity
                } catch {
                    self.failed.wrappedValue = true
                    Log.scan.error("AR load failed \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard !placed, model != nil else { return }
            guard case .normal = frame.camera.trackingState else { return }
            placed = true
            let transform = frame.camera.transform
            DispatchQueue.main.async { [weak self] in
                guard let self, let model = self.model, let view = self.view else { return }
                let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                let anchor = AnchorEntity(world: origin + forward * 1.4)
                anchor.addChild(model)
                view.scene.addAnchor(anchor)
            }
        }

        private func loadEntity() throws -> Entity {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                return try Entity.load(contentsOf: url)
            }
            guard let mesh, !mesh.isEmpty else { throw ScanError.fileMissing }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("usdz")
            try MeshExporter.usdz(mesh: mesh, baked: nil, to: file, allowBake: false)
            return try Entity.load(contentsOf: file)
        }

        private func prepare(_ entity: Entity) {
            let bounds = entity.meshBounds()
            let extents = bounds.max - bounds.min
            let maxDimension = max(extents.x, max(extents.y, extents.z))
            let scale: Float = maxDimension > 1.5 ? 1.5 / max(maxDimension, 0.001) : 1
            entity.scale = SIMD3(repeating: scale)
            let center = (bounds.min + bounds.max) * 0.5
            entity.position = -center * scale
            if !colored {
                let material = SimpleMaterial(color: UIColor(red: 0.78, green: 0.64, blue: 0.50, alpha: 1), roughness: 0.65, isMetallic: false)
                entity.applyMaterial(material)
            }
        }
    }
}

private extension Entity {
    func applyMaterial(_ material: SimpleMaterial) {
        if var model = components[ModelComponent.self] {
            model.materials = [material]
            components[ModelComponent.self] = model
        }
        for child in children {
            child.applyMaterial(material)
        }
    }

    /// World-space mesh bounds. Uses MeshResource, which is available on iOS 17.
    func meshBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        func visit(_ entity: Entity, _ parent: simd_float4x4) {
            let world = parent * entity.transform.matrix
            if let model = entity.components[ModelComponent.self] {
                let box = model.mesh.bounds
                let corners = [
                    SIMD3(box.min.x, box.min.y, box.min.z),
                    SIMD3(box.max.x, box.min.y, box.min.z),
                    SIMD3(box.min.x, box.max.y, box.min.z),
                    SIMD3(box.max.x, box.max.y, box.min.z),
                    SIMD3(box.min.x, box.min.y, box.max.z),
                    SIMD3(box.max.x, box.min.y, box.max.z),
                    SIMD3(box.min.x, box.max.y, box.max.z),
                    SIMD3(box.max.x, box.max.y, box.max.z)
                ]
                for corner in corners {
                    let point = world * SIMD4(corner.x, corner.y, corner.z, 1)
                    let vector = SIMD3(point.x, point.y, point.z)
                    minV = simd_min(minV, vector)
                    maxV = simd_max(maxV, vector)
                    found = true
                }
            }
            for child in entity.children {
                visit(child, world)
            }
        }
        visit(self, matrix_identity_float4x4)
        if !found { return (min: .zero, max: SIMD3(repeating: 1)) }
        return (min: minV, max: maxV)
    }
}
