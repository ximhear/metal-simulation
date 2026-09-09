import MetalKit
import simd

private struct RenderUniforms {
    var transform: simd_float4x4
    var appearance: SIMD4<Float>
}

enum RendererError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

@MainActor
final class GalaxyRenderer: NSObject, MTKViewDelegate {
    private let model: SimulationModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let starPipeline: MTLRenderPipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let tonePipeline: MTLRenderPipelineState
    private var sceneTexture: MTLTexture?
    private var recordingTexture: MTLTexture?
    private var dynamics: GalaxyDynamics?
    private var generation = -1
    private var count = 0
    private var lastTime: CFTimeInterval = 0
    private var accumulator: Double = 0
    private var statsTime: CFTimeInterval = 0
    private var frames = 0
    private var stepGPUSeconds = 0.016
    private let inFlight = DispatchSemaphore(value: 3)

    init(view: MTKView, model: SimulationModel) throws {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            throw RendererError.unavailable("Metal을 초기화할 수 없습니다. Metal 지원 기기에서 실행해 주세요.")
        }
        self.model = model
        self.device = device
        self.queue = queue
        self.library = library
        func render(_ vertex: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: "starFragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .rgba16Float
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        starPipeline = try render("starVertex")
        backgroundPipeline = try render("backgroundVertex")
        let tone = MTLRenderPipelineDescriptor()
        tone.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        tone.fragmentFunction = library.makeFunction(name: "toneMapFragment")
        tone.colorAttachments[0].pixelFormat = view.colorPixelFormat
        tonePipeline = try device.makeRenderPipelineState(descriptor: tone)
        super.init()
        // Avoid publishing during SwiftUI's view construction.
        Task { @MainActor [weak model] in model?.deviceName = device.name }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func stopRecording() { model.recorder.stop() }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let wallDelta = lastTime == 0 ? 0 : min(now - lastTime, 0.05)
        lastTime = now
        guard model.isActive, model.error == nil else { model.recorder.stop(); return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        command.label = "Galaxy simulation + render"
        let semaphore = inFlight
        var submittedSteps = 0

        do {
            if generation != model.generation || count != model.particleCount {
                let system = try GalaxyDynamics(device: device, library: library,
                                                starCount: model.particleCount, preset: model.preset)
                try system.initialize(command: command)
                submittedSteps = 1
                stepGPUSeconds = 0.016
                dynamics = system
                count = model.particleCount
                generation = model.generation
                accumulator = 0
            } else if model.isPlaying {
                accumulator += wallDelta
                // Long steps should produce a frame individually. Fast devices
                // may batch two steps to keep the fixed-step cadence.
                let stepLimit = stepGPUSeconds < 0.010 ? 2 : 1
                let steps = min(Int(accumulator / Double(GalaxyPhysics.step)), stepLimit)
                for _ in 0..<steps { try dynamics?.step(command: command) }
                submittedSteps = steps
                accumulator -= Double(steps) * Double(GalaxyPhysics.step)
                accumulator = min(accumulator, Double(GalaxyPhysics.step))
            } else {
                accumulator = 0
            }
        } catch {
            model.error = error.localizedDescription
            model.recorder.stop()
            inFlight.signal()
            return
        }

        let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
        if !renderScene(command: command, pass: pass, size: view.drawableSize, pointScale: scale) {
            model.error = "은하 화면을 그릴 GPU 자원을 확보할 수 없습니다. 입자 수를 줄이거나 다시 시작해 주세요."
            model.recorder.stop()
        }
        if let frame = model.recorder.nextFrame(device: device, size: view.drawableSize, at: now) {
            let recordingPass = MTLRenderPassDescriptor()
            recordingPass.colorAttachments[0].texture = frame.texture
            recordingPass.colorAttachments[0].loadAction = .clear
            recordingPass.colorAttachments[0].storeAction = .store
            recordingPass.colorAttachments[0].clearColor = view.clearColor
            let size = CGSize(width: frame.texture.width, height: frame.texture.height)
            let rendered = renderScene(command: command, pass: recordingPass, size: size, pointScale: 1.5, recording: true)
            let recorder = model.recorder
            command.addCompletedHandler { completed in
                let error = completed.status == .error ? completed.error?.localizedDescription ?? "녹화 중 GPU 오류가 발생했습니다." : nil
                Task { @MainActor in
                    recorder.complete(frame, gpuError: rendered ? error : "녹화 프레임을 그릴 수 없습니다.")
                }
            }
        }
        let completedSteps = submittedSteps
        let submittedGeneration = generation
        command.addCompletedHandler { [weak self, weak model] completed in
            semaphore.signal()
            let duration = completed.gpuEndTime - completed.gpuStartTime
            let failure = completed.status == .error ? completed.error?.localizedDescription ?? "GPU 작업이 실패했습니다." : nil
            Task { @MainActor in
                if let failure { model?.error = failure }
                if completedSteps > 0, duration > 0, self?.generation == submittedGeneration {
                    let sample = duration / Double(completedSteps)
                    if let self { self.stepGPUSeconds = self.stepGPUSeconds * 0.8 + sample * 0.2 }
                }
            }
        }
        command.present(drawable)
        command.commit()
        frames += 1
        if now - statsTime > 0.5 {
            if statsTime != 0 { model.fps = Double(frames) / (now - statsTime) }
            model.elapsed = dynamics?.time ?? 0
            frames = 0
            statsTime = now
        }
    }

    @discardableResult
    private func renderScene(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, pointScale: Float, recording: Bool = false) -> Bool {
        var texture = recording ? recordingTexture : sceneTexture
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            if recording { recordingTexture = texture } else { sceneTexture = texture }
        }
        guard let texture else { return false }
        let linearPass = MTLRenderPassDescriptor()
        linearPass.colorAttachments[0].texture = texture
        linearPass.colorAttachments[0].loadAction = .clear
        linearPass.colorAttachments[0].storeAction = .store
        linearPass.colorAttachments[0].clearColor = pass.colorAttachments[0].clearColor
        if let encoder = command.makeRenderCommandEncoder(descriptor: linearPass) {
            let aspect = Float(max(size.width, 1) / max(size.height, 1))
            let halfHeight = (aspect < 1 ? 16 / aspect : 16) / Float(model.zoom)
            let projection = simd_float4x4(columns: (
                SIMD4(1 / (halfHeight * aspect), 0, 0, 0),
                SIMD4(0, 1 / halfHeight, 0, 0),
                SIMD4(0, 0, 1 / 160, 0), SIMD4(0, 0, 0.5, 1)))
            let rotation = simd_float4x4(simd_quatf(angle: model.pitch, axis: [1, 0, 0]) * simd_quatf(angle: model.yaw, axis: [0, 1, 0]))
            let density = min(2.0, sqrt(Float(32_768) / Float(max(count, 1))))
            var uniforms = RenderUniforms(transform: projection * rotation,
                                          appearance: [pointScale, Float(model.exposure) * density * 0.65, model.emphasizeCompanion && !model.preset.isSingle ? 1 : 0, 0])
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 900)
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(dynamics?.particles, offset: 0, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: model.showHalo ? (dynamics?.count ?? count) : count)
            encoder.endEncoding()
            guard let tone = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            tone.setRenderPipelineState(tonePipeline)
            tone.setFragmentTexture(texture, index: 0)
            tone.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            tone.endEncoding()
            return true
        }
        return false
    }
}
