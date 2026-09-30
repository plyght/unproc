import AVFoundation
import CoreImage
import Foundation
import Observation
import os

/// The camera, as seen by the UI. All state is MainActor-observable; the actual
/// `AVCaptureSession` work happens on `CameraEngine`'s serial session queue.
@MainActor
@Observable
final class CameraController {
    enum Status: Equatable { case idle, running, unauthorized, failed(String) }

    let frames: PreviewFrameBus
    private(set) var status: Status = .idle
    /// Ordered by zoom, front last.
    private(set) var lenses: [Lens] = []
    private(set) var currentLens: Lens?
    /// The lens a camera change (back ↔ front) is on its way to, while the
    /// session reconfigures; nil otherwise.
    private(set) var switchTarget: Lens?
    /// The camera the UI should treat as current: where a flip in flight is
    /// going, else the current lens. The zoom ruler, pinch and flip read this
    /// so they never act on the camera that is being left.
    var activeLens: Lens? { switchTarget ?? currentLens }
    private(set) var exposure: ExposureState = .initial
    private(set) var focus: FocusState = .initial
    /// Seconds the shutter is open right now (drives the screen dim), else nil.
    private(set) var openShutterDuration: Double?
    /// false => full auto, continuous AF fixed at centre. true keeps auto until something manual is set.
    var proEnabled: Bool = false {
        didSet {
            guard proEnabled != oldValue else { return }
            if !proEnabled { revertToAuto() }
        }
    }

    /// True when the current lens has a selectable aperture (e.g. iPhone 18 Pro main camera).
    var supportsVariableAperture: Bool { !exposure.apertureStops.isEmpty }

    private let engine: CameraEngine
    private let demo: SimulatorCamera?
    @ObservationIgnored private var rawFlavor: RawFlavor = .bayer
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var captureTail: Task<Void, Never>?

    /// Square Center Stage front camera (iPhone 17+): selfies can be portrait or
    /// landscape without rotating the phone.
    private(set) var supportsSelfieOrientation = false

    /// Landscape selfie on the square front camera.
    var selfieLandscape = false {
        didSet {
            guard demo == nil, selfieLandscape != oldValue else { return }
            engine.setSelfieLandscape(selfieLandscape)
        }
    }

    /// True when the frame being shot is landscape (square front, landscape selfie).
    var isLandscapeSelfie: Bool {
        selfieLandscape && supportsSelfieOrientation && currentLens?.isFront == true
    }

    /// Whether the current lens has a flash (every back camera shares the LED;
    /// the front camera has none here).
    /// Back: flash (torch in video). Front: Retina Flash for photos (the
    /// photo output lights the screen); no front light for video.
    var hasFlash: Bool {
        guard let lens = currentLens else { return false }
        return !lens.isFront || !isVideoMode
    }

    /// Flash for the next shot. Ignored where unsupported (and on the front camera).
    var flash: FlashSetting = .off {
        didSet {
            guard demo == nil else { return }
            let mode: AVCaptureDevice.FlashMode
            switch flash {
            case .off: mode = .off
            case .auto: mode = .auto
            case .on: mode = .on
            }
            engine.setFlash(mode)
        }
    }

    // MARK: Video mode state

    /// True once the camera runs in video mode (16:9 video format).
    private(set) var isVideoMode = false
    /// The format video mode actually records (nil in photo mode).
    private(set) var videoFormat: ActiveVideoFormat?
    /// A photo ↔ video reconfiguration is in progress.
    private(set) var isSwitchingMode = false
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?

    /// Frame rates the menu offers for the current video resolution.
    var offeredFrameRates: [VideoFrameRate] { videoFormat?.offered ?? VideoFrameRate.allCases }

    private enum ModeTarget: Equatable {
        case photo
        case video(VideoModeRequest)
    }

    @ObservationIgnored private var desiredMode: ModeTarget = .photo
    /// The engine starts in photo mode.
    @ObservationIgnored private var appliedMode: ModeTarget = .photo
    @ObservationIgnored private var modeLoop: Task<Void, Never>?

    /// Allowed range for manual white balance.
    static let kelvinRange: ClosedRange<Float> = 1800...12000

    init() {
        let frames = PreviewFrameBus()
        self.frames = frames
        self.engine = CameraEngine(frames: frames)
        self.demo = Self.isDemo ? SimulatorCamera(frames: frames) : nil
        engine.setEventHandler { [weak self] event in
            let target = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    target?.handle(event)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Asks for camera permission, configures the session on first use and
    /// (re)starts it. Safe to call repeatedly (e.g. every time the scene becomes
    /// active): a running session is left alone, a stopped or interrupted one is
    /// restarted. Selects `preferredLensID` on first start, else "back.wide".
    func start(preferredLensID: String?, rawFlavor: RawFlavor) async {
        Log.camera.info("controller: start preferred=\(preferredLensID ?? "nil", privacy: .public) flavor=\(rawFlavor.rawValue, privacy: .public) inProgress=\(self.startTask != nil, privacy: .public) demo=\(self.demo != nil, privacy: .public)")
        if let startTask {
            await startTask.value
            return
        }
        let task = Task {
            await self.performStart(preferredLensID: preferredLensID, rawFlavor: rawFlavor)
        }
        startTask = task
        await task.value
        startTask = nil
    }

    func stop() {
        Log.camera.info("controller: stop status=\(String(describing: self.status), privacy: .public)")
        if let demo {
            demo.stop()
            status = .idle
            return
        }
        stopTrackingState()
        engine.stop()
        if status == .running { status = .idle }
    }

    private func performStart(preferredLensID: String?, rawFlavor flavor: RawFlavor) async {
        rawFlavor = flavor
        if let demo {
            startDemo(demo, preferredLensID: preferredLensID)
            return
        }
        guard await Self.requestAuthorization() else {
            Log.camera.error("controller: camera not authorized")
            status = .unauthorized
            return
        }
        if lenses.isEmpty {
            lenses = await engine.discoverLenses()
            let list = lenses.map(CameraLogText.lens).joined(separator: " ")
            Log.camera.notice("controller: lenses \(list, privacy: .public)")
        }
        guard let lens = resolveLens(preferredLensID) else {
            Log.camera.error("controller: no camera available (lenses=\(self.lenses.count, privacy: .public))")
            status = .failed("No camera available")
            return
        }
        switch await engine.start(lens: lens, flavor: flavor, intent: makeIntent()) {
        case let .started(active, ranges, isRunning):
            Log.camera.notice("controller: started lens=\(active.id, privacy: .public) running=\(isRunning, privacy: .public)")
            currentLens = active
            rememberFront(active)
            apply(ranges)
            hasStarted = true
            status = isRunning ? .running : .idle
        case let .failed(message):
            Log.camera.error("controller: start failed: \(message, privacy: .public)")
            status = .failed(message)
        }
    }

    /// Demo mode (Simulator / `-UNPROC_DEMO`): fake lenses and exposure, frames
    /// from `SimulatorCamera`; no capture session and no permission prompt.
    private func startDemo(_ demo: SimulatorCamera, preferredLensID: String?) {
        if lenses.isEmpty {
            lenses = SimulatorCamera.lenses
            exposure = SimulatorCamera.exposure
            focus = SimulatorCamera.focus
        }
        guard let lens = resolveLens(preferredLensID) else {
            status = .failed("No camera available")
            return
        }
        currentLens = lens
        rememberFront(lens)
        Log.camera.info("controller: demo start lens=\(lens.id, privacy: .public)")
        demo.start(lens: lens)
        hasStarted = true
        status = .running
    }

    private static func requestAuthorization() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        Log.camera.info("controller: camera authorization=\(current.rawValue, privacy: .public)")
        switch current {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Log.camera.notice("controller: camera access prompt granted=\(granted, privacy: .public)")
            return granted
        default:
            return false
        }
    }

    private func resolveLens(_ preferredLensID: String?) -> Lens? {
        let candidates: [String?] = [
            hasStarted ? currentLens?.id : nil,
            preferredLensID,
            currentLens?.id,
            "back.wide",
        ]
        for case let id? in candidates {
            if let lens = lenses.first(where: { $0.id == id }) { return lens }
        }
        return lenses.first
    }

    // MARK: - Lens / format

    /// Switching between lenses of the same device — every back stop on a
    /// virtual camera, or a crop of a physical one — only changes the zoom
    /// (ramped when `animated`); other switches (back ↔ front) reconfigure the
    /// session.
    func select(_ lens: Lens, animated: Bool = true) async {
        // Known lenses, or a continuous-zoom crop of a known physical camera.
        let known = lenses.first(where: { $0.id == lens.id })
        let zoomCrop = lenses.contains(where: { $0.deviceID == lens.deviceID && $0.position == lens.position }) ? lens : nil
        guard let target = known ?? zoomCrop ?? (lenses.isEmpty ? lens : nil) else {
            Log.camera.error("controller: select unknown lens \(CameraLogText.lens(lens), privacy: .public)")
            return
        }
        let fromID = currentLens?.id ?? "nil"
        let fromDevice = currentLens?.deviceID
        if isRecording, target.deviceID != fromDevice || target.isFront != (currentLens?.isFront ?? false) {
            Log.video.notice("controller: select \(target.id, privacy: .public) ignored while recording (camera change)")
            return
        }
        // Back ↔ front: a zoom still queued from the scrub that led here
        // belongs to the camera being left. Applying it after the switch
        // selected a back lens again and silently undid the flip.
        let crossing = activeLens.map { $0.isFront != target.isFront } ?? false
        if crossing {
            if let stale = pendingZoom {
                Log.camera.info("controller: dropping queued zoom \(Double(stale.zoom), privacy: .public) (camera change to \(target.id, privacy: .public))")
            }
            pendingZoom = nil
            switchTarget = target
        }
        defer {
            if crossing, switchTarget?.id == target.id { switchTarget = nil }
        }
        Log.camera.info("controller: select \(fromID, privacy: .public) -> \(target.id, privacy: .public) crossing=\(crossing, privacy: .public)")
        stopTrackingState()
        focus.point = nil
        if let demo {
            currentLens = target
            rememberFront(target)
            demo.setLens(target)
            return
        }
        switch await engine.select(target, intent: makeIntent(), animated: animated) {
        case .notConfigured:
            Log.camera.info("controller: select \(target.id, privacy: .public) stored (not configured)")
            currentLens = target
            rememberFront(target)
        case let .switched(active, ranges):
            currentLens = active
            rememberFront(active)
            apply(ranges)
            if isVideoMode, active.deviceID != fromDevice {
                videoFormat = await engine.currentVideoFormat()
            }
            // The Camera Control zoom slider carries the back stops only.
            if !zoomFromCameraControl, !active.isFront { engine.updateControlZoom(Float(active.zoom)) }
        case let .failed(message):
            Log.camera.error("controller: select \(target.id, privacy: .public) failed: \(message, privacy: .public)")
        }
    }

    // MARK: - Flip (back ↔ selfie)

    /// Last selfie framing used this session (wide or standard, or a zoom in
    /// between); a flip to the front comes back to it.
    @ObservationIgnored private var lastFrontLens: Lens?

    private func rememberFront(_ lens: Lens) {
        guard lens.isFront, lastFrontLens?.id != lens.id else { return }
        lastFrontLens = lens
        Log.camera.debug("controller: remember front framing \(lens.id, privacy: .public) zoom=\(Double(lens.zoom), privacy: .public)")
    }

    /// Selfie lenses, widest first (two on the square Center Stage sensor).
    var frontLenses: [Lens] { lenses.filter(\.isFront).sorted { $0.zoom < $1.zoom } }

    /// The selfie camera offers more than one framing.
    var frontHasStops: Bool { frontLenses.count > 1 }

    /// Where a flip lands: on the front, the last framing used this session
    /// (else the standard one, "front.tight"); on the back, the main camera.
    func flipTarget(toFront: Bool) -> Lens? {
        if toFront {
            if let last = lastFrontLens { return last }
            return lenses.first { $0.id == "front.tight" } ?? frontLenses.first
        }
        return lenses.first { $0.id == "back.wide" } ?? lenses.first { !$0.isFront }
    }

    /// Flips between the back and selfie cameras (no-op if already there or
    /// while recording, which can't change cameras).
    func flip(toFront: Bool) async {
        guard let target = flipTarget(toFront: toFront) else {
            Log.camera.error("controller: flip toFront=\(toFront, privacy: .public): no such camera")
            return
        }
        guard activeLens?.isFront != toFront else {
            Log.camera.info("controller: flip toFront=\(toFront, privacy: .public) ignored: already there (active=\(self.activeLens?.id ?? "nil", privacy: .public))")
            return
        }
        guard !isRecording else {
            Log.camera.notice("controller: flip toFront=\(toFront, privacy: .public) ignored while recording")
            return
        }
        Log.camera.info("controller: flip toFront=\(toFront, privacy: .public) -> \(target.id, privacy: .public) (remembered front=\(self.lastFrontLens?.id ?? "nil", privacy: .public))")
        await select(target)
    }

    /// Selfie camera with two framings: a tap swaps them (to the standard one
    /// from anywhere else, to the wide one from the standard one).
    func toggleFrontFraming() async {
        let front = frontLenses
        guard let current = activeLens, current.isFront, front.count > 1,
              let wide = front.first, let tight = front.last else { return }
        let onTight = abs(current.zoom - tight.zoom) / tight.zoom < 0.01
        let target = onTight ? wide : tight
        Log.camera.info("controller: front framing \(current.id, privacy: .public) -> \(target.id, privacy: .public)")
        await select(target)
    }

    // MARK: - Continuous zoom

    /// The latest zoom asked for and which camera it is for.
    @ObservationIgnored private var pendingZoom: (zoom: CGFloat, front: Bool)?
    @ObservationIgnored private var isApplyingZoom = false

    /// Zoom factors (relative to the main wide) of the back lenses, ascending,
    /// crops included — the detents of the zoom scrubber on the back camera.
    var backZoomStops: [CGFloat] {
        Array(Set(lenses.filter { !$0.isFront }.map(\.zoom))).sorted()
    }

    /// The selfie camera's framings as display zoom (standard = 1), ascending.
    var frontZoomStops: [CGFloat] {
        Array(Set(lenses.filter(\.isFront).map(\.zoom))).sorted()
    }

    /// Stops of the camera in use (or being switched to).
    var zoomStops: [CGFloat] {
        activeLens?.isFront == true ? frontZoomStops : backZoomStops
    }

    /// Continuous zoom on the camera in use: across the back cameras, or
    /// between the selfie framings (one device, `videoZoomFactor` only). On a
    /// back virtual camera this is
    /// just its `videoZoomFactor`; otherwise it picks the longest physical lens
    /// at or below `zoom` and crops it digitally (the preview via
    /// `videoZoomFactor`, the photo via `Lens.crop` in development). Exact stops
    /// resolve to the real lens. Safe to call every frame of a drag: calls are
    /// coalesced and only the latest value is applied.
    func setZoom(_ zoom: CGFloat) {
        setZoom(zoom, fromCameraControl: false)
    }

    @ObservationIgnored private var zoomFromCameraControl = false

    private func setZoom(_ zoom: CGFloat, fromCameraControl: Bool) {
        // The Camera Control slider carries the back stops (it isn't rebuilt
        // per camera); everything else zooms the camera in use.
        let front = fromCameraControl ? false : (activeLens?.isFront ?? false)
        Log.camera.debug("zoom: request \(Double(zoom), privacy: .public) front=\(front, privacy: .public) cameraControl=\(fromCameraControl, privacy: .public) busy=\(self.isApplyingZoom, privacy: .public)")
        zoomFromCameraControl = fromCameraControl
        pendingZoom = (zoom, front)
        guard !isApplyingZoom else { return }
        isApplyingZoom = true
        Task {
            while let next = pendingZoom {
                pendingZoom = nil
                guard let lens = lensForZoom(next.zoom, front: next.front), lens.id != currentLens?.id else { continue }
                // An on-screen zoom never changes cameras: if a flip happened
                // since it was asked for, it's stale.
                if !zoomFromCameraControl, lens.isFront != (activeLens?.isFront ?? lens.isFront) {
                    Log.camera.info("zoom: dropping \(Double(next.zoom), privacy: .public) for the \(next.front ? "front" : "back", privacy: .public) camera (active=\(self.activeLens?.id ?? "nil", privacy: .public))")
                    continue
                }
                Log.camera.debug("zoom: \(Double(next.zoom), privacy: .public) -> lens \(lens.id, privacy: .public) crop=\(Double(lens.crop), privacy: .public)")
                // Scrubbing tracks the finger: no zoom ramp.
                await select(lens, animated: false)
            }
            isApplyingZoom = false
            zoomFromCameraControl = false
        }
    }

    private func lensForZoom(_ zoom: CGFloat, front: Bool) -> Lens? {
        if front { return frontLensForZoom(zoom) }
        let back = lenses.filter { !$0.isFront }
        guard !back.isEmpty else { return nil }
        let stops = backZoomStops
        let clamped = min(max(zoom, stops.first ?? zoom), stops.last ?? zoom)
        // An exact (±1 %) stop is the real lens, crop lenses included.
        if let exact = back.first(where: { abs($0.zoom - clamped) / $0.zoom < 0.01 }) {
            return exact
        }
        // Virtual camera: all back stops are one device and its zoom factor is
        // display zoom / base zoom (the same ratio for every stop).
        let sorted = back.sorted { $0.zoom < $1.zoom }
        if let virtualScale = Self.virtualZoomScale(sorted) {
            let stop = sorted.last(where: { $0.zoom <= clamped }) ?? sorted[0]
            return Lens(
                id: String(format: "back.zoom@%.2f", clamped),
                deviceID: stop.deviceID,
                position: stop.position,
                kind: stop.kind,
                crop: max(clamped * virtualScale, 1),
                zoom: clamped
            )
        }
        let physical = back.filter { $0.crop <= 1.0001 }.sorted { $0.zoom < $1.zoom }
        guard let base = physical.last(where: { $0.zoom <= clamped }) ?? physical.first else { return nil }
        let crop = max(clamped / base.zoom, 1)
        return Lens(
            id: String(format: "%@@%.2f", base.id, clamped),
            deviceID: base.deviceID,
            position: base.position,
            kind: base.kind,
            crop: crop,
            zoom: clamped
        )
    }

    /// Selfie camera: the exact framing at a stop, otherwise the same device
    /// at the proportional `videoZoomFactor` (all front lenses share one
    /// `factor / displayZoom` ratio).
    private func frontLensForZoom(_ zoom: CGFloat) -> Lens? {
        let front = frontLenses
        guard let first = front.first, let last = front.last, first.zoom > 0 else { return nil }
        let clamped = min(max(zoom, first.zoom), last.zoom)
        if let exact = front.first(where: { abs($0.zoom - clamped) / $0.zoom < 0.01 }) {
            return exact
        }
        let scale = first.crop / first.zoom
        return Lens(
            id: String(format: "front.zoom@%.2f", clamped),
            deviceID: first.deviceID,
            position: first.position,
            kind: first.kind,
            crop: max(clamped * scale, 1),
            zoom: clamped
        )
    }

    /// `crop / zoom` when every back lens shares one device and that ratio
    /// (i.e. the virtual camera's base zoom) is the same for all of them; nil
    /// for physical lenses (which includes demo mode's per-lens crops).
    private static func virtualZoomScale(_ back: [Lens]) -> CGFloat? {
        guard let first = back.first, first.zoom > 0, Set(back.map(\.kind)).count > 1,
              back.allSatisfy({ $0.deviceID == first.deviceID && $0.zoom > 0 }) else { return nil }
        let scale = first.crop / first.zoom
        guard back.allSatisfy({ abs($0.crop / $0.zoom - scale) <= scale * 0.01 }) else { return nil }
        return scale
    }

    func setRawFlavor(_ flavor: RawFlavor) async {
        Log.camera.info("controller: raw flavor \(flavor.rawValue, privacy: .public)")
        rawFlavor = flavor
        guard demo == nil else { return }
        await engine.setRawFlavor(flavor)
    }

    // MARK: - Video mode

    /// Photo mode (`nil`) or video mode with `request`. Calls are coalesced:
    /// only the latest request is applied once the current one finishes.
    func setVideoMode(_ request: VideoModeRequest?) async {
        desiredMode = request.map { ModeTarget.video($0) } ?? .photo
        if modeLoop == nil {
            modeLoop = Task { await self.runModeLoop() }
        }
        await modeLoop?.value
    }

    private func runModeLoop() async {
        isSwitchingMode = true
        while desiredMode != appliedMode {
            let target = desiredMode
            switch target {
            case .photo: await applyVideoMode(nil)
            case .video(let request): await applyVideoMode(request)
            }
            appliedMode = target
        }
        isSwitchingMode = false
        modeLoop = nil
    }

    private func applyVideoMode(_ request: VideoModeRequest?) async {
        let wanted = request.map { "video \($0.resolution.label)@\($0.fps.rawValue) hdr=\($0.hdr)" } ?? "photo"
        Log.video.notice("controller: mode -> \(wanted, privacy: .public) recording=\(self.isRecording, privacy: .public)")
        if let demo {
            demo.setVideoMode(request != nil)
            isVideoMode = request != nil
            videoFormat = request.map {
                ActiveVideoFormat(resolution: $0.resolution, fps: $0.fps, tenBit: false, hdr: false,
                                  offered: VideoFrameRate.allCases)
            }
            return
        }
        if let request, request.audio {
            await Self.requestMicrophoneIfNeeded()
        }
        switch await engine.setVideoMode(request, intent: makeIntent()) {
        case let .configured(lens, ranges, video):
            currentLens = lens
            apply(ranges)
            isVideoMode = request != nil
            videoFormat = video
            Log.video.notice("controller: mode now \(request == nil ? "photo" : "video", privacy: .public) format=\(video?.label ?? "-", privacy: .public) tenBit=\(video?.tenBit ?? false, privacy: .public) hdr=\(video?.hdr ?? false, privacy: .public)")
        case .deferred:
            isVideoMode = request != nil
            videoFormat = nil
        case let .failed(message):
            Log.video.error("controller: mode change failed: \(message, privacy: .public)")
        }
    }

    /// Asks for the microphone the first time video mode is used.
    private static func requestMicrophoneIfNeeded() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            Log.video.info("controller: microphone authorization=\(status.rawValue, privacy: .public)")
            return
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Log.video.notice("controller: microphone prompt granted=\(granted, privacy: .public)")
    }

    /// Starts recording with `look` baked into the frames (ignored for HDR).
    func startRecording(look: Look) async throws {
        guard isVideoMode, !isRecording, !isSwitchingMode, status == .running else {
            Log.video.error("controller: record refused videoMode=\(self.isVideoMode, privacy: .public) recording=\(self.isRecording, privacy: .public) switching=\(self.isSwitchingMode, privacy: .public) status=\(String(describing: self.status), privacy: .public)")
            throw UnprocError.cameraUnavailable
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unproc-rec-\(UUID().uuidString).mov")
        if let demo {
            let format = videoFormat
            let config = VideoRecorder.Config(
                url: url,
                look: look,
                resolution: format?.resolution ?? .hd1080,
                fps: format?.fps.rawValue ?? 30,
                tenBit: false,
                hdr: false,
                rotationDegrees: 0,
                audioSettings: nil
            )
            demo.startRecording(config: config)
        } else {
            try await engine.startRecording(url: url, look: look)
        }
        isRecording = true
        recordingStartedAt = Date()
        Log.video.notice("controller: recording \(url.lastPathComponent, privacy: .public)")
    }

    /// Stops recording and returns the finished movie (in a temporary folder).
    func stopRecording() async throws -> RecordedVideo {
        guard isRecording else { throw UnprocError.captureFailed("Not recording") }
        isRecording = false
        recordingStartedAt = nil
        if let demo {
            return try await demo.stopRecording()
        }
        return try await engine.stopRecording()
    }

    // MARK: - Focus

    /// Tap: one-shot AF + AE at a normalized viewfinder point ((0,0) top-left).
    /// With manual focus set, only exposure is metered there.
    func focus(at point: CGPoint) {
        let p = ViewfinderGeometry.clampUnit(point)
        stopTrackingState()
        focus.point = p
        guard demo == nil else { return }
        engine.focusOnce(at: p)
    }

    /// Long press: Vision-tracks the subject at the point and keeps AF/AE on it.
    func track(at point: CGPoint) {
        let p = ViewfinderGeometry.clampUnit(point)
        let seed = ViewfinderGeometry.trackingSeed(around: p)
        focus.manualLensPosition = nil
        focus.point = p
        focus.isTracking = true
        focus.trackedRect = seed
        guard demo == nil else { return }
        engine.startTracking(seed: seed)
    }

    /// Back to centre continuous AF, stop tracking, release manual focus.
    func resetFocus() {
        focus.isTracking = false
        focus.trackedRect = nil
        focus.point = nil
        focus.manualLensPosition = nil
        guard demo == nil else { return }
        engine.resetFocus()
    }

    /// 0…1 lens position, or nil for continuous AF.
    func setManualFocus(_ lensPosition: Float?) {
        if let lensPosition {
            let value = CameraMath.clamp(lensPosition, 0, 1)
            stopTrackingState()
            focus.manualLensPosition = value
            if demo != nil { focus.lensPosition = value }
        } else {
            focus.manualLensPosition = nil
        }
        guard demo == nil else { return }
        engine.setManualFocus(focus.manualLensPosition, point: focus.point)
    }

    // MARK: - Exposure / white balance

    func setISO(_ iso: Float?) {
        exposure.manualISO = iso.map { CameraMath.clamp($0, exposure.isoRange) }
        if demo != nil {
            if let value = exposure.manualISO { exposure.iso = value }
            return
        }
        engine.setExposure(iso: exposure.manualISO, shutter: exposure.manualShutter)
    }

    /// May exceed what the preview can run at: the preview is kept at ≥ 1/15 s
    /// and the missing brightness is simulated via `frames.previewGainEV`.
    func setShutter(_ seconds: Double?) {
        exposure.manualShutter = seconds.map { CameraMath.clamp($0, exposure.shutterRange) }
        if demo != nil {
            if let value = exposure.manualShutter { exposure.shutter = value }
            return
        }
        engine.setExposure(iso: exposure.manualISO, shutter: exposure.manualShutter)
    }

    func setExposureBias(_ ev: Float) {
        setExposureBias(ev, fromCameraControl: false)
    }

    private func setExposureBias(_ ev: Float, fromCameraControl: Bool) {
        exposure.bias = CameraMath.clamp(ev, exposure.biasRange)
        guard demo == nil else { return }
        engine.setBias(exposure.bias)
        if !fromCameraControl { engine.updateControlBias(exposure.bias) }
    }

    func setWhiteBalance(kelvin: Float?) {
        exposure.manualKelvin = kelvin.map { CameraMath.clamp($0, Self.kelvinRange) }
        if demo != nil {
            if let value = exposure.manualKelvin { exposure.kelvin = value }
            return
        }
        engine.setWhiteBalance(kelvin: exposure.manualKelvin)
    }

    /// Manual f-number (snapped to the nearest available stop), or nil for automatic.
    /// No-op on fixed-aperture lenses.
    func setAperture(_ fNumber: Float?) {
        guard supportsVariableAperture || fNumber == nil else { return }
        exposure.manualAperture = fNumber.flatMap { Self.nearestStop(to: $0, in: exposure.apertureStops) }
        if demo != nil {
            exposure.aperture = exposure.manualAperture ?? exposure.apertureStops.first ?? exposure.aperture
            return
        }
        engine.setAperture(exposure.manualAperture)
    }

    private static func nearestStop(to value: Float, in stops: [Float]) -> Float? {
        stops.min { abs($0 - value) < abs($1 - value) }
    }

    private func revertToAuto() {
        Log.camera.info("controller: pro off, reverting to auto")
        exposure.manualAperture = nil
        exposure.manualISO = nil
        exposure.manualShutter = nil
        exposure.manualKelvin = nil
        exposure.bias = 0
        focus.manualLensPosition = nil
        focus.isTracking = false
        focus.trackedRect = nil
        focus.point = nil
        if demo != nil {
            exposure.iso = SimulatorCamera.exposure.iso
            exposure.shutter = SimulatorCamera.exposure.shutter
            exposure.kelvin = SimulatorCamera.exposure.kelvin
            exposure.aperture = SimulatorCamera.exposure.aperture
            return
        }
        engine.applyFullAuto()
    }

    // MARK: - Capture

    /// Captures one frame. Always RAW when the lens supports it (the output
    /// format only matters to the caller); processed HEVC otherwise (front).
    /// Calls are serialized in order, so rapid presses never lose a frame.
    func capture(output: OutputFormat) async throws -> CapturedFrame {
        let previous = captureTail
        let task = Task { () async throws -> CapturedFrame in
            await previous?.value
            return try await self.performCapture(output: output)
        }
        captureTail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }

    private func performCapture(output: OutputFormat) async throws -> CapturedFrame {
        guard let lens = currentLens else {
            Log.capture.error("controller: capture with no current lens (status=\(String(describing: self.status), privacy: .public))")
            throw UnprocError.cameraUnavailable
        }
        Log.capture.info("controller: capture lens=\(lens.id, privacy: .public) output=\(String(describing: output), privacy: .public)")
        if let demo {
            return try await demo.capture(lens: lens, exposureDuration: exposure.shutter, iso: exposure.iso,
                                          withRAW: output == .raw)
        }
        let seconds = await engine.prepareCaptureExposure()
        Log.capture.debug("controller: shutter open duration=\(String(describing: seconds), privacy: .public)")
        openShutterDuration = seconds
        defer {
            engine.restorePreviewExposure()
            openShutterDuration = nil
        }
        return try await engine.capturePhoto(fallbackLens: lens)
    }

    // MARK: - Camera Control

    /// Camera Control (iPhone 16+): installs an exposure-bias slider and a Look picker.
    /// Re-installed automatically when the lens changes (the slider is device-bound).
    /// Camera Control (iPhone 16+): Zoom and Exposure drive the camera
    /// directly; Look and Ratio report back through the callbacks.
    func installCaptureControls(lookCodes: [String], selectedIndex: Int,
                                onSelect: @escaping @Sendable (Int) -> Void,
                                ratioTitles: [String] = [], ratioIndex: Int = 0,
                                onRatio: @escaping @Sendable (Int) -> Void = { _ in }) {
        guard demo == nil else { return }
        Log.controls.info("controller: install capture controls looks=\(lookCodes.count, privacy: .public) sel=\(selectedIndex, privacy: .public) ratios=\(ratioTitles.count, privacy: .public) ratioSel=\(ratioIndex, privacy: .public)")
        let config = CaptureControlsConfig(
            // Back stops only: the controls are installed once, not per camera.
            zoomStops: backZoomStops.map { Float($0) },
            zoom: Float(currentLens.map { $0.isFront ? 1 : $0.zoom } ?? 1),
            onZoom: { [weak self] value in
                Log.controls.debug("controls: zoom action \(value, privacy: .public)")
                Task { @MainActor in self?.setZoom(CGFloat(value), fromCameraControl: true) }
            },
            biasRange: exposure.biasRange,
            bias: exposure.bias,
            onBias: { [weak self] value in
                Log.controls.debug("controls: bias action \(value, privacy: .public)")
                Task { @MainActor in self?.setExposureBias(value, fromCameraControl: true) }
            },
            lookCodes: lookCodes,
            selectedIndex: selectedIndex,
            onSelect: onSelect,
            ratioTitles: ratioTitles,
            ratioIndex: ratioIndex,
            onRatio: onRatio
        )
        engine.installCaptureControls(config)
    }

    /// Keeps the Camera Control Ratio picker in step with the on-screen setting.
    func setCaptureControlsRatio(_ index: Int) {
        guard demo == nil else { return }
        engine.updateControlRatio(index)
    }

    /// Moves the Camera Control Look picker's selection without rebuilding the controls.
    func setCaptureControlsSelection(_ index: Int) {
        guard demo == nil else { return }
        engine.updateLookSelection(index)
    }

    // MARK: - Engine events

    private func handle(_ event: CameraEngineEvent) {
        guard demo == nil else { return }
        switch event {
        case let .running(isRunning):
            Log.camera.info("controller: event running=\(isRunning, privacy: .public) status=\(String(describing: self.status), privacy: .public)")
            guard hasStarted, status != .unauthorized else { return }
            if case .failed = status, !isRunning { return }
            status = isRunning ? .running : .idle
        case let .failed(message):
            Log.camera.error("controller: event failed \(message, privacy: .public)")
            status = .failed(message)
        case let .live(values):
            applyLive(values)
        case .subjectAreaChanged:
            if !proEnabled, !focus.isTracking, focus.manualLensPosition == nil, focus.point != nil {
                resetFocus()
            }
        case let .trackingUpdated(rect):
            guard focus.isTracking else { return }
            focus.trackedRect = rect
            focus.point = CGPoint(x: rect.midX, y: rect.midY)
        case .trackingLost:
            Log.camera.info("controller: tracking lost (tracking=\(self.focus.isTracking, privacy: .public))")
            guard focus.isTracking else { return }
            focus.isTracking = false
            focus.trackedRect = nil
        }
    }

    private func applyLive(_ values: CameraLiveValues) {
        var updated = exposure
        updated.iso = values.iso
        updated.shutter = values.shutter
        updated.bias = values.bias
        updated.kelvin = values.kelvin
        updated.aperture = values.aperture
        if updated != exposure { exposure = updated }
        if focus.lensPosition != values.lensPosition { focus.lensPosition = values.lensPosition }
    }

    private func apply(_ ranges: CameraDeviceRanges) {
        var updated = exposure
        updated.isoRange = ranges.isoRange
        updated.shutterRange = ranges.shutterRange
        updated.biasRange = ranges.biasRange
        updated.apertureStops = ranges.apertureStops
        supportsSelfieOrientation = ranges.isSquareFront
        updated.manualAperture = updated.manualAperture.flatMap { Self.nearestStop(to: $0, in: ranges.apertureStops) }
        updated.manualISO = updated.manualISO.map { CameraMath.clamp($0, ranges.isoRange) }
        updated.manualShutter = updated.manualShutter.map { CameraMath.clamp($0, ranges.shutterRange) }
        updated.bias = CameraMath.clamp(updated.bias, ranges.biasRange)
        exposure = updated
    }

    private func makeIntent() -> CameraIntent {
        CameraIntent(iso: exposure.manualISO,
                     shutter: exposure.manualShutter,
                     kelvin: exposure.manualKelvin,
                     lensPosition: focus.manualLensPosition,
                     bias: exposure.bias,
                     aperture: exposure.manualAperture,
                     point: focus.point)
    }

    private func stopTrackingState() {
        guard focus.isTracking || focus.trackedRect != nil else { return }
        focus.isTracking = false
        focus.trackedRect = nil
        if demo == nil { engine.stopTracking() }
    }
}
