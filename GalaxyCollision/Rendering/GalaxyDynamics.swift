import Foundation
import Metal

/// GPU-only live gravity. All encoding must use one serial command queue.
/// Buffers use tracked hazards; separate compute passes order tree construction.
final class GalaxyDynamics {
    let particles: MTLBuffer
    let accelerations: MTLBuffer
    let nodes: MTLBuffer
    let moments: MTLBuffer
    let bounds: MTLBuffer
    let starCount: Int
    let count: Int
    private(set) var time: Float = 0
    var uniforms: DynamicsUniforms
    private let pipelines: [String: MTLComputePipelineState]
    private let keys: MTLBuffer
    private let links: MTLBuffer
    private let parents: MTLBuffer
    private let levels: MTLBuffer
    private let escapes: MTLBuffer
    private let low: MTLBuffer
    private let high: MTLBuffer
    private let sortCapacity: Int
    private let scratch: MTLBuffer
    private let radialTable: MTLBuffer
    private let speedTable: MTLBuffer
    private let diskTable: MTLBuffer

    init(device: MTLDevice, library: MTLLibrary, starCount: Int, preset: EncounterPreset,
         readable: Bool = false, seed: UInt32 = 42) throws {
        self.starCount = starCount; count = starCount * 2
        var capacity = 1
        while capacity < count { capacity *= 2 }
        sortCapacity = capacity
        uniforms = DynamicsUniforms(starCount: starCount, preset: preset, seed: seed)
        var states: [String: MTLComputePipelineState] = [:]
        for name in ["initializeGalaxies", "reduceBounds", "finishBounds", "makeKeys", "sortKeys", "buildTopology", "initializeLeaves", "buildEscapes", "refitLevel", "treeGravity", "driftParticles", "finishKick"] {
            guard let f = library.makeFunction(name: name) else { throw DynamicsError.failure("Missing shader: \(name)") }
            states[name] = try device.makeComputePipelineState(function: f)
        }
        pipelines = states
        func buffer(_ length: Int, _ label: String, readable: Bool = false) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: length, options: readable ? .storageModeShared : .storageModePrivate) else {
                throw DynamicsError.failure("GPU 메모리를 할당할 수 없습니다: \(label)")
            }
            b.label = label; return b
        }
        particles = try buffer(count * 32, "Live stars + dark matter", readable: readable)
        accelerations = try buffer(count * 16, "Gravity and potential", readable: readable)
        let nodeCount = count * 2 - 1
        nodes = try buffer(nodeCount * 16, "Compact tree mass and centers", readable: readable)
        moments = try buffer(nodeCount * 32, "Second central moments", readable: readable)
        bounds = try buffer(16, "Adaptive root bounds", readable: readable)
        keys = try buffer(sortCapacity * 16, "Sorted Morton keys and particle IDs")
        links = try buffer(count * 16, "Children and sorted ranges")
        parents = try buffer(nodeCount * 4, "Tree parents")
        levels = try buffer(count * 4, "Radix prefix lengths")
        escapes = try buffer(nodeCount * 4, "Stackless traversal escapes")
        low = try buffer(nodeCount * 16, "Tree lower bounds and size")
        high = try buffer(nodeCount * 16, "Tree upper bounds")
        scratch = try buffer(((count + 255) / 256) * 32, "Bounds reduction")
        let configuration = EncounterConfiguration(preset: preset)
        func tables(_ definition: GalaxyDefinition) -> EquilibriumTables {
            if !definition.spherical && definition.stellarMass == 3 && definition.haloMass == 17
                && definition.radiusScale == 1 && definition.toomreQ == 1.6 { return .shared }
            return EquilibriumTables(
                diskMass: definition.spherical ? 0 : Double(definition.stellarMass),
                haloMass: definition.spherical ? Double(definition.stellarMass + definition.haloMass) : Double(definition.haloMass),
                haloScale: definition.spherical ? 1 : GalaxyPhysics.haloScale,
                cutoff: definition.spherical ? 6 : GalaxyPhysics.haloCutoff,
                height: Double(definition.height), toomreQ: Double(definition.toomreQ),
                softening: Double(GalaxyPhysics.softening / definition.radiusScale))
        }
        let firstTables = tables(configuration.primary)
        let secondTables = preset.isSingle ? firstTables : tables(configuration.secondary)
        func upload<T>(_ values: [T]) throws -> MTLBuffer {
            guard let b = values.withUnsafeBytes({ bytes in device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) }) else {
                throw DynamicsError.failure("초기 은하 모델을 GPU에 올릴 수 없습니다.")
            }
            return b
        }
        radialTable = try upload(firstTables.haloRadii + secondTables.haloRadii)
        speedTable = try upload(firstTables.haloSpeeds + secondTables.haloSpeeds)
        diskTable = try upload(firstTables.diskKinematics + secondTables.diskKinematics)
    }

    private func encode(_ name: String, count: Int, command: MTLCommandBuffer, bindings: (MTLComputeCommandEncoder) -> Void) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw DynamicsError.failure("GPU 명령을 만들 수 없습니다.") }
        let pipeline = pipelines[name]!
        encoder.label = name
        encoder.setComputePipelineState(pipeline)
        bindings(encoder)
        // Bounds reduction needs 256 lanes. Smaller gravity groups spread the
        // register-heavy traversal across GPU cores even in a short dispatch.
        let width = name == "treeGravity" ? 64 : 256
        encoder.dispatchThreadgroups(MTLSize(width: (count + width - 1) / width, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
    }

    func initialize(command: MTLCommandBuffer) throws {
        var u = uniforms
        try encode("initializeGalaxies", count: count, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
            e.setBuffer(radialTable, offset: 0, index: 2)
            e.setBuffer(speedTable, offset: 0, index: 3)
            e.setBuffer(diskTable, offset: 0, index: 4)
        }
        try rebuildGravity(command: command)
        time = 0
    }

    func step(command: MTLCommandBuffer) throws {
        var u = uniforms
        try encode("driftParticles", count: count, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0)
            e.setBuffer(accelerations, offset: 0, index: 1)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 2)
        }
        try rebuildGravity(command: command)
        try encode("finishKick", count: count, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0)
            e.setBuffer(accelerations, offset: 0, index: 1)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 2)
        }
        time += u.dt
    }

    func rebuildGravity(command: MTLCommandBuffer) throws {
        try rebuildTree(command: command)
        try evaluateGravity(command: command)
    }

    // Exposed internally so the GPU benchmark can time construction and force
    // separately without adding readbacks or profiling waits to the app.
    func rebuildTree(command: MTLCommandBuffer) throws {
        var u = uniforms
        try encode("reduceBounds", count: count, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
            e.setBuffer(scratch, offset: 0, index: 2)
        }
        var groups = UInt32((count + 255) / 256)
        try encode("finishBounds", count: 1, command: command) { e in
            e.setBuffer(scratch, offset: 0, index: 0); e.setBuffer(bounds, offset: 0, index: 1)
            e.setBytes(&groups, length: 4, index: 2)
        }
        var capacity = UInt32(sortCapacity)
        try encode("makeKeys", count: sortCapacity, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
            e.setBuffer(bounds, offset: 0, index: 2); e.setBuffer(keys, offset: 0, index: 3)
            e.setBytes(&capacity, length: 4, index: 4)
        }
        var size = 2
        while size <= sortCapacity {
            var distance = size / 2
            while distance > 0 {
                var stage = SIMD4<UInt32>(UInt32(size), UInt32(distance), capacity, 0)
                try encode("sortKeys", count: sortCapacity, command: command) { e in
                    e.setBuffer(keys, offset: 0, index: 0); e.setBytes(&stage, length: 16, index: 1)
                }
                distance /= 2
            }
            size *= 2
        }
        try encode("buildTopology", count: count - 1, command: command) { e in
            e.setBuffer(keys, offset: 0, index: 0)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
            e.setBuffer(links, offset: 0, index: 2); e.setBuffer(parents, offset: 0, index: 3)
            e.setBuffer(levels, offset: 0, index: 4)
        }
        try encode("initializeLeaves", count: count, command: command) { e in
            e.setBuffer(particles, offset: 0, index: 0); e.setBuffer(keys, offset: 0, index: 1)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 2)
            e.setBuffer(nodes, offset: 0, index: 3); e.setBuffer(low, offset: 0, index: 4)
            e.setBuffer(high, offset: 0, index: 5)
            e.setBuffer(moments, offset: 0, index: 6)
        }
        try encode("buildEscapes", count: count * 2 - 1, command: command) { e in
            e.setBuffer(links, offset: 0, index: 0); e.setBuffer(parents, offset: 0, index: 1)
            e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 2)
            e.setBuffer(escapes, offset: 0, index: 3)
        }
        for level in stride(from: 95, through: 0, by: -1) {
            var level = UInt32(level)
            try encode("refitLevel", count: count - 1, command: command) { e in
                e.setBuffer(links, offset: 0, index: 0); e.setBuffer(levels, offset: 0, index: 1)
                e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 2)
                e.setBytes(&level, length: 4, index: 3)
                e.setBuffer(nodes, offset: 0, index: 4); e.setBuffer(low, offset: 0, index: 5)
                e.setBuffer(high, offset: 0, index: 6)
                e.setBuffer(moments, offset: 0, index: 7)
            }
        }
    }

    func evaluateGravity(command: MTLCommandBuffer) throws {
        var u = uniforms
        // Bound the duration of a dispatch on a GPU shared with the display.
        for start in stride(from: 0, to: count, by: 8192) {
            var offset = UInt32(start)
            try encode("treeGravity", count: min(8192, count - start), command: command) { e in
                e.setBuffer(keys, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<DynamicsUniforms>.stride, index: 1)
                e.setBuffer(links, offset: 0, index: 2); e.setBuffer(escapes, offset: 0, index: 3)
                e.setBuffer(low, offset: 0, index: 4); e.setBuffer(nodes, offset: 0, index: 5)
                e.setBuffer(accelerations, offset: 0, index: 6)
                e.setBytes(&offset, length: 4, index: 7)
                e.setBuffer(moments, offset: 0, index: 8)
            }
        }
    }
}

enum DynamicsError: LocalizedError {
    case failure(String)
    var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
}
