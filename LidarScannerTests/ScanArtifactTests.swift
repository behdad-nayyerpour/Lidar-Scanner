import XCTest
import simd
@testable import LidarScanner

final class ScanArtifactTests: XCTestCase {
    @MainActor
    func testSwitchingVersionsKeepsTheBuiltAtlasSeparateFromOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ScanLibrary(root: root)
        let id = UUID()
        let record = ScanRecord(id: id, name: "Version test", createdAt: Date(), updatedAt: Date(),
                                mode: .room, status: .ready, vertexCount: 3, triangleCount: 1,
                                surfaceArea: 0.5, boundsMin: [0, 0, 0], boundsMax: [1, 1, 0],
                                isProcessed: true, isColored: true, builtAvailable: true, showingBuilt: true)
        library.adopt(record: record, thumbnail: nil)
        let paths = library.paths(for: id)
        var original = ScanMesh()
        original.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        original.indices = [0, 1, 2]
        original.recomputeNormals()
        var built = original
        built.positions[0].z = 0.1
        try MeshIO.encode(original).write(to: paths.original)
        try MeshIO.encode(built).write(to: paths.built)
        try MeshIO.encode(built).write(to: paths.mesh)
        let atlas = Data("built atlas".utf8)
        try atlas.write(to: paths.texture)
        try UVFile.write([.zero, SIMD2(1, 0), SIMD2(0, 1)], to: paths.uvs)

        try library.showOriginalMesh(id: id)
        XCTAssertEqual(try library.loadMesh(id: id)?.positions, original.positions)
        XCTAssertEqual(library.record(id)?.showingBuilt, false)
        XCTAssertEqual(library.record(id)?.isColored, false)
        XCTAssertEqual(library.record(id)?.isProcessed, false)
        XCTAssertEqual(try Data(contentsOf: paths.texture), atlas)

        try library.showBuiltMesh(id: id)
        XCTAssertEqual(try library.loadMesh(id: id)?.positions, built.positions)
        XCTAssertEqual(library.record(id)?.showingBuilt, true)
        XCTAssertEqual(library.record(id)?.isColored, true)
        XCTAssertEqual(library.record(id)?.isProcessed, true)
    }

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
