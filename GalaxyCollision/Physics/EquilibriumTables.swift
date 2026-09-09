import Foundation

/// Approximate disk + live halo initial conditions. The spherical halo DF is
/// obtained by Eddington inversion in the combined halo + sphericalized disk
/// potential. The actual disk is flattened, so isolation tests remain essential.
public struct EquilibriumTables {
    public static let shared = EquilibriumTables()
    public static let radialCount = 4096
    public static let radiusBins = 256
    public static let speedBins = 128
    public static let minRadius: Double = 0.01
    public static let maxRadius: Double = 64
    public let haloRadii: [Float]
    public let haloSpeeds: [Float]
    public let diskKinematics: [SIMD4<Float>]

    public init(diskMass md: Double = GalaxyPhysics.diskMass,
                haloMass mh: Double = GalaxyPhysics.haloMass,
                haloScale a: Double = GalaxyPhysics.haloScale,
                cutoff: Double = GalaxyPhysics.haloCutoff,
                height: Double = GalaxyPhysics.diskHeight,
                toomreQ: Double = 1.6,
                softening epsilon: Double = Double(GalaxyPhysics.softening)) {
        let n = 2048
        let radii = (0..<n).map { exp(log(0.0001) + Double($0) / Double(n - 1) * log(150 / 0.0001)) }
        var rho = radii.map { r in a / (2 * Double.pi * r * pow(r + a, 3)) * exp(-pow(r / cutoff, 2)) }
        var mass = [Double](repeating: 0, count: n)
        for i in 1..<n {
            mass[i] = mass[i - 1] + 2 * .pi * (rho[i] * radii[i] * radii[i] + rho[i - 1] * radii[i - 1] * radii[i - 1]) * (radii[i] - radii[i - 1])
        }
        let normalization = mh / mass[n - 1]
        rho = rho.map { $0 * normalization }; mass = mass.map { $0 * normalization }
        let totalMass = zip(radii, mass).map { r, m in m + md * (1 - (1 + r) * exp(-r)) }
        var psi = [Double](repeating: 0, count: n)
        psi[n - 1] = (mh + md) / radii[n - 1]
        for i in stride(from: n - 2, through: 0, by: -1) {
            psi[i] = psi[i + 1] + 0.5 * (totalMass[i] / pow(radii[i], 2) + totalMass[i + 1] / pow(radii[i + 1], 2)) * (radii[i + 1] - radii[i])
        }
        var second = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let r = radii[i]
            let slope = -1 / r - 3 / (r + a) - 2 * r / (cutoff * cutoff)
            let rhoPrime = rho[i] * slope
            let rhoSecond = rho[i] * (slope * slope + 1 / (r * r) + 3 / pow(r + a, 2) - 2 / (cutoff * cutoff))
            let p1 = -totalMass[i] / (r * r)
            let massPrime = 4 * .pi * r * r * rho[i] + md * r * exp(-r)
            let p2 = 2 * totalMass[i] / pow(r, 3) - massPrime / (r * r)
            second[i] = (rhoSecond * p1 - rhoPrime * p2) / pow(p1, 3)
        }
        func interpolate(_ x: Double, xs: [Double], ys: [Double], ascending: Bool = true) -> Double {
            var low = 0, high = xs.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if (x > xs[mid]) == ascending { low = mid } else { high = mid }
            }
            let t = max(0, min(1, (x - xs[low]) / (xs[high] - xs[low])))
            return ys[low] + t * (ys[high] - ys[low])
        }
        let energies = (0..<1024).map { Double($0) / 1024 * psi[0] }
        let df = energies.map { energy -> Double in
            guard energy > psi[n - 1] else { return 0 }
            var integral = 0.0
            for j in 0..<128 {
                let angle = (Double(j) + 0.5) * .pi / 256
                let potential = energy * pow(sin(angle), 2)
                if potential >= psi[n - 1] {
                    integral += sin(angle) * interpolate(potential, xs: psi, ys: second, ascending: false)
                }
            }
            return max(0, integral * 2 * sqrt(energy) * .pi / 256 / (sqrt(8) * .pi * .pi))
        }
        haloRadii = (0..<Self.radialCount).map {
            Float(interpolate((Double($0) + 0.5) / Double(Self.radialCount) * mh, xs: mass, ys: radii))
        }
        var speeds = [Float]()
        for row in 0..<Self.radiusBins {
            let r = Self.minRadius * pow(Self.maxRadius / Self.minRadius, Double(row) / Double(Self.radiusBins - 1))
            let potential = interpolate(r, xs: radii, ys: psi)
            let escape = sqrt(2 * potential)
            let velocity = (0...256).map { Double($0) / 256 * escape }
            let density = velocity.map { v in v * v * interpolate(max(0, potential - 0.5 * v * v), xs: energies, ys: df) }
            var cdf = [Double](repeating: 0, count: velocity.count)
            for i in 1..<velocity.count { cdf[i] = cdf[i - 1] + (density[i] + density[i - 1]) * 0.5 }
            for q in 0..<Self.speedBins {
                speeds.append(Float(interpolate((Double(q) + 0.5) / Double(Self.speedBins) * cdf.last!, xs: cdf, ys: velocity)))
            }
        }
        haloSpeeds = speeds

        let diskR = (0..<Self.radiusBins).map { Self.minRadius * pow(Self.maxRadius / Self.minRadius, Double($0) / Double(Self.radiusBins - 1)) }
        let vc2 = diskR.map { radius -> Double in
            var inward = 0.0
            // Axisymmetric ring quadrature, softened to approximate disk thickness.
            for j in 0..<128 {
                let ring = (Double(j) + 0.5) * 8 / 128
                let ringMass = md * ring * exp(-ring) * 8 / 128 / 128
                for k in 0..<128 {
                    let x = ring * cos((Double(k) + 0.5) * 2 * .pi / 128)
                    let d2 = radius * radius + ring * ring - 2 * radius * x + epsilon * epsilon + height * height
                    inward += ringMass * (radius - x) / pow(d2, 1.5)
                }
            }
            let enclosed = interpolate(radius, xs: radii, ys: mass)
            return max(0.001, radius * inward + enclosed * radius * radius / pow(radius * radius + epsilon * epsilon, 1.5))
        }
        diskKinematics = diskR.enumerated().map { i, r in
            let lo = max(0, i - 1), hi = min(Self.radiusBins - 1, i + 1)
            let derivative = (vc2[hi] - vc2[lo]) / (diskR[hi] - diskR[lo])
            let kappa = sqrt(max(0.001, derivative / r + 2 * vc2[i] / (r * r)))
            let sigma = md / (2 * .pi) * exp(-r)
            let sigmaR = max(0.025, min(0.4 * sqrt(vc2[i]), toomreQ * 3.36 * sigma / kappa))
            let sigmaPhi = sigmaR * min(1, kappa * r / (2 * sqrt(vc2[i])))
            let rotation = sqrt(max(0.05 * vc2[i], vc2[i] + sigmaR * sigmaR * (1 - 2 * r) - sigmaPhi * sigmaPhi))
            let haloOmega2 = interpolate(r, xs: radii, ys: mass) / pow(r * r + epsilon * epsilon, 1.5)
            let sigmaZ = sqrt(.pi * sigma * height * height / (height + epsilon) + haloOmega2 * height * height * .pi * .pi / 12)
            return SIMD4(Float(rotation), Float(sigmaR), Float(sigmaPhi), Float(sigmaZ))
        }
    }
}
