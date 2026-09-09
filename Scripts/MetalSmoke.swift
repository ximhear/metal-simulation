import Foundation
import Metal
import simd

@main
struct MetalSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let source = try String(contentsOfFile: "GalaxyCollision/Rendering/Galaxy.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        var commandIndex = 0
        func execute(_ body: (MTLCommandBuffer) throws -> Void) throws {
            commandIndex += 1
            let command = queue.makeCommandBuffer()!
            try body(command)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "Command \(commandIndex): \(String(describing: command.error))")
        }
        let start = Date()
        let small = try GalaxyDynamics(device: device, library: library, starCount: 512, preset: .isolated, readable: true)
        try execute { try small.initialize(command: $0) }
        let reference = device.makeBuffer(length: small.count * 16, options: .storageModeShared)!
        let direct = try device.makeComputePipelineState(function: library.makeFunction(name: "directGravity")!)
        try execute { command in
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(direct)
            var u = small.uniforms
            encoder.setBuffer(small.particles, offset: 0, index: 0)
            encoder.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
            encoder.setBuffer(reference, offset: 0, index: 2)
            encoder.dispatchThreads(MTLSize(width: small.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        }
        let exact = reference.contents().bindMemory(to: SIMD4<Float>.self, capacity: small.count)
        let approx = small.accelerations.contents().bindMemory(to: SIMD4<Float>.self, capacity: small.count)
        var squaredError = 0.0, squaredForce = 0.0
        for i in 0..<small.count {
            let d = SIMD3(approx[i].x - exact[i].x, approx[i].y - exact[i].y, approx[i].z - exact[i].z)
            squaredError += Double(simd_length_squared(d))
            squaredForce += Double(simd_length_squared(SIMD3(exact[i].x, exact[i].y, exact[i].z)))
        }
        let forceError = sqrt(squaredError / squaredForce)
        print("Tree/direct force relative RMS:", forceError)
        precondition(forceError < 0.01, "Tree force error exceeds 1%")
        let root = small.nodes.contents().load(as: SIMD4<Float>.self)
        precondition(abs(root.w - 20) < 0.001, "Mass was not conserved by tree aggregation")
        precondition(simd_length(SIMD3(root.x, root.y, root.z)) < 0.0001)
        // Alter a real source particle and require a changed force on another body.
        let bodies = small.particles.contents().bindMemory(to: Particle.self, capacity: small.count)
        let before = approx[0]
        bodies[small.count - 1].position = bodies[0].position + SIMD4<Float>(0.3, 0, 0, 0)
        bodies[small.count - 1].position.w = 1
        try execute { try small.rebuildGravity(command: $0) }
        precondition(simd_length(approx[0] - before) > 1, "Moving a massive source must change the field")
        // Verify the force law and self-exclusion against a CPU analytic pair.
        small.uniforms.count = 2
        bodies[0] = Particle(position: [-2, 0, 0, 3], velocity: .zero)
        bodies[1] = Particle(position: [2, 0, 0, 17], velocity: .zero)
        try execute { try small.rebuildGravity(command: $0) }
        let distance2: Float = 16 + GalaxyPhysics.softening * GalaxyPhysics.softening
        let expected: Float = 4 * 17 / pow(distance2, 1.5)
        precondition(abs(approx[0].x - expected) < 0.00001 && abs(approx[0].y) < 0.00001)
        precondition(abs(approx[0].x * 3 + approx[1].x * 17) < 0.00001)
        print("PASS: analytic pair, source response, root mass, force accuracy; setup seconds", Date().timeIntervalSince(start))

        // Exercise radix ties, very wide bounds, and padded sort capacity.
        for fixture in ["coincident", "clump + escapers", "non-power-of-two"] {
            small.uniforms.count = fixture == "non-power-of-two" ? 1000 : UInt32(small.count)
            let n = Int(small.uniforms.count)
            for i in 0..<n {
                let r: Float = fixture == "coincident" ? 0 : 0.1
                let x = Float(i)
                bodies[i] = Particle(position: [r * sin(x * 1.7), r * cos(x * 0.37), r * sin(x * 0.61), 20 / Float(n)], velocity: .zero)
            }
            if fixture == "clump + escapers" {
                bodies[n - 1].position.x = 10_000
                bodies[n - 2].position.x = -10_000
            }
            try execute { try small.rebuildGravity(command: $0) }
            try execute { command in
                let e = command.makeComputeCommandEncoder()!
                e.setComputePipelineState(direct)
                var u = small.uniforms
                e.setBuffer(small.particles, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
                e.setBuffer(reference, offset: 0, index: 2)
                e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                e.endEncoding()
            }
            var error2 = 0.0, force2 = 0.0
            for i in 0..<n {
                precondition(approx[i].x.isFinite && approx[i].y.isFinite && approx[i].z.isFinite && approx[i].w.isFinite)
                let difference = SIMD3(approx[i].x - exact[i].x, approx[i].y - exact[i].y, approx[i].z - exact[i].z)
                error2 += Double(simd_length_squared(difference))
                force2 += Double(simd_length_squared(SIMD3(exact[i].x, exact[i].y, exact[i].z)))
                if fixture == "coincident" {
                    precondition(simd_length(difference) < 1e-6)
                    precondition(abs(approx[i].w - exact[i].w) < 0.001)
                }
            }
            let error = sqrt(error2 / max(force2, 1e-30))
            precondition(error < 0.01, "Adversarial force error exceeds 1%")
            precondition(abs(small.nodes.contents().load(as: SIMD4<Float>.self).w - 20) < 0.001)
            print("PASS:", fixture, "relative force RMS", error)
        }

        let starCount = Int(ProcessInfo.processInfo.environment["GALAXY_TEST_STARS"] ?? "8192")!
        let steps = Int(ProcessInfo.processInfo.environment["GALAXY_TEST_STEPS"] ?? "1800")!
        let preset: EncounterPreset = ProcessInfo.processInfo.environment["GALAXY_TEST_COLLISION"] == "1" ? .tidal : .isolated
        let system = try GalaxyDynamics(device: device, library: library, starCount: starCount, preset: preset, readable: true)
        try execute { try system.initialize(command: $0) }
        let initialBodies = system.particles.contents().bindMemory(to: Particle.self, capacity: system.count)
        var coreIDs = [[Int](), [Int]()]
        for i in 0..<starCount {
            let p = initialBodies[i]
            let galaxy = Int(p.velocity.w)
            let c = galaxy == 0 ? system.uniforms.center0 : system.uniforms.center1
            let d = SIMD3(p.position.x - c.x, p.position.y - c.y, p.position.z - c.z)
            if simd_length(d) < 1 { coreIDs[galaxy].append(i) }
        }
        func coreSeparation() -> Float {
            guard !coreIDs[1].isEmpty else { return 0 }
            let p = system.particles.contents().bindMemory(to: Particle.self, capacity: system.count)
            let centers = coreIDs.map { indices -> SIMD3<Float> in
                indices.reduce(SIMD3<Float>.zero) { result, i in result + SIMD3(p[i].position.x, p[i].position.y, p[i].position.z) } / Float(indices.count)
            }
            return simd_length(centers[0] - centers[1])
        }
        func metrics() -> (Double, Double, Double, Double, Double) {
            let p = system.particles.contents().bindMemory(to: Particle.self, capacity: system.count)
            let a = system.accelerations.contents().bindMemory(to: SIMD4<Float>.self, capacity: system.count)
            var kinetic = 0.0, potential = 0.0, height = 0.0
            var momentum = SIMD3<Double>.zero
            var radii = [Float](), halo = [Float]()
            for i in 0..<system.count {
                let pos = SIMD3(p[i].position.x, p[i].position.y, p[i].position.z)
                let v = SIMD3(p[i].velocity.x, p[i].velocity.y, p[i].velocity.z)
                precondition(pos.x.isFinite && pos.y.isFinite && pos.z.isFinite && v.x.isFinite && v.y.isFinite && v.z.isFinite)
                let mass = Double(p[i].position.w)
                kinetic += 0.5 * mass * Double(simd_length_squared(v))
                potential += 0.5 * mass * Double(a[i].w)
                momentum += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)) * mass
                if i < starCount { radii.append(sqrt(pos.x * pos.x + pos.y * pos.y)); height += Double(pos.z * pos.z) }
                else { halo.append(simd_length(pos)) }
            }
            radii.sort(); halo.sort()
            return (Double(radii[radii.count / 2]), sqrt(height / Double(starCount)), Double(halo[halo.count / 2]), kinetic + potential, simd_length(momentum))
        }
        let initial = metrics()
        print("INITIAL R50, height RMS, halo R50, energy, momentum", initial)
        fflush(stdout)
        let simulationStart = Date()
        for i in 1...steps {
            try execute { try system.step(command: $0) }
            if i % 300 == 0 {
                print("STEP", i, "time", system.time, "metrics", metrics(), "core separation", coreSeparation(), "wall", Date().timeIntervalSince(simulationStart)); fflush(stdout)
            }
        }
        let final = metrics()
        print("FINAL metrics", final, "core separation", coreSeparation())
        if preset == .isolated {
            precondition(abs(final.0 / initial.0 - 1) < 0.2, "Isolated stellar half-mass radius drift >20%")
            precondition(final.1 / initial.1 < 2, "Isolated disk thickness grew by >2x")
            precondition(abs(final.2 / initial.2 - 1) < 0.2, "Isolated halo half-mass radius drift >20%")
            precondition(abs((final.3 - initial.3) / initial.3) < 0.02, "Energy drift >2%")
            precondition(final.4 < 0.1, "Momentum drift too large")
        }
        if preset == .tidal && steps >= 3600 {
            precondition(coreSeparation() < 8, "Encounter cores have not contracted from their 24-unit separation")
            precondition(abs((final.3 - initial.3) / initial.3) < 0.02, "Collision energy drift >2%")
        }
        print("PASS: live", preset.rawValue, system.count, "massive bodies,", steps, "steps; wall seconds", Date().timeIntervalSince(simulationStart))
    }
}
