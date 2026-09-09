import AVKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct RecordedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url.standardizedFileURL)
        }
        .suggestedFileName { $0.url.lastPathComponent }
    }
}

struct RecordingControls: View {
    @ObservedObject var recorder: GalaxyRecorder
    var compact: Bool
    var available: Bool
    @State private var showPreview = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if recorder.state == .recording { recorder.stop() } else { recorder.start() }
            } label: {
                HStack(spacing: 7) {
                    if recorder.state == .finishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: recorder.state == .recording ? "stop.fill" : "record.circle")
                            .font(.system(size: 18)).foregroundStyle(recorder.state == .recording ? .red : .primary)
                    }
                    if !compact {
                        Text(recorder.state == .recording ? "녹화 종료" : recorder.state == .finishing ? "저장 중" : "녹화")
                            .font(.system(size: 12))
                    }
                }
                .frame(minWidth: 20, minHeight: 38).padding(.horizontal, compact ? 6 : 10)
                .background(recorder.state == .recording ? .red.opacity(0.12) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(recorder.state == .finishing || (!available && recorder.state != .recording))
            .accessibilityLabel(recorder.state == .recording ? "녹화 종료" : "녹화 시작")
            .help("은하 화면을 소리 없이 MP4로 녹화합니다")
            Button { showPreview = true } label: {
                Image(systemName: "play.rectangle").font(.system(size: 18)).frame(width: 32, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(recorder.savedURL == nil || recorder.state != .idle)
            .accessibilityLabel("최근 녹화 보기 및 저장")
            .help("최근 녹화 보기 및 저장")
        }
        .onChange(of: recorder.savedURL) { _, url in if url != nil { showPreview = true } }
        .sheet(isPresented: $showPreview) {
            if let url = recorder.savedURL { RecordingPreview(url: url) }
        }
        .alert("녹화 오류", isPresented: Binding(get: { recorder.error != nil }, set: { if !$0 { recorder.error = nil } })) {
            Button("확인", role: .cancel) { recorder.error = nil }
        } message: { Text(recorder.error ?? "") }
    }
}

struct RecordingBadge: View {
    @ObservedObject var recorder: GalaxyRecorder
    var body: some View {
        if recorder.state != .idle {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(recorder.state == .finishing ? "SAVING" : String(format: "REC %02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                    .font(.system(size: 10, design: .monospaced)).monospacedDigit()
            }
            .padding(9).background(.black.opacity(0.5), in: Capsule())
            .accessibilityLabel(recorder.state == .finishing ? "녹화 저장 중" : "녹화 중 \(Int(recorder.elapsed))초")
        }
    }
}

private struct RecordingPreview: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var exporting = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("은하 충돌 녹화").font(.title2.bold())
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            MoviePlayerView(player: player)
                .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("은하 화면만 녹화 · 소리 없음 · MP4").font(.callout).foregroundStyle(.secondary)
            Text("녹화는 앱에 보관됩니다. 파일로 저장하거나 공유할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button { exporting = true } label: { Label("파일로 저장", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                ShareLink(item: RecordedMovie(url: url), preview: SharePreview("은하 충돌 녹화", image: Image(systemName: "sparkles"))) {
                    Label("공유", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 640, height: 540)
        #endif
        .presentationDetents([.large])
        .onDisappear { player.pause() }
        .fileExporter(isPresented: $exporting, item: RecordedMovie(url: url), contentTypes: [.mpeg4Movie],
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            switch result {
            case .success: message = "파일을 저장했습니다."
            case .failure(let error): message = "저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }
}

// Bridge AVKit's native player views directly. This also avoids depending on
// the OS-specific _AVKit_SwiftUI VideoPlayer class metadata at runtime.
#if os(macOS)
private struct MoviePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
#else
private struct MoviePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}
#endif
