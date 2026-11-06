import XCTest
@testable import LidarScanner

final class ScanArtifactTests: XCTestCase {
    func testRoomResolutionFitsTheVolumeWithoutReducingSmallObjectDetail() {
        XCTAssertEqual(FusionVoxel.budgetedMillimeters(detail: 2, surfaceArea: 0.5), 2, accuracy: 0.001)
        let roomVoxel = FusionVoxel.budgetedMillimeters(detail: 2, surfaceArea: 100) / 1000
        let estimatedBlocks = 100 / (32 * roomVoxel * roomVoxel)
        XCTAssertLessThanOrEqual(estimatedBlocks, Float(FusionVoxel.maxBlocks) * 0.701)
        XCTAssertGreaterThan(roomVoxel, 0.002)
    }

    func testFailedCommitRestoresMeshAndRemovedTexture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mesh = root.appendingPathComponent("mesh.ply")
        let texture = root.appendingPathComponent("texture.jpg")
        let oldMesh = Data("original mesh".utf8)
        let oldTexture = Data("matching texture".utf8)
        try oldMesh.write(to: mesh)
        try oldTexture.write(to: texture)
        let impossible = root.appendingPathComponent("missing-parent/meta.json")
        XCTAssertThrowsError(try ScanArtifactTransaction.replace([
            (mesh, Data("new mesh".utf8)), (texture, nil), (impossible, Data())
        ]))
        XCTAssertEqual(try Data(contentsOf: mesh), oldMesh)
        XCTAssertEqual(try Data(contentsOf: texture), oldTexture)
    }

    func testUntexturedCommitRemovesPreviousAtlasAndUVs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let texture = root.appendingPathComponent("texture.jpg")
        let uvs = root.appendingPathComponent("uvs.bin")
        try Data([1]).write(to: texture)
        try Data([2]).write(to: uvs)
        try ScanArtifactTransaction.replace([(texture, nil), (uvs, nil)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: texture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uvs.path))
    }
}
