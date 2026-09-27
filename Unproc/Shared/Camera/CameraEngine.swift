import AVFoundation
import Synchronization
import CoreImage
import Foundation
import ImageIO
import os

// MARK: - Values exchanged between the engine and CameraController

/// Capability ranges of the active device.
struct CameraDeviceRanges: Equatable, Sendable {
    var isoRange: ClosedRange<Float>
    var shutterRange: ClosedRange<Double>
    var biasRange: ClosedRange<Float>
    /// Selectable f-numbers; empty when the aperture is fixed.
    var apertureStops: [Float]
    /// Square Center Stage front camera: can shoot portrait or landscape.
    var isSquareFront: Bool = false
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
    /// Flash for the next capture (session queue).
    private var flashMode: AVCaptureDevice.FlashMode = .off
    /// Square front camera: shoot landscape while the phone is held upright.
    private var selfieLandscape = false

    /// Guards the frame-orientation fix (video queue → session queue).
    private let rotationFixPending = Mutex(false)
    /// Square front camera frame-shape check (video queue ↔ session queue).
    private let selfieShape = Mutex(SelfieShapeCheck())
    /// Physical hold (gravity) for photo orientation.
    private let hold = HoldOrientation()
    /// The square front sensor's 4x3/3x4 naming is swapped relative to our
    /// portrait UI (learned from frames, remembered across launches).
    private var selfieRatioSwapped: Bool {
        get { UserDefaults.standard.bool(forKey: "selfieRatioSwapped.\(DeviceModel.identifier)") }
        set { UserDefaults.standard.set(newValue, forKey: "selfieRatioSwapped.\(DeviceModel.identifier)") }
    }
    private var rotationCoordinators: [String: AVCaptureDevice.RotationCoordinator] = [:]
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]
    private var deviceObservations: [NSKeyValueObservation] = []
    private var liveThrottle: CameraLiveThrottle?
    private var subjectAreaToken: NSObjectProtocol?
    private var sessionTokens: [NSObjectProtocol] = []
    private var controlsConfig: CaptureControlsConfig?
    private var installedControls = InstalledCaptureControls()
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
        await onSessionQueue { () -> [Lens] in
            let clock = ContinuousClock()
            let began = clock.now
            let lenses = LensDiscovery.discover()
            let ms = CameraLogText.ms(clock.now - began)
            Log.camera.info("lenses: discovered count=\(lenses.count, privacy: .public) in \(ms, privacy: .public)ms")
            return lenses
        }
    }

    /// Configures (first time), selects `lens` if nothing is active yet, and
    /// (re)starts the session. Idempotent: a running session is left alone, a
    /// stopped or interrupted one is restarted.
    func start(lens: Lens, flavor: RawFlavor, intent: CameraIntent) async -> CameraStartOutcome {
        await onSessionQueue { [self] () -> CameraStartOutcome in
            let clock = ContinuousClock()
            let began = clock.now
            Log.camera.notice("session: start lens=\(lens.id, privacy: .public) flavor=\(flavor.rawValue, privacy: .public) configured=\(self.configured, privacy: .public) hasDevice=\(self.device != nil, privacy: .public) running=\(self.session.isRunning, privacy: .public)")
            wantsRunning = true
            hold.start()
            if !configured {
                configureOutputs()
            }
            if device == nil || self.lens == nil {
                rawFlavor = flavor
                do {
                    try switchTo(lens)
                } catch {
                    Log.camera.error("session: start failed switching to \(lens.id, privacy: .public): \(Log.describe(error), privacy: .public)")
                    return .failed(error.localizedDescription)
                }
                applyIntent(intent)
            } else if flavor != rawFlavor {
                Log.camera.info("session: start flavor change \(self.rawFlavor.rawValue, privacy: .public) -> \(flavor.rawValue, privacy: .public)")
                rawFlavor = flavor
                configurePhotoOutput()
            }
            if !session.isRunning {
                Log.camera.info("session: startRunning")
                session.startRunning()
                Log.camera.info("session: startRunning returned running=\(self.session.isRunning, privacy: .public) interrupted=\(self.session.isInterrupted, privacy: .public)")
            }
            guard let active = self.lens, let device else {
                Log.camera.error("session: start ended without active lens/device")
                return .failed("Camera unavailable")
            }
            let ms = CameraLogText.ms(clock.now - began)
            Log.camera.notice("session: started lens=\(active.id, privacy: .public) running=\(self.session.isRunning, privacy: .public) in \(ms, privacy: .public)ms")
            return .started(lens: active, ranges: ranges(of: device), isRunning: session.isRunning)
        }
    }

    func stop() {
        Log.camera.notice("session: stop requested")
        tracker.stop()
        hold.stop()
        sessionQueue.async { [self] in
            wantsRunning = false
            if session.isRunning {
                session.stopRunning()
                Log.camera.info("session: stopRunning returned running=\(self.session.isRunning, privacy: .public)")
            } else {
                Log.camera.debug("session: stop, already not running")
            }
        }
    }

    // MARK: - Lens / format

    /// Makes `lens` active. Lenses on the active device (every back stop on a
    /// virtual camera) only change `videoZoomFactor` — ramped smoothly when
    /// `animated`, set directly otherwise (continuous scrubbing).
    func select(_ lens: Lens, intent: CameraIntent, animated: Bool = true) async -> CameraSelectOutcome {
        await onSessionQueue { [self] () -> CameraSelectOutcome in
            guard configured, device != nil else {
                Log.camera.info("lens: select \(lens.id, privacy: .public) before configuration; deferred to start")
                return .notConfigured
            }
            let sameDevice = device?.uniqueID == lens.deviceID
            let fromID = self.lens?.id ?? "nil"
            let clock = ContinuousClock()
            let began = clock.now
            Log.camera.info("lens: switch \(fromID, privacy: .public) -> \(lens.id, privacy: .public) mode=\(sameDevice ? "zoom" : "device", privacy: .public) crop=\(Double(lens.crop), privacy: .public) animated=\(animated, privacy: .public)")
            do {
                try switchTo(lens, animated: animated)
            } catch {
                Log.camera.error("lens: switch \(fromID, privacy: .public) -> \(lens.id, privacy: .public) failed: \(Log.describe(error), privacy: .public)")
                return .failed(error.localizedDescription)
            }
            let ms = CameraLogText.ms(clock.now - began)
            Log.camera.info("lens: switched to \(lens.id, privacy: .public) mode=\(sameDevice ? "zoom" : "device", privacy: .public) in \(ms, privacy: .public)ms")
            if !sameDevice {
                applyIntent(intent)
            } else {
                // Only the zoom changed (no session work): keep everything, but
                // re-centre AF/AE on the new framing.
                pointOfInterest(intent.point ?? ViewfinderGeometry.centre, focusMode: .continuousAutoFocus, meter: true)
            }
            guard let active = self.lens, let device else {
                Log.camera.error("lens: switch ended without active lens/device")
                return .failed("Camera unavailable")
            }
            return .switched(lens: active, ranges: ranges(of: device))
        }
    }

    func setRawFlavor(_ flavor: RawFlavor) async {
        await onSessionQueue { [self] () -> Void in
            guard flavor != rawFlavor else { return }
            Log.camera.info("session: raw flavor \(self.rawFlavor.rawValue, privacy: .public) -> \(flavor.rawValue, privacy: .public) configured=\(self.configured, privacy: .public)")
            rawFlavor = flavor
            if configured, device != nil {
                configurePhotoOutput()
            }
        }
    }

    private func configureOutputs() {
        Log.camera.info("session: configuring outputs")
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else {
            Log.camera.error("session: cannot set .photo preset")
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        } else {
            Log.camera.error("session: cannot add photo output")
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            Log.camera.error("session: cannot add video output")
        }
        session.commitConfiguration()
        configured = true
        Log.camera.info("session: outputs configured preset=\(self.session.sessionPreset.rawValue, privacy: .public) outputs=\(self.session.outputs.count, privacy: .public) supportsControls=\(self.session.supportsControls, privacy: .public)")
    }

    /// Makes `lens` active. Same device (any two back stops on a virtual
    /// camera, or a crop of a physical one) → only the zoom changes, no
    /// session reconfiguration. A different device (back ↔ front, or physical
    /// lenses on single-camera phones) swaps the input.
    private func switchTo(_ lens: Lens, animated: Bool = false) throws {
        if let device, device.uniqueID == lens.deviceID, input != nil {
            Log.camera.debug("lens: same-device zoom \(lens.id, privacy: .public) factor=\(Double(lens.crop), privacy: .public) animated=\(animated, privacy: .public)")
            setZoom(lens.crop, on: device, animated: animated)
            self.lens = lens
            return
        }
        guard let newDevice = AVCaptureDevice(uniqueID: lens.deviceID) else {
            Log.camera.error("lens: no AVCaptureDevice for id=\(lens.deviceID, privacy: .public) (lens \(lens.id, privacy: .public))")
            throw UnprocError.cameraUnavailable
        }
        Log.camera.info("lens: device switch to \(newDevice.localizedName, privacy: .public) type=\(newDevice.deviceType.rawValue, privacy: .public) id=\(newDevice.uniqueID, privacy: .public)")
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: newDevice)
        } catch {
            Log.camera.error("lens: AVCaptureDeviceInput failed for \(lens.id, privacy: .public): \(Log.describe(error), privacy: .public)")
            throw error
        }
        tracker.stop()

        session.beginConfiguration()
        if let input {
            session.removeInput(input)
        }
        guard session.canAddInput(newInput) else {
            Log.camera.error("lens: session cannot add input for \(lens.id, privacy: .public); restoring previous input=\(self.input != nil, privacy: .public)")
            if let input, session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            throw UnprocError.cameraUnavailable
        }
        session.addInput(newInput)
        // Adopt the new device now: everything below (preview rotation, selfie
        // aspect) reads `device`. Assigning it only after commit made the front
        // camera's rotation come from the outgoing back camera (always 90°).
        input = newInput
        device = newDevice
        self.lens = lens

        // Keep the device locked across commit so the session can't override the format.
        var lockedForFormat = false
        let bestFormat = CaptureFormatPicker.bestPhotoFormat(for: newDevice)
        if bestFormat == nil {
            Log.camera.error("format: no suitable 4:3 high-quality format on \(lens.id, privacy: .public) (\(newDevice.formats.count, privacy: .public) formats); using .photo preset")
        }
        if let format = bestFormat,
           (try? newDevice.lockForConfiguration()) != nil {
            newDevice.activeFormat = format
            lockedForFormat = true
            Log.camera.info("format: chose \(CameraLogText.format(format), privacy: .public)")
        } else if session.canSetSessionPreset(.photo) {
            if bestFormat != nil {
                Log.camera.error("format: lockForConfiguration failed on \(lens.id, privacy: .public); using .photo preset")
            }
            session.sessionPreset = .photo
        }
        configureConnections(isFront: newDevice.position == .front)
        session.commitConfiguration()
        if lockedForFormat {
            newDevice.unlockForConfiguration()
        }
        // Connections can be rebuilt on commit (notably for the front camera);
        // re-apply rotation + mirroring to the final ones.
        configureConnections(isFront: newDevice.position == .front)
        applySelfieAspect()

        frozenISO = nil
        frozenDuration = nil
        simulatingLongExposure = false

        Log.camera.info("format: active \(CameraLogText.format(newDevice.activeFormat), privacy: .public) preset=\(self.session.sessionPreset.rawValue, privacy: .public)")

        configurePhotoOutput()
        // The chosen format didn't give us RAW: fall back to the photo preset.
        if photoOutput.availableRawPhotoPixelFormatTypes.isEmpty,
           newDevice.position == .back,
           session.sessionPreset != .photo,
           session.canSetSessionPreset(.photo) {
            Log.camera.error("format: no RAW formats with chosen format on \(lens.id, privacy: .public); falling back to .photo preset")
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.commitConfiguration()
            configurePhotoOutput()
        }

        if newDevice.isVirtualDevice {
            configureConstituentSwitching(newDevice)
        }
        if rotationCoordinators[newDevice.uniqueID] == nil {
            rotationCoordinators[newDevice.uniqueID] = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: nil)
        }
        setZoom(lens.crop, on: newDevice)
        bind(newDevice)
        // Controls aren't device-bound: install once, keep them across lens switches.
        if controlsConfig != nil, session.controls.isEmpty {
            Log.controls.info("controls: none installed after device switch; installing")
            installControls()
        }
    }

    /// Preview rotation that makes frames upright in our portrait UI: 90° for
    /// the usual landscape-mounted sensors, 0° for the portrait-mounted square
    /// Center Stage front sensor (iPhone 17+).
    private var previewAngle: CGFloat {
        guard let device else { return 90 }
        // Back sensors are all landscape-mounted: 90° in our portrait UI.
        guard device.position == .front else { return 90 }
        return frontPortraitAngle(for: device)
    }

    /// Rotation coordinator for a back camera, used as an orientation reference.
    private lazy var referenceCoordinator: AVCaptureDevice.RotationCoordinator? = {
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return nil }
        return AVCaptureDevice.RotationCoordinator(device: back, previewLayer: nil)
    }()

    /// The rotation that shows the front camera upright while the phone is
    /// held portrait, derived from Apple's rotation coordinators rather than
    /// assuming a sensor mounting (the iPhone 17+ square Center Stage sensor
    /// is mounted differently from earlier front cameras).
    ///
    /// Each coordinator's capture angle = its sensor's portrait angle + a
    /// device-orientation term (with opposite sign for the mirrored front
    /// camera). The back reference is 90° in portrait, so
    /// `offset = backCapture − 90` is the orientation term, and the front's
    /// portrait angle is `frontCapture + offset`.
    private func frontPortraitAngle(for device: AVCaptureDevice) -> CGFloat {
        let front: AVCaptureDevice.RotationCoordinator
        if let existing = rotationCoordinators[device.uniqueID] {
            front = existing
        } else {
            front = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinators[device.uniqueID] = front
        }
        let frontCapture = front.videoRotationAngleForHorizonLevelCapture
        let fallback: CGFloat = CaptureFormatPicker.isSquareFront(device) ? 0 : 90
        guard let reference = referenceCoordinator else {
            Log.camera.notice("rotation: no back reference; front capture=\(Double(frontCapture), privacy: .public) using \(Double(fallback), privacy: .public)")
            return fallback
        }
        let backCapture = reference.videoRotationAngleForHorizonLevelCapture
        var angle = (frontCapture + (backCapture - 90)).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        angle = (angle / 90).rounded() * 90
        if angle >= 360 { angle -= 360 }
        Log.camera.notice("rotation: front portrait angle=\(Double(angle), privacy: .public) (frontCapture=\(Double(frontCapture), privacy: .public) backCapture=\(Double(backCapture), privacy: .public) square=\(CaptureFormatPicker.isSquareFront(device), privacy: .public) type=\(device.deviceType.rawValue, privacy: .public))")
        return angle
    }

    /// Whether preview frames should be landscape (square front, landscape selfie).
    private var expectsLandscapeFrames: Bool {
        guard let device else { return false }
        return CaptureFormatPicker.isSquareFront(device) && selfieLandscape
    }

    private func configureConnections(isFront: Bool) {
        if let connection = videoOutput.connection(with: .video) {
            let angle = previewAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                Log.camera.info("preview: rotation \(Double(angle), privacy: .public) front=\(isFront, privacy: .public)")
            } else {
                Log.camera.error("preview: rotation \(Double(angle), privacy: .public) unsupported on video connection (front=\(isFront, privacy: .public))")
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

    /// Lets the virtual camera pick its physical constituent freely (like the
    /// Camera app: e.g. wide + digital zoom instead of tele in low light or
    /// close up).
    private func configureConstituentSwitching(_ device: AVCaptureDevice) {
        let before = device.primaryConstituentDeviceSwitchingBehavior
        guard before != .unsupported else {
            Log.camera.notice("virtual: constituent switching unsupported on \(device.deviceType.rawValue, privacy: .public)")
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            Log.camera.error("virtual: lock failed setting constituent switching: \(Log.describe(error), privacy: .public)")
            return
        }
        device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        device.unlockForConfiguration()
        let constituents = device.constituentDevices.map(\.deviceType.rawValue).joined(separator: ",")
        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { String(format: "%.2f", $0.doubleValue) }.joined(separator: ",")
        Log.camera.notice("virtual: constituent switching \(String(describing: before.rawValue), privacy: .public) -> \(String(describing: device.primaryConstituentDeviceSwitchingBehavior.rawValue), privacy: .public) (active \(String(describing: device.activePrimaryConstituentDeviceSwitchingBehavior.rawValue), privacy: .public)) constituents=[\(constituents, privacy: .public)] switchOver=[\(switchOver, privacy: .public)]")
    }

    private func configurePhotoOutput() {
        guard let device else { return }
        session.beginConfiguration()
        photoOutput.maxPhotoQualityPrioritization = .balanced
        // A virtual camera has no Bayer RAW: ProRAW is its only RAW, so it is
        // always on there, whatever the flavour setting.
        let virtualNeedsProRAW = device.isVirtualDevice
        let wantProRAW = (rawFlavor == .proRAW || virtualNeedsProRAW) && photoOutput.isAppleProRAWSupported
        photoOutput.isAppleProRAWEnabled = wantProRAW
        session.commitConfiguration()
        if virtualNeedsProRAW {
            if wantProRAW {
                Log.camera.notice("photo output: virtual device \(device.deviceType.rawValue, privacy: .public): ProRAW enabled (no Bayer RAW on virtual cameras; flavor=\(self.rawFlavor.rawValue, privacy: .public))")
            } else {
                Log.camera.error("photo output: virtual device \(device.deviceType.rawValue, privacy: .public) without ProRAW support: captures will be processed")
            }
        }

        // Bayer requested but unavailable: fall back to ProRAW when possible.
        if !wantProRAW,
           !photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }),
           photoOutput.isAppleProRAWSupported {
            Log.camera.notice("photo output: no Bayer RAW available; enabling ProRAW as fallback")
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = true
            session.commitConfiguration()
        }

        if let dims = CaptureFormatPicker.largestPhotoDimensions(of: device.activeFormat) {
            photoOutput.maxPhotoDimensions = dims
        } else {
            Log.camera.error("photo output: active format has no supportedMaxPhotoDimensions")
        }
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes.map(CameraLogText.fourCC).joined(separator: ",")
        let codecs = photoOutput.availablePhotoCodecTypes.map(\.rawValue).joined(separator: ",")
        Log.camera.info("photo output: flavor=\(self.rawFlavor.rawValue, privacy: .public) proRAWSupported=\(self.photoOutput.isAppleProRAWSupported, privacy: .public) proRAWEnabled=\(self.photoOutput.isAppleProRAWEnabled, privacy: .public) raw=[\(rawTypes, privacy: .public)] codecs=[\(codecs, privacy: .public)] maxDims=\(CameraLogText.dims(self.photoOutput.maxPhotoDimensions), privacy: .public)")
        if photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            Log.camera.notice("photo output: no RAW formats available on this device/format; captures will be processed")
        }
    }

    /// Zoom-ramp speed in doublings per second (the Camera app's lens buttons
    /// feel about this quick).
    private static let zoomRampRate: Float = 10

    /// Sets `videoZoomFactor` (clamped to what the device can do now), ramping
    /// there when `animated`.
    private func setZoom(_ factor: CGFloat, on device: AVCaptureDevice, animated: Bool = false) {
        let lower = max(device.minAvailableVideoZoomFactor, 1)
        let upper = max(min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor), lower)
        let zoom = CameraMath.clamp(factor, lower, upper)
        do {
            try device.lockForConfiguration()
        } catch {
            Log.camera.error("zoom: lock failed: \(Log.describe(error), privacy: .public)")
            return
        }
        Log.camera.debug("zoom: videoZoomFactor requested=\(Double(factor), privacy: .public) applied=\(Double(zoom), privacy: .public) range=\(Double(lower), privacy: .public)-\(Double(upper), privacy: .public) from=\(Double(device.videoZoomFactor), privacy: .public) animated=\(animated, privacy: .public)")
        device.cancelVideoZoomRamp()
        if animated {
            device.ramp(toVideoZoomFactor: zoom, withRate: Self.zoomRampRate)
        } else {
            device.videoZoomFactor = zoom
        }
        device.unlockForConfiguration()
    }

    /// Crop still to apply to a RAW frame from `device`.
    ///
    /// A virtual camera's RAW comes from the active constituent at its native
    /// field of view (digital zoom isn't applied), so the residual is the
    /// virtual zoom divided by the zoom at which that constituent takes over
    /// (widest = 1, then the switch-over factors). Physical devices: the
    /// lens's crop (= its `videoZoomFactor`) already is the residual.
    private func rawResidualCrop(for lens: Lens, on device: AVCaptureDevice) -> CGFloat {
        guard device.isVirtualDevice else { return lens.crop }
        let zoom = device.videoZoomFactor
        let constituents = device.constituentDevices.sorted { Self.fieldRank($0.deviceType) < Self.fieldRank($1.deviceType) }
        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let active = device.activePrimaryConstituent
        var native: CGFloat = 1
        var activeName = "nil"
        if let active, let index = constituents.firstIndex(where: { $0.uniqueID == active.uniqueID }) {
            activeName = active.deviceType.rawValue
            if index > 0, index - 1 < switchOver.count {
                native = switchOver[index - 1]
            }
        } else {
            // Unknown constituent: assume the longest one whose switch-over we've passed.
            native = switchOver.last(where: { $0 <= zoom + 0.001 }) ?? 1
            Log.capture.notice("capture: virtual active constituent unknown (\(active?.deviceType.rawValue ?? "nil", privacy: .public)); assuming native factor \(Double(native), privacy: .public)")
        }
        let residual = max(zoom / max(native, 1), 1)
        let switchText = switchOver.map { String(format: "%.2f", Double($0)) }.joined(separator: ",")
        Log.capture.notice("capture: virtual RAW constituent=\(activeName, privacy: .public) zoomFactor=\(Double(zoom), privacy: .public) native=\(Double(native), privacy: .public) switchOver=[\(switchText, privacy: .public)] residualCrop=\(Double(residual), privacy: .public) lens=\(lens.id, privacy: .public)")
        return residual
    }

    /// Orders constituents widest first.
    private static func fieldRank(_ type: AVCaptureDevice.DeviceType) -> Int {
        switch type {
        case .builtInUltraWideCamera: return 0
        case .builtInWideAngleCamera: return 1
        case .builtInTelephotoCamera: return 2
        default: return 3
        }
    }

    private func ranges(of device: AVCaptureDevice) -> CameraDeviceRanges {
        let format = device.activeFormat
        let minISO = format.minISO
        let maxISO = max(format.maxISO, minISO)
        let minShutter = format.minExposureDuration.seconds
        let maxShutter = max(format.maxExposureDuration.seconds, minShutter)
        let minBias = device.minExposureTargetBias
        let maxBias = max(device.maxExposureTargetBias, minBias)
        Log.camera.debug("ranges: iso=\(minISO, privacy: .public)-\(maxISO, privacy: .public) shutter=\(minShutter, privacy: .public)-\(maxShutter, privacy: .public)s bias=\(minBias, privacy: .public)-\(maxBias, privacy: .public)")
        return CameraDeviceRanges(isoRange: minISO...maxISO,
                                  shutterRange: minShutter...maxShutter,
                                  biasRange: minBias...maxBias,
                                  apertureStops: availableApertures(for: device).sorted(),
                                  isSquareFront: CaptureFormatPicker.isSquareFront(device))
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
                                                object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            Log.camera.error("session: runtime error \(error.map(Log.describe) ?? "unknown", privacy: .public)")
            self?.restartIfWanted()
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                                object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            Log.camera.notice("session: interrupted reason=\(reason, privacy: .public)")
            self?.emit(.running(false))
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                object: session, queue: nil) { [weak self] _ in
            Log.camera.notice("session: interruption ended")
            self?.restartIfWanted()
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                object: session, queue: nil) { [weak self] _ in
            Log.camera.info("session: did start running")
            self?.emit(.running(true))
        })
        sessionTokens.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification,
                                                object: session, queue: nil) { [weak self] _ in
            Log.camera.info("session: did stop running")
            self?.emit(.running(false))
        })
    }

    private func restartIfWanted() {
        sessionQueue.async { [self] in
            guard wantsRunning, configured else {
                Log.camera.info("session: restart skipped wantsRunning=\(self.wantsRunning, privacy: .public) configured=\(self.configured, privacy: .public)")
                return
            }
            if !session.isRunning {
                Log.camera.notice("session: restarting")
                session.startRunning()
            }
            Log.camera.info("session: restart result running=\(self.session.isRunning, privacy: .public) interrupted=\(self.session.isInterrupted, privacy: .public)")
            emit(.running(session.isRunning))
        }
    }

    // MARK: - Video frames

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if connection.isVideoMirrored {
            checkSelfieShape(landscape: width > height, square: width == height)
        } else if connection.videoRotationAngle != 90, width > height {
            // Back cameras are always 90° in our portrait UI. If a connection
            // lost that (seen after front↔back switches), restore exactly 90 —
            // never step relative to the current angle: stray frames from the
            // outgoing camera used to walk it 90 → 180 → 270 (upside down).
            let shouldFix = rotationFixPending.withLock { pending -> Bool in
                if pending { return false }
                pending = true
                return true
            }
            if shouldFix {
                let angle = connection.videoRotationAngle
                sessionQueue.async { [self] in
                    defer { rotationFixPending.withLock { $0 = false } }
                    guard device?.position == .back,
                          let video = videoOutput.connection(with: .video),
                          !video.isVideoMirrored,
                          video.videoRotationAngle != 90,
                          video.isVideoRotationAngleSupported(90) else { return }
                    Log.camera.error("preview: back connection at angle=\(Double(angle), privacy: .public); restoring 90")
                    video.videoRotationAngle = 90
                }
            }
        }
        frames.publish(CIImage(cvPixelBuffer: pixelBuffer))
        tracker.feed(pixelBuffer)
    }

    // MARK: - Device configuration helpers (session queue)

    private func withLockedDevice(_ body: (AVCaptureDevice) -> Void) {
        guard let device else {
            Log.camera.debug("device: no active device to configure")
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            Log.camera.error("device: lockForConfiguration failed: \(Log.describe(error), privacy: .public)")
            return
        }
        body(device)
        device.unlockForConfiguration()
    }

    /// Points AF (unless focus is manual) and, if `meter` and exposure is auto,
    /// AE at a viewfinder point.
    private func pointOfInterest(_ viewPoint: CGPoint, focusMode: AVCaptureDevice.FocusMode, meter: Bool) {
        withLockedDevice { device in
            let p = ViewfinderGeometry.devicePoint(fromViewfinder: viewPoint, isFront: device.position == .front)
            Log.camera.debug("focus: point view=\(String(describing: viewPoint), privacy: .public) device=\(String(describing: p), privacy: .public) mode=\(focusMode.rawValue, privacy: .public) meter=\(meter, privacy: .public) afAuto=\(self.focusIsAuto, privacy: .public) aeAuto=\(self.exposureIsAuto, privacy: .public)")
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
        Log.camera.info("intent: apply iso=\(String(describing: intent.iso), privacy: .public) shutter=\(String(describing: intent.shutter), privacy: .public) kelvin=\(String(describing: intent.kelvin), privacy: .public) lensPos=\(String(describing: intent.lensPosition), privacy: .public) bias=\(intent.bias, privacy: .public) aperture=\(String(describing: intent.aperture), privacy: .public) point=\(String(describing: intent.point), privacy: .public)")
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
        Log.camera.debug("focus: apply lensPos=\(String(describing: lensPosition), privacy: .public) customSupported=\(device.isLockingFocusWithCustomLensPositionSupported, privacy: .public)")
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
        Log.camera.debug("exposure: bias requested=\(ev, privacy: .public) applied=\(bias, privacy: .public)")
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
            Log.camera.debug("wb: locked kelvin=\(kelvin, privacy: .public) gains r=\(gains.redGain, privacy: .public) g=\(gains.greenGain, privacy: .public) b=\(gains.blueGain, privacy: .public)")
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            Log.camera.debug("wb: continuous auto (requested kelvin=\(String(describing: kelvin), privacy: .public))")
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        } else {
            Log.camera.debug("wb: no supported mode for kelvin=\(String(describing: kelvin), privacy: .public)")
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
            Log.camera.debug("exposure: auto (manual requested=\(!self.exposureIsAuto, privacy: .public) customSupported=\(device.isExposureModeSupported(.custom), privacy: .public))")
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
            Log.camera.info("exposure: long-exposure simulated want=\(wantSeconds, privacy: .public)s iso=\(baseISO, privacy: .public) preview=\(previewCap, privacy: .public)s@iso\(previewISO, privacy: .public) gainEV=\(gain, privacy: .public)")
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
            Log.camera.debug("exposure: custom duration=\(duration.seconds, privacy: .public)s iso=\(iso, privacy: .public) (current sentinel=\(iso == AVCaptureDevice.currentISO, privacy: .public)) wasSimulating=\(wasSimulating, privacy: .public)")
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
        Log.camera.info("controls: full auto")
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
        Log.camera.debug("exposure: set iso=\(String(describing: iso), privacy: .public) shutter=\(String(describing: shutter), privacy: .public)")
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
        Log.camera.debug("wb: set kelvin=\(String(describing: kelvin), privacy: .public)")
        sessionQueue.async { [self] in
            withLockedDevice { applyWhiteBalanceLocked($0, kelvin: kelvin) }
        }
    }

    /// Manual f-number, or nil for automatic. See `ApertureSupport.swift`.
    func setAperture(_ fNumber: Float?) {
        Log.camera.debug("aperture: set f=\(String(describing: fNumber), privacy: .public)")
        sessionQueue.async { [self] in
            withLockedDevice { applyAperture(fNumber, to: $0) }
        }
    }

    /// `nil` returns to continuous AF at `point` (nil = centre).
    func setManualFocus(_ lensPosition: Float?, point: CGPoint?) {
        Log.camera.debug("focus: manual lensPos=\(String(describing: lensPosition), privacy: .public)")
        if lensPosition != nil { tracker.stop() }
        sessionQueue.async { [self] in
            withLockedDevice { applyFocusLocked($0, lensPosition: lensPosition, point: point) }
        }
    }

    /// Tap: one-shot AF (unless focus is manual) + continuous AE (if exposure is auto) at the point.
    func focusOnce(at viewPoint: CGPoint) {
        Log.camera.debug("focus: tap at \(String(describing: viewPoint), privacy: .public)")
        tracker.stop()
        sessionQueue.async { [self] in
            pointOfInterest(viewPoint, focusMode: .autoFocus, meter: true)
        }
    }

    /// Back to centre continuous AF/AE and no tracking. Manual focus is released.
    func resetFocus() {
        Log.camera.debug("focus: reset to centre")
        tracker.stop()
        sessionQueue.async { [self] in
            focusIsAuto = true
            pointOfInterest(ViewfinderGeometry.centre, focusMode: .continuousAutoFocus, meter: true)
        }
    }

    func startTracking(seed: CGRect) {
        let centre = CGPoint(x: seed.midX, y: seed.midY)
        Log.camera.info("tracker: start seed=\(String(describing: seed), privacy: .public)")
        sessionQueue.async { [self] in
            focusIsAuto = true
            pointOfInterest(centre, focusMode: .continuousAutoFocus, meter: true)
        }
        tracker.start(seed: seed)
    }

    func stopTracking() {
        Log.camera.info("tracker: stop")
        tracker.stop()
    }

    private func trackerDidUpdate(_ rect: CGRect?) {
        guard let rect else {
            Log.camera.info("tracker: subject lost")
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

    // MARK: - Selfie orientation (square front sensor)

    func setSelfieLandscape(_ landscape: Bool) {
        sessionQueue.async { [self] in
            selfieLandscape = landscape
            applySelfieAspect()
        }
    }

    /// Crops the square front sensor to portrait (3:4) or landscape (4:3).
    private func applySelfieAspect(correcting: Bool = false) {
        let wantsLandscape = expectsLandscapeFrames
        guard let device, CaptureFormatPicker.isSquareFront(device) else {
            selfieShape.withLock { $0 = SelfieShapeCheck() }
            return
        }
        // Pick from the format's own list (keeps us independent of the type's name).
        let supported = device.activeFormat.supportedDynamicAspectRatios
        // Whether 4x3 means landscape in our portrait UI depends on how the
        // sensor is mounted; `selfieRatioSwapped` is learned from the frames.
        let swapped = selfieRatioSwapped
        let wantsNative4x3 = wantsLandscape != swapped
        selfieShape.withLock { $0 = SelfieShapeCheck(active: true, expectsLandscape: wantsLandscape, afterSwap: correcting) }
        let match = supported.first { wantsNative4x3 ? $0 == .ratio4x3 : $0 == .ratio3x4 }
        guard let ratio = match else {
            Log.camera.error("selfie: aspect \(wantsLandscape ? "4x3" : "3x4", privacy: .public) unsupported by active format")
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            Log.camera.error("selfie: lock failed: \(Log.describe(error), privacy: .public)")
            return
        }
        device.setDynamicAspectRatio(ratio) { [weak self] _, error in
            if let error {
                Log.camera.error("selfie: setDynamicAspectRatio failed: \(Log.describe(error), privacy: .public)")
            } else {
                Log.camera.info("selfie: aspect \(wantsLandscape ? "landscape" : "portrait", privacy: .public) via \(wantsNative4x3 ? "4x3" : "3x4", privacy: .public) (swapped=\(swapped, privacy: .public))")
                // Start checking the frame shape once the new crop has had
                // a moment to reach the video output.
                self?.selfieShape.withLock { $0.settledAt = CFAbsoluteTimeGetCurrent() + 0.35 }
            }
        }
        device.unlockForConfiguration()
    }

    /// Frames from the square front camera have the wrong shape for the
    /// requested orientation: the ratio naming is the other way round on this
    /// sensor. Swap it (once per request, remembered) and re-apply.
    private func checkSelfieShape(landscape: Bool, square: Bool) {
        guard !square else { return }
        let mismatch = selfieShape.withLock { check -> Bool? in
            guard check.active, let settled = check.settledAt,
                  CFAbsoluteTimeGetCurrent() > settled,
                  landscape != check.expectsLandscape else { return nil }
            check.settledAt = nil   // one correction per request
            return check.afterSwap
        }
        guard let afterSwap = mismatch else { return }
        sessionQueue.async { [self] in
            selfieRatioSwapped.toggle()
            if afterSwap {
                // Neither naming changed the frame shape: undo and stop.
                Log.camera.error("selfie: frames stay \(landscape ? "landscape" : "portrait", privacy: .public) with either ratio; reverting swap -> swapped=\(self.selfieRatioSwapped, privacy: .public)")
                applySelfieAspect(correcting: true)
                selfieShape.withLock { $0.active = false }
            } else {
                Log.camera.error("selfie: frames \(landscape ? "landscape" : "portrait", privacy: .public) but wanted the other; swapping ratio naming -> swapped=\(self.selfieRatioSwapped, privacy: .public)")
                applySelfieAspect(correcting: true)
            }
        }
    }

    // MARK: - Flash

    func setFlash(_ mode: AVCaptureDevice.FlashMode) {
        sessionQueue.async { [self] in
            flashMode = mode
            Log.capture.info("flash: set \(mode.rawValue, privacy: .public)")
        }
    }

    /// The requested flash if this output/config supports it, else off
    /// (an unsupported mode would raise when capturing).
    private func resolvedFlashMode() -> AVCaptureDevice.FlashMode {
        guard flashMode != .off else { return .off }
        let supported = photoOutput.supportedFlashModes
        if supported.contains(flashMode) { return flashMode }
        Log.capture.notice("flash: \(self.flashMode.rawValue, privacy: .public) unsupported here (supported=\(String(describing: supported.map(\.rawValue)), privacy: .public)); shooting without flash")
        return .off
    }

    // MARK: - Capture controls

    func installCaptureControls(_ config: CaptureControlsConfig) {
        Log.controls.info("controls: install requested stops=\(String(describing: config.zoomStops), privacy: .public) zoom=\(config.zoom, privacy: .public) bias=\(config.bias, privacy: .public) range=\(config.biasRange.lowerBound, privacy: .public)...\(config.biasRange.upperBound, privacy: .public) looks=\(config.lookCodes.count, privacy: .public) sel=\(config.selectedIndex, privacy: .public) ratios=\(config.ratioTitles.count, privacy: .public) ratioSel=\(config.ratioIndex, privacy: .public)")
        sessionQueue.async { [self] in
            controlsConfig = config
            installControls()
        }
    }

    /// Updates the Look picker's selection without rebuilding the controls.
    func updateLookSelection(_ index: Int) {
        sessionQueue.async { [self] in
            guard var config = controlsConfig else {
                Log.controls.debug("controls: look update \(index, privacy: .public) ignored, no config")
                return
            }
            config.selectedIndex = index
            controlsConfig = config
            if let look = installedControls.look, !config.lookCodes.isEmpty {
                let clamped = CameraMath.clamp(index, 0, config.lookCodes.count - 1)
                Log.controls.debug("controls: look picker set \(clamped, privacy: .public) (requested \(index, privacy: .public)) on session queue")
                look.selectedIndex = clamped
            } else {
                Log.controls.debug("controls: look update \(index, privacy: .public) stored, picker not installed")
            }
        }
    }

    /// Keeps the Camera Control zoom slider in step with on-screen zooming.
    func updateControlZoom(_ zoom: Float) {
        sessionQueue.async { [self] in
            controlsConfig?.zoom = zoom
            guard let slider = installedControls.zoom, !installedControls.zoomValues.isEmpty else { return }
            let value = CaptureControlsInstaller.nearest(zoom, in: installedControls.zoomValues)
            if slider.value != value {
                Log.controls.debug("controls: zoom slider set \(value, privacy: .public) (zoom \(zoom, privacy: .public)) on session queue")
                slider.value = value
            }
        }
    }

    func updateControlBias(_ bias: Float) {
        sessionQueue.async { [self] in
            controlsConfig?.bias = bias
            guard let slider = installedControls.bias, let bounds = installedControls.biasBounds else { return }
            // Out-of-range values would raise; snap to the slider's third stops.
            let snapped = min(max((bias * 3).rounded() / 3, bounds.lowerBound), bounds.upperBound)
            if abs(slider.value - snapped) > 0.01 {
                Log.controls.debug("controls: bias slider set \(snapped, privacy: .public) (bias \(bias, privacy: .public)) on session queue")
                slider.value = snapped
            }
        }
    }

    func updateControlRatio(_ index: Int) {
        sessionQueue.async { [self] in
            controlsConfig?.ratioIndex = index
            guard let picker = installedControls.ratio, let config = controlsConfig, !config.ratioTitles.isEmpty else {
                Log.controls.debug("controls: ratio update \(index, privacy: .public) stored, picker not installed")
                return
            }
            let clamped = CameraMath.clamp(index, 0, config.ratioTitles.count - 1)
            Log.controls.debug("controls: ratio picker set \(clamped, privacy: .public) (requested \(index, privacy: .public)) on session queue")
            picker.selectedIndex = clamped
        }
    }

    private func installControls() {
        guard let config = controlsConfig, device != nil, configured else {
            Log.controls.info("controls: install deferred config=\(self.controlsConfig != nil, privacy: .public) device=\(self.device != nil, privacy: .public) configured=\(self.configured, privacy: .public)")
            return
        }
        installedControls = CaptureControlsInstaller.install(on: session,
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
                    Log.capture.debug("exposure: prepare, no long-exposure switch (long=\(self.longExposure != nil, privacy: .public) running=\(self.session.isRunning, privacy: .public)) shutter=\(String(describing: seconds), privacy: .public)")
                    continuation.resume(returning: seconds)
                    return
                }
                let once = CameraResumeOnce(continuation)
                let clock = ContinuousClock()
                let began = clock.now
                Log.capture.info("exposure: prepare long exposure \(long.duration.seconds, privacy: .public)s iso=\(long.iso, privacy: .public)")
                frames.previewGainEV = 0
                device.setExposureModeCustom(duration: long.duration, iso: long.iso) { _ in
                    let ms = CameraLogText.ms(clock.now - began)
                    Log.capture.info("exposure: long exposure applied after \(ms, privacy: .public)ms")
                    once.resume(returning: seconds)
                }
                device.unlockForConfiguration()
                // Safety net in case the completion never fires.
                sessionQueue.asyncAfter(deadline: .now() + long.duration.seconds * 3 + 1) {
                    Log.capture.debug("exposure: long exposure safety timeout fired (no-op if already resumed)")
                    once.resume(returning: seconds)
                }
            }
        }
    }

    /// Returns the viewfinder to its (possibly simulated) preview exposure after a capture.
    func restorePreviewExposure() {
        sessionQueue.async { [self] in
            guard !exposureIsAuto else { return }
            Log.capture.debug("exposure: restore preview exposure")
            withLockedDevice { applyExposureLocked($0) }
        }
    }

    /// Captures one frame. Always RAW when the lens can (Bayer or ProRAW per
    /// flavour, falling back to the other); otherwise a processed HEVC/JPEG.
    func capturePhoto(fallbackLens: Lens) async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedFrame, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning, let device else {
                    Log.capture.error("capture: camera unavailable running=\(self.session.isRunning, privacy: .public) device=\(self.device != nil, privacy: .public) interrupted=\(self.session.isInterrupted, privacy: .public)")
                    continuation.resume(throwing: UnprocError.cameraUnavailable)
                    return
                }
                let activeLens = self.lens ?? fallbackLens
                let (settings, flavor) = makePhotoSettings()
                // RAW from a virtual camera needs the crop left over after its
                // constituent's native field of view; processed photos keep the
                // lens as is (they already carry the digital zoom).
                let lens: Lens
                if flavor != nil, device.isVirtualDevice {
                    let residual = rawResidualCrop(for: activeLens, on: device)
                    lens = Lens(id: activeLens.id, deviceID: activeLens.deviceID, position: activeLens.position,
                                kind: activeLens.kind, crop: residual, zoom: activeLens.zoom)
                } else {
                    lens = activeLens
                }
                applyCaptureOrientation(for: device)
                let clock = ContinuousClock()
                let began = clock.now
                let inFlightCount = inFlight.count
                Log.capture.notice("capture: begin id=\(settings.uniqueID, privacy: .public) lens=\(lens.id, privacy: .public) raw=\(CameraLogText.fourCC(settings.rawPhotoPixelFormatType), privacy: .public) flavor=\(flavor?.rawValue ?? "processed", privacy: .public) dims=\(CameraLogText.dims(settings.maxPhotoDimensions), privacy: .public) inFlight=\(inFlightCount, privacy: .public)")

                let deviceExposure: (Double, Float) = longExposure.map { ($0.duration.seconds, $0.iso) }
                    ?? (device.exposureDuration.seconds, device.iso)
                let capturedAt = Date()
                let id = settings.uniqueID

                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.sessionQueue.async { [weak self] in
                        self?.inFlight[id] = nil
                    }
                    let ms = CameraLogText.ms(clock.now - began)
                    switch result {
                    case .success(let output):
                        Log.capture.notice("capture: end id=\(id, privacy: .public) ok raw=\(output.raw?.count ?? 0, privacy: .public)B processed=\(output.processed?.count ?? 0, privacy: .public)B metaKeys=\(output.metadata.count, privacy: .public) in \(ms, privacy: .public)ms")
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
                        Log.capture.error("capture: end id=\(id, privacy: .public) failed after \(ms, privacy: .public)ms: \(Log.describe(error), privacy: .public)")
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

        let availableText = available.map(CameraLogText.fourCC).joined(separator: ",")
        Log.capture.debug("capture: settings wanted=\(self.rawFlavor.rawValue, privacy: .public) available=[\(availableText, privacy: .public)] bayer=\(bayer.map(CameraLogText.fourCC) ?? "nil", privacy: .public) proRAW=\(proRAW.map(CameraLogText.fourCC) ?? "nil", privacy: .public)")
        if let choice, choice.1 != rawFlavor {
            Log.capture.notice("capture: wanted \(self.rawFlavor.rawValue, privacy: .public) unavailable, using \(choice.1.rawValue, privacy: .public)")
        }

        let settings: AVCapturePhotoSettings
        if let choice {
            let (format, flavor) = choice
            settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            settings.photoQualityPrioritization = .speed
            settings.maxPhotoDimensions = rawPhotoDimensions(for: flavor)
            settings.flashMode = resolvedFlashMode()
            return (settings, flavor)
        }

        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        Log.capture.notice("capture: no RAW available, processed codec=\(codec.rawValue, privacy: .public)")
        settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.photoQualityPrioritization = .speed
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.flashMode = resolvedFlashMode()
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
            Log.capture.debug("capture: bayer dims \(CameraLogText.dims(fitting), privacy: .public) (output max \(CameraLogText.dims(outputMax), privacy: .public))")
            return fitting
        }
        Log.capture.notice("capture: no bayer size <= 12.2MP; supported=\(supported.map(CameraLogText.dims).joined(separator: ","), privacy: .public)")
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
        let coordinatorAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        // Portrait unless the phone is clearly held sideways: the UI never
        // rotates, so a stale or flat-phone coordinator reading used to turn
        // ordinary portrait shots sideways.
        let portraitAngle: CGFloat = device.position == .front ? frontPortraitAngle(for: device) : 90
        let held = hold.current
        let angle: CGFloat
        switch held {
        case .portrait: angle = portraitAngle
        case .landscape, .unknown: angle = coordinatorAngle
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        } else {
            Log.capture.notice("capture: rotation angle \(Double(angle), privacy: .public) unsupported")
        }
        Log.capture.notice("capture: rotation angle \(Double(angle), privacy: .public) hold=\(held.rawValue, privacy: .public) coordinator=\(Double(coordinatorAngle), privacy: .public) portrait=\(Double(portraitAngle), privacy: .public)")
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }
    }
}

/// What the square front camera's frames should look like, and when to
/// start checking (nil: not yet settled, or already corrected).
struct SelfieShapeCheck: Sendable {
    var active = false
    var expectsLandscape = false
    var settledAt: CFAbsoluteTime?
    /// This request already swapped the naming; a second mismatch reverts.
    var afterSwap = false
}

// MARK: - Small helpers

/// String helpers for log messages.
enum CameraLogText {
    static func dims(_ d: CMVideoDimensions) -> String {
        "\(d.width)x\(d.height)"
    }

    /// Four-character code ("bgg4") or the decimal value when not printable.
    static func fourCC(_ code: OSType) -> String {
        guard code != 0 else { return "0" }
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(code)
    }

    static func format(_ f: AVCaptureDevice.Format) -> String {
        let video = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let photo = f.supportedMaxPhotoDimensions.map(dims).joined(separator: ",")
        let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "video=\(dims(video)) sub=\(fourCC(subtype)) photo=[\(photo)] maxFPS=\(fps) hq=\(f.isHighestPhotoQualitySupported) iso=\(f.minISO)-\(f.maxISO) maxZoom=\(f.videoMaxZoomFactor)"
    }

    static func lens(_ l: Lens) -> String {
        "\(l.id)[dev=\(l.deviceID) zoom=\(l.zoom) crop=\(l.crop) \(l.kind.rawValue)]"
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return (Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15).rounded() 
    }
}

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
