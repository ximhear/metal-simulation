import XCTest
import simd
@testable import GalaxyPhysics

final class EncounterTests: XCTestCase {
    func testSharedMetalLayout() {
        XCTAssertEqual(MemoryLayout<Particle>.stride, 32)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.stride, 176)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.count), 64)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.dt), 80)
    }
    func testNewEncounterMassMomentumAndAllocation() {
        for preset in EncounterPreset.allCases {
            let c = EncounterConfiguration(preset: preset)
            let u = DynamicsUniforms(starCount: 8192, preset: preset)
            let momentum = c.primary.totalMass * c.bulk0 + (preset.isSingle ? 0 : c.secondary.totalMass) * c.bulk1
            XCTAssertLessThan(simd_length(momentum), 1e-5, preset.rawValue)
            XCTAssertEqual(u.allocation.x % 2, 0)
            XCTAssertEqual(u.allocation.x, u.allocation.y)
            XCTAssertEqual(u.galaxyCount, preset.isSingle ? 1 : 2)
            XCTAssertEqual(u.count, 16384)
        }
        let pro = DynamicsUniforms(starCount: 8192, preset: .prograde)
        let retro = DynamicsUniforms(starCount: 8192, preset: .retrograde)
        XCTAssertEqual(pro.center0, retro.center0)
        XCTAssertEqual(pro.bulk0, retro.bulk0)
        XCTAssertEqual(pro.seed, retro.seed)
        XCTAssertEqual(pro.model0.z, -retro.model0.z)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.model0), 96)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.allocation), 160)
    }
    func testSphericalAndBarTablesAreFinite() {
        for table in [EquilibriumTables(diskMass: 0, haloMass: 20, haloScale: 1, cutoff: 6, softening: 0.3),
                      EquilibriumTables(diskMass: 8, haloMass: 12, height: 0.12, toomreQ: 1.2)] {
            XCTAssertTrue(table.haloSpeeds.allSatisfy { $0.isFinite && $0 >= 0 })
            XCTAssertTrue(table.diskKinematics.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        }
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
