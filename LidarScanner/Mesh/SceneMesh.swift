import ARKit
import SceneKit
import simd
import UIKit

enum ViewerColorMode {
    case vertex
    case classification
}

enum SurfaceClass {
    static func color(raw: UInt8) -> SIMD3<Float> {
        switch ARMeshClassification(rawValue: Int(raw)) {
        case .floor: return SIMD3(0.25, 0.75, 0.52)
        case .wall: return SIMD3(0.36, 0.62, 0.95)
        case .ceiling: return SIMD3(0.95, 0.78, 0.35)
        case .table: return SIMD3(0.95, 0.55, 0.30)
        case .seat: return SIMD3(0.70, 0.48, 0.95)
        case .window: return SIMD3(0.42, 0.88, 0.95)
        case .door: return SIMD3(0.78, 0.52, 0.32)
        default: return SIMD3(0.74, 0.77, 0.79)
        }
    }

    static func title(raw: UInt8) -> String {
        switch ARMeshClassification(rawValue: Int(raw)) {
        case .floor: return L10n.classFloor
        case .wall: return L10n.classWall
        case .ceiling: return L10n.classCeiling
        case .table: return L10n.classTable
        case .seat: return L10n.classSeat
        case .window: return L10n.classWindow
        case .door: return L10n.classDoor
        default: return L10n.classOther
        }
    }

    static func uiColor(raw: UInt8) -> UIColor {
        let color = color(raw: raw)
        return UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
    }

    /// A lightened class color so triangle edges stay readable over the fill and the camera.
    static func wireUIColor(raw: UInt8) -> UIColor {
        let color = color(raw: raw)
        return UIColor(
            red: CGFloat(min(1, color.x * 0.35 + 0.65)),
            green: CGFloat(min(1, color.y * 0.35 + 0.65)),
            blue: CGFloat(min(1, color.z * 0.35 + 0.65)),
            alpha: 1
        )
    }
}

extension ScanMesh {
    func makeGeometry(mode: ViewerColorMode, lit: Bool, wireframe: Bool, solidColor: UIColor? = nil) -> SCNGeometry {
        switch mode {
        case .vertex:
            return makeIndexedGeometry(
                positions: positions,
                normals: normals.count == positions.count ? normals : flatNormals(),
                colors: colors.count == positions.count ? colors : [SIMD3<Float>](repeating: SIMD3(repeating: 0.72), count: positions.count),
                indices: indices,
                lit: lit,
                wireframe: wireframe,
                solidColor: solidColor
            )
        case .classification:
            var expandedPositions: [SIMD3<Float>] = []
            var expandedNormals: [SIMD3<Float>] = []
            var expandedColors: [SIMD3<Float>] = []
            var expandedIndices: [UInt32] = []
            for triangle in 0..<triangleCount {
                let corners = (0..<3).map { Int(indices[triangle * 3 + $0]) }
                guard corners.allSatisfy({ $0 >= 0 && $0 < positions.count }) else { continue }
                let raw = triangle < faceClasses.count ? faceClasses[triangle] : 0
                let color = SurfaceClass.color(raw: raw)
                let start = UInt32(expandedPositions.count)
                for index in corners {
                    expandedPositions.append(positions[index])
                    expandedNormals.append(index < normals.count ? normals[index] : SIMD3<Float>(0, 1, 0))
                    expandedColors.append(color)
                }
                expandedIndices.append(contentsOf: [start, start + 1, start + 2])
            }
            return makeIndexedGeometry(
                positions: expandedPositions,
                normals: expandedNormals,
                colors: expandedColors,
                indices: expandedIndices,
                lit: false,
                wireframe: wireframe
            )
        }
    }

    private func flatNormals() -> [SIMD3<Float>] {
        var mesh = self
        mesh.recomputeNormals()
        return mesh.normals
    }

    private func makeIndexedGeometry(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        colors: [SIMD3<Float>],
        indices: [UInt32],
        lit: Bool,
        wireframe: Bool,
        solidColor: UIColor? = nil
    ) -> SCNGeometry {
        var sources = [
            geometrySource(Packed.float3Data(positions), semantic: .vertex, components: 3),
            geometrySource(Packed.float3Data(normals), semantic: .normal, components: 3)
        ]
        if solidColor == nil {
            sources.append(geometrySource(Packed.float3Data(colors), semantic: .color, components: 3))
        }
        let element = SCNGeometryElement(
            data: Packed.indexData(indices),
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = wireframe ? .constant : (lit ? .lambert : .constant)
        material.diffuse.contents = solidColor ?? UIColor.white
        material.isDoubleSided = true
        material.locksAmbientWithDiffuse = true
        if wireframe {
            material.fillMode = .lines
        }
        geometry.materials = [material]
        return geometry
    }

    private func geometrySource(_ data: Data, semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: data.count / (components * 4),
            usesFloatComponents: true,
            componentsPerVector: components,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: components * 4
        )
    }
}

extension BakedTexture {
    func makeTexturedGeometry() -> SCNGeometry? {
        guard let image = cgImage() else { return nil }
        let sources = [
            SCNGeometrySource(
                data: Packed.float3Data(positions),
                semantic: .vertex,
                vectorCount: positions.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: 4,
                dataOffset: 0,
                dataStride: 12
            ),
            SCNGeometrySource(
                data: Packed.float3Data(normals),
                semantic: .normal,
                vectorCount: normals.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: 4,
                dataOffset: 0,
                dataStride: 12
            ),
            SCNGeometrySource(
                data: Packed.float2Data(uvs),
                semantic: .texcoord,
                vectorCount: uvs.count,
                usesFloatComponents: true,
                componentsPerVector: 2,
                bytesPerComponent: 4,
                dataOffset: 0,
                dataStride: 8
            )
        ]
        let element = SCNGeometryElement(
            data: Packed.indexData(indices),
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: 4
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIImage(cgImage: image)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .none
        material.isDoubleSided = true
        material.locksAmbientWithDiffuse = true
        geometry.materials = [material]
        return geometry
    }
}

enum SceneFraming {
    static func prepare(_ scene: SCNScene, background: UIColor, sculpted: Bool = false) {
        scene.rootNode.childNodes.filter { $0.name == "camera" }.forEach { $0.removeFromParentNode() }
        addLights(to: scene, sculpted: sculpted)
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = 500
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        frame(cameraNode, in: scene)
        scene.background.contents = background
    }

    static func frame(_ cameraNode: SCNNode, in scene: SCNScene) {
        let box = bounds(of: scene)
        let center = (box.min + box.max) * 0.5
        let extent = box.max - box.min
        let radius = max(0.05, max(extent.x, max(extent.y, extent.z)) * 0.5)
        let halfFov = 45 * Float.pi / 180 / 2
        let distance = radius / tan(halfFov) * 1.45
        cameraNode.camera?.zFar = Double(max(50, distance * 30))
        cameraNode.simdPosition = center + SIMD3(radius * 0.15, radius * 0.25, distance)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }

    static func bounds(of scene: SCNScene) -> AABB {
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        func visit(_ node: SCNNode) {
            if node.geometry != nil, node.name != "light", node.name != "camera" {
                let localMin = SIMD3<Float>(node.boundingBox.min)
                let localMax = SIMD3<Float>(node.boundingBox.max)
                let corners = [
                    SIMD3(localMin.x, localMin.y, localMin.z),
                    SIMD3(localMax.x, localMin.y, localMin.z),
                    SIMD3(localMin.x, localMax.y, localMin.z),
                    SIMD3(localMax.x, localMax.y, localMin.z),
                    SIMD3(localMin.x, localMin.y, localMax.z),
                    SIMD3(localMax.x, localMin.y, localMax.z),
                    SIMD3(localMin.x, localMax.y, localMax.z),
                    SIMD3(localMax.x, localMax.y, localMax.z)
                ]
                for corner in corners {
                    let world4 = node.simdWorldTransform * SIMD4(corner.x, corner.y, corner.z, 1)
                    let world = SIMD3(world4.x, world4.y, world4.z)
                    minV = simd_min(minV, world)
                    maxV = simd_max(maxV, world)
                    found = true
                }
            }
            for child in node.childNodes { visit(child) }
        }
        visit(scene.rootNode)
        if !found { return AABB(min: .zero, max: SIMD3(repeating: 1)) }
        return AABB(min: minV, max: maxV)
    }

    private static func addLights(to scene: SCNScene, sculpted: Bool) {
        scene.rootNode.childNodes.filter { $0.name == "light" }.forEach { $0.removeFromParentNode() }
        let ambient = SCNNode()
        ambient.name = "light"
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = sculpted ? 280 : 220
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.name = "light"
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = sculpted ? 1100 : 650
        key.eulerAngles = SCNVector3(-0.8, 0.55, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.name = "light"
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = sculpted ? 420 : 220
        fill.eulerAngles = SCNVector3(0.4, -1.2, 0)
        scene.rootNode.addChildNode(fill)
    }
}

extension SCNVector3 {
    init(_ vector: SIMD3<Float>) {
        self.init(vector.x, vector.y, vector.z)
    }
}

extension SIMD3 where Scalar == Float {
    init(_ vector: SCNVector3) {
        self.init(Float(vector.x), Float(vector.y), Float(vector.z))
    }
}
