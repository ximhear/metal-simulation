import AVFoundation
import Metal

@main
struct RecordingSmoke {
    @MainActor
    static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GalaxyRecordingSmoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = GalaxyRecorder(directory: directory)

        func waitForFinish() async throws {
            for _ in 0..<1000 {
                if recorder.state == .idle { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Recording did not finish")
        }

        // An immediate stop must not leave an invalid MP4 or a stuck saving state.
        recorder.start()
        recorder.stop()
        precondition(recorder.state == .idle && recorder.savedURL == nil && recorder.error != nil)

        recorder.start()
        for index in 0..<60 {
            var captured: GalaxyRecorder.Frame?
            for _ in 0..<1000 {
                // A resize during recording must keep the encoded dimensions fixed.
                captured = recorder.nextFrame(device: device,
                    size: index == 0 ? CGSize(width: 641, height: 361) : CGSize(width: 1280, height: 720),
                    at: 1 + Double(index) / 30)
                if captured != nil { break }
                precondition(recorder.error == nil, recorder.error ?? "")
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let frame = captured else { fatalError("Frame allocation timed out") }
            precondition(frame.texture.width == 640 && frame.texture.height == 360)
            let command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = frame.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = index < 30 ? MTLClearColorMake(1, 0, 0, 1) : MTLClearColorMake(0, 0, 1, 1)
            command.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
            await command.commitAndWait()
            precondition(command.status == .completed)
            if index == 59 {
                recorder.stop()
                precondition(recorder.state == .finishing, "Stop must wait for the outstanding GPU frame")
            }
            recorder.complete(frame)
        }
        try await waitForFinish()
        precondition(recorder.error == nil, recorder.error ?? "")
        let url = recorder.savedURL!
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let descriptions = try await track.load(.formatDescriptions)
        precondition(CMFormatDescriptionGetMediaSubType(descriptions[0]) == kCMVideoCodecType_H264)
        precondition(abs(duration - 2) < 0.04, "Wrong movie duration: \(duration)")
        precondition(size == CGSize(width: 640, height: 360))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var decoded = 0
        var firstColor: (UInt8, UInt8)?
        var lastColor: (UInt8, UInt8)?
        while let sample = output.copyNextSampleBuffer(), let pixel = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let offset = CVPixelBufferGetBytesPerRow(pixel) * 180 + 320 * 4
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let redBlue = (bytes[offset + 2], bytes[offset])
            if firstColor == nil { firstColor = redBlue }
            lastColor = redBlue
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            decoded += 1
        }
        precondition(reader.status == .completed)
        precondition(decoded >= 55, "Too many dropped frames: \(decoded)")
        precondition(firstColor!.0 > 220 && firstColor!.1 < 30, "First frame is not red")
        precondition(lastColor!.1 > 220 && lastColor!.0 < 30, "Last frame is not blue")

        // Reload exposes the latest completed movie; a failed later recording preserves it.
        let reloadedURL = GalaxyRecorder(directory: directory).savedURL
        precondition(reloadedURL?.standardizedFileURL == url.standardizedFileURL,
                     "Reload mismatch: \(String(describing: reloadedURL)) vs \(url)")
        recorder.start()
        let failedFrame = recorder.nextFrame(device: device, size: CGSize(width: 100, height: 100), at: 0)!
        recorder.complete(failedFrame, gpuError: "Injected GPU failure")
        precondition(recorder.state == .idle && recorder.error == "Injected GPU failure" && recorder.savedURL == url)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(files.count == 1, "Failed recording left a partial file")
        print("PASS: \(decoded) decoded H.264 frames, \(size), \(duration) s; red/blue GPU pixels verified; resize, pending-frame finish, immediate stop, GPU failure, and reload passed")
    }
}

private extension MTLCommandBuffer {
    func commitAndWait() async {
        await withCheckedContinuation { continuation in
            addCompletedHandler { _ in continuation.resume() }
            commit()
        }
    }
}
