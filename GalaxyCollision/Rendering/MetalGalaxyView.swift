import SwiftUI
import MetalKit

@MainActor
private func makeGalaxyView(model: SimulationModel, coordinator: MetalCoordinator) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0.009, green: 0.016, blue: 0.032, alpha: 1)
    view.preferredFramesPerSecond = 60
    view.framebufferOnly = true
    view.enableSetNeedsDisplay = false
    do {
        coordinator.renderer = try GalaxyRenderer(view: view, model: model)
        view.delegate = coordinator.renderer
    } catch {
        Task { @MainActor in model.error = error.localizedDescription }
    }
    return view
}

@MainActor
final class MetalCoordinator {
    var renderer: GalaxyRenderer?
}

#if os(macOS)
struct MetalGalaxyView: NSViewRepresentable {
    @ObservedObject var model: SimulationModel
    func makeCoordinator() -> MetalCoordinator { MetalCoordinator() }
    func makeNSView(context: Context) -> MTKView { makeGalaxyView(model: model, coordinator: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { view.isPaused = !model.isActive }
    static func dismantleNSView(_ view: MTKView, coordinator: MetalCoordinator) {
        coordinator.renderer?.stopRecording()
        view.isPaused = true; view.delegate = nil
    }
}
#else
struct MetalGalaxyView: UIViewRepresentable {
    @ObservedObject var model: SimulationModel
    func makeCoordinator() -> MetalCoordinator { MetalCoordinator() }
    func makeUIView(context: Context) -> MTKView { makeGalaxyView(model: model, coordinator: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { view.isPaused = !model.isActive }
    static func dismantleUIView(_ view: MTKView, coordinator: MetalCoordinator) {
        coordinator.renderer?.stopRecording()
        view.isPaused = true; view.delegate = nil
    }
}
#endif
