import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// What a finished recording produced.
struct RecordedVideo: Sendable {
    let url: URL
    let startedAt: Date
    let duration: Double
    let frames: Int
    let dropped: Int
    let width: Int
    let height: Int
    let codec: String
}

/// Writes one recording: video frames (and, optionally, microphone audio)
/// into a QuickTime movie with `AVAssetWriter`.
///
/// Frames arrive on the capture queue and are handed to a private serial
/// writer queue; the capture queue never waits. While more than
/// `maxPending` frames are queued, new ones are dropped instead of blocking.
///
/// Zero processing: with the identity Look and frames already the output
/// size, the camera's own pixel buffers go straight to the encoder. Otherwise
/// each frame is centre-cropped to 16:9, scaled, run through the same Look
/// filter as stills (`LookLibrary.apply`) and rendered with the shared Metal
/// `CIContext` into buffers from the adaptor's pool.
///
/// The writer is created on the first video frame (its size and timestamp
/// define the movie); the session starts at that frame's presentation time,
/// and audio before it is dropped.
final class VideoRecorder: @unchecked Sendable {
    struct Config: @unchecked Sendable {
        var url: URL
        /// Baked into every frame. `.zero` = passthrough.
        var look: Look
        var resolution: VideoResolution
        var fps: Int
        /// Source frames are 10-bit: encode HEVC Main10 when possible.
        var tenBit: Bool
        /// HLG BT.2020 (else SDR BT.709).
        var hdr: Bool
        /// Clockwise rotation players apply (landscape recordings).
        var rotationDegrees: Int
        /// Audio track settings; nil = no audio track.
        var audioSettings: [String: Any]?
        /// Allow HEVC (falls back to H.264 when the encoder is missing or refuses).
        var allowHEVC: Bool = true
    }

    static let maxPending = 3

    /// HEVC encoding is available on this device / simulator.
    static let hevcAvailable: Bool = AVOutputSettingsAssistant.availableOutputSettingsPresets().contains(.hevc1920x1080)

    private enum Source {
        case buffer(CVPixelBuffer)
        case image(CIImage)

        var size: CGSize {
            switch self {
            case .buffer(let buffer):
                return CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            case .image(let image):
                return image.extent.size
            }
        }
    }

    let config: Config
    private let queue = DispatchQueue(label: "lol.peril.unproc.video.writer", qos: .userInitiated)
    private let startedAt = Date()
    private let isIdentityLook: Bool
    private let renderColorSpace: CGColorSpace

    // Guarded by `lock` (touched from capture queues).
    private let lock = NSLock()
    private var pending = 0
    private var accepting = true
    private var dropped = 0

    // Writer-queue state.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var lastVideoTime: CMTime = .invalid
    private var outputSize: CGSize = .zero
    private var frames = 0
    private var passthroughFrames = 0
    private var audioSamples = 0
    private var renderFailures = 0
    private var appendFailures = 0
    private var failure: Error?
    private var codecLabel = "none"
    private var setUpAttempted = false

    init(config: Config) {
        self.config = config
        isIdentityLook = config.look.id == Look.zero.id
        if config.hdr {
            renderColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpaceCreateDeviceRGB()
        } else {
            renderColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        }
        let audio = config.audioSettings != nil
        Log.video.notice("recorder: new \(config.url.lastPathComponent, privacy: .public) look=\(config.look.id, privacy: .public) res=\(config.resolution.label, privacy: .public) fps=\(config.fps, privacy: .public) tenBit=\(config.tenBit, privacy: .public) hdr=\(config.hdr, privacy: .public) rotation=\(config.rotationDegrees, privacy: .public) audio=\(audio, privacy: .public) hevc=\(config.allowHEVC && Self.hevcAvailable, privacy: .public)")
    }

    // MARK: - Input (any queue)

    /// A camera frame (capture queue). Never blocks; drops when the writer is behind.
    func appendVideo(pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard reserveSlot() else { return }
        queue.async { [self] in
            defer { releaseSlot() }
            handleVideo(.buffer(pixelBuffer), time: time)
        }
    }

    /// A synthetic frame (demo camera). Never blocks; drops when the writer is behind.
    func appendVideo(image: CIImage, time: CMTime) {
        guard reserveSlot() else { return }
        queue.async { [self] in
            defer { releaseSlot() }
            handleVideo(.image(image), time: time)
        }
    }

    /// Microphone audio (audio queue).
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        let open = lock.withLock { accepting }
        guard open, config.audioSettings != nil else { return }
        queue.async { [self] in
            handleAudio(sampleBuffer)
        }
    }

    private func reserveSlot() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            guard pending < Self.maxPending else {
                dropped += 1
                return false
            }
            pending += 1
            return true
        }
    }

    private func releaseSlot() {
        lock.withLock { pending -= 1 }
    }

    private func countDrop() {
        lock.withLock { dropped += 1 }
    }

    // MARK: - Finish

    /// Stops accepting input, drains what is queued and finishes the file.
    func finish() async throws -> RecordedVideo {
        lock.withLock { accepting = false }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecordedVideo, Error>) in
            // Serial queue: runs after every frame already queued.
            queue.async { [self] in
                finishOnQueue(continuation)
            }
        }
    }

    /// Stops and deletes the file (e.g. the camera went away).
    func cancel() {
        lock.withLock { accepting = false }
        queue.async { [self] in
            if let writer, writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: config.url)
            Log.video.notice("recorder: cancelled \(self.config.url.lastPathComponent, privacy: .public) after \(self.frames, privacy: .public) frames")
        }
    }

    private func finishOnQueue(_ continuation: CheckedContinuation<RecordedVideo, Error>) {
        let droppedCount = lock.withLock { dropped }
        guard let writer, writer.status == .writing, frames > 0, let startTime else {
            let status = writer.map { String(describing: $0.status.rawValue) } ?? "none"
            let error = failure ?? writer?.error ?? UnprocError.captureFailed("No video frames were recorded")
            Log.video.error("recorder: finish without a usable file (status=\(status, privacy: .public) frames=\(self.frames, privacy: .public) dropped=\(droppedCount, privacy: .public)): \(Log.describe(error), privacy: .public)")
            if writer?.status == .writing { writer?.cancelWriting() }
            try? FileManager.default.removeItem(at: config.url)
            continuation.resume(throwing: error)
            return
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(config.fps, 1)))
        let end = lastVideoTime + frameDuration
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        let duration = (end - startTime).seconds
        let size = outputSize
        let url = config.url
        let codec = codecLabel
        let frameCount = frames
        let passthrough = passthroughFrames
        let audio = audioSamples
        let renderFails = renderFailures
        let began = startedAt
        Log.video.info("recorder: finishing \(url.lastPathComponent, privacy: .public) frames=\(frameCount, privacy: .public) passthrough=\(passthrough, privacy: .public) audioSamples=\(audio, privacy: .public) dropped=\(droppedCount, privacy: .public) renderFailures=\(renderFails, privacy: .public) duration=\(duration, privacy: .public)s")
        writer.finishWriting {
            if writer.status == .completed {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
                Log.video.notice("recorder: finished \(url.lastPathComponent, privacy: .public) \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) \(codec, privacy: .public) \(duration, privacy: .public)s \(bytes, privacy: .public)B")
                continuation.resume(returning: RecordedVideo(url: url, startedAt: began, duration: duration,
                                                             frames: frameCount, dropped: droppedCount,
                                                             width: Int(size.width), height: Int(size.height),
                                                             codec: codec))
            } else {
                let error = writer.error ?? UnprocError.captureFailed("Video writer status \(writer.status.rawValue)")
                Log.video.error("recorder: finishWriting failed status=\(writer.status.rawValue, privacy: .public): \(Log.describe(error), privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Writer queue

    private func handleVideo(_ source: Source, time: CMTime) {
        guard failure == nil, time.isValid else { return }
        if writer == nil {
            guard !setUpAttempted else { return }
            setUpAttempted = true
            do {
                try setUp(frameSize: source.size)
            } catch {
                failure = error
                Log.video.error("recorder: set-up failed: \(Log.describe(error), privacy: .public)")
                return
            }
        }
        guard let writer, let videoInput, let adaptor, writer.status == .writing else {
            if let writer, writer.status == .failed, failure == nil {
                failure = writer.error ?? UnprocError.captureFailed("Video writer failed")
                Log.video.error("recorder: writer failed mid-recording: \(Log.describe(self.failure ?? UnprocError.captureFailed("?")), privacy: .public)")
            }
            return
        }
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
            Log.video.info("recorder: session started at \(time.seconds, privacy: .public)s")
        }
        if lastVideoTime.isValid, time <= lastVideoTime {
            countDrop()
            return
        }
        guard videoInput.isReadyForMoreMediaData else {
            countDrop()
            return
        }

        // Passthrough: the camera's own buffer, untouched.
        if case .buffer(let buffer) = source, isIdentityLook,
           CVPixelBufferGetWidth(buffer) == Int(outputSize.width),
           CVPixelBufferGetHeight(buffer) == Int(outputSize.height) {
            if adaptor.append(buffer, withPresentationTime: time) {
                frames += 1
                passthroughFrames += 1
                lastVideoTime = time
            } else {
                noteAppendFailure(writer)
            }
            return
        }

        guard let pool = adaptor.pixelBufferPool else {
            countDrop()
            if renderFailures == 0 { Log.video.error("recorder: adaptor has no pixel buffer pool") }
            renderFailures += 1
            return
        }
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let output = created else {
            countDrop()
            return
        }
        tagColor(output)
        let image: CIImage
        switch source {
        case .buffer(let buffer): image = prepared(CIImage(cvPixelBuffer: buffer))
        case .image(let frame): image = prepared(frame)
        }
        let destination = CIRenderDestination(pixelBuffer: output)
        destination.colorSpace = renderColorSpace
        do {
            let task = try Developer.shared.context.startTask(toRender: image, to: destination)
            _ = try task.waitUntilCompleted()
        } catch {
            renderFailures += 1
            countDrop()
            if renderFailures <= 3 {
                Log.video.error("recorder: render failed (\(self.renderFailures, privacy: .public)): \(Log.describe(error), privacy: .public)")
            }
            return
        }
        if adaptor.append(output, withPresentationTime: time) {
            frames += 1
            lastVideoTime = time
        } else {
            noteAppendFailure(writer)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard failure == nil, let audioInput, let startTime, let writer, writer.status == .writing else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time >= startTime, audioInput.isReadyForMoreMediaData else { return }
        if audioInput.append(sampleBuffer) {
            audioSamples += 1
        } else if appendFailures < 3 {
            appendFailures += 1
            Log.video.error("recorder: audio append failed status=\(writer.status.rawValue, privacy: .public): \(Log.describe(writer.error ?? UnprocError.captureFailed("?")), privacy: .public)")
        }
    }

    private func noteAppendFailure(_ writer: AVAssetWriter) {
        countDrop()
        appendFailures += 1
        if appendFailures <= 3 {
            Log.video.error("recorder: video append failed status=\(writer.status.rawValue, privacy: .public): \(Log.describe(writer.error ?? UnprocError.captureFailed("?")), privacy: .public)")
        }
        if writer.status == .failed, failure == nil {
            failure = writer.error ?? UnprocError.captureFailed("Video writer failed")
        }
    }

    /// Centre-crops to the output aspect, scales to the output size and applies the Look.
    private func prepared(_ source: CIImage) -> CIImage {
        let extent = source.extent
        let target = outputSize
        guard extent.width > 0, extent.height > 0, target.width > 0, target.height > 0 else { return source }
        let targetAspect = target.width / target.height
        let crop: CGRect
        if extent.width / extent.height > targetAspect {
            let width = extent.height * targetAspect
            crop = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / targetAspect
            crop = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
        var image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = target.width / crop.width
        if abs(scale - 1) > 0.0001 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        image = LookLibrary.apply(config.look, to: image)
        return image.clampedToExtent().cropped(to: CGRect(origin: .zero, size: target))
    }

    private func tagColor(_ buffer: CVPixelBuffer) {
        if config.hdr {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        } else {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
    }

    // MARK: - Set-up

    private struct Attempt {
        let codec: AVVideoCodecType
        let main10: Bool
        var label: String {
            if codec == .hevc { return main10 ? "HEVC Main10" : "HEVC Main" }
            return "H.264 High"
        }
    }

    private func setUp(frameSize: CGSize) throws {
        outputSize = VideoSpec.outputSize(frame: frameSize, longSide: config.resolution.longSide)
        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw UnprocError.captureFailed("Invalid video frame size")
        }
        var attempts: [Attempt] = []
        if config.allowHEVC && Self.hevcAvailable {
            if config.tenBit { attempts.append(Attempt(codec: .hevc, main10: true)) }
            attempts.append(Attempt(codec: .hevc, main10: false))
        }
        attempts.append(Attempt(codec: .h264, main10: false))
        Log.video.info("recorder: set-up frame=\(Int(frameSize.width), privacy: .public)x\(Int(frameSize.height), privacy: .public) output=\(Int(self.outputSize.width), privacy: .public)x\(Int(self.outputSize.height), privacy: .public) attempts=\(attempts.map(\.label).joined(separator: ","), privacy: .public)")

        var lastError: Error?
        for attempt in attempts {
            try? FileManager.default.removeItem(at: config.url)
            let candidate: AVAssetWriter
            do {
                candidate = try AVAssetWriter(outputURL: config.url, fileType: .mov)
            } catch {
                lastError = error
                Log.video.error("recorder: AVAssetWriter init failed: \(Log.describe(error), privacy: .public)")
                continue
            }
            let settings = videoSettings(for: attempt)
            guard candidate.canApply(outputSettings: settings, forMediaType: .video) else {
                Log.video.notice("recorder: \(attempt.label, privacy: .public) settings refused, trying next")
                continue
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.transform = VideoSpec.trackTransform(degrees: config.rotationDegrees,
                                                       width: outputSize.width, height: outputSize.height)
            guard candidate.canAdd(input) else {
                Log.video.notice("recorder: \(attempt.label, privacy: .public) input refused, trying next")
                continue
            }
            candidate.add(input)
            let pixelFormat: OSType = attempt.main10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let newAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                  sourcePixelBufferAttributes: attributes)
            var newAudio: AVAssetWriterInput?
            if let audioSettings = config.audioSettings {
                if candidate.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    audio.expectsMediaDataInRealTime = true
                    if candidate.canAdd(audio) {
                        candidate.add(audio)
                        newAudio = audio
                    } else {
                        Log.video.error("recorder: audio input refused; recording without sound")
                    }
                } else {
                    Log.video.error("recorder: audio settings refused; recording without sound")
                }
            }
            guard candidate.startWriting() else {
                lastError = candidate.error
                Log.video.error("recorder: startWriting failed with \(attempt.label, privacy: .public): \(Log.describe(candidate.error ?? UnprocError.captureFailed("?")), privacy: .public)")
                continue
            }
            writer = candidate
            videoInput = input
            audioInput = newAudio
            adaptor = newAdaptor
            codecLabel = attempt.label
            Log.video.notice("recorder: writing \(attempt.label, privacy: .public) \(Int(self.outputSize.width), privacy: .public)x\(Int(self.outputSize.height), privacy: .public)@\(self.config.fps, privacy: .public) \(VideoSpec.bitrate(resolution: self.config.resolution, fps: self.config.fps, hdr: self.config.hdr), privacy: .public)b/s hdr=\(self.config.hdr, privacy: .public) audio=\(newAudio != nil, privacy: .public) passthroughEligible=\(self.isIdentityLook, privacy: .public)")
            return
        }
        throw lastError ?? UnprocError.captureFailed("No video encoder accepted the settings")
    }

    private func videoSettings(for attempt: Attempt) -> [String: Any] {
        let fps = max(config.fps, 1)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: VideoSpec.bitrate(resolution: config.resolution, fps: fps, hdr: config.hdr),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ]
        if attempt.codec == .hevc {
            compression[AVVideoProfileLevelKey] = attempt.main10
                ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
                : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let color: [String: Any]
        if config.hdr {
            color = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            color = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        return [
            AVVideoCodecKey: attempt.codec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color,
        ]
    }
}
