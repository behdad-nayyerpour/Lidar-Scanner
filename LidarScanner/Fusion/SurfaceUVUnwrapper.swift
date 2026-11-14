import Foundation
import simd

/// Geometry owns the UV layout. Camera images never become UV charts.
enum SurfaceUVUnwrapper {
    static func unwrap(_ mesh: ScanMesh, resolution: Int, signal: WorkSignal?) -> ScanMesh? {
        guard !mesh.isEmpty, mesh.indices.count % 3 == 0,
              mesh.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else { return nil }
        var xyz = [Float]()
        xyz.reserveCapacity(mesh.positions.count * 3)
        for p in mesh.positions { xyz.append(contentsOf: [p.x, p.y, p.z]) }
        var native = NMMesh()
        let state = UnwrapCancellation(signal: signal)
        let context = Unmanaged.passUnretained(state).toOpaque()
        let code = xyz.withUnsafeBufferPointer { vertices in
            mesh.indices.withUnsafeBufferPointer { indices in
                NMBuildSurfaceAtlas(vertices.baseAddress, UInt32(mesh.positions.count), indices.baseAddress,
                                    UInt32(mesh.indices.count), Int32(resolution), unwrapCancelled, context, &native)
            }
        }
        defer { NMFreeMesh(&native) }
        guard code == 0, signal?.isCancelled != true,
              native.indexCount == mesh.indices.count, native.vertexCount > 0,
              let positions = native.positions, let uvs = native.uvs, let indices = native.indices else { return nil }
        var result = ScanMesh()
        for i in 0..<Int(native.vertexCount) {
            result.positions.append(SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]))
            result.uvs.append(SIMD2(uvs[i * 2], 1 - uvs[i * 2 + 1]))
            if let mapping = native.sourceVertices, mesh.normals.count == mesh.positions.count {
                result.normals.append(mesh.normals[Int(mapping[i])])
            }
        }
        for i in 0..<Int(native.indexCount) { result.indices.append(indices[i]) }
        result.faceClasses = mesh.faceClasses
        if result.normals.count != result.positions.count { result.recomputeNormals() }
        guard result.uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) else { return nil }
        return result
    }
}

private final class UnwrapCancellation {
    let signal: WorkSignal?
    init(signal: WorkSignal?) { self.signal = signal }
}

private let unwrapCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    return Unmanaged<UnwrapCancellation>.fromOpaque(context).takeUnretainedValue().signal?.isCancelled == true ? 1 : 0
}
