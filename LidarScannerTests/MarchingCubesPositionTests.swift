import XCTest
@testable import LidarScanner

final class MarchingCubesPositionTests: XCTestCase {
    func testSurfaceIsLocatedAtVoxelCentersOnBothSidesOfOrigin() {
        for blockX: Int32 in [-1, 0] {
            let spacing: Float = 0.01
            let plane = (Float(blockX) * 8 + 3) * spacing
            let voxels = UnsafeMutablePointer<TSDFVoxel>.allocate(capacity: 512)
            defer { voxels.deallocate() }
            for z in 0..<8 {
                for y in 0..<8 {
                    for x in 0..<8 {
                        let worldX = (Float(blockX * 8) + Float(x) + 0.5) * spacing
                        voxels[z * 64 + y * 8 + x] = TSDFVoxel(sdf: (worldX - plane) / spacing, weight: 1)
                    }
                }
            }
            let mesh = MarchingCubes.extract(pointer: voxels, origins: [(blockX, 0, 0)], lookup: { key in
                key.0 == blockX && key.1 == 0 && key.2 == 0 ? 0 : nil
            }, voxel: spacing, blockSize: 8)
            XCTAssertFalse(mesh.positions.isEmpty)
            let interior = mesh.positions.filter { $0.y < 0.065 && $0.z < 0.065 }
            XCTAssertFalse(interior.isEmpty)
            for position in interior {
                XCTAssertEqual(position.x, plane, accuracy: 0.00001)
                XCTAssertGreaterThanOrEqual(position.y, spacing * 0.49)
                XCTAssertGreaterThanOrEqual(position.z, spacing * 0.49)
            }
        }
    }
}
