import AVFoundation
import Combine
import Metal

/// Owns both recording state and the encoder. GPU callbacks return to the main actor;
/// completed frames are ordered explicitly before appending to AVAssetWriter.
@MainActor
final class GalaxyRecorder: ObservableObject {
    enum State { case idle, recording, finishing }
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var savedURL: URL?
    @Published var error: String?

    // Immutable handles cross the GPU callback boundary. The renderer alone writes
    // the texture; complete() accesses its pixel buffer only after GPU completion.
    struct Frame: @unchecked Sendable {
        let index: Int
        let pixelBuffer: CVPixelBuffer
        let metalTexture: CVMetalTexture // Retain the Core Video wrapper until GPU completion.
        let texture: MTLTexture
        let time: CMTime
    }

    private let directory: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cache: CVMetalTextureCache?
    private var width = 0
    private var height = 0
    private var startTime: Double?
    private var nextCaptureTime = -Double.infinity
    private var scheduled = 0
    private var nextAppend = 0
    private var pending = 0
    private var completed: [Int: Frame] = [:]
    private var lastAppendedTime: CMTime?
    private var failure: String?
    private var finalizing = false
    private var stagingURL: URL?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalaxyLab/Recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        savedURL = files.filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.contains(".partial.") }
            .max {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }

    func start() {
        guard state == .idle else { return }
        elapsed = 0
        error = nil
        state = .recording
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        finalizeIfReady()
    }

    /// Return at most 30 frames/second and bound outstanding pixel buffers to three.
    /// The renderer draws a second pass directly into this IOSurface-backed texture.
    func nextFrame(device: MTLDevice, size: CGSize, at now: Double) -> Frame? {
        guard state == .recording else { return nil }
        do {
            if writer == nil { try prepare(device: device, size: size) }
            guard now >= nextCaptureTime - 0.0001, pending + completed.count < 3,
                  let input, input.isReadyForMoreMediaData,
                  let pool = adaptor?.pixelBufferPool, let cache else {
                if writer?.status == .failed { fail(writer?.error?.localizedDescription ?? "영상 인코딩에 실패했습니다.") }
                return nil
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &pixelBuffer)
            if status == kCVReturnWouldExceedAllocationThreshold { return nil }
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw RecordingError.message("녹화 프레임을 할당할 수 없습니다 (\(status)).")
            }
            var wrapper: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer,
                [kCVMetalTextureUsage: MTLTextureUsage.renderTarget.rawValue] as CFDictionary,
                .bgra8Unorm, width, height, 0, &wrapper)
            guard result == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
                throw RecordingError.message("녹화용 Metal 텍스처를 만들 수 없습니다 (\(result)).")
            }
            if startTime == nil { startTime = now }
            let time = CMTime(seconds: max(0, now - startTime!), preferredTimescale: 60_000)
            let frame = Frame(index: scheduled, pixelBuffer: pixelBuffer, metalTexture: wrapper, texture: texture, time: time)
            scheduled += 1
            pending += 1
            nextCaptureTime = startTime! + (floor((now - startTime!) * 30 + 0.0001) + 1) / 30
            if Int(elapsed) != Int(time.seconds) { elapsed = time.seconds }
            return frame
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    func complete(_ frame: Frame, gpuError: String? = nil) {
        pending -= 1
        if let gpuError { failure = gpuError; state = .finishing }
        if failure == nil {
            completed[frame.index] = frame
            while let next = completed.removeValue(forKey: nextAppend) {
                // Backpressure can change while the GPU works. Drop that frame while
                // preserving wall-clock timestamps instead of slowing the movie down.
                if let input, input.isReadyForMoreMediaData {
                    if adaptor?.append(next.pixelBuffer, withPresentationTime: next.time) == true {
                        lastAppendedTime = next.time
                    } else {
                        failure = writer?.error?.localizedDescription ?? "영상 프레임을 저장할 수 없습니다."
                        state = .finishing
                        break
                    }
                }
                nextAppend += 1
            }
        }
        finalizeIfReady()
    }

    private func prepare(device: MTLDevice, size: CGSize) throws {
        let scale = min(1, 1920 / max(size.width, size.height, 2))
        width = max(2, Int(size.width * scale) / 2 * 2)
        height = max(2, Int(size.height * scale) / 2 * 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Galaxy-\(timestamp)-\(UUID().uuidString.prefix(8)).partial.mp4")
        stagingURL = url
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.writer = writer
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.message("이 기기에서 H.264 녹화를 시작할 수 없습니다.") }
        writer.add(input)
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess else { throw RecordingError.message("녹화용 텍스처 캐시를 만들 수 없습니다.") }
        guard writer.startWriting() else { throw writer.error ?? RecordingError.message("녹화를 시작할 수 없습니다.") }
        writer.startSession(atSourceTime: .zero)
    }

    private func fail(_ message: String) {
        failure = message
        state = .finishing
        finalizeIfReady()
    }

    private func finalizeIfReady() {
        guard state == .finishing, pending == 0, !finalizing else { return }
        finalizing = true
        guard failure == nil, let writer, let input, let lastAppendedTime, let stagingURL else {
            writer?.cancelWriting()
            let message = failure ?? "녹화된 프레임이 없습니다. 잠시 녹화한 후 종료해 주세요."
            if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
            reset()
            error = message
            return
        }
        writer.endSession(atSourceTime: CMTimeAdd(lastAppendedTime, CMTime(value: 1, timescale: 30)))
        input.markAsFinished()
        Task { @MainActor in
            await writer.finishWriting()
            do {
                guard writer.status == .completed else {
                    throw writer.error ?? RecordingError.message("녹화 파일 마무리에 실패했습니다.")
                }
                let finalURL = stagingURL.deletingLastPathComponent()
                    .appendingPathComponent(stagingURL.lastPathComponent.replacingOccurrences(of: ".partial.mp4", with: ".mp4"))
                try FileManager.default.moveItem(at: stagingURL, to: finalURL)
                reset()
                savedURL = finalURL
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                reset()
                self.error = error.localizedDescription
            }
        }
    }

    private func reset() {
        writer = nil; input = nil; adaptor = nil; cache = nil
        startTime = nil; nextCaptureTime = -.infinity
        scheduled = 0; nextAppend = 0; pending = 0
        completed.removeAll(); lastAppendedTime = nil
        failure = nil; finalizing = false; stagingURL = nil
        state = .idle
    }
}

private enum RecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
