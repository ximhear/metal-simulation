import Foundation
import Metal

/// GPU timings exclude CPU encoding/waiting; full wall time includes both.
/// This executable does not render and is not an app FPS benchmark.
@main struct GravityBenchmark {
    static func main() throws {
        setbuf(stdout, nil)
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let source = try String(contentsOfFile: "GalaxyCollision/Rendering/Galaxy.metal", encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        func run(_ action: (MTLCommandBuffer) throws -> Void) throws -> (gpu: Double, wall: Double) {
            let start = Date()
            let command = queue.makeCommandBuffer()!
            try action(command)
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, String(describing: command.error))
            return ((command.gpuEndTime - command.gpuStartTime) * 1000, Date().timeIntervalSince(start) * 1000)
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let counts = ProcessInfo.processInfo.environment["GALAXY_BENCH_STARS"]?.split(separator: ",").compactMap { Int($0) }
            ?? [8192, 16384, 32768, 65536]
        print("device=\(device.name), theta=\(GalaxyPhysics.openingAngle), seed=42; milliseconds, median of 7 after 2 warmups")
        print("fixture,stars,total,tree_gpu_ms,force_gpu_ms,full_gpu_ms,full_wall_ms")
        for n in counts {
            for fixture in ["tidal", "compact+escapers"] {
                let system = try GalaxyDynamics(device: device, library: library, starCount: n, preset: .tidal, readable: true)
                _ = try run { try system.initialize(command: $0) }
                if fixture == "compact+escapers" {
                    // Stress geometry, not an equilibrium model: a dense body
                    // distribution and two remote bodies must remain efficient.
                    let p = system.particles.contents().bindMemory(to: Particle.self, capacity: system.count)
                    for i in 0..<system.count {
                        p[i].position.x *= 0.05; p[i].position.y *= 0.05; p[i].position.z *= 0.05
                    }
                    p[system.count - 1].position.x = 500
                    p[system.count - 2].position.x = -500
                }
                var tree = [Double](), force = [Double](), full = [Double](), wall = [Double]()
                for iteration in 0..<9 {
                    let t = try run { try system.rebuildTree(command: $0) }
                    let f = try run { try system.evaluateGravity(command: $0) }
                    let all = try run { try system.rebuildGravity(command: $0) }
                    if iteration >= 2 { tree.append(t.gpu); force.append(f.gpu); full.append(all.gpu); wall.append(all.wall) }
                }
                print(String(format: "%@,%d,%d,%.3f,%.3f,%.3f,%.3f", fixture, n, system.count, median(tree), median(force), median(full), median(wall)))
            }
        }
    }
}
