import Foundation
import Metal

/// Integration check: CPU/GPU initialization must not block the main actor,
/// cancelled selections must not publish, and completed buffers must be usable.
@main struct PreparationSmoke {
    @MainActor static func main() async throws {
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let library = try await device.makeLibrary(source: String(contentsOfFile: "GalaxyCollision/Rendering/Galaxy.metal", encoding: .utf8), options: nil)
        let loader = GalaxyPreparation()
        var staleCallbacks = 0
        let first = loader.prepare(device: device, library: library, commandQueue: queue,
                                   starCount: 8192, preset: .shells) { _ in staleCallbacks += 1 }
        // Give the worker a chance to start, then supersede its request.
        try await Task.sleep(nanoseconds: 10_000_000)
        first.cancel()
        var heartbeatCount = 0
        var largestGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = Date()
                largestGap = max(largestGap, now.timeIntervalSince(last))
                last = now
                heartbeatCount += 1
            }
        }
        let system: GalaxyDynamics = try await withCheckedThrowingContinuation { continuation in
            loader.prepare(device: device, library: library, commandQueue: queue,
                           starCount: 8192, preset: .bar, readable: true) { result in
                continuation.resume(with: result)
            }
        }
        heartbeat.cancel()
        precondition(staleCallbacks == 0, "A cancelled selection was published")
        precondition(heartbeatCount > 0 && largestGap < 0.25, "Main actor stalled during preparation")
        let root = system.nodes.contents().load(as: SIMD4<Float>.self)
        precondition(abs(root.w - 20) < 0.001, "Callback arrived before valid GPU buffers")
        let command = queue.makeCommandBuffer()!
        try system.step(command: command)
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        precondition(command.status == .completed)
        print("PASS: main actor heartbeat", heartbeatCount, "max gap", largestGap,
              "seconds; cancelled callback suppressed; prepared system stepped successfully")
    }
}
