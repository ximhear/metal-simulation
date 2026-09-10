import Foundation
import simd

/// Physical conversion for the M51 approximation only. Internal gravity uses G = 1.
public enum M51Model {
    public static let lengthKpc: Float = 2.26
    public static let massSolar: Float = 1e10
    // G in kpc (km/s)^2 / solar mass.
    public static let velocityKms: Float = sqrt(4.30091e-6 * massSolar / lengthKpc)
    public static let timeMyr: Float = 977.7922 * lengthKpc / velocityKms
    // Dobbs et al. (2010), Table 1, sky coordinates (+z toward observer).
    public static let position0Kpc: SIMD3<Float> = [4.91, 1.89, 0.95]
    public static let position1Kpc: SIMD3<Float> = [-17, -6.55, -3.30]
    // Use the explicit relative velocity in Tress et al. (2020), Table 3.
    // It differs by a factor of ten from subtracting the printed 2010 table.
    public static let relativeVelocityKms: SIMD3<Float> = [73.2, -31.2, 188.6]
    public static let orbitSourceURL = URL(string: "https://academic.oup.com/mnras/article/492/2/2973/5698815")!
    public static let sourceURL = URL(string: "https://academic.oup.com/mnras/article/403/2/625/1180363")!
}
