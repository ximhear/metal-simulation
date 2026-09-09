import XCTest
import simd
@testable import GalaxyPhysics

final class EncounterTests: XCTestCase {
    func testSharedMetalLayout() {
        XCTAssertEqual(MemoryLayout<Particle>.stride, 32)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.stride, 96)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.count), 64)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.dt), 80)
    }
    func testIsolationHasNoExternalGalaxyOrBulkMotion() {
        let u = DynamicsUniforms(starCount: 8192, preset: .isolated)
        XCTAssertEqual(u.galaxyCount, 1)
        XCTAssertEqual(u.center0, .zero)
        XCTAssertEqual(u.bulk0, .zero)
        XCTAssertEqual(u.count, 16384)
    }
    func testEncounterMomentumSymmetryAndPresetDifferences() {
        let tidal = DynamicsUniforms(starCount: 8192, preset: .tidal)
        let head = DynamicsUniforms(starCount: 8192, preset: .headOn)
        let flyby = DynamicsUniforms(starCount: 8192, preset: .flyby)
        XCTAssertEqual(tidal.bulk0 + tidal.bulk1, .zero)
        XCTAssertEqual(head.bulk0.y, 0)
        XCTAssertGreaterThan(flyby.bulk0.x, tidal.bulk0.x)
    }
    func testEquilibriumTablesAreFiniteAndMonotonic() {
        let t = EquilibriumTables.shared
        XCTAssertEqual(t.haloRadii.count, 4096)
        XCTAssertEqual(t.haloSpeeds.count, 256 * 128)
        XCTAssertEqual(t.diskKinematics.count, 256)
        XCTAssertTrue(t.haloRadii.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertTrue(zip(t.haloRadii, t.haloRadii.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertTrue(t.haloSpeeds.allSatisfy { $0.isFinite && $0 >= 0 })
        for row in 0..<256 {
            let speeds = t.haloSpeeds[(row * 128)..<((row + 1) * 128)]
            XCTAssertTrue(zip(speeds, speeds.dropFirst()).allSatisfy { $0 <= $1 })
        }
        XCTAssertTrue(t.diskKinematics.allSatisfy { $0.x.isFinite && $0.y > 0 && $0.z > 0 && $0.w.isFinite && $0.w > 0 })
        XCTAssertGreaterThan(t.haloRadii[2048], 3)
        XCTAssertLessThan(t.haloRadii[2048], 5)
    }
}
