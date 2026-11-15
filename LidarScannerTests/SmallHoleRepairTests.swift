import XCTest
@testable import LidarScanner

final class SmallHoleRepairTests: XCTestCase {
    private func ring(inner: Float, outer: Float) -> ScanMesh {
        var mesh = ScanMesh()
        mesh.positions = [
            [-outer, -outer, 0], [outer, -outer, 0], [outer, outer, 0], [-outer, outer, 0],
            [-inner, -inner, 0], [inner, -inner, 0], [inner, inner, 0], [-inner, inner, 0]
        ]
        mesh.indices = [0,1,5, 0,5,4, 1,2,6, 1,6,5, 2,3,7, 2,7,6, 3,0,4, 3,4,7]
        return mesh
    }

    func testRepairsSmallHoleWithoutMovingVerticesOrFillingOuterBoundary() {
        let mesh = ring(inner: 0.01, outer: 0.2)
        let result = mesh.repairingSmallHoles()
        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(result.mesh.triangleCount, mesh.triangleCount + 2)
        XCTAssertEqual(result.mesh.positions, mesh.positions)
        XCTAssertEqual(mesh.triangleCount, 8)
    }

    func testLargeHoleIsLeftOpen() {
        let mesh = ring(inner: 0.1, outer: 0.2)
        let result = mesh.repairingSmallHoles()
        XCTAssertEqual(result.filled, 0)
        XCTAssertEqual(result.mesh.indices, mesh.indices)
    }

    func testTextureSeamsAreNotTreatedAsHoles() {
        let original = ring(inner: 0.01, outer: 0.2)
        var unwrapped = ScanMesh()
        for index in original.indices {
            unwrapped.positions.append(original.positions[Int(index)])
            unwrapped.indices.append(UInt32(unwrapped.indices.count))
        }
        let result = unwrapped.repairingSmallHoles()
        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(result.mesh.triangleCount, original.triangleCount + 2)
        XCTAssertEqual(result.mesh.positions, unwrapped.positions)
    }
}
