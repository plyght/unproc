import AVFoundation
import CoreImage
import Foundation
import ImageIO

// MARK: - Values exchanged between the engine and CameraController

/// Capability ranges of the active device.
struct CameraDeviceRanges: Equatable, Sendable {
    var isoRange: ClosedRange<Float>
    var shutterRange: ClosedRange<Double>
    var biasRange: ClosedRange<Float>
    /// Selectable f-numbers; empty when the aperture is fixed.
    var apertureStops: [Float]
}

/// Throttled live readings of the active device.
struct CameraLiveValues: Equatable, Sendable {
    var iso: Float
    var shutter: Double
    var bias: Float
    var kelvin: Float
    var lensPosition: Float
    var aperture: Float
}

/// Everything the user has asked for, re-applied when the device changes.
struct CameraIntent: Sendable {
    var iso: Float?
    var shutter: Double?
    var kelvin: Float?
    var lensPosition: Float?
    var bias: Float
    /// Manual f-number, nil = automatic.
    var aperture: Float?
    /// Normalized viewfinder point for AF/AE, nil = centre.
    var point: CGPoint?
}

enum CameraEngineEvent: Sendable {
    case running(Bool)
    case failed(String)
    case live(CameraLiveValues)
    case subjectAreaChanged
    case trackingUpdated(CGRect)
    case trackingLost
}

enum CameraStartOutcome: Sendable {
    case started(lens: Lens, ranges: CameraDeviceRanges, isRunning: Bool)
    case failed(String)
}

enum CameraSelectOutcome: Sendable {
    /// The session isn't configured yet; the lens will be used by `start`.
    case notConfigured
    case switched(lens: Lens, ranges: CameraDeviceRanges)
    case failed(String)
}

// MARK: - Engine

/// Owns the `AVCaptureSession` and the active `AVCaptureDevice`.
///
/// Every piece of session/device state below the "session-queue state" mark is
/// only touched on `sessionQueue`. Public methods either hop there
/// asynchronously (fire-and-forget) or bridge to `async` with a continuation.
/// Results flow back to `CameraController` through the event handler.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "lol.peril.unproc.camera.session", qos: .userInitiated)
    let frames: PreviewFrameBus

    /// Longest exposure the viewfinder actually runs at; longer shutters are simulated.
    static let longestPreviewExposure: Double = 1.0 / 15.0

    private let videoQueue = DispatchQueue(label: "lol.peril.unproc.camera.video", qos: .userInteractive)
    private let liveQueue = DispatchQueue(label: "lol.peril.unproc.camera.live", qos: .utility)
    private let tracker = SubjectTracker()

    // Lock-protected, read from any queue.
    private let stateLock = NSLock()
    private var eventHandler: (@Sendable (CameraEngineEvent) -> Void)?
    private var liveOverride: (shutter: Double, iso: Float)?

    // MARK: session-queue state
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var wantsRunning = false
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var lens: Lens?
    private var rawFlavor: RawFlavor = .bayer
    private var rotationCoordinators: [String: AVCaptureDevice.RotationCoordinator] = [:]
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var deviceObservations: [NSKeyValueObservation] = []
    private var liveThrottle: CameraLiveThrottle?
    private var subjectAreaToken: NSObjectProtocol?
    private var sessionTokens: [NSObjectProtocol] = []
    private var controlsConfig: CaptureControlsConfig?
    private var lookPicker: AVCaptureIndexPicker?
    private let controlsDelegate = CaptureControlsDelegate()

    // Exposure / focus intent as applied to the device.
    private var manualISO: Float?
    private var manualShutter: Double?
    private var frozenISO: Float?
    private var frozenDuration: CMTime?
    private var simulatingLongExposure = false
    /// The real exposure to use at capture while the preview simulates it.
    private var longExposure: (duration: CMTime, iso: Float)?
    private var focusIsAuto = true
    private var exposureIsAuto: Bool { manualISO == nil && manualShutter == nil }

    init(frames: PreviewFrameBus) {
        self.frames = frames
        super.init()
        tracker.setUpdateHandler { [weak self] rect in
            self?.trackerDidUpdate(rect)
        }
        observeSession()
    }

    deinit {
        let center = NotificationCenter.default
        sessionTokens.forEach { center.removeObserver($0) }
        if let subjectAreaToken { center.removeObserver(subjectAreaToken) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (CameraEngineEvent) -> Void) {
        stateLock.withLock { eventHandler = handler }
    }

    private func emit(_ event: CameraEngineEvent) {
        let handler = stateLock.withLock { eventHandler }
        handler?(event)
    }

    /// Runs `body` on the session queue and returns its result.
    private func onSessionQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            sessionQueue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Lifecycle

    func discoverLenses() async -> [Lens] {
        await onSessionQueue { () -> [Lens] in LensDiscovery.discover() }
    }

    /// Configures (first time), selects `lens` if nothing is active yet, and
    /// (re)starts the session. Idempotent: a running session is left alone, a
    /// stopped or interrupted one is restarted.
    func start(lens: Lens, flavor: RawFlavor, intent: CameraIntent) async -> CameraStartOutcome {
        await onSessionQueue { [self] () -> CameraStartOutcome in
            wantsRunning = true
            if !configured {
                configureOutputs()
            }
            if device == nil || self.lens == nil {
                rawFlavor = flavor
                do {
                    try switchTo(lens)
                } catch {
                    return .failed(error.localizedDescription)
                }
                applyIntent(intent)
            } else if flavor != rawFlavor {
                rawFlavor = flavor
                configurePhotoOutput()
            }
            if !session.isRunning {
                session.startRunning()
            }
            guard let active = self.lens, let device else {
                return .failed("Camera unavailable")
            }
            return .started(lens: active, ranges: ranges(of: device), isRunning: session.isRunning)
        }
    }

    func stop() {
        tracker.stop()
        sessionQueue.async { [self] in
            wantsRunning = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Lens / format

    func select(_ lens: Lens, intent: CameraIntent) async -> CameraSelectOutcome {
        await onSessionQueue { [self] () -> CameraSelectOutcome in
            guard configured, device != nil else { return .notConfigured }
            let sameDevice = device?.uniqueID == lens.deviceID
            do {
                try switchTo(lens)
            } catch {
                return .failed(error.localizedDescription)
            }
            if !sameDevice {
                applyIntent(intent)
            } else {
                // Only the crop changed: keep everything, but re-centre AF/AE on the new framing.
                pointOfInterest(intent.point ?? ViewfinderGeometry.centre, focusMode: .continuousAutoFocus, meter: true)
            }
            guard let active = self.lens, let device else { return .failed("Camera unavailable") }
            return .switched(lens: active, ranges: ranges(of: device))
        }
    }

    func setRawFlavor(_ flavor: RawFlavor) async {
        await onSessionQueue { [self] () -> Void in
            guard flavor != rawFlavor else { return }
            rawFlavor = flavor
            if configured, device != nil {
                configurePhotoOutput()
            }
        }
    }

    private func configureOutputs() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        configured = true
    }

    /// Makes `lens` active. Same physical device → only the zoom changes (fast).
    private func switchTo(_ lens: Lens) throws {
        if let device, device.uniqueID == lens.deviceID, input != nil {
            setZoom(lens.crop, on: device)
            self.lens = lens
            return
        }
        guard let newDevice = AVCaptureDevice(uniqueID: lens.deviceID) else {
            throw UnprocError.cameraUnavailable
        }
        let newInput = try AVCaptureDeviceInput(device: newDevice)
        tracker.stop()

        session.beginConfiguration()
        if let input {
            session.removeInput(input)
        }
        guard session.canAddInput(newInput) else {
            if let input, session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            throw UnprocError.cameraUnavailable
        }
        session.addInput(newInput)

        // Keep the device locked across commit so the session can't override the format.
        var lockedForFormat = false
        if let format = CaptureFormatPicker.bestPhotoFormat(for: newDevice),
           (try? newDevice.lockForConfiguration()) != nil {
            newDevice.activeFormat = format
            lockedForFormat = true
        } else if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }
        configureConnections(isFront: newDevice.position == .front)
        session.commitConfiguration()
        if lockedForFormat {
            newDevice.unlockForConfiguration()
        }

        input = newInput
        device = newDevice
        self.lens = lens
        frozenISO = nil
        frozenDuration = nil
        simulatingLongExposure = false

        configurePhotoOutput()
        // The chosen format didn't give us RAW: fall back to the photo preset.
        if photoOutput.availableRawPhotoPixelFormatTypes.isEmpty,
           newDevice.position == .back,
           session.sessionPreset != .photo,
           session.canSetSessionPreset(.photo) {
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.commitConfiguration()
            configurePhotoOutput()
        }

        if rotationCoordinators[newDevice.uniqueID] == nil {
            rotationCoordinators[newDevice.uniqueID] = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
        }
        setZoom(lens.crop, on: newDevice)
        bind(newDevice)
        if controlsConfig != nil {
            installControls()
        }
    }

    private func configureConnections(isFront: Bool) {
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFront
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isFront
        }
    }

    private func configurePhotoOutput() {
        guard let device else { return }
        session.beginConfiguration()
        photoOutput.maxPhotoQualityPrioritization = .balanced
        let wantProRAW = rawFlavor == .proRAW && photoOutput.isAppleProRAWSupported
        photoOutput.isAppleProRAWEnabled = wantProRAW
        session.commitConfiguration()

        // Bayer requested but unavailable: fall back to ProRAW when possible.
        if !wantProRAW,
           !photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }),
           photoOutput.isAppleProRAWSupported {
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = true
            session.commitConfiguration()
        }

        if let dims = CaptureFormatPicker.largestPhotoDimensions(of: device.activeFormat) {
            photoOutput.maxPhotoDimensions = dims
        }
    }

    private func setZoom(_ crop: CGFloat, on device: AVCaptureDevice) {
        let upper = max(device.activeFormat.videoMaxZoomFactor, 1)
        let zoom = CameraMath.clamp(crop, max(device.minAvailableVideoZoomFactor, 1), upper)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = zoom
        device.unlockForConfiguration()
    }

    private func ranges(of device: AVCaptureDevice) -> CameraDeviceRanges {
        let format = device.activeFormat
        let minISO = format.minISO
        let maxISO = max(format.maxISO, minISO)
        let minShutter = format.minExposureDuration.seconds
        let maxShutter = max(format.maxExposureDuration.seconds, minShutter)
        let minBias = device.minExposureTargetBias
        let maxBias = max(device.maxExposureTargetBias, minBias)
        return CameraDeviceRanges(isoRange: minISO...maxISO,
                                  shutterRange: minShutter...maxShutter,
                                  biasRange: minBias...maxBias,
                                  apertureStops: availableApertures(for: device).sorted())
    }

    // MARK: - Device observation

    private func bind(_ device: AVCaptureDevice) {
        deviceObservations.forEach { $0.invalidate() }
        let throttle = CameraLiveThrottle(queue: liveQueue, interval: 1.0 / 15.0) { [weak self, weak device] in
            guard let self, let device else { return }
            self.emitLive(from: device)
        }
        liveThrottle = throttle
        deviceObservations = [
            device.observe(\.iso) { _, _ in throttle.fire() },
            device.observe(\.exposureDuration) { _, _ in throttle.fire() },
            device.observe(\.lensPosition) { _, _ in throttle.fire() },
            device.observe(\.deviceWhiteBalanceGains) { _, _ in throttle.fire() },
            device.observe(\.exposureTargetBias) { _, _ in throttle.fire() },
            device.observe(\.lensAperture) { _, _ in throttle.fire() },
        ]

        let center = NotificationCenter.default
        if let subjectAreaToken {
            center.removeObserver(subjectAreaToken)
        }
        subjectAreaToken = center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                              object: device,
                                              queue: nil) { [weak self] _ in
            self?.emit(.subjectAreaChanged)
        }
        throttle.fire()
    }

    private func emitLive(from device: AVCaptureDevice) {
        let override = stateLock.withLock { liveOverride }
        let maxGain = max(device.maxWhiteBalanceGain, 1)
        var gains = device.deviceWhiteBalanceGains
        gains.redGain = CameraMath.clamp(gains.redGain, 1, maxGain)
        gains.greenGain = CameraMath.clamp(gains.greenGain, 1, maxGain)
        gains.blueGain = CameraMath.clamp(gains.blueGain, 1, maxGain)
        var kelvin = device.temperatureAndTintValues(for: gains).temperature
        if !kelvin.isFinite { kelvin = 5500 }
        let values = CameraLiveValues(
            iso: override?.iso ?? device.iso,
            shutter: override?.shutter ?? device.exposureDuration.seconds,
            bias: device.exposureTargetBias,
            kelvin: kelvin,
            lensPosition: device.lensPosition,
            aperture: device.lensAperture
        )
        emit(.live(values))
    }

    private func setLiveOverride(_ value: (shutter: Double, iso: Float)?) {
        stateLock.withLock { liveOverride = value }
        liveThrottle?.fire()
    }

    // MARK: - Session notifications

    private func observeSession() {
        let center = NotificationCenter.default
        let session = self.session
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                object: session, queue: nil) { [weak self] _ in
            self?.restartIfWanted()
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                object: session, queue: nil) { [weak self] _ in
            self?.emit(.running(false))
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                object: session, queue: nil) { [weak self] _ in
            self?.restartIfWanted()
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                object: session, queue: nil) { [weak self] _ in
            self?.emit(.running(true))
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification,
                                                object: session, queue: nil) { [weak self] _ in
            self?.emit(.running(false))
        })
    }

    private func restartIfWanted() {
        sessionQueue.async { [self] in
            guard wantsRunning, configured else { return }
            if !session.isRunning {
                session.startRunning()
            }
            emit(.running(session.isRunning))
        }
    }

    // MARK: - Video frames

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.publish(CIImage(cvPixelBuffer: pixelBuffer))
        tracker.feed(pixelBuffer)
    }

    // MARK: - Device configuration helpers (session queue)

    private func withLockedDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        body(device)
        device.unlockForConfiguration()
    }

    /// Points AF (unless focus is manual) and, if `meter` and exposure is auto,
    /// AE at a viewfinder point.
    private func pointOfInterest(_ viewPoint: CGPoint, focusMode: AVCaptureDevice.FocusMode, meter: Bool) {
        withLockedDevice { device in
            let p = ViewfinderGeometry.devicePoint(fromViewfinder: viewPoint, isFront: device.position == .front)
            if focusIsAuto {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = p
                }
                if device.isFocusModeSupported(focusMode) {
                    device.focusMode = focusMode
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
            if meter && exposureIsAuto {
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = p
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    private func applyIntent(_ intent: CameraIntent) {
        manualISO = intent.iso
        manualShutter = intent.shutter
        frozenISO = nil
        frozenDuration = nil
        simulatingLongExposure = false
        withLockedDevice { device in
            applyFocusLocked(device, lensPosition: intent.lensPosition, point: intent.point)
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = ViewfinderGeometry.devicePoint(
                    fromViewfinder: intent.point ?? ViewfinderGeometry.centre,
                    isFront: device.position == .front)
            }
            applyExposureLocked(device)
            applyBiasLocked(device, intent.bias)
            applyWhiteBalanceLocked(device, kelvin: intent.kelvin)
            applyAperture(intent.aperture, to: device)
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    private func applyFocusLocked(_ device: AVCaptureDevice, lensPosition: Float?, point: CGPoint?) {
        if let lensPosition, device.isLockingFocusWithCustomLensPositionSupported {
            focusIsAuto = false
            device.setFocusModeLocked(lensPosition: CameraMath.clamp(lensPosition, 0, 1), completionHandler: nil)
        } else {
            focusIsAuto = true
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = ViewfinderGeometry.devicePoint(
                    fromViewfinder: point ?? ViewfinderGeometry.centre,
                    isFront: device.position == .front)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    private func applyBiasLocked(_ device: AVCaptureDevice, _ ev: Float) {
        let bias = CameraMath.clamp(ev, device.minExposureTargetBias, max(device.maxExposureTargetBias, device.minExposureTargetBias))
        device.setExposureTargetBias(bias, completionHandler: nil)
    }

    private func applyWhiteBalanceLocked(_ device: AVCaptureDevice, kelvin: Float?) {
        if let kelvin, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = max(device.maxWhiteBalanceGain, 1)
            gains.redGain = CameraMath.clamp(gains.redGain, 1, maxGain)
            gains.greenGain = CameraMath.clamp(gains.greenGain, 1, maxGain)
            gains.blueGain = CameraMath.clamp(gains.blueGain, 1, maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// Applies `manualISO` / `manualShutter` to a locked device.
    ///
    /// Shutters longer than `longestPreviewExposure` are simulated: the device
    /// runs at 1/15 s with ISO raised by the ratio (up to maxISO) and the
    /// remaining shortfall goes to `frames.previewGainEV`. The real exposure is
    /// remembered in `longExposure` and used at capture time.
    private func applyExposureLocked(_ device: AVCaptureDevice) {
        guard !exposureIsAuto, device.isExposureModeSupported(.custom) else {
            frozenISO = nil
            frozenDuration = nil
            simulatingLongExposure = false
            longExposure = nil
            frames.previewGainEV = 0
            setLiveOverride(nil)
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            return
        }

        // Entering manual: remember what auto exposure had settled on.
        if frozenISO == nil || frozenDuration == nil {
            frozenISO = device.iso
            frozenDuration = device.exposureDuration
        }

        let format = device.activeFormat
        let minISO = format.minISO
        let maxISO = max(format.maxISO, minISO)
        let minSeconds = format.minExposureDuration.seconds
        let maxSeconds = max(format.maxExposureDuration.seconds, minSeconds)
        let baseISO = CameraMath.clamp(manualISO ?? frozenISO ?? device.iso, minISO, maxISO)
        let wantSeconds = CameraMath.clamp(manualShutter ?? frozenDuration?.seconds ?? device.exposureDuration.seconds,
                                           minSeconds, maxSeconds)
        let previewCap = max(Self.longestPreviewExposure, minSeconds)

        if manualShutter != nil, wantSeconds > previewCap {
            let wantedISO = Double(baseISO) * (wantSeconds / previewCap)
            let previewISO = min(wantedISO, Double(maxISO))
            let gain = Float(log2(max(wantedISO / previewISO, 1)))
            device.setExposureModeCustom(duration: Self.time(previewCap),
                                         iso: Float(previewISO),
                                         completionHandler: nil)
            frames.previewGainEV = gain
            longExposure = (Self.time(wantSeconds), baseISO)
            simulatingLongExposure = true
            setLiveOverride((wantSeconds, baseISO))
        } else {
            // After a simulated long exposure the device's "current" values are the
            // fake ones, so use the frozen auto values instead of the sentinels.
            let wasSimulating = simulatingLongExposure
            let duration: CMTime
            if manualShutter != nil {
                duration = Self.time(wantSeconds)
            } else if wasSimulating, let frozenDuration {
                duration = frozenDuration
            } else {
                duration = AVCaptureDevice.currentExposureDuration
            }
            let iso: Float
            if manualISO != nil || wasSimulating {
                iso = baseISO
            } else {
                iso = AVCaptureDevice.currentISO
            }
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            frames.previewGainEV = 0
            longExposure = nil
            simulatingLongExposure = false
            setLiveOverride(nil)
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    // MARK: - Public controls (fire-and-forget onto the session queue)

    /// Full auto: centre continuous AF/AE, subject-area monitoring, auto WB, bias 0.
    func applyFullAuto() {
        tracker.stop()
        sessionQueue.async { [self] in
            manualISO = nil
            manualShutter = nil
            focusIsAuto = true
            withLockedDevice { device in
                applyFocusLocked(device, lensPosition: nil, point: nil)
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                applyExposureLocked(device)
                applyBiasLocked(device, 0)
                applyWhiteBalanceLocked(device, kelvin: nil)
                applyAperture(nil, to: device)
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
        }
    }

    func setExposure(iso: Float?, shutter: Double?) {
        sessionQueue.async { [self] in
            manualISO = iso
            manualShutter = shutter
            withLockedDevice { applyExposureLocked($0) }
        }
    }

    func setBias(_ ev: Float) {
        sessionQueue.async { [self] in
            withLockedDevice { applyBiasLocked($0, ev) }
        }
    }

    func setWhiteBalance(kelvin: Float?) {
        sessionQueue.async { [self] in
            withLockedDevice { applyWhiteBalanceLocked($0, kelvin: kelvin) }
        }
    }

    /// Manual f-number, or nil for automatic. See `ApertureSupport.swift`.
    func setAperture(_ fNumber: Float?) {
        sessionQueue.async { [self] in
            withLockedDevice { applyAperture(fNumber, to: $0) }
        }
    }

    /// `nil` returns to continuous AF at `point` (nil = centre).
    func setManualFocus(_ lensPosition: Float?, point: CGPoint?) {
        if lensPosition != nil { tracker.stop() }
        sessionQueue.async { [self] in
            withLockedDevice { applyFocusLocked($0, lensPosition: lensPosition, point: point) }
        }
    }

    /// Tap: one-shot AF (unless focus is manual) + continuous AE (if exposure is auto) at the point.
    func focusOnce(at viewPoint: CGPoint) {
        tracker.stop()
        sessionQueue.async { [self] in
            pointOfInterest(viewPoint, focusMode: .autoFocus, meter: true)
        }
    }

    /// Back to centre continuous AF/AE and no tracking. Manual focus is released.
    func resetFocus() {
        tracker.stop()
        sessionQueue.async { [self] in
            focusIsAuto = true
            pointOfInterest(ViewfinderGeometry.centre, focusMode: .continuousAutoFocus, meter: true)
        }
    }

    func startTracking(seed: CGRect) {
        let centre = CGPoint(x: seed.midX, y: seed.midY)
        sessionQueue.async { [self] in
            focusIsAuto = true
            pointOfInterest(centre, focusMode: .continuousAutoFocus, meter: true)
        }
        tracker.start(seed: seed)
    }

    func stopTracking() {
        tracker.stop()
    }

    private func trackerDidUpdate(_ rect: CGRect?) {
        guard let rect else {
            emit(.trackingLost)
            return
        }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        sessionQueue.async { [self] in
            guard tracker.isActive else { return }
            pointOfInterest(centre, focusMode: .continuousAutoFocus, meter: true)
        }
        emit(.trackingUpdated(rect))
    }

    // MARK: - Capture controls

    func installCaptureControls(_ config: CaptureControlsConfig) {
        sessionQueue.async { [self] in
            controlsConfig = config
            installControls()
        }
    }

    /// Updates the Look picker's selection without rebuilding the controls.
    func updateLookSelection(_ index: Int) {
        sessionQueue.async { [self] in
            guard var config = controlsConfig else { return }
            config.selectedIndex = index
            controlsConfig = config
            if let lookPicker, !config.lookCodes.isEmpty {
                lookPicker.selectedIndex = CameraMath.clamp(index, 0, config.lookCodes.count - 1)
            }
        }
    }

    private func installControls() {
        guard let config = controlsConfig, let device, configured else { return }
        lookPicker = CaptureControlsInstaller.install(on: session,
                                                      device: device,
                                                      config: config,
                                                      delegate: controlsDelegate,
                                                      delegateQueue: sessionQueue)
    }

    // MARK: - Capture

    /// Switches the device to the real exposure when a long shutter is being
    /// simulated, and waits until frames are exposed with it.
    /// Returns the manual shutter duration in seconds (nil in auto).
    func prepareCaptureExposure() async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            sessionQueue.async { [self] in
                let seconds: Double? = longExposure?.duration.seconds ?? manualShutter.map { (value: Double) -> Double in
                    guard let device else { return value }
                    let format = device.activeFormat
                    return CameraMath.clamp(value, format.minExposureDuration.seconds,
                                            max(format.maxExposureDuration.seconds, format.minExposureDuration.seconds))
                }
                guard let long = longExposure, let device, session.isRunning,
                      (try? device.lockForConfiguration()) != nil else {
                    continuation.resume(returning: seconds)
                    return
                }
                let once = CameraResumeOnce(continuation)
                frames.previewGainEV = 0
                device.setExposureModeCustom(duration: long.duration, iso: long.iso) { _ in
                    once.resume(returning: seconds)
                }
                device.unlockForConfiguration()
                // Safety net in case the completion never fires.
                sessionQueue.asyncAfter(deadline: .now() + long.duration.seconds * 3 + 1) {
                    once.resume(returning: seconds)
                }
            }
        }
    }

    /// Returns the viewfinder to its (possibly simulated) preview exposure after a capture.
    func restorePreviewExposure() {
        sessionQueue.async { [self] in
            guard !exposureIsAuto else { return }
            withLockedDevice { applyExposureLocked($0) }
        }
    }

    /// Captures one frame. Always RAW when the lens can (Bayer or ProRAW per
    /// flavour, falling back to the other); otherwise a processed HEVC/JPEG.
    func capturePhoto(fallbackLens: Lens) async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedFrame, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, let device else {
                    continuation.resume(throwing: UnprocError.cameraUnavailable)
                    return
                }
                let lens = self.lens ?? fallbackLens
                let (settings, flavor) = makePhotoSettings()
                applyCaptureOrientation(for: device)

                let deviceExposure: (Double, Float) = longExposure.map { ($0.duration.seconds, $0.iso) }
                    ?? (device.exposureDuration.seconds, device.iso)
                let capturedAt = Date()
                let id = settings.uniqueID

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.sessionQueue.async { [weak self] in
                        self?.inFlight[id] = nil
                    }
                    switch result {
                    case .success(let output):
                        let exif = output.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
                        let exifDuration = (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
                        let exifISO = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue
                        let frame = CapturedFrame(
                            rawDNG: output.raw,
                            rawFlavor: output.raw != nil ? flavor : nil,
                            processed: output.processed,
                            metadata: output.metadata,
                            lens: lens,
                            exposureDuration: exifDuration ?? deviceExposure.0,
                            iso: exifISO ?? deviceExposure.1,
                            capturedAt: capturedAt
                        )
                        continuation.resume(returning: frame)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                inFlight[id] = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func makePhotoSettings() -> (AVCapturePhotoSettings, RawFlavor?) {
        let available = photoOutput.availableRawPhotoPixelFormatTypes
        let bayer = available.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let proRAW = photoOutput.isAppleProRAWEnabled
            ? available.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            : nil

        let choice: (OSType, RawFlavor)?
        switch rawFlavor {
        case .bayer:
            choice = bayer.map { ($0, RawFlavor.bayer) } ?? proRAW.map { ($0, RawFlavor.proRAW) }
        case .proRAW:
            choice = proRAW.map { ($0, RawFlavor.proRAW) } ?? bayer.map { ($0, RawFlavor.bayer) }
        }

        let settings: AVCapturePhotoSettings
        if let choice {
            let (format, flavor) = choice
            settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            settings.photoQualityPrioritization = .speed
            settings.maxPhotoDimensions = rawPhotoDimensions(for: flavor)
            settings.flashMode = .off
            return (settings, flavor)
        }

        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.photoQualityPrioritization = .speed
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = .off
        return (settings, nil)
    }

    /// Per-shot size for a RAW capture.
    ///
    /// ProRAW can use the full sensor (48 MP on quad-Bayer sensors), so it gets
    /// the output's maximum. Bayer RAW on a quad-Bayer sensor is read out
    /// binned (12 MP); asking for more per shot is not a supported combination,
    /// so Bayer is clamped to the largest supported size of at most ~12.2 MP
    /// (4032×3024), or the smallest supported size if none fits under that.
    private func rawPhotoDimensions(for flavor: RawFlavor) -> CMVideoDimensions {
        let outputMax = photoOutput.maxPhotoDimensions
        guard flavor == .bayer, let device else { return outputMax }
        let bayerLimit = 4032 * 3024
        let supported = device.activeFormat.supportedMaxPhotoDimensions
            .filter { CaptureFormatPicker.area($0) <= CaptureFormatPicker.area(outputMax) }
        if let fitting = supported.filter({ CaptureFormatPicker.area($0) <= bayerLimit })
            .max(by: { CaptureFormatPicker.area($0) < CaptureFormatPicker.area($1) }) {
            return fitting
        }
        return supported.min(by: { CaptureFormatPicker.area($0) < CaptureFormatPicker.area($1) }) ?? outputMax
    }

    private func applyCaptureOrientation(for device: AVCaptureDevice) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        let coordinator: AVCaptureDevice.RotationCoordinator
        if let existing = rotationCoordinators[device.uniqueID] {
            coordinator = existing
        } else {
            coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinators[device.uniqueID] = coordinator
        }
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }
    }
}

// MARK: - Small helpers

/// Coalesces bursts of KVO callbacks into at most one action per `interval`.
final class CameraLiveThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private let queue: DispatchQueue
    private let interval: Double
    private let action: @Sendable () -> Void

    init(queue: DispatchQueue, interval: Double, action: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.interval = interval
        self.action = action
    }

    func fire() {
        let shouldSchedule: Bool = lock.withLock {
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + interval) { [self] in
            lock.withLock { scheduled = false }
            action()
        }
    }
}

/// Resumes a continuation exactly once, whichever path gets there first.
final class CameraResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
