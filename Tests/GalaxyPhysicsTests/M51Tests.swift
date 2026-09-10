import XCTest
import simd
@testable import GalaxyPhysics

final class M51Tests: XCTestCase {
    func testPublishedMassesRelativeOrbitAndPhysicalUnits() {
        let c = EncounterConfiguration(preset: .m51)
        XCTAssertEqual(c.primary.stellarMass, 5.3)
        XCTAssertEqual(c.primary.bulgeMass, 0.53)
        XCTAssertEqual(c.primary.haloMass, 60.4)
        XCTAssertEqual(c.primary.totalMass, 66.23, accuracy: 1e-5)
        XCTAssertEqual(c.secondary.totalMass, 4, accuracy: 1e-5)
        let r = (c.center1 - c.center0) * M51Model.lengthKpc
        let v = (c.bulk1 - c.bulk0) * M51Model.velocityKms
        XCTAssertLessThan(simd_length(SIMD3(r.x, r.y, r.z) - SIMD3<Float>(-21.91, -8.44, -4.25)), 1e-4)
        XCTAssertLessThan(simd_length(SIMD3(v.x, v.y, v.z) - SIMD3<Float>(73.2, -31.2, 188.6)), 1e-4)
        XCTAssertEqual(M51Model.timeMyr * M51Model.velocityKms / 977.7922, M51Model.lengthKpc, accuracy: 1e-5)
        XCTAssertEqual(c.primary.diskCutoff * M51Model.lengthKpc, 15, accuracy: 1e-5)
        XCTAssertEqual(c.primary.tiltY, -20 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(c.center0.w, -10 * .pi / 180, accuracy: 1e-5)
    }

    func testBulgeKeepsMirroredPairsAndTotalStellarBudgetAtEverySize() {
        for stars in [8192, 16384, 32768, 65536] {
            let u = DynamicsUniforms(starCount: stars, preset: .m51)
            XCTAssertGreaterThan(u.allocation.z, 0)
            XCTAssertLessThan(u.allocation.z, u.allocation.x)
            XCTAssertEqual(u.allocation.z % 2, 0)
            XCTAssertEqual(u.allocation.w, 0)
            XCTAssertEqual(u.count, UInt32(stars * 2))
            XCTAssertEqual(u.component0.w, 0.53)
        }
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.shape0), 176)
        XCTAssertEqual(MemoryLayout<DynamicsUniforms>.offset(of: \.shape1), 192)
    }

    func testBulgeAndHaloHaveDistinctFiniteDistributionsInCombinedPotential() {
        let c = EncounterConfiguration(preset: .m51).primary
        let t = EquilibriumTables(diskMass: Double(c.stellarMass), bulgeMass: Double(c.bulgeMass),
            bulgeScale: Double(c.bulgeScale), bulgeCutoff: Double(c.bulgeCutoff),
            haloMass: Double(c.haloMass), haloScale: Double(c.haloScale), cutoff: Double(c.haloCutoff),
            speedMaxRadius: Double(c.speedRadius), height: Double(c.height), toomreQ: Double(c.toomreQ))
        for radii in [t.haloRadii, t.bulgeRadii] {
            XCTAssertEqual(radii.count, 4096)
            XCTAssertTrue(radii.allSatisfy { $0.isFinite && $0 > 0 })
            XCTAssertTrue(zip(radii, radii.dropFirst()).allSatisfy { $0 <= $1 })
        }
        for speeds in [t.haloSpeeds, t.bulgeSpeeds] {
            XCTAssertTrue(speeds.allSatisfy { $0.isFinite && $0 >= 0 })
        }
        XCTAssertLessThan(t.bulgeRadii[2048], t.haloRadii[2048] / 3)
        XCTAssertTrue(t.diskKinematics.allSatisfy { $0.x.isFinite && $0.w.isFinite })
    }
}
