import Foundation
import CryptoKit
import UIKit

struct ScanSurface: @unchecked Sendable {
    let mesh: ScanMesh
    let texture: UIImage?
}

/// One immutable, versioned payload binds topology, embedded UVs and lossless image bytes.
/// Consumers cannot combine an atlas from one build with the vertex order of another build.
enum SurfaceAsset {
    private struct Payload: Codable {
        let version: Int
        let mesh: Data
        let image: Data
        let meshHash: Data
        let imageHash: Data
    }

    static func encode(mesh: ScanMesh, image: UIImage) throws -> Data {
        try validate(mesh)
        guard let png = image.pngData() else { throw ScanError.unreadableMesh }
        let ply = MeshIO.encode(mesh)
        let payload = Payload(version: 2, mesh: ply, image: png,
                              meshHash: Data(SHA256.hash(data: ply)), imageHash: Data(SHA256.hash(data: png)))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> ScanSurface {
        let payload = try PropertyListDecoder().decode(Payload.self, from: data)
        guard payload.version == 2,
              payload.meshHash == Data(SHA256.hash(data: payload.mesh)),
              payload.imageHash == Data(SHA256.hash(data: payload.image)),
              let image = UIImage(data: payload.image) else { throw ScanError.unreadableMesh }
        let mesh = try MeshIO.decode(payload.mesh)
        try validate(mesh)
        return ScanSurface(mesh: mesh, texture: image)
    }

    static func load(paths: ScanPaths, showingBuilt: Bool) throws -> ScanSurface {
        if showingBuilt, paths.exists(paths.surfaceAsset) {
            return try decode(Data(contentsOf: paths.surfaceAsset))
        }
        // Legacy split atlas files are never guessed onto a mesh. A Build regenerates the new asset.
        return ScanSurface(mesh: try MeshIO.read(from: paths.mesh), texture: nil)
    }

    private static func validate(_ mesh: ScanMesh) throws {
        guard !mesh.isEmpty, mesh.uvs.count == mesh.positions.count,
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }),
              mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else {
            throw ScanError.unreadableMesh
        }
    }
}
