import Foundation
import Metal
import simd

/// Bounded direct-sum oracle at the application's maximum particle count.
@main struct GravityAccuracy {
    static func main() throws {
        setbuf(stdout, nil)
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let source = try String(contentsOfFile: "GalaxyCollision/Rendering/Galaxy.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let direct = try device.makeComputePipelineState(function: library.makeFunction(name: "directGravitySamples")!)
        func execute(_ body: (MTLCommandBuffer) throws -> Void) throws {
            let command = queue.makeCommandBuffer()!
            try body(command)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, String(describing: command.error))
        }
        let system = try GalaxyDynamics(device: device, library: library, starCount: 65536, preset: .tidal, readable: true)
        try execute { try system.initialize(command: $0) }
        let n = system.count
        let p = system.particles.contents().bindMemory(to: Particle.self, capacity: n)
        let a = system.accelerations.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let sampleCount = 512
        // One deterministic pseudorandom target per stratum, covering both
        // galaxies and populations without aliasing the quiet paired sampling.
        var seed: UInt32 = 9173
        var targets: [UInt32] = (0..<sampleCount).map { i in
            seed = seed &* 1664525 &+ 1013904223
            return UInt32(i * n / sampleCount) + seed % UInt32(n / sampleCount)
        }
        targets[sampleCount - 2] = UInt32(n - 2)
        targets[sampleCount - 1] = UInt32(n - 1)
        let targetBuffer = device.makeBuffer(bytes: targets, length: sampleCount * 4, options: .storageModeShared)!
        let reference = device.makeBuffer(length: sampleCount * 16, options: .storageModeShared)!
        for fixture in ["tidal", "compact+escapers"] {
            if fixture == "compact+escapers" {
                for i in 0..<n { p[i].position.x *= 0.05; p[i].position.y *= 0.05; p[i].position.z *= 0.05 }
                p[n - 2].position.x = -500; p[n - 1].position.x = 500
                try execute { try system.rebuildGravity(command: $0) }
            }
            // Independently aggregate all six central moments in CPU Double.
            var mass = 0.0, center = SIMD3<Double>.zero
            for i in 0..<n {
                let m = Double(p[i].position.w)
                mass += m
                center += SIMD3(Double(p[i].position.x), Double(p[i].position.y), Double(p[i].position.z)) * m
            }
            center /= mass
            var diagonal = SIMD3<Double>.zero, off = SIMD3<Double>.zero
            for i in 0..<n {
                let d = SIMD3(Double(p[i].position.x), Double(p[i].position.y), Double(p[i].position.z)) - center
                let m = Double(p[i].position.w)
                diagonal += m * d * d
                off += m * SIMD3(d.x * d.y, d.x * d.z, d.y * d.z)
            }
            let moments = system.moments.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
            let expected = [diagonal.x, diagonal.y, diagonal.z, diagonal.x + diagonal.y + diagonal.z, off.x, off.y, off.z]
            let actual = [moments[0].x, moments[0].y, moments[0].z, moments[0].w, moments[1].x, moments[1].y, moments[1].z]
            print("Root moments CPU:", expected, "GPU:", actual)
            for j in 0..<expected.count {
                // Off-diagonal entries can cancel almost to zero. Scale by
                // the tensor trace, not the residual of that cancellation.
                precondition(abs(Double(actual[j]) - expected[j]) < 1e-6 * expected[3], "Incorrect central moment \(j)")
            }
            try execute { command in
                let e = command.makeComputeCommandEncoder()!
                e.setComputePipelineState(direct)
                var u = system.uniforms, count = UInt32(sampleCount)
                e.setBuffer(system.particles, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
                e.setBuffer(reference, offset: 0, index: 2)
                e.setBuffer(targetBuffer, offset: 0, index: 3)
                e.setBytes(&count, length: 4, index: 4)
                e.dispatchThreads(MTLSize(width: sampleCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                e.endEncoding()
            }
            let exact = reference.contents().bindMemory(to: SIMD4<Float>.self, capacity: sampleCount)
            var error2 = 0.0, force2 = 0.0
            for i in 0..<sampleCount {
                let value = a[Int(targets[i])]
                let delta = SIMD3(value.x - exact[i].x, value.y - exact[i].y, value.z - exact[i].z)
                error2 += Double(simd_length_squared(delta))
                force2 += Double(simd_length_squared(SIMD3(exact[i].x, exact[i].y, exact[i].z)))
            }
            let rms = sqrt(error2 / force2)
            precondition(rms.isFinite && rms < 0.01, "Large-N sampled force error exceeds 1%")
            print("PASS: \(fixture), \(n) bodies, \(sampleCount) direct targets; force RMS \(rms); CPU central moments agree")
        }
    }
}
