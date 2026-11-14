import Foundation
import simd

enum MeshIO {
    static func encode(_ mesh: ScanMesh) -> Data {
        let vertexCount = mesh.positions.count
        let faceCount = mesh.triangleCount
        var fields = [
            "ply",
            "format binary_little_endian 1.0",
            "comment Lidar Scanner",
            "element vertex \(vertexCount)",
            "property float x",
            "property float y",
            "property float z",
            "property float nx",
            "property float ny",
            "property float nz",
            "property uchar red",
            "property uchar green",
            "property uchar blue"
        ]
        let textured = mesh.uvs.count == vertexCount
        if textured { fields += ["property float texture_u", "property float texture_v"] }
        fields += [
            "element face \(faceCount)",
            "property list uchar uint vertex_indices",
            "end_header"
        ]
        let header = fields.joined(separator: "\n") + "\n"
        var data = Data(header.utf8)
        for index in 0..<vertexCount {
            let position = mesh.positions[index]
            let normal = index < mesh.normals.count ? mesh.normals[index] : SIMD3<Float>(0, 1, 0)
            let color = index < mesh.colors.count ? mesh.colors[index] : SIMD3<Float>(repeating: 0.72)
            data.appendFloat(position.x)
            data.appendFloat(position.y)
            data.appendFloat(position.z)
            data.appendFloat(normal.x)
            data.appendFloat(normal.y)
            data.appendFloat(normal.z)
            data.appendUInt8(UInt8((min(1, max(0, color.x)) * 255).rounded()))
            data.appendUInt8(UInt8((min(1, max(0, color.y)) * 255).rounded()))
            data.appendUInt8(UInt8((min(1, max(0, color.z)) * 255).rounded()))
            if textured {
                data.appendFloat(mesh.uvs[index].x)
                data.appendFloat(mesh.uvs[index].y)
            }
        }
        for triangle in 0..<faceCount {
            data.appendUInt8(3)
            data.appendUInt32(mesh.indices[triangle * 3])
            data.appendUInt32(mesh.indices[triangle * 3 + 1])
            data.appendUInt32(mesh.indices[triangle * 3 + 2])
        }
        return data
    }

    static func read(from url: URL) throws -> ScanMesh {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> ScanMesh {
        guard let headerEnd = data.range(of: Data("end_header\n".utf8)) ?? data.range(of: Data("end_header\r\n".utf8)) else {
            throw ScanError.unreadableMesh
        }
        let headerData = data.subdata(in: 0..<headerEnd.upperBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw ScanError.unreadableMesh
        }
        guard header.contains("binary_little_endian") else {
            throw ScanError.unreadableMesh
        }

        var vertexCount = 0
        var faceCount = 0
        var vertexProperties: [String] = []
        var section = ""
        for rawLine in header.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("element ") {
                let parts = line.split(separator: " ")
                if parts.count == 3 {
                    section = String(parts[1])
                    let count = Int(parts[2]) ?? 0
                    if section == "vertex" { vertexCount = count }
                    if section == "face" { faceCount = count }
                }
            } else if line.hasPrefix("property ") {
                if section == "vertex" {
                    let name = line.split(separator: " ").last.map(String.init) ?? ""
                    vertexProperties.append(name)
                }
            }
        }

        var cursor = headerEnd.upperBound
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var colors = [SIMD3<Float>]()
        var uvs = [SIMD2<Float>]()
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        colors.reserveCapacity(vertexCount)

        for _ in 0..<vertexCount {
            var values: [String: Float] = [:]
            var colorBytes: [String: UInt8] = [:]
            for property in vertexProperties {
                if property == "red" || property == "green" || property == "blue" {
                    colorBytes[property] = try data.readUInt8(&cursor)
                } else {
                    values[property] = try data.readFloat(&cursor)
                }
            }
            if let u = values["texture_u"], let v = values["texture_v"] { uvs.append(SIMD2(u, v)) }
            positions.append(SIMD3(values["x"] ?? 0, values["y"] ?? 0, values["z"] ?? 0))
            normals.append(SIMD3(values["nx"] ?? 0, values["ny"] ?? 1, values["nz"] ?? 0))
            colors.append(SIMD3(
                Float(colorBytes["red"] ?? 184) / 255,
                Float(colorBytes["green"] ?? 184) / 255,
                Float(colorBytes["blue"] ?? 184) / 255
            ))
        }

        var indices = [UInt32]()
        indices.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            let count = Int(try data.readUInt8(&cursor))
            guard count == 3 else { throw ScanError.unreadableMesh }
            indices.append(try data.readUInt32(&cursor))
            indices.append(try data.readUInt32(&cursor))
            indices.append(try data.readUInt32(&cursor))
        }

        var mesh = ScanMesh(positions: positions, normals: normals, colors: colors, indices: indices, faceClasses: [])
        mesh.uvs = uvs
        if mesh.normals.count != mesh.positions.count || mesh.normals.allSatisfy({ simd_length($0) < 0.01 }) {
            mesh.recomputeNormals()
        }
        return mesh
    }
}

private extension Data {
    mutating func appendFloat(_ value: Float) {
        var little = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func readFloat(_ cursor: inout Int) throws -> Float {
        guard cursor + 4 <= count else { throw ScanError.unreadableMesh }
        let value = withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        }
        cursor += 4
        return Float(bitPattern: UInt32(littleEndian: value))
    }

    func readUInt32(_ cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= count else { throw ScanError.unreadableMesh }
        let value = withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        }
        cursor += 4
        return UInt32(littleEndian: value)
    }

    func readUInt8(_ cursor: inout Int) throws -> UInt8 {
        guard cursor < count else { throw ScanError.unreadableMesh }
        let value = self[cursor]
        cursor += 1
        return value
    }
}
