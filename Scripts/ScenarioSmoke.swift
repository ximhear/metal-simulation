import Foundation
import Metal
import simd

/// Physical diagnostics and optional snapshots; no rendering or scripted paths.
@main struct ScenarioSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: String(contentsOfFile: "GalaxyCollision/Rendering/Galaxy.metal", encoding: .utf8), options: nil)
        let env = ProcessInfo.processInfo.environment
        let stars = Int(env["GALAXY_TEST_STARS"] ?? "8192")!
        let steps = Int(env["GALAXY_TEST_STEPS"] ?? "3600")!
        let presets: [(String, EncounterPreset)] = [("stream", .stream), ("ring", .ring), ("prograde", .prograde), ("retrograde", .retrograde), ("shells", .shells), ("bar", .bar)]
        let output = env["GALAXY_SNAPSHOTS"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        func execute(_ body: (MTLCommandBuffer) throws -> Void) throws {
            let command = queue.makeCommandBuffer()!
            try body(command); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, String(describing: command.error))
        }
        let direct = try device.makeComputePipelineState(function: library.makeFunction(name: "directGravitySamples")!)
        var progradeInitial: [Particle]?
        for (name, preset) in presets where env["GALAXY_SCENARIO"] == nil || env["GALAXY_SCENARIO"] == name {
            let system = try GalaxyDynamics(device: device, library: library, starCount: stars, preset: preset, readable: true)
            try execute { try system.initialize(command: $0) }
            let p = system.particles.contents().bindMemory(to: Particle.self, capacity: system.count)
            let a = system.accelerations.contents().bindMemory(to: SIMD4<Float>.self, capacity: system.count)
            if preset == .prograde { progradeInitial = Array(UnsafeBufferPointer(start: p, count: system.count)) }
            if preset == .retrograde, let reference = progradeInitial {
                for i in 0..<system.count {
                    precondition(p[i].position == reference[i].position, "Comparison positions differ")
                    let bulk = Int(p[i].velocity.w) % 2 == 0 ? system.uniforms.bulk0 : system.uniforms.bulk1
                    let v = SIMD3(p[i].velocity.x - bulk.x, p[i].velocity.y - bulk.y, p[i].velocity.z - bulk.z)
                    let old = reference[i].velocity
                    let w = SIMD3(old.x - bulk.x, old.y - bulk.y, old.z - bulk.z)
                    precondition(abs(simd_length_squared(v) - simd_length_squared(w)) < 1e-5, "Comparison kinetic energies differ")
                }
            }
            let sampleCount = 128
            let targets = (0..<sampleCount).map { UInt32($0 * system.count / sampleCount + 1) }
            let targetBuffer = device.makeBuffer(bytes: targets, length: sampleCount * 4, options: .storageModeShared)!
            let reference = device.makeBuffer(length: sampleCount * 16, options: .storageModeShared)!
            try execute { command in
                let e = command.makeComputeCommandEncoder()!
                var u = system.uniforms, n = UInt32(sampleCount)
                e.setComputePipelineState(direct)
                e.setBuffer(system.particles, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
                e.setBuffer(reference, offset: 0, index: 2)
                e.setBuffer(targetBuffer, offset: 0, index: 3)
                e.setBytes(&n, length: 4, index: 4)
                e.dispatchThreads(MTLSize(width: sampleCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                e.endEncoding()
            }
            let exact = reference.contents().bindMemory(to: SIMD4<Float>.self, capacity: sampleCount)
            var error2 = 0.0, force2 = 0.0
            for i in 0..<sampleCount {
                let value = a[Int(targets[i])], f = exact[i]
                error2 += Double(simd_length_squared(SIMD3(value.x - f.x, value.y - f.y, value.z - f.z)))
                force2 += Double(simd_length_squared(SIMD3(f.x, f.y, f.z)))
            }
            let rms = sqrt(error2 / force2)
            precondition(rms < 0.01, "Sampled force error exceeds 1%")
            print(name, "sampled force RMS", rms)
            let configuration = EncounterConfiguration(preset: preset)
            let expectedMass = Double(configuration.primary.totalMass + (preset.isSingle ? 0 : configuration.secondary.totalMass))
            func diagnostics(_ step: Int) -> (energy: Double, a2: Double, satelliteR90: Double) {
                var mass = 0.0, energy = 0.0, momentum = SIMD3<Double>.zero
                var center = SIMD3<Double>.zero, countA = 0.0
                for i in 0..<stars where p[i].velocity.w == 0 {
                    center += SIMD3(Double(p[i].position.x), Double(p[i].position.y), Double(p[i].position.z)); countA += 1
                }
                center /= countA
                var c2 = 0.0, s2 = 0.0, barCount = 0.0, satellite = [Double]()
                for i in 0..<system.count {
                    let pos = SIMD3(Double(p[i].position.x), Double(p[i].position.y), Double(p[i].position.z))
                    let v = SIMD3(Double(p[i].velocity.x), Double(p[i].velocity.y), Double(p[i].velocity.z))
                    precondition(pos.x.isFinite && pos.y.isFinite && pos.z.isFinite && v.x.isFinite && v.y.isFinite && v.z.isFinite)
                    let m = Double(p[i].position.w)
                    mass += m; momentum += m * v
                    energy += m * (simd_length_squared(v) + Double(a[i].w)) * 0.5
                    if i < stars {
                        let d = pos - center, r = hypot(d.x, d.y)
                        if p[i].velocity.w == 0 && r > 0.3 && r < 3 {
                            let phi = atan2(d.y, d.x); c2 += cos(2 * phi); s2 += sin(2 * phi); barCount += 1
                        }
                        if p[i].velocity.w == 1 { satellite.append(simd_length(d)) }
                    }
                }
                precondition(abs(mass - expectedMass) < 0.001, "Mass changed in \(name)")
                precondition(simd_length(momentum) < 0.15, "Large momentum drift in \(name)")
                satellite.sort()
                let r90 = satellite.isEmpty ? 0 : satellite[min(satellite.count - 1, satellite.count * 9 / 10)]
                let a2 = hypot(c2, s2) / max(1, barCount)
                print(name, step, "energy", energy, "momentum", simd_length(momentum), "A2", a2, "satelliteR90", r90)
                if let output { try! Data(bytes: p, count: system.count * MemoryLayout<Particle>.stride).write(to: URL(fileURLWithPath: "\(output)/\(name)-\(step).bin")) }
                return (energy, a2, r90)
            }
            let initial = diagnostics(0)
            var last = initial, peakBar = initial.a2
            for step in 1...steps {
                try execute { try system.step(command: $0) }
                if step % 300 == 0 || step == steps {
                    last = diagnostics(step); peakBar = max(peakBar, last.a2)
                    precondition(abs((last.energy - initial.energy) / initial.energy) < 0.02, "Energy drift exceeds 2% in \(name)")
                }
            }
            if preset == .bar && steps >= 3600 { precondition(peakBar > 0.2, "No resolved bar formed") }
            print("PASS", name, "steps", steps, "relative energy drift", abs((last.energy - initial.energy) / initial.energy))
        }
    }
}
