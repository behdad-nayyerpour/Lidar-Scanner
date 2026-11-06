import Foundation
import MetalKit
import ModelIO
import SceneKit
import UIKit
import simd

enum MeshExporter {
    static func plyData(mesh: ScanMesh) -> Data {
        MeshIO.encode(mesh)
    }

    static func stlData(mesh: ScanMesh, millimeters: Bool, zUp: Bool) -> Data {
        let scale: Float = millimeters ? 1000 : 1
        var data = Data()
        var header = [UInt8](repeating: 32, count: 80)
        for (index, byte) in Array("Lidar Scanner".utf8).enumerated() where index < 80 {
            header[index] = byte
        }
        data.append(contentsOf: header)
        data.appendLE(UInt32(mesh.triangleCount))
        for triangle in 0..<mesh.triangleCount {
            let a = oriented(mesh.positions[Int(mesh.indices[triangle * 3])], scale: scale, zUp: zUp)
            let b = oriented(mesh.positions[Int(mesh.indices[triangle * 3 + 1])], scale: scale, zUp: zUp)
            let c = oriented(mesh.positions[Int(mesh.indices[triangle * 3 + 2])], scale: scale, zUp: zUp)
            let normalRaw = simd_cross(b - a, c - a)
            let length = simd_length(normalRaw)
            let normal = length > 1e-8 ? normalRaw / length : SIMD3<Float>(0, 0, 1)
            data.append(normal)
            data.append(a)
            data.append(b)
            data.append(c)
            data.appendLE(UInt16(0))
        }
        return data
    }

    static func dxfData(mesh: ScanMesh, millimeters: Bool, zUp: Bool) -> Data {
        var data = Data()
        data.reserveCapacity(mesh.triangleCount * 180 + 256)
        func line(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(contentsOf: [0x0D, 0x0A])
        }
        func vertex(_ codeX: String, _ codeY: String, _ codeZ: String, _ point: SIMD3<Float>) {
            line(codeX)
            line(String(format: "%.5f", point.x))
            line(codeY)
            line(String(format: "%.5f", point.y))
            line(codeZ)
            line(String(format: "%.5f", point.z))
        }
        line("0")
        line("SECTION")
        line("2")
        line("HEADER")
        line("9")
        line("$ACADVER")
        line("1")
        line("AC1009")
        line("9")
        line("$INSUNITS")
        line("70")
        line(millimeters ? "4" : "6")
        line("9")
        line("$MEASUREMENT")
        line("70")
        line("1")
        line("0")
        line("ENDSEC")
        line("0")
        line("SECTION")
        line("2")
        line("TABLES")
        line("0")
        line("TABLE")
        line("2")
        line("LAYER")
        line("70")
        line("1")
        line("0")
        line("LAYER")
        line("2")
        line("MESH")
        line("70")
        line("0")
        line("62")
        line("7")
        line("6")
        line("CONTINUOUS")
        line("0")
        line("ENDTAB")
        line("0")
        line("ENDSEC")
        line("0")
        line("SECTION")
        line("2")
        line("ENTITIES")
        for triangle in 0..<mesh.triangleCount {
            let a = oriented(mesh.positions[Int(mesh.indices[triangle * 3])], scale: millimeters ? 1000 : 1, zUp: zUp)
            let b = oriented(mesh.positions[Int(mesh.indices[triangle * 3 + 1])], scale: millimeters ? 1000 : 1, zUp: zUp)
            let c = oriented(mesh.positions[Int(mesh.indices[triangle * 3 + 2])], scale: millimeters ? 1000 : 1, zUp: zUp)
            line("0")
            line("3DFACE")
            line("8")
            line("MESH")
            vertex("10", "20", "30", a)
            vertex("11", "21", "31", b)
            vertex("12", "22", "32", c)
            vertex("13", "23", "33", c)
        }
        line("0")
        line("ENDSEC")
        line("0")
        line("EOF")
        return data
    }

    static func objPackage(mesh: ScanMesh, baseName: String, atlas: UIImage? = nil) throws -> Data {
        let safe = FileNames.safe(baseName)
        if let atlas, mesh.uvs.count == mesh.positions.count, let jpeg = atlas.jpegData(compressionQuality: 0.9) {
            let obj = objText(positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs, colors: nil, indices: mesh.indices, material: "\(safe).mtl")
            let mtl = "newmtl scan\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nd 1\nmap_Kd \(safe).jpg\n"
            return try ZipWriter.store(files: [
                ("\(safe).obj", Data(obj.utf8)),
                ("\(safe).mtl", Data(mtl.utf8)),
                ("\(safe).jpg", jpeg)
            ])
        }
        if let baked = TextureBaker.bake(mesh), let png = baked.pngData() {
            let obj = objText(positions: baked.positions, normals: baked.normals, uvs: baked.uvs, colors: nil, indices: baked.indices, material: "\(safe).mtl")
            let mtl = "newmtl scan\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nd 1\nmap_Kd \(safe).png\n"
            return try ZipWriter.store(files: [
                ("\(safe).obj", Data(obj.utf8)),
                ("\(safe).mtl", Data(mtl.utf8)),
                ("\(safe).png", png)
            ])
        }
        let obj = objText(
            positions: mesh.positions,
            normals: mesh.normals.count == mesh.positions.count ? mesh.normals : mesh.positions.map { _ in SIMD3<Float>(0, 1, 0) },
            uvs: nil,
            colors: mesh.colors.count == mesh.positions.count ? mesh.colors : nil,
            indices: mesh.indices,
            material: nil
        )
        return try ZipWriter.store(files: [("\(safe).obj", Data(obj.utf8))])
    }

    static func glbData(mesh: ScanMesh, atlas: UIImage? = nil) throws -> Data {
        if let atlas, mesh.uvs.count == mesh.positions.count, let png = atlas.pngData() {
            return try GLBPacker.pack(
                positions: mesh.positions,
                normals: mesh.normals.count == mesh.positions.count ? mesh.normals : [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: mesh.positions.count),
                uvs: mesh.uvs.map { SIMD2($0.x, 1 - $0.y) },
                colors: nil,
                indices: mesh.indices,
                png: png
            )
        }
        if let baked = TextureBaker.bake(mesh), let png = baked.pngData() {
            let flipped = baked.uvs.map { SIMD2<Float>($0.x, 1 - $0.y) }
            return try GLBPacker.pack(
                positions: baked.positions,
                normals: baked.normals,
                uvs: flipped,
                colors: nil,
                indices: baked.indices,
                png: png
            )
        }
        return try GLBPacker.pack(
            positions: mesh.positions,
            normals: mesh.normals.count == mesh.positions.count ? mesh.normals : [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: mesh.positions.count),
            uvs: nil,
            colors: mesh.colors.count == mesh.positions.count ? mesh.colors : [SIMD3<Float>](repeating: SIMD3(repeating: 0.72), count: mesh.positions.count),
            indices: mesh.indices,
            png: nil
        )
    }

    static func usdzTextured(mesh: ScanMesh, image: UIImage, to url: URL) throws {
        guard let geometry = mesh.texturedGeometry(image: image) else {
            try usdz(mesh: mesh, baked: nil, to: url, allowBake: false)
            return
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ScanError.exportFailed(L10n.exportFailed)
        }
    }

    static func usdz(mesh: ScanMesh, baked: BakedTexture? = nil, to url: URL, allowBake: Bool = true) throws {
        let texture = baked ?? (allowBake ? TextureBaker.bake(mesh) : nil)
        if let texture, let geometry = texture.makeTexturedGeometry() {
            let scene = SCNScene()
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            if scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) {
                return
            }
        }
        try writeVertexColorUSDZ(mesh: mesh, to: url)
    }

    static func allFormatsZip(mesh: ScanMesh, baseName: String, includeOriginalUSDZ: URL?, atlas: UIImage? = nil) throws -> Data {
        let safe = FileNames.safe(baseName)
        var files: [(String, Data)] = []
        files.append(("\(safe).ply", plyData(mesh: mesh)))
        files.append(("\(safe).stl", stlData(mesh: mesh, millimeters: true, zUp: true)))
        files.append(("\(safe).dxf", dxfData(mesh: mesh, millimeters: true, zUp: true)))
        files.append(("\(safe).glb", try glbData(mesh: mesh, atlas: atlas)))
        if let atlas, mesh.uvs.count == mesh.positions.count, let jpeg = atlas.jpegData(compressionQuality: 0.9) {
            let obj = objText(positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs, colors: nil, indices: mesh.indices, material: "\(safe).mtl")
            let mtl = "newmtl scan\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nd 1\nmap_Kd \(safe).jpg\n"
            files.append(("\(safe).obj", Data(obj.utf8)))
            files.append(("\(safe).mtl", Data(mtl.utf8)))
            files.append(("\(safe).jpg", jpeg))
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("usdz")
            try? usdzTextured(mesh: mesh, image: atlas, to: temp)
            if let usdzData = try? Data(contentsOf: temp) {
                files.append(("\(safe).usdz", usdzData))
            }
            try? FileManager.default.removeItem(at: temp)
            if let includeOriginalUSDZ, let data = try? Data(contentsOf: includeOriginalUSDZ) {
                files.append(("\(safe)-original.usdz", data))
            }
            return try ZipWriter.store(files: files)
        }
        if let baked = TextureBaker.bake(mesh), let png = baked.pngData() {
            let obj = objText(positions: baked.positions, normals: baked.normals, uvs: baked.uvs, colors: nil, indices: baked.indices, material: "\(safe).mtl")
            let mtl = "newmtl scan\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nd 1\nmap_Kd \(safe).png\n"
            files.append(("\(safe).obj", Data(obj.utf8)))
            files.append(("\(safe).mtl", Data(mtl.utf8)))
            files.append(("\(safe).png", png))
        } else {
            let obj = objText(positions: mesh.positions, normals: mesh.normals, uvs: nil, colors: mesh.colors, indices: mesh.indices, material: nil)
            files.append(("\(safe).obj", Data(obj.utf8)))
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("usdz")
        try usdz(mesh: mesh, baked: nil, to: temp)
        if let usdzData = try? Data(contentsOf: temp) {
            files.append(("\(safe).usdz", usdzData))
        }
        try? FileManager.default.removeItem(at: temp)
        if let includeOriginalUSDZ, let data = try? Data(contentsOf: includeOriginalUSDZ) {
            files.append(("\(safe)-original.usdz", data))
        }
        return try ZipWriter.store(files: files)
    }

    private static func oriented(_ position: SIMD3<Float>, scale: Float, zUp: Bool) -> SIMD3<Float> {
        let scaled = position * scale
        if zUp {
            return SIMD3(scaled.x, -scaled.z, scaled.y)
        }
        return scaled
    }

    private static func objText(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs: [SIMD2<Float>]?,
        colors: [SIMD3<Float>]?,
        indices: [UInt32],
        material: String?
    ) -> String {
        var lines: [String] = ["# Lidar Scanner"]
        if let material {
            lines.append("mtllib \(material)")
            lines.append("usemtl scan")
        }
        for index in positions.indices {
            let p = positions[index]
            if let colors, index < colors.count {
                let c = colors[index]
                lines.append(String(format: "v %.6f %.6f %.6f %.5f %.5f %.5f", p.x, p.y, p.z, c.x, c.y, c.z))
            } else {
                lines.append(String(format: "v %.6f %.6f %.6f", p.x, p.y, p.z))
            }
        }
        if let uvs {
            for uv in uvs {
                lines.append(String(format: "vt %.6f %.6f", uv.x, uv.y))
            }
        }
        for index in normals.indices {
            let n = normals[index]
            lines.append(String(format: "vn %.6f %.6f %.6f", n.x, n.y, n.z))
        }
        let triangles = indices.count / 3
        for triangle in 0..<triangles {
            let a = Int(indices[triangle * 3]) + 1
            let b = Int(indices[triangle * 3 + 1]) + 1
            let c = Int(indices[triangle * 3 + 2]) + 1
            if uvs != nil {
                lines.append("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)")
            } else {
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeVertexColorUSDZ(mesh: ScanMesh, to url: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ScanError.exportFailed(L10n.exportFailed)
        }
        let allocator = MTKMeshBufferAllocator(device: device)
        var interleaved = Data()
        interleaved.reserveCapacity(mesh.positions.count * 36)
        for index in mesh.positions.indices {
            let position = mesh.positions[index]
            let normal = index < mesh.normals.count ? mesh.normals[index] : SIMD3<Float>(0, 1, 0)
            let color = index < mesh.colors.count ? mesh.colors[index] : SIMD3<Float>(repeating: 0.72)
            interleaved.append(position)
            interleaved.append(normal)
            interleaved.append(color)
        }
        let vertexBuffer = allocator.newBuffer(with: interleaved, type: .vertex)
        let indexBuffer = allocator.newBuffer(with: Packed.indexData(mesh.indices), type: .index)
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float3, offset: 24, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 36)
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: mesh.positions.count,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        let asset = MDLAsset(bufferAllocator: allocator)
        asset.add(mdlMesh)
        try asset.export(to: url)
    }
}

private extension Data {
    mutating func append(_ vector: SIMD3<Float>) {
        appendLE(vector.x.bitPattern)
        appendLE(vector.y.bitPattern)
        appendLE(vector.z.bitPattern)
    }
}

enum GLBPacker {
    static func pack(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs: [SIMD2<Float>]?,
        colors: [SIMD3<Float>]?,
        indices: [UInt32],
        png: Data?
    ) throws -> Data {
        guard !positions.isEmpty, indices.count >= 3 else { throw ScanError.emptyMesh }
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func align() {
            while bin.count % 4 != 0 { bin.append(0) }
        }
        func addView(_ data: Data, target: Int?) -> Int {
            align()
            let offset = bin.count
            bin.append(data)
            var view: [String: Any] = ["buffer": 0, "byteOffset": offset, "byteLength": data.count]
            if let target { view["target"] = target }
            bufferViews.append(view)
            return bufferViews.count - 1
        }
        func addAccessor(view: Int, count: Int, type: String, component: Int, min: [Double]? = nil, max: [Double]? = nil) -> Int {
            var accessor: [String: Any] = [
                "bufferView": view,
                "byteOffset": 0,
                "componentType": component,
                "count": count,
                "type": type
            ]
            if let min { accessor["min"] = min }
            if let max { accessor["max"] = max }
            accessors.append(accessor)
            return accessors.count - 1
        }

        var minP = positions[0]
        var maxP = positions[0]
        for position in positions {
            minP = simd_min(minP, position)
            maxP = simd_max(maxP, position)
        }
        let positionView = addView(Packed.float3Data(positions), target: 34962)
        let positionAccessor = addAccessor(
            view: positionView,
            count: positions.count,
            type: "VEC3",
            component: 5126,
            min: [Double(minP.x), Double(minP.y), Double(minP.z)],
            max: [Double(maxP.x), Double(maxP.y), Double(maxP.z)]
        )
        let normalView = addView(Packed.float3Data(normals), target: 34962)
        let normalAccessor = addAccessor(view: normalView, count: normals.count, type: "VEC3", component: 5126)
        var attributes: [String: Any] = ["POSITION": positionAccessor, "NORMAL": normalAccessor]
        if let uvs {
            let view = addView(Packed.float2Data(uvs), target: 34962)
            attributes["TEXCOORD_0"] = addAccessor(view: view, count: uvs.count, type: "VEC2", component: 5126)
        }
        if let colors {
            let view = addView(Packed.float3Data(colors), target: 34962)
            attributes["COLOR_0"] = addAccessor(view: view, count: colors.count, type: "VEC3", component: 5126)
        }
        let indexView = addView(Packed.indexData(indices), target: 34963)
        let indexAccessor = addAccessor(view: indexView, count: indices.count, type: "SCALAR", component: 5125)

        var material: [String: Any] = [
            "doubleSided": true,
            "pbrMetallicRoughness": [
                "baseColorFactor": [1, 1, 1, 1],
                "metallicFactor": 0,
                "roughnessFactor": 0.9
            ]
        ]
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        var samplers: [[String: Any]] = []
        if let png {
            let view = addView(png, target: nil)
            images.append(["bufferView": view, "mimeType": "image/png"])
            samplers.append(["magFilter": 9729, "minFilter": 9729, "wrapS": 33071, "wrapT": 33071])
            textures.append(["sampler": 0, "source": 0])
            var pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
            pbr["baseColorTexture"] = ["index": 0]
            material["pbrMetallicRoughness"] = pbr
        }

        align()
        var root: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Lidar Scanner"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [[
                "primitives": [[
                    "attributes": attributes,
                    "indices": indexAccessor,
                    "material": 0,
                    "mode": 4
                ]]
            ]],
            "materials": [material],
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]]
        ]
        if !images.isEmpty {
            root["images"] = images
            root["textures"] = textures
            root["samplers"] = samplers
        }

        var json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        while json.count % 4 != 0 { json.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }

        let total = 12 + 8 + json.count + 8 + bin.count
        var file = Data()
        file.appendLE(UInt32(0x46546C67))
        file.appendLE(UInt32(2))
        file.appendLE(UInt32(total))
        file.appendLE(UInt32(json.count))
        file.appendLE(UInt32(0x4E4F534A))
        file.append(json)
        file.appendLE(UInt32(bin.count))
        file.appendLE(UInt32(0x004E4942))
        file.append(bin)
        return file
    }
}
