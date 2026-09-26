import AVFoundation
import CoreImage
import Foundation
import Observation

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
            status = .unauthorized
            return
        }
        if lenses.isEmpty {
            lenses = await engine.discoverLenses()
        }
        guard let lens = resolveLens(preferredLensID) else {
            status = .failed("No camera available")
            return
        }
        switch await engine.start(lens: lens, flavor: flavor, intent: makeIntent()) {
        case let .started(active, ranges, isRunning):
            currentLens = active
            apply(ranges)
            hasStarted = true
            status = isRunning ? .running : .idle
        case let .failed(message):
            status = .failed(message)
        }
    }

    private static func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
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

    /// Switching between lenses of the same physical camera (e.g. 1× ↔ 2× crop)
    /// only changes the zoom; other switches reconfigure the session.
    func select(_ lens: Lens) async {
        guard let target = lenses.first(where: { $0.id == lens.id }) ?? (lenses.isEmpty ? lens : nil) else { return }
        stopTrackingState()
        focus.point = nil
        if let demo {
            currentLens = target
            demo.setLens(target)
            return
        }
        switch await engine.select(target, intent: makeIntent()) {
        case .notConfigured:
            currentLens = target
        case let .switched(active, ranges):
            currentLens = active
            apply(ranges)
        case .failed:
            break
        }
    }

    func setRawFlavor(_ flavor: RawFlavor) async {
        rawFlavor = flavor
        guard demo == nil else { return }
        await engine.setRawFlavor(flavor)
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
        exposure.bias = CameraMath.clamp(ev, exposure.biasRange)
        guard demo == nil else { return }
        engine.setBias(exposure.bias)
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
        _ = output
        let previous = captureTail
        let task = Task { () async throws -> CapturedFrame in
            await previous?.value
            return try await self.performCapture()
        }
        captureTail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }

    private func performCapture() async throws -> CapturedFrame {
        guard let lens = currentLens else { throw UnprocError.cameraUnavailable }
        if let demo {
            return try await demo.capture(lens: lens, exposureDuration: exposure.shutter, iso: exposure.iso)
        }
        let seconds = await engine.prepareCaptureExposure()
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
    func installCaptureControls(lookCodes: [String], selectedIndex: Int, onSelect: @escaping @Sendable (Int) -> Void) {
        guard demo == nil else { return }
        engine.installCaptureControls(CaptureControlsConfig(lookCodes: lookCodes,
                                                            selectedIndex: selectedIndex,
                                                            onSelect: onSelect))
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
            guard hasStarted, status != .unauthorized else { return }
            if case .failed = status, !isRunning { return }
            status = isRunning ? .running : .idle
        case let .failed(message):
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
