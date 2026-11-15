import XCTest
@testable import LidarScanner

final class PartialFusionTests: XCTestCase {
    func testCoverageUsesTriangleSurfaceNotOnlyVertices() {
        var coarse = ScanMesh()
        coarse.positions = [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 2, 0)]
        coarse.indices = [0, 1, 2]
        var small = ScanMesh()
        small.positions = [SIMD3(0.8, 0.6, 0.005), SIMD3(0.9, 0.6, 0.005), SIMD3(0.8, 0.7, 0.005)]
        small.indices = [0, 1, 2]
        XCTAssertEqual(MeshCoverage.fraction(of: small, near: coarse, tolerance: 0.01), 1)
        XCTAssertEqual(MeshCoverage.fraction(of: small, near: coarse, tolerance: 0.001), 0)
        let combined = MeshCoverage.fillingGaps(fused: coarse, reference: small, tolerance: 0.01)
        XCTAssertEqual(combined.triangleCount, 1)
    }

    func testAlignedPartialCaptureRefinesInsteadOfDiscardingTheEntireBuild() {
        let reference = wall(columns: 200)
        let partial = wall(columns: 20)
        let coverage = MeshCoverage.fraction(of: reference, near: partial, tolerance: 0.04)
        XCTAssertLessThan(coverage, 0.2)
        XCTAssertTrue(ScanProcessor.canUseFusion(partial, reference: reference, tolerance: 0.04))
        var settings = FusionSettings.fast
        settings.smoothIterations = 0
        settings.targetTriangles = 20_000
        let filled = ScanProcessor.closeGaps(in: partial, reference: reference, settings: settings, tolerance: 0.04).mesh
        XCTAssertGreaterThan(MeshCoverage.fraction(of: reference, near: filled, tolerance: 0.06), 0.95)
    }

    func testUnrelatedFusedGeometryStillFallsBack() {
        let reference = wall(columns: 40)
        var unrelated = wall(columns: 20)
        for i in unrelated.positions.indices { unrelated.positions[i].z += 2 }
        XCTAssertFalse(ScanProcessor.canUseFusion(unrelated, reference: reference, tolerance: 0.04))
    }

    private func wall(columns: Int) -> ScanMesh {
        var mesh = ScanMesh()
        for y in 0...20 {
            for x in 0...columns { mesh.positions.append(SIMD3(Float(x) * 0.05, Float(y) * 0.05, 0)) }
        }
        for y in 0..<20 {
            for x in 0..<columns {
                let a = UInt32(y * (columns + 1) + x)
                let b = a + 1
                let c = a + UInt32(columns + 1)
                mesh.indices.append(contentsOf: [a, b, c, b, c + 1, c])
            }
        }
        mesh.recomputeNormals()
        return mesh
    }
}
