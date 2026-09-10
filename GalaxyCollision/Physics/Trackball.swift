import Foundation
import simd

/// Camera orientation is stored as a unit quaternion, never as Euler angles.
/// Drag vectors live in view space, so controls remain independent at the poles.
public enum Trackball {
    public static let identity = simd_quatf(real: 1, imag: .zero)

    public static func rotate(_ orientation: simd_quatf, from start: SIMD2<Float>,
                              to end: SIMD2<Float>, viewport: SIMD2<Float>) -> simd_quatf {
        guard viewport.x.isFinite, viewport.y.isFinite, viewport.x > 0, viewport.y > 0,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return orientation }
        guard start != end else { return orientation }
        let a = project(start, viewport: viewport), b = project(end, viewport: viewport)
        let cosine = max(-1, min(1, simd_dot(a, b)))
        let delta: simd_quatf
        if cosine < -0.999999 {
            // A deterministic perpendicular axis handles the antipodal limit.
            let reference: SIMD3<Float> = abs(a.x) < abs(a.y) ? [1, 0, 0] : [0, 1, 0]
            delta = simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(a, reference)))
        } else {
            delta = simd_normalize(simd_quatf(real: 1 + cosine, imag: simd_cross(a, b)))
        }
        // Pre-multiplication applies the increment around screen-space axes.
        return simd_normalize(delta * orientation)
    }

    private static func project(_ point: SIMD2<Float>, viewport: SIMD2<Float>) -> SIMD3<Float> {
        let scale = Double(min(viewport.x, viewport.y))
        let x = (2 * Double(point.x) - Double(viewport.x)) / scale
        let y = (Double(viewport.y) - 2 * Double(point.y)) / scale
        let distance2 = x * x + y * y
        // Sphere near the center, smooth hyperbolic continuation outside it.
        // Double intermediates also keep distant/out-of-bounds drags finite.
        let z = distance2 <= 0.5 ? sqrt(1 - distance2) : 0.5 / sqrt(distance2)
        let length = sqrt(distance2 + z * z)
        return SIMD3(Float(x / length), Float(y / length), Float(z / length))
    }
}
