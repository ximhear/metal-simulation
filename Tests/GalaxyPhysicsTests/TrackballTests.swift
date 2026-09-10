import XCTest
import simd
@testable import GalaxyPhysics

final class TrackballTests: XCTestCase {
    private let size: SIMD2<Float> = [400, 400]
    private let center: SIMD2<Float> = [200, 200]

    private func assertSameRotation(_ a: simd_quatf, _ b: simd_quatf, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(abs(simd_dot(a.vector, b.vector)), 1, accuracy: 1e-5, file: file, line: line)
    }

    func testNoMovementAndInvalidViewportLeaveOrientationUnchanged() {
        let q = simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        assertSameRotation(Trackball.rotate(q, from: center, to: center, viewport: size), q)
        assertSameRotation(Trackball.rotate(q, from: center, to: [250, 200], viewport: .zero), q)
        assertSameRotation(Trackball.rotate(q, from: [.nan, 0], to: center, viewport: size), q)
    }

    func testIndependentControlsAtBothPolesAndUpsideDown() {
        for angle: Float in [.pi / 2, -.pi / 2, .pi] {
            let q = simd_quatf(angle: angle, axis: [1, 0, 0])
            let horizontal = Trackball.rotate(q, from: center, to: [220, 200], viewport: size)
            let vertical = Trackball.rotate(q, from: center, to: [200, 220], viewport: size)
            let h = simd_normalize((horizontal * q.inverse).imag)
            let v = simd_normalize((vertical * q.inverse).imag)
            XCTAssertEqual(simd_dot(h, v), 0, accuracy: 1e-5)
            XCTAssertGreaterThan(simd_length(horizontal.vector - q.vector), 0.01)
            XCTAssertGreaterThan(simd_length(vertical.vector - q.vector), 0.01)
        }
    }

    func testReverseDragRestoresPoseEvenOutsideSphere() {
        let q = simd_quatf(angle: 1.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        for end: SIMD2<Float> in [[260, 170], [-300, 900], [10000, -20000]] {
            let moved = Trackball.rotate(q, from: center, to: end, viewport: size)
            assertSameRotation(Trackball.rotate(moved, from: end, to: center, viewport: size), q)
        }
    }

    func testContinuousRotationCrossesPolesAndMaintainsOrthonormalBasis() {
        var q = Trackball.identity
        for i in 0..<20000 {
            let end: SIMD2<Float> = i % 2 == 0 ? [208, 210] : [190, 206]
            q = Trackball.rotate(q, from: center, to: end, viewport: size)
            XCTAssertTrue(q.vector.x.isFinite && q.vector.y.isFinite && q.vector.z.isFinite && q.vector.w.isFinite)
        }
        XCTAssertEqual(simd_length(q.vector), 1, accuracy: 1e-6)
        let m = simd_float3x3(q)
        XCTAssertEqual(simd_determinant(m), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(m.columns.0, m.columns.1), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(m.columns.2), 1, accuracy: 1e-5)
    }

    func testVerticalDragCanPassNinetyDegreesWithoutClamp() {
        var q = Trackball.identity
        for _ in 0..<20 { q = Trackball.rotate(q, from: center, to: [200, 220], viewport: size) }
        // Twenty ~5.74 degree increments pass the old ±86 degree limit.
        XCTAssertLessThan(q.act(SIMD3<Float>(0, 0, 1)).z, 0)
        let continued = Trackball.rotate(q, from: center, to: [220, 200], viewport: size)
        XCTAssertGreaterThan(simd_length(continued.vector - q.vector), 0.01)
    }

    func testExtremeOppositeDragStaysFinite() {
        let q = Trackball.rotate(Trackball.identity, from: [-1e20, 200], to: [1e20, 200], viewport: size)
        XCTAssertEqual(simd_length(q.vector), 1, accuracy: 1e-5)
    }
}
