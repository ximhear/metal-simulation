import Foundation
import simd

public enum EncounterPreset: String, CaseIterable, Identifiable {
    case m51 = "M51 · 소용돌이 은하"
    case tidal = "조석 꼬리"
    case headOn = "정면 충돌"
    case flyby = "스쳐 지나가기"
    case isolated = "단독 은하 검증"
    case stream = "왜소은하 해체"
    case ring = "고리 은하"
    case prograde = "순행 충돌"
    case retrograde = "역행 충돌"
    case shells = "껍질 은하"
    case bar = "막대 은하 형성"
    public var id: String { rawValue }
    public var isSingle: Bool { self == .isolated || self == .bar }
    public var icon: String {
        switch self {
        case .m51: return "sparkles"
        case .tidal: return "hurricane"
        case .headOn: return "arrow.right.and.line.vertical.and.arrow.left"
        case .flyby: return "arrow.up.right"
        case .isolated: return "scope"
        case .stream: return "moon.stars"
        case .ring: return "circle.circle"
        case .prograde: return "arrow.triangle.2.circlepath"
        case .retrograde: return "arrow.uturn.backward"
        case .shells: return "water.waves"
        case .bar: return "sparkles"
        }
    }
    public var detail: String {
        switch self {
        case .m51: return "M51과 NGC 5195의 연구 모델 질량·초기 궤도를 반영했습니다. 별과 암흑물질의 근사 모델이며, 가스·먼지와 사진의 색은 재현하지 않습니다."
        case .tidal: return "별과 암흑물질이 함께 변형되며 궤도 에너지를 주고받습니다."
        case .headOn: return "중앙을 통과하는 두 은하. 물질 분포가 바뀌며 중력도 달라집니다."
        case .flyby: return "빠른 근접 통과. 붙잡히지 않은 물질은 멀리 빠져나갑니다."
        case .isolated: return "외부 은하 없이 원반과 헤일로가 안정적으로 유지되는지 관측합니다."
        case .stream: return "질량비 20:1. 작은 구형 위성이 공전하며 별을 잃고 궤도를 따라 긴 흐름을 만듭니다."
        case .ring: return "질량비 5:1. 작은 은하가 원반을 수직으로 관통합니다. 바깥으로 퍼지는 별의 밀도파를 관찰하세요."
        case .prograde: return "원반 회전과 공전 방향이 같습니다. 역행 충돌과 같은 위치·궤도·난수로 꼬리의 차이를 비교합니다."
        case .retrograde: return "순행 충돌에서 두 원반의 방위 방향 속도만 반전했습니다. 같은 시간의 꼬리 길이와 흩어진 별을 비교하세요."
        case .shells: return "질량비 50:1. 작은 구형 은하가 중심으로 낙하하며, 별들이 궤도의 바깥 전환점에 활 모양으로 모입니다."
        case .bar: return "외부 충돌 없이 원반의 집단 불안정성으로 막대가 자랍니다. 원반 질량 비율을 높인 별도 초기 모델입니다."
        }
    }
    public var observation: String {
        switch self {
        case .m51: return "관측: 동반 은하가 만드는 나선팔 · 경과 150–400 Myr (1 Myr = 백만 년)"
        case .stream: return "관측: 주황 위성의 별이 늘어나는 방향 · 권장 SIM TIME 15–40"
        case .ring: return "관측: 원반을 위에서 본 고리의 반지름 · 권장 SIM TIME 4–15"
        case .prograde, .retrograde: return "비교: 같은 SIM TIME 15–30의 꼬리 · 전환 시 초기화"
        case .shells: return "관측: 주황 별의 활 모양 밀도 경계 · 권장 SIM TIME 15–50"
        case .bar: return "관측: 원반 중심의 길쭉한 막대 · 권장 SIM TIME 10–60"
        default: return "파랑·주황은 처음 속했던 은하를 나타냅니다."
        }
    }
    public var zoom: Double {
        switch self { case .m51: return 1.3; case .bar, .isolated: return 2.2; case .ring: return 1.8; case .stream: return 0.85; case .shells: return 0.8; default: return 1 }
    }
    public var pitch: Float {
        switch self { case .m51, .ring, .bar, .prograde, .retrograde, .stream, .shells: return 0; default: return 0.42 }
    }
}

public enum GalaxyPhysics {
    public static let step: Float = 1 / 60
    public static let softening: Float = 0.15
    public static let openingAngle: Float = 0.7
    public static let diskMass: Double = 3
    public static let haloMass: Double = 17
    public static let diskScale: Double = 1
    public static let diskHeight: Double = 0.2
    public static let haloScale: Double = 3
    public static let haloCutoff: Double = 18
}

/// Spherical models sample both populations from the same isotropic DF.
/// Homologous models scale positions by R and velocities by sqrt(M/R).
public struct GalaxyDefinition {
    public var massScale: Float = 1
    public var radiusScale: Float = 1
    public var spin: Float = 1
    public var spherical = false
    public var stellarMass: Float = 3
    public var bulgeMass: Float = 0
    public var bulgeScale: Float = 0.25
    public var bulgeCutoff: Float = 2
    public var haloScale: Float = 3
    public var haloCutoff: Float = 18
    public var speedRadius: Float = 64
    public var diskCutoff: Float = 7
    public var tiltY: Float = 0
    public var haloMass: Float = 17
    public var height: Float = 0.2
    public var toomreQ: Float = 1.6
    public var totalMass: Float { (stellarMass + bulgeMass + haloMass) * massScale }
    public var modelUniform: SIMD4<Float> { [massScale, radiusScale, spin, spherical ? 1 : 0] }
    public var shapeUniform: SIMD4<Float> { [diskCutoff, tiltY, speedRadius, 0] }
    public var componentUniform: SIMD4<Float> { [stellarMass, haloMass, height, bulgeMass] }
}

public struct EncounterConfiguration {
    public var primary = GalaxyDefinition()
    public var secondary = GalaxyDefinition()
    public var primaryFraction: Float = 0.5
    public var center0: SIMD4<Float> = [-12, 0, 0, 0.12]
    public var center1: SIMD4<Float> = [12, 0, 0, 0.5]
    public var bulk0: SIMD4<Float> = [0.67, -0.39, 0, 0]
    public var bulk1: SIMD4<Float> = [-0.67, 0.39, 0, 0]

    public init(preset: EncounterPreset) {
        switch preset {
        case .m51:
            // Tress (2020), Tables 2–3; softened/truncated surrogate profiles in docs/M51.md.
            primary.stellarMass = 5.3; primary.bulgeMass = 0.53; primary.haloMass = 60.4
            primary.height = 0.6 / M51Model.lengthKpc
            primary.haloScale = 28.7 / M51Model.lengthKpc
            primary.haloCutoff = 200 / M51Model.lengthKpc
            primary.speedRadius = 150
            primary.bulgeScale = 0.6 / M51Model.lengthKpc
            primary.bulgeCutoff = 4.8 / M51Model.lengthKpc
            primary.diskCutoff = 15 / M51Model.lengthKpc
            primary.tiltY = -20 * .pi / 180
            primary.toomreQ = 1.5
            secondary.spherical = true
            secondary.stellarMass = 2.5; secondary.haloMass = 1.5
            secondary.radiusScale = 1 / M51Model.lengthKpc
            primaryFraction = 0.8
            let separation = (M51Model.position1Kpc - M51Model.position0Kpc) / M51Model.lengthKpc
            let velocity = M51Model.relativeVelocityKms / M51Model.velocityKms
            let fraction = secondary.totalMass / (primary.totalMass + secondary.totalMass)
            center0 = SIMD4(-fraction * separation, -10 * .pi / 180)
            center1 = SIMD4((1 - fraction) * separation, 0)
            bulk0 = SIMD4(-fraction * velocity, 0)
            bulk1 = SIMD4((1 - fraction) * velocity, 0)
        case .headOn: bulk0 = [0.65, 0, 0, 0]; bulk1 = [-0.65, 0, 0, 0]
        case .flyby:
            center0.y = -3; center1.y = 3
            bulk0 = [1.3, 0, 0, 0]; bulk1 = [-1.3, 0, 0, 0]
        case .isolated, .bar:
            primaryFraction = 1
            center0 = .zero; center1 = .zero; bulk0 = .zero; bulk1 = .zero
            if preset == .bar {
                primary.stellarMass = 8; primary.haloMass = 12
                primary.height = 0.12; primary.toomreQ = 1.2
            }
        case .stream, .ring, .shells:
            primaryFraction = 0.75 // Keep enough samples to resolve the satellite.
            secondary.spherical = true
            secondary.massScale = preset == .ring ? 0.2 : 0.05
            secondary.radiusScale = 0.5
            if preset == .shells {
                primary.spherical = true
                secondary.massScale = 0.02
                secondary.radiusScale = 0.8
            }
            let separation: SIMD3<Float>
            let relativeVelocity: SIMD3<Float>
            if preset == .stream { separation = [9, 0, 0]; relativeVelocity = [0, 0.85, 0.18] }
            else if preset == .ring { separation = [0, 0, -10]; relativeVelocity = [0, 0, 3] }
            else { separation = [12, 0, 0]; relativeVelocity = [-0.25, 0.015, 0] }
            let fraction = secondary.totalMass / (primary.totalMass + secondary.totalMass)
            center0 = SIMD4(-fraction * separation, 0)
            center1 = SIMD4((1 - fraction) * separation, 0)
            bulk0 = SIMD4(-fraction * relativeVelocity, 0)
            bulk1 = SIMD4((1 - fraction) * relativeVelocity, 0)
        case .prograde, .retrograde:
            center0.w = 0; center1.w = 0
            // Orbital angular momentum is +z for the default approach.
            primary.spin = preset == .retrograde ? -1 : 1
            secondary.spin = primary.spin
        case .tidal: break
        }
    }
}

/// 0/1 = stars A/B; 2/3 = dark matter A/B. One body is a mass element.
public struct Particle {
    public var position: SIMD4<Float>
    public var velocity: SIMD4<Float>
    public init(position: SIMD4<Float>, velocity: SIMD4<Float>) { self.position = position; self.velocity = velocity }
}

public struct DynamicsUniforms {
    public var center0: SIMD4<Float>
    public var center1: SIMD4<Float>
    public var bulk0: SIMD4<Float>
    public var bulk1: SIMD4<Float>
    public var count: UInt32
    public var starCount: UInt32
    public var galaxyCount: UInt32
    public var seed: UInt32
    public var dt: Float
    public var softening: Float
    public var theta: Float
    public var mode: UInt32
    public var model0: SIMD4<Float>
    public var model1: SIMD4<Float>
    public var component0: SIMD4<Float>
    public var component1: SIMD4<Float>
    public var allocation: SIMD4<UInt32>
    public var shape0: SIMD4<Float>
    public var shape1: SIMD4<Float>

    public init(starCount: Int, preset: EncounterPreset, seed: UInt32 = 42) {
        let c = EncounterConfiguration(preset: preset)
        count = UInt32(starCount * 2); self.starCount = UInt32(starCount)
        galaxyCount = preset.isSingle ? 1 : 2; self.seed = seed
        dt = GalaxyPhysics.step; softening = GalaxyPhysics.softening; theta = GalaxyPhysics.openingAngle; mode = 0
        center0 = c.center0; center1 = c.center1; bulk0 = c.bulk0; bulk1 = c.bulk1
        model0 = c.primary.modelUniform; model1 = c.secondary.modelUniform
        component0 = c.primary.componentUniform; component1 = c.secondary.componentUniform
        // Even population counts preserve mirrored pairs at every picker size.
        let first = preset.isSingle ? starCount : max(2, min(starCount - 2, Int(Float(starCount) * c.primaryFraction) / 2 * 2))
        func bulgeCount(_ definition: GalaxyDefinition, stars: Int) -> UInt32 {
            guard definition.bulgeMass > 0 else { return 0 }
            return UInt32(max(2, min(stars - 2, Int(Float(stars) * definition.bulgeMass / (definition.stellarMass + definition.bulgeMass)) / 2 * 2)))
        }
        allocation = [UInt32(first), UInt32(first), bulgeCount(c.primary, stars: first), preset.isSingle ? 0 : bulgeCount(c.secondary, stars: starCount - first)]
        shape0 = c.primary.shapeUniform; shape1 = c.secondary.shapeUniform
    }
}
