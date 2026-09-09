import Foundation
import simd

public enum EncounterPreset: String, CaseIterable, Identifiable {
    case tidal = "조석 꼬리"
    case headOn = "정면 충돌"
    case flyby = "스쳐 지나가기"
    case isolated = "단독 은하 검증"
    public var id: String { rawValue }
    public var detail: String {
        switch self {
        case .tidal: return "별과 암흑물질이 함께 변형되며 궤도 에너지를 주고받습니다."
        case .headOn: return "중앙을 통과하는 두 은하. 물질 분포가 바뀌며 중력도 달라집니다."
        case .flyby: return "빠른 근접 통과. 붙잡히지 않은 물질은 멀리 빠져나갑니다."
        case .isolated: return "외부 은하 없이 원반과 헤일로가 안정적으로 유지되는지 관측합니다."
        }
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

/// Every particle carries gravitational mass. velocity.w is a population tag:
/// 0/1 = stars A/B, 2/3 = dark matter A/B. One particle represents a mass element,
/// not a literal individual star. Shared 32-byte ABI with Metal.
public struct Particle {
    public var position: SIMD4<Float>
    public var velocity: SIMD4<Float>
    public init(position: SIMD4<Float>, velocity: SIMD4<Float>) {
        self.position = position; self.velocity = velocity
    }
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

    public init(starCount: Int, preset: EncounterPreset, seed: UInt32 = 42) {
        count = UInt32(starCount * 2)
        self.starCount = UInt32(starCount)
        galaxyCount = preset == .isolated ? 1 : 2
        self.seed = seed
        dt = GalaxyPhysics.step; softening = GalaxyPhysics.softening
        theta = GalaxyPhysics.openingAngle; mode = 0
        center0 = [-12, 0, 0, 0.12]; center1 = [12, 0, 0, 0.5]
        bulk0 = [0.67, -0.39, 0, 0]; bulk1 = [-0.67, 0.39, 0, 0]
        if preset == .headOn { bulk0 = [0.65, 0, 0, 0]; bulk1 = [-0.65, 0, 0, 0] }
        if preset == .flyby {
            center0.y = -3; center1.y = 3
            bulk0 = [1.3, 0, 0, 0]; bulk1 = [-1.3, 0, 0, 0]
        }
        if preset == .isolated { center0 = .zero; center1 = .zero; bulk0 = .zero; bulk1 = .zero }
    }
}
