import SwiftUI
import simd

@MainActor
final class SimulationModel: ObservableObject {
    let recorder = GalaxyRecorder()
    @Published var isPlaying = true
    @Published var isPreparing = false
    @Published var exposure: Double = 1
    @Published var zoom: Double = EncounterPreset.m51.zoom
    @Published var orientation = Trackball.identity
    @Published var preset: EncounterPreset = .m51
    #if os(macOS)
    @Published var particleCount = 16_384
    #else
    @Published var particleCount = 8_192
    #endif
    @Published var showHalo = false
    @Published var emphasizeCompanion = false
    @Published var generation = 0
    @Published var elapsed: Float = 0
    @Published var fps: Double = 0
    @Published var error: String?
    @Published var deviceName = "Metal"
    @Published var isActive = true

    func restart() {
        error = nil
        elapsed = 0
        generation += 1
    }

    func resetCamera() {
        zoom = preset.zoom
        orientation = simd_quatf(angle: preset.pitch, axis: [1, 0, 0])
    }
}
