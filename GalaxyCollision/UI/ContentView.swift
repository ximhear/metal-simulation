import SwiftUI

private let accent = Color(red: 0.43, green: 0.83, blue: 0.96)
private let panel = Color(red: 0.045, green: 0.061, blue: 0.085)

struct ContentView: View {
    @StateObject private var model = SimulationModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var dragOrigin: SIMD2<Float>?
    @State private var zoomOrigin: Double?
    @State private var showInfo = false
    @State private var showControls = true

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850
            VStack(spacing: 0) {
                header(wide: wide)
                if wide {
                    HStack(spacing: 0) {
                        universe
                        controls.frame(width: 290).background(panel)
                    }
                } else {
                    universe
                    if showControls {
                        controls.frame(maxHeight: geometry.size.height * 0.38).background(panel)
                    }
                }
                transport(wide: wide)
            }
            .background(Color(red: 0.009, green: 0.016, blue: 0.032))
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 560)
        #endif
        .tint(accent)
        .onChange(of: scenePhase) { _, phase in
            model.isActive = phase == .active
            if phase != .active { model.recorder.stop() }
        }
        .onChange(of: model.preset) { _, preset in
            model.restart()
            model.resetCamera()
            model.emphasizeCompanion = preset == .stream || preset == .shells
        }
        .onChange(of: model.particleCount) { _, _ in model.restart() }
        .sheet(isPresented: $showInfo) { modelInfo }
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("GALAXY LAB").font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(3)
                Text("은하 충돌 실험실").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if wide {
                Text("GRAVITY IN MOTION").font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                Divider().frame(height: 22).padding(.horizontal, 12)
            }
            Button { showInfo = true } label: { Image(systemName: "info.circle").font(.title3) }
                .buttonStyle(.plain).accessibilityLabel("시뮬레이션 모델 설명")
            if !wide {
                Button { showControls.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                    .buttonStyle(.plain).padding(.leading, 8).accessibilityLabel("설정 패널 표시 전환")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(panel.opacity(0.8))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var universe: some View {
        ZStack {
            MetalGalaxyView(model: model)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = [model.yaw, model.pitch] }
                        model.yaw = dragOrigin!.x + Float(value.translation.width) * 0.005
                        model.pitch = max(-1.5, min(1.5, dragOrigin!.y + Float(value.translation.height) * 0.005))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        if zoomOrigin == nil { zoomOrigin = model.zoom }
                        model.zoom = max(0.4, min(3, zoomOrigin! * value.magnification))
                    }
                    .onEnded { _ in zoomOrigin = nil })
                .accessibilityLabel("두 은하의 실시간 입자 시뮬레이션")
                .accessibilityHint("드래그로 회전하고 두 손가락으로 확대합니다. 설정에서도 시점을 조절할 수 있습니다.")
            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.preset.isSingle ? "01 / ISOLATED EVOLUTION" : "01 / LIVE GRAVITY").font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(accent)
                        Text(model.preset.rawValue).font(.system(size: 25, weight: .light))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(model.isPreparing ? .orange : model.isPlaying ? accent : .orange).frame(width: 5, height: 5)
                            Text(model.isPreparing ? "준비 중" : model.isPlaying ? "LIVE" : "PAUSED").font(.system(size: 10, design: .monospaced))
                        }
                        .padding(9).background(.black.opacity(0.25), in: Capsule())
                        RecordingBadge(recorder: model.recorder)
                    }
                }
                Spacer()
                HStack {
                    HStack(spacing: 14) {
                        legend("은하 A", color: accent)
                        if !model.preset.isSingle { legend("은하 B", color: .orange) }
                    }
                    Spacer()
                    Text("드래그로 회전").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(24).allowsHitTesting(false)
            if let error = model.error {
                ContentUnavailableView("시뮬레이션을 시작할 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding().background(panel.opacity(0.95))
            }
        }
        .clipped()
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10))
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("SCENARIOS", subtitle: "은하 실험")
                    ScenarioPicker(selection: $model.preset)
                    if model.preset == .prograde || model.preset == .retrograde {
                        Button(model.preset == .prograde ? "같은 궤도로 역행 실험" : "같은 궤도로 순행 실험") {
                            model.preset = model.preset == .prograde ? .retrograde : .prograde
                        }
                        .font(.system(size: 12)).buttonStyle(.bordered)
                    }
                    Text(model.preset.observation).font(.system(size: 11)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
                    Text(model.preset.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("SIMULATION", subtitle: "시뮬레이션")
                    Picker("별 입자", selection: $model.particleCount) {
                        Text("8,192").tag(8_192)
                        Text("16,384").tag(16_384)
                        Text("32,768").tag(32_768)
                        Text("65,536").tag(65_536)
                    }.font(.system(size: 12))
                    Text("암흑물질 \(model.particleCount.formatted())개 추가 · 모두 중력에 기여\n개수·시나리오 변경 시 처음부터 시작합니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("OBSERVATORY", subtitle: "관측 시점")
                    controlSlider("확대", value: $model.zoom, range: 0.4...3, text: String(format: "%.1f×", model.zoom))
                    controlSlider("별 밝기", value: $model.exposure, range: 0.25...2.5, text: String(format: "%.1f", model.exposure))
                    Toggle("암흑물질 분포 보기", isOn: $model.showHalo).font(.system(size: 12))
                    if !model.preset.isSingle {
                        Toggle("동반 은하 별 강조", isOn: $model.emphasizeCompanion).font(.system(size: 12))
                    }
                    HStack {
                        Button("위에서 보기") { model.pitch = 0; model.yaw = 0 }
                        Spacer()
                        Button("시점 초기화") { model.resetCamera() }
                    }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Label("METAL COMPUTE", systemImage: "cpu").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                    Text(model.deviceName).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("살아 있는 중력장 · 별 + 암흑물질").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .overlay(alignment: .leading) { Divider().opacity(0.5) }
    }

    private func sectionLabel(_ title: String, subtitle: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5)
            Spacer()
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func controlSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.system(size: 11, design: .monospaced)).monospacedDigit()
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private func transport(wide: Bool) -> some View {
        HStack(spacing: wide ? 16 : 10) {
            Button { model.isPlaying.toggle() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18, height: 18).padding(10)
            }
            .buttonStyle(.plain).foregroundStyle(.black).background(accent, in: RoundedRectangle(cornerRadius: 10))
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(model.isPlaying ? "일시 정지" : "재생")
            Button { model.restart() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 17)).frame(width: 30, height: 38) }
                .buttonStyle(.plain).keyboardShortcut("r", modifiers: []).accessibilityLabel("처음부터 다시 시작")
            RecordingControls(recorder: model.recorder, compact: !wide, available: model.error == nil && model.isActive)
            Divider().frame(height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("SIM TIME").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                Text(String(format: "%06.2f", model.elapsed)).font(.system(size: 15, design: .monospaced)).monospacedDigit()
            }
            Spacer(minLength: 0)
            if wide {
                Text("\(model.particleCount.formatted()) STARS + HALO").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("\(Int(model.fps.rounded())) FPS").font(.system(size: 11, design: .monospaced)).foregroundStyle(accent).monospacedDigit()
        }
        .padding(.horizontal, wide ? 22 : 16).padding(.vertical, 14).background(panel)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var modelInfo: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("작은 별들, 거대한 만남").font(.title2.bold())
            Text("별과 암흑물질 입자 모두가 질량을 가진 N-body 시뮬레이션입니다. 분포가 바뀌면 중력장도 바뀌며, 은하 궤도의 에너지가 내부 운동으로 전달될 수 있습니다. 입자 하나는 여러 별 또는 암흑물질의 질량을 대표합니다.")
            Text("기본 별 분포는 두께와 속도 분산이 있는 지수 원반입니다. 위성과 껍질 실험은 구형 별 분포를 사용하고, 막대 실험은 원반 질량 비율을 높입니다. 각 은하의 질량과 크기에 맞춰 초기 속도를 계산합니다.")
            Text("먼 입자 묶음의 중력은 트리로 근사하며, 가까운 입자는 직접 계산합니다. 가스·별 생성·블랙홀은 포함하지 않습니다. 초기 평형과 중력 계산에도 근사가 있으므로 관측 천체를 정밀 예측하는 연구용 모델은 아닙니다. 단위는 무차원이며 G = 1입니다.")
                .foregroundStyle(.secondary)
            Button("관측 계속하기") { showInfo = false }.buttonStyle(.borderedProminent)
        }
        .font(.callout).lineSpacing(4).padding(30).frame(idealWidth: 480)
        .presentationDetents([.medium, .large])
    }
}
