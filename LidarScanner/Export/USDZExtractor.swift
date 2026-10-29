import ModelIO
import SceneKit
import UIKit
import simd

enum USDZExtractor {
    static func extract(from url: URL) throws -> ScanMesh {
        if let scene = try? SCNScene(url: url, options: nil) {
            var mesh = ScanMesh()
            append(node: scene.rootNode, into: &mesh)
            mesh = mesh.compacted()
            if !mesh.isEmpty {
                if mesh.normals.count != mesh.positions.count {
                    mesh.recomputeNormals()
                }
                return mesh
            }
        }
        var mesh = extractModelIO(from: url)
        mesh = mesh.compacted()
        guard !mesh.isEmpty else { throw ScanError.unreadableMesh }
        if mesh.normals.count != mesh.positions.count {
            mesh.recomputeNormals()
        }
        return mesh
    }

    private static func append(node: SCNNode, into mesh: inout ScanMesh) {
        if let geometry = node.geometry {
            append(geometry: geometry, transform: node.simdWorldTransform, into: &mesh)
        }
        for child in node.childNodes {
            append(node: child, into: &mesh)
        }
    }

    private static func append(geometry: SCNGeometry, transform: simd_float4x4, into mesh: inout ScanMesh) {
        let vertexSource = geometry.sources(for: .vertex).first
        let normalSource = geometry.sources(for: .normal).first
        let colorSource = geometry.sources(for: .color).first
        let uvSource = geometry.sources(for: .texcoord).first
        let localPositions = vectors3(vertexSource)
        guard !localPositions.isEmpty else { return }
        let localNormals = vectors3(normalSource)
        let localColors = vectors3(colorSource)
        let localUVs = vectors2(uvSource)
        let normalMatrix = normalMatrix(from: transform)

        for (elementIndex, element) in geometry.elements.enumerated() {
            let material = geometry.materials.isEmpty ? nil : geometry.materials[min(elementIndex, geometry.materials.count - 1)]
            let texture = cgImage(from: material?.diffuse.contents)
            let fallback = color(from: material?.diffuse.contents) ?? SIMD3<Float>(repeating: 0.74)
            let rawIndices = indices(from: element)
            guard !rawIndices.isEmpty else { continue }
            let triangles = triangles(from: rawIndices, primitive: element.primitiveType)
            let base = UInt32(mesh.positions.count)
            for position in localPositions {
                mesh.positions.append(transformPoint(position, transform))
            }
            if localNormals.count == localPositions.count {
                for normal in localNormals {
                    let transformed = normalMatrix * normal
                    let length = simd_length(transformed)
                    mesh.normals.append(length > 1e-6 ? transformed / length : SIMD3(0, 1, 0))
                }
            } else {
                mesh.normals.append(contentsOf: repeatElement(SIMD3<Float>(0, 1, 0), count: localPositions.count))
            }
            for index in localPositions.indices {
                if index < localColors.count {
                    mesh.colors.append(localColors[index])
                } else if let texture, index < localUVs.count {
                    mesh.colors.append(sample(texture, localUVs[index]))
                } else {
                    mesh.colors.append(fallback)
                }
            }
            for triangle in triangles {
                let limit = UInt32(localPositions.count)
                guard triangle.0 < limit, triangle.1 < limit, triangle.2 < limit else { continue }
                mesh.indices.append(base + triangle.0)
                mesh.indices.append(base + triangle.1)
                mesh.indices.append(base + triangle.2)
                mesh.faceClasses.append(0)
            }
        }
    }

    private static func extractModelIO(from url: URL) -> ScanMesh {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        var mesh = ScanMesh()
        for index in 0..<asset.count {
            walk(asset.object(at: index), transform: matrix_identity_float4x4, into: &mesh)
        }
        return mesh
    }

    private static func walk(_ object: MDLObject, transform: simd_float4x4, into mesh: inout ScanMesh) {
        let local = object.transform?.matrix ?? matrix_identity_float4x4
        let world = transform * local
        if let mdlMesh = object as? MDLMesh {
            append(mdlMesh: mdlMesh, transform: world, into: &mesh)
        }
        for child in object.children.objects {
            walk(child, transform: world, into: &mesh)
        }
    }

    private static func append(mdlMesh: MDLMesh, transform: simd_float4x4, into mesh: inout ScanMesh) {
        guard let positionData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition),
              positionData.stride >= 12 else { return }
        let map = positionData.map
        let normalData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal)
        let normalMap = normalData?.map
        let colorData = mdlMesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor)
        let colorMap = colorData?.map
        let count = mdlMesh.vertexCount
        let base = mesh.positions.count
        let normalMatrix = normalMatrix(from: transform)
        for index in 0..<count {
            let position = read3(positionData.dataStart, stride: positionData.stride, index: index)
            mesh.positions.append(transformPoint(position, transform))
            if let normalData, normalData.stride >= 12 {
                let normal = normalMatrix * read3(normalData.dataStart, stride: normalData.stride, index: index)
                let length = simd_length(normal)
                mesh.normals.append(length > 1e-6 ? normal / length : SIMD3(0, 1, 0))
            } else {
                mesh.normals.append(SIMD3(0, 1, 0))
            }
            if let colorData, colorData.stride >= 12 {
                mesh.colors.append(simd_clamp(read3(colorData.dataStart, stride: colorData.stride, index: index), .zero, SIMD3(repeating: 1)))
            } else {
                mesh.colors.append(SIMD3(repeating: 0.74))
            }
        }
        _ = map
        _ = normalMap
        _ = colorMap

        for case let submesh as MDLSubmesh in mdlMesh.submeshes ?? [] {
            guard submesh.geometryType == .triangles else { continue }
            let indexMap = submesh.indexBuffer.map()
            let indexBase = UInt32(base)
            for triangle in triangles(submesh: submesh, bytes: indexMap.bytes) {
                mesh.indices.append(indexBase + triangle.0)
                mesh.indices.append(indexBase + triangle.1)
                mesh.indices.append(indexBase + triangle.2)
                mesh.faceClasses.append(0)
            }
        }
    }

    private static func triangles(submesh: MDLSubmesh, bytes: UnsafeMutableRawPointer) -> [(UInt32, UInt32, UInt32)] {
        let count = submesh.indexCount
        var values = [UInt32]()
        values.reserveCapacity(count)
        switch submesh.indexType {
        case .uInt32:
            for index in 0..<count {
                values.append(bytes.advanced(by: index * 4).loadUnaligned(as: UInt32.self))
            }
        case .uInt16:
            for index in 0..<count {
                values.append(UInt32(bytes.advanced(by: index * 2).loadUnaligned(as: UInt16.self)))
            }
        case .uInt8:
            for index in 0..<count {
                values.append(UInt32(bytes.advanced(by: index).loadUnaligned(as: UInt8.self)))
            }
        default:
            return []
        }
        var triangles: [(UInt32, UInt32, UInt32)] = []
        var index = 0
        while index + 2 < values.count {
            triangles.append((values[index], values[index + 1], values[index + 2]))
            index += 3
        }
        return triangles
    }

    private static func read3(_ pointer: UnsafeMutableRawPointer, stride: Int, index: Int) -> SIMD3<Float> {
        let raw = UnsafeRawPointer(pointer).advanced(by: stride * index)
        return SIMD3(
            raw.loadUnaligned(as: Float.self),
            raw.advanced(by: 4).loadUnaligned(as: Float.self),
            raw.advanced(by: 8).loadUnaligned(as: Float.self)
        )
    }

    private static func vectors3(_ source: SCNGeometrySource?) -> [SIMD3<Float>] {
        guard let source, source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                guard offset + 12 <= raw.count else { break }
                result.append(SIMD3(
                    raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                ))
            }
        }
        return result
    }

    private static func vectors2(_ source: SCNGeometrySource?) -> [SIMD2<Float>] {
        guard let source, source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 2 else { return [] }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                guard offset + 8 <= raw.count else { break }
                result.append(SIMD2(
                    raw.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                ))
            }
        }
        return result
    }

    private static func indices(from element: SCNGeometryElement) -> [UInt32] {
        let perPrimitive: Int
        switch element.primitiveType {
        case .triangles: perPrimitive = 3
        case .triangleStrip: perPrimitive = 1
        default: return []
        }
        let indexCount = element.primitiveType == .triangleStrip ? element.primitiveCount + 2 : element.primitiveCount * perPrimitive
        guard indexCount > 0 else { return [] }
        var result = [UInt32]()
        result.reserveCapacity(indexCount)
        element.data.withUnsafeBytes { raw in
            for index in 0..<indexCount {
                let offset = index * element.bytesPerIndex
                if element.bytesPerIndex == 4, offset + 4 <= raw.count {
                    result.append(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                } else if element.bytesPerIndex == 2, offset + 2 <= raw.count {
                    result.append(UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                } else if element.bytesPerIndex == 1, offset < raw.count {
                    result.append(UInt32(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)))
                }
            }
        }
        return result
    }

    private static func triangles(from indices: [UInt32], primitive: SCNGeometryPrimitiveType) -> [(UInt32, UInt32, UInt32)] {
        switch primitive {
        case .triangles:
            var triangles: [(UInt32, UInt32, UInt32)] = []
            var index = 0
            while index + 2 < indices.count {
                triangles.append((indices[index], indices[index + 1], indices[index + 2]))
                index += 3
            }
            return triangles
        case .triangleStrip:
            guard indices.count >= 3 else { return [] }
            return (0..<(indices.count - 2)).map { index in
                if index.isMultiple(of: 2) {
                    return (indices[index], indices[index + 1], indices[index + 2])
                }
                return (indices[index + 1], indices[index], indices[index + 2])
            }
        default:
            return []
        }
    }

    private static func transformPoint(_ point: SIMD3<Float>, _ transform: simd_float4x4) -> SIMD3<Float> {
        let result = transform * SIMD4(point.x, point.y, point.z, 1)
        return SIMD3(result.x, result.y, result.z)
    }

    private static func normalMatrix(from transform: simd_float4x4) -> simd_float3x3 {
        let upper = simd_float3x3(columns: (
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        let determinant = simd_determinant(upper)
        guard abs(determinant) > 1e-8 else { return upper }
        return simd_transpose(simd_inverse(upper))
    }

    private static func cgImage(from contents: Any?) -> CGImage? {
        switch contents {
        case let image as UIImage:
            return image.cgImage
        case let image as CGImage:
            return image
        case let url as URL:
            return UIImage(contentsOfFile: url.path)?.cgImage
        case let path as String:
            return UIImage(contentsOfFile: path)?.cgImage
        case let data as Data:
            return UIImage(data: data)?.cgImage
        default:
            return nil
        }
    }

    private static func color(from contents: Any?) -> SIMD3<Float>? {
        guard let color = contents as? UIColor else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return SIMD3(Float(red), Float(green), Float(blue))
    }

    private static func sample(_ image: CGImage, _ uv: SIMD2<Float>) -> SIMD3<Float> {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else {
            return SIMD3(repeating: 0.74)
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return SIMD3(repeating: 0.74) }
        let x = min(width - 1, max(0, Int(uv.x * Float(width - 1))))
        let y = min(height - 1, max(0, Int((1 - uv.y) * Float(height - 1))))
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(image.bitsPerPixel / 8, 3)
        let offset = y * bytesPerRow + x * bytesPerPixel
        let length = CFDataGetLength(data)
        guard offset + 2 < length else { return SIMD3(repeating: 0.74) }
        return SIMD3(
            Float(pointer[offset]) / 255,
            Float(pointer[offset + 1]) / 255,
            Float(pointer[offset + 2]) / 255
        )
    }
}
