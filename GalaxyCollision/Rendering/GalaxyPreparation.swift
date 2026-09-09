import Foundation
import Metal

/// Serial preparation keeps rapid selection changes from building multiple
/// large systems concurrently. A ticket suppresses stale work and callbacks.
final class GalaxyPreparation {
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private let worker = DispatchQueue(label: "GalaxyLab.prepare", qos: .userInitiated)

    @discardableResult
    func prepare(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue,
                 starCount: Int, preset: EncounterPreset, readable: Bool = false,
                 completion: @escaping @MainActor (Result<GalaxyDynamics, Error>) -> Void) -> Ticket {
        let ticket = Ticket()
        worker.async {
            guard !ticket.isCancelled else { return }
            let result: Result<GalaxyDynamics, Error> = Result {
                let system = try GalaxyDynamics(device: device, library: library,
                                                starCount: starCount, preset: preset, readable: readable)
                guard !ticket.isCancelled else { throw CancellationError() }
                guard let command = commandQueue.makeCommandBuffer() else {
                    throw DynamicsError.failure("초기 은하의 GPU 명령을 만들 수 없습니다.")
                }
                command.label = "Prepare galaxy off main thread"
                try system.initialize(command: command)
                command.commit()
                // Only the worker waits. The renderer can keep displaying the
                // previous system, using the same serial Metal command queue.
                command.waitUntilCompleted()
                guard command.status == .completed else {
                    throw command.error ?? DynamicsError.failure("초기 은하의 GPU 계산이 실패했습니다.")
                }
                return system
            }
            guard !ticket.isCancelled else { return }
            Task { @MainActor in
                guard !ticket.isCancelled else { return }
                completion(result)
            }
        }
        return ticket
    }
}
