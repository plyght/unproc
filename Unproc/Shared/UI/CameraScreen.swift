import SwiftUI
import AVKit
import os

/// The whole camera: viewfinder, status badge, settings menu, PRO controls,
/// bottom bar (thumbnail · shutter · lens) and the photo viewer on top.
/// Shared between the app and the lock-screen capture extension.
struct CameraScreen: View {
    let camera: CameraController
    let store: any PhotoStore
    let sink: any CaptureSink
    let hooks: HostHooks

    @State private var shutter: ShutterCoordinator
    @State private var video: VideoCoordinator
    /// Self-timer: seconds left while counting down, else nil.
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var countdownTick = 0
    @State private var timerFireTick = 0
    @State private var showViewer = false
    @State private var showSettings = false
    @State private var showLensPicker = false
    @State private var zoomScrub = ZoomScrubModel()
    @State private var zoomDialVisible = false
    @State private var zoomHideTask: Task<Void, Never>?
    /// Zoom when the current pinch began.
    @State private var pinchBase: CGFloat?
    @State private var proExpanded: ProControls.ProParameter?
    @State private var lookToast: Look?
    @State private var lookToastTick = 0
    @State private var flashOpacity: Double = 0
    @State private var longExposureStart: Date?
    @State private var isActivating = false
    @Namespace private var heroNamespace

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: SettingsStore { SettingsStore.shared }

    init(camera: CameraController, store: any PhotoStore, sink: any CaptureSink, hooks: HostHooks) {
        self.camera = camera
        self.store = store
        self.sink = sink
        self.hooks = hooks
        _shutter = State(initialValue: ShutterCoordinator(camera: camera, sink: sink, store: store))
        _video = State(initialValue: VideoCoordinator(camera: camera, sink: sink, store: store))
    }

    // MARK: - Mode

    /// Video mode (never in the lock-screen extension: photos only there).
    private var isVideo: Bool { !hooks.isLockedCapture && settings.value.mode == .video }

    /// HLG video: Looks are not applied (their LUTs are built for SDR).
    private var isHDRVideo: Bool { isVideo && (camera.videoFormat?.hdr ?? false) }

    /// Frame shape on screen: 9:16 in video mode, else the photo ratio.
    private var effectiveRatio: FrameRatio { isVideo ? .sixteenNine : settings.value.ratio }

    /// What the camera should be configured for, from the settings.
    static func videoRequest(_ value: CaptureSettings, locked: Bool) -> VideoModeRequest? {
        guard !locked, value.mode == .video else { return nil }
        return VideoModeRequest(resolution: value.videoResolution, fps: value.videoFPS,
                                hdr: value.videoHDR, audio: true)
    }

    // MARK: - Layout

    /// Layout for one screen size and frame ratio.
    ///
    /// Everything is placed relative to a fixed 3:4 "reference" frame so the
    /// controls never move when the ratio changes. Shorter ratios (1:1) sit
    /// centred inside it; taller ones (3:2, 16:9) grow downward, and when they
    /// reach the bottom bar the bar simply floats over the image.
    private struct Metrics {
        let vfTop: CGFloat
        let vfWidth: CGFloat
        let vfHeight: CGFloat
        let barTop: CGFloat
        let barHeight: CGFloat
        let shutterWidth: CGFloat
        let shutterHeight: CGFloat
        /// Side items (thumbnail, lens) are inset so their centres mirror each other.
        let barInset: CGFloat
        /// How far the bottom bar reaches into the viewfinder (0 when it doesn't).
        let barOverlap: CGFloat
        /// Global y of the screen's bottom edge (how far a drag can go down).
        var screenBottom: CGFloat = .infinity
        /// Top of the shutter pill, for placing popovers above it.
        var shutterTop: CGFloat { barTop + (barHeight - shutterHeight) / 2 }

        static let gutter: CGFloat = 10
        static let sideItem: CGFloat = 52

        init(size: CGSize, ratio: FrameRatio, landscape: Bool = false, screenBottom: CGFloat = .infinity) {
            self.screenBottom = screenBottom
            let gutter = Self.gutter
            let minBar: CGFloat = 104
            let refTop: CGFloat = 4

            // The 3:4 reference frame and the bar below it.
            let byWidth = max(size.width - gutter * 2, 0)
            let byHeight = max(size.height - refTop - minBar, 0) * Theme.frameAspect
            let refWidth = min(byWidth, byHeight)
            let refHeight = refWidth / Theme.frameAspect
            let remaining = max(size.height - refTop - refHeight, 0)
            barHeight = min(max(remaining * 0.6, 84), 120)
            barTop = refTop + refHeight + max((remaining - barHeight) / 2, 0)
            let compact = size.width < 380 || remaining < 150
            // Every bottom-bar control shares one 52pt height: thumbnail tile,
            // mode tile, shutter / record pill and the lens circle.
            shutterWidth = compact ? 112 : 124
            shutterHeight = Metrics.sideItem
            barInset = gutter + 16

            // The actual viewfinder for this ratio.
            // Landscape selfie on the square front camera: a wide frame.
            let aspect = CGFloat(landscape ? ratio.longOverShort : ratio.portraitAspect)
            var width = refWidth
            var height = width / aspect
            if height <= refHeight {
                vfTop = refTop + (refHeight - height) / 2
            } else {
                let maxHeight = max(size.height - refTop - 4, 0)
                if height > maxHeight {
                    height = maxHeight
                    width = height * aspect
                }
                vfTop = refTop
            }
            vfWidth = width
            vfHeight = height
            barOverlap = max(vfTop + vfHeight - barTop, 0)
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size, ratio: effectiveRatio, landscape: camera.isLandscapeSelfie && !isVideo,
                            screenBottom: geo.frame(in: .global).maxY + geo.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                viewfinder(m)
                    .frame(width: m.vfWidth, height: m.vfHeight)
                    .padding(.top, m.vfTop)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                bottomBar(m)
                    .frame(height: m.barHeight)
                    .padding(.top, m.barTop)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)

                // Tap-outside catcher for the settings menu / lens picker.
                if showSettings || showLensPicker {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { closeFloating() }
                        .ignoresSafeArea()
                        .accessibilityElement()
                        .accessibilityLabel("Close")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("menu.dismiss")
                }

                if showSettings {
                    SettingsMenu(settings: settings,
                                 isVideo: isVideo,
                                 offeredRates: camera.offeredFrameRates,
                                 activeVideoLabel: camera.videoFormat?.label,
                                 onClose: { closeFloating() })
                        .frame(width: m.vfWidth)
                        .padding(.top, m.vfTop)
                        .transition(Theme.popover(anchor: .topTrailing, offsetY: -8, reduceMotion: reduceMotion))
                        .zIndex(2)
                }

            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The accent is read at draw time; rebuild the tree when it changes.
            .id(settings.value.accent)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay {
            if longExposureStart != nil, let duration = camera.openShutterDuration {
                LongExposureOverlay(duration: duration, start: longExposureStart ?? Date())
                    .transition(.opacity)
            }
        }
        .overlay {
            if showViewer {
                PhotoViewer(store: store, namespace: heroNamespace) {
                    Log.ui.info("ui: viewer close")
                    withAnimation(Theme.snappy) { showViewer = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(Theme.snappy, value: showSettings)
        .animation(Theme.snappy, value: showLensPicker)
        .animation(Theme.snappy, value: zoomDialVisible)
        .modifier(CameraHaptics(
            zoomScrub: zoomScrub,
            lookID: settings.value.lookID,
            showSettings: showSettings,
            awaitingSecondExposure: shutter.awaitingSecondExposure,
            shutterClosed: camera.openShutterDuration == nil,
            focusPoint: camera.focus.point,
            isTracking: camera.focus.isTracking
        ))
        .animation(Theme.snappy, value: settings.value.proMode)
        .animation(Theme.snappy, value: settings.value.ratio)
        .animation(Theme.fade, value: longExposureStart)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        // Haptics (the shutter's own press haptic lives in its button style).
        .sensoryFeedback(.selection, trigger: camera.currentLens?.id)
        .sensoryFeedback(.error, trigger: shutter.lastError) { _, new in new != nil }
        // Hardware shutter: Camera Control, volume buttons, AirPods.
        .onCameraCaptureEvent { event in
            Log.ui.debug("ui: hardware capture event phase=\(String(describing: event.phase), privacy: .public)")
            if event.phase == .ended {
                hardwareShutter()
            }
        }
        // Lifecycle.
        .task {
            LaunchArguments.applyResetIfNeeded()
            await activate()
        }
        .onChange(of: scenePhase) { old, phase in
            Log.ui.notice("ui: scenePhase \(String(describing: old), privacy: .public) -> \(String(describing: phase), privacy: .public)")
            switch phase {
            case .active: Task { await activate() }
            case .background: deactivate()
            default: break
            }
        }
        // Settings → camera.
        .modifier(Observers(camera: camera, settings: settings, shutter: shutter))
        .modifier(ModeObservers(
            camera: camera,
            settings: settings,
            shutter: shutter,
            isLocked: hooks.isLockedCapture,
            recordStart: video.startTick,
            recordStop: video.stopTick,
            countdownTick: countdownTick,
            timerFire: timerFireTick,
            videoError: video.lastError
        ))
        .onChange(of: settings.value.proMode) { _, pro in
            Log.ui.info("settings: pro=\(pro, privacy: .public)")
            camera.proEnabled = pro
            if !pro { proExpanded = nil }
        }
        .onChange(of: settings.value.lookID) { _, id in
            showLookToast(LookLibrary.look(id: id))
        }
        .onChange(of: shutter.flash) { _, _ in blink() }
        .onChange(of: camera.openShutterDuration) { _, duration in
            longExposureStart = duration == nil ? nil : Date()
        }
    }

    /// Settings → camera sync (no view state touched). Split out of `body`
    /// so it type-checks on its own.
    private struct Observers: ViewModifier {
        let camera: CameraController
        let settings: SettingsStore
        let shutter: ShutterCoordinator

        func body(content: Content) -> some View {
            content
                .onChange(of: camera.currentLens?.id) { _, id in
                    if let id, settings.value.lensID != id { settings.value.lensID = id }
                }
                .onChange(of: settings.value.rawFlavor) { _, flavor in
                    Log.ui.info("settings: rawFlavor=\(flavor.rawValue, privacy: .public)")
                    Task { await camera.setRawFlavor(flavor) }
                }
                .onChange(of: settings.value.output) { old, new in
                    Log.ui.info("settings: output \(old.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public)")
                }
                .onChange(of: settings.value.accent) { old, new in
                    Log.ui.info("settings: accent \(old, privacy: .public) -> \(new, privacy: .public)")
                    DeviceAccent.refresh()
                }
                .onChange(of: settings.value.doubleExposure) { _, on in
                    Log.ui.info("settings: doubleExposure=\(on, privacy: .public)")
                    if !on { shutter.cancelDoubleExposure() }
                }
                .onChange(of: settings.value.lookID) { old, id in
                    Log.ui.info("settings: look \(old, privacy: .public) -> \(id, privacy: .public)")
                    if let index = LookLibrary.all.firstIndex(where: { $0.id == id }) {
                        camera.setCaptureControlsSelection(index)
                    } else {
                        Log.ui.error("settings: look id \(id, privacy: .public) not in library")
                    }
                }
                .onChange(of: settings.value.flash) { _, flash in
                    camera.flash = flash
                }
                .onChange(of: settings.value.ratio) { old, ratio in
                    Log.ui.info("settings: ratio \(old.rawValue, privacy: .public) -> \(ratio.rawValue, privacy: .public)")
                    camera.setCaptureControlsRatio(FrameRatio.allCases.firstIndex(of: ratio) ?? 0)
                }
        }
    }

    /// Mode / video settings → camera, plus recording and self-timer haptics.
    private struct ModeObservers: ViewModifier {
        let camera: CameraController
        let settings: SettingsStore
        let shutter: ShutterCoordinator
        let isLocked: Bool
        let recordStart: Int
        let recordStop: Int
        let countdownTick: Int
        let timerFire: Int
        let videoError: String?

        func body(content: Content) -> some View {
            content
                .modifier(VideoTimerHaptics(recordStart: recordStart, recordStop: recordStop,
                                            countdownTick: countdownTick, timerFire: timerFire))
                .sensoryFeedback(.error, trigger: videoError) { (_: String?, new: String?) -> Bool in new != nil }
                .animation(Theme.snappy, value: settings.value.mode)
                .onChange(of: settings.value.mode) { (old: CaptureMode, new: CaptureMode) in
                    Log.ui.info("settings: mode \(old.rawValue, privacy: .public) -> \(new.rawValue, privacy: .public)")
                    if new == .video, shutter.awaitingSecondExposure { shutter.cancelDoubleExposure() }
                    // Video is always 9:16 portrait frames (no landscape selfie crop).
                    if new == .video, camera.selfieLandscape { camera.selfieLandscape = false }
                    apply()
                }
                .onChange(of: settings.value.videoResolution) { (_: VideoResolution, new: VideoResolution) in
                    Log.ui.info("settings: video resolution \(new.label, privacy: .public)")
                    apply()
                }
                .onChange(of: settings.value.videoFPS) { (_: VideoFrameRate, new: VideoFrameRate) in
                    Log.ui.info("settings: video fps \(new.rawValue, privacy: .public)")
                    apply()
                }
                .onChange(of: settings.value.videoHDR) { (_: Bool, new: Bool) in
                    Log.ui.info("settings: video hdr \(new, privacy: .public)")
                    apply()
                }
                .onChange(of: settings.value.timer) { (old: SelfTimer, new: SelfTimer) in
                    Log.ui.info("settings: timer \(old.seconds, privacy: .public)s -> \(new.seconds, privacy: .public)s")
                }
        }

        private func apply() {
            let request = CameraScreen.videoRequest(settings.value, locked: isLocked)
            Task { await camera.setVideoMode(request) }
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private func viewfinder(_ m: Metrics) -> some View {
        let value = settings.value
        let pro = value.proMode
        ZStack {
            ViewfinderView(
                bus: camera.frames,
                look: isHDRVideo ? .zero : LookLibrary.look(id: value.lookID),
                zebras: value.zebras,
                peaking: value.peaking,
                onTap: { point in
                    guard SettingsStore.shared.value.proMode else { return }
                    camera.focus(at: point)
                },
                onDoubleTap: { _ in
                    guard SettingsStore.shared.value.proMode else { return }
                    camera.resetFocus()
                },
                onLongPress: { point in
                    guard SettingsStore.shared.value.proMode else { return }
                    camera.track(at: point)
                },
                onSwipe: { direction in
                    guard !camera.isRecording else { return }
                    stepLook(direction)
                },
                onPinch: { handlePinch($0) }
            )

            if pro {
                // FocusOverlay works in the 3:4 sensor frame; aspect-fill that
                // frame into the viewfinder so points line up at any ratio.
                // Sized explicitly inside a GeometryReader so it can never grow
                // the viewfinder (an `.aspectRatio(.fill)` view here did, which
                // pushed the badge and PRO chips off screen at non-4:3 ratios).
                GeometryReader { proxy in
                    let size = proxy.size
                    let scale = max(size.width / Theme.frameAspect, size.height)
                    let fill = CGSize(width: scale * Theme.frameAspect, height: scale)
                    FocusOverlay(
                        point: camera.focus.point,
                        isTracking: camera.focus.isTracking,
                        trackedRect: camera.focus.trackedRect
                    )
                    .frame(width: fill.width, height: fill.height)
                    .position(x: size.width / 2, y: size.height / 2)
                }
                .allowsHitTesting(false)
            }

            if effectiveRatio == .sixteenNine {
                // Tall frame: a gentle darkening at the top and bottom edges so the
                // floating controls stay legible (no blur).
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0), location: 0.12),
                    .init(color: .black.opacity(0), location: 0.78),
                    .init(color: .black.opacity(0.5), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            }

            Color.black
                .opacity(flashOpacity)
                .allowsHitTesting(false)

            statusMessage

            if let look = lookToast {
                VStack(spacing: 4) {
                    Text(look.code)
                        .monoLabel(22, weight: .semibold, color: Theme.accent)
                        .contentTransition(.opacity)
                    Text(look.name)
                        .monoLabel(10, color: Theme.primary.opacity(0.8))
                        .contentTransition(.opacity)
                    if isHDRVideo {
                        Text("LOOKS OFF IN HDR")
                            .monoLabel(8, color: Theme.secondary)
                    }
                }
                .animation(Theme.fade, value: look.id)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: .rect(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
                .transition(Theme.blurFade)
            }

            if let countdown {
                CountdownNumber(value: countdown)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.viewfinderCorner, style: .continuous))
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.viewfinderCorner, style: .continuous))
        .overlay(alignment: .top) {
            topOverlay(value)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let error = shutter.lastError ?? video.lastError {
                    Text(error)
                        .monoLabel(9, weight: .semibold, color: Theme.accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .transition(Theme.blurFade)
                }
                if pro && camera.status == .running {
                    ProControls(camera: camera, expanded: $proExpanded)
                        .transition(Theme.transition(
                            .offset(x: 0, y: 12).combined(with: .opacity),
                            reduceMotion: reduceMotion
                        ))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14 + m.barOverlap)
            .animation(Theme.snappy, value: shutter.lastError)
            .animation(Theme.snappy, value: video.lastError)
        }
        .animation(Theme.fade, value: lookToast == nil)
        .task(id: lookToastTick) {
            // Re-keyed on every change, so rapid swipes restart the timer cleanly.
            guard lookToastTick > 0 else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.exit) { lookToast = nil }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch camera.status {
        case .unauthorized:
            VStack(spacing: 10) {
                Text("CAMERA ACCESS NEEDED")
                    .monoLabel(12, weight: .semibold, color: Theme.primary)
                Text("ALLOW CAMERA ACCESS FOR UNPROC\nIN SETTINGS › PRIVACY › CAMERA")
                    .monoLabel(9, color: Theme.secondary)
                    .multilineTextAlignment(.center)
                if !hooks.isLockedCapture, let url = URL(string: "app-settings:") {
                    Button {
                        openURL(url)
                    } label: {
                        Text("OPEN SETTINGS")
                            .monoLabel(10, weight: .semibold, color: .black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 4)
                }
            }
            .padding(24)
        case .failed(let message):
            VStack(spacing: 8) {
                Text("CAMERA UNAVAILABLE")
                    .monoLabel(12, weight: .semibold, color: Theme.primary)
                Text(message)
                    .monoLabel(9, color: Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        case .idle, .running:
            EmptyView()
        }
    }

    // MARK: - Bottom bar

    // MARK: - Top overlay

    /// Flash / selfie + timer (top-left), the recording timecode (centre) and
    /// the status badge (top-right). While recording only the timecode stays.
    private func topOverlay(_ value: CaptureSettings) -> some View {
        let recording = camera.isRecording
        return ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    if camera.hasFlash {
                        // Stays live while recording: the torch can be toggled mid-take.
                        flashButton
                    }
                    if camera.supportsSelfieOrientation && camera.currentLens?.isFront == true && !isVideo {
                        selfieOrientationButton
                            .opacity(recording ? 0 : 1)
                            .allowsHitTesting(!recording)
                    }
                    timerButton
                        .opacity(recording ? 0 : 1)
                        .allowsHitTesting(!recording)
                }
                .padding(8)   // buttons carry 4pt of invisible tap margin: glass stays 12pt from the edge
                .animation(Theme.snappy, value: camera.currentLens?.id)

                Spacer(minLength: 0)

                StatusBadge(settings: value,
                            videoLabel: isVideo ? (camera.videoFormat?.label ?? VideoSpec.badge(resolution: value.videoResolution, fps: value.videoFPS.rawValue)) : nil,
                            videoHDR: isHDRVideo) {
                    showLensPicker = false
                    proExpanded = nil
                    showSettings = true
                }
                .padding(12)
                .opacity(recording ? 0 : 1)
                .allowsHitTesting(!recording)
            }
            if let start = camera.recordingStartedAt {
                RecordingTimecode(start: start)
                    .padding(.top, 14)
                    .transition(Theme.blurFade)
            }
        }
        .animation(Theme.snappy, value: recording)
    }

    // MARK: - Top-left buttons

    /// Self-timer: off → 3 s → 10 s.
    private var timerButton: some View {
        let timer = settings.value.timer
        return Button {
            let next = timer.next
            Log.ui.info("ui: timer \(timer.seconds, privacy: .public)s -> \(next.seconds, privacy: .public)s")
            settings.value.timer = next
        } label: {
            Group {
                if timer == .off {
                    Image(systemName: "timer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(timer.seconds)S")
                            .font(Theme.mono(8, weight: .bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 38, height: 38)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(4)   // 46pt tap target, like the flash button
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(Theme.snappy, value: timer)
        .accessibilityLabel(timer == .off ? "Timer off" : "Timer \(timer.seconds) seconds")
        .accessibilityIdentifier("timerButton")
    }

    private var flashButton: some View {
        let flash = settings.value.flash
        let symbol: String
        switch flash {
        case .off: symbol = "bolt.slash.fill"
        case .auto: symbol = "bolt.badge.automatic.fill"
        case .on: symbol = "bolt.fill"
        }
        return Button {
            let all = FlashSetting.allCases
            let next = all[((all.firstIndex(of: flash) ?? 0) + 1) % all.count]
            Log.ui.info("ui: flash \(flash.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public)")
            settings.value.flash = next
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(flash == .off ? Theme.primary : Theme.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(4)   // 46pt tap target; the overlay padding below compensates
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Flash \(flash.rawValue)")
        .accessibilityIdentifier("flashButton")
    }

    private var selfieOrientationButton: some View {
        let landscape = camera.selfieLandscape
        return Button {
            withAnimation(Theme.snappy) { camera.selfieLandscape.toggle() }
            Log.ui.info("ui: selfie orientation -> \(camera.selfieLandscape ? "landscape" : "portrait", privacy: .public)")
        } label: {
            Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(landscape ? Theme.accent : Theme.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(4)   // 46pt tap target; the overlay padding below compensates
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(landscape ? "Portrait selfie" : "Landscape selfie")
        .accessibilityIdentifier("selfieOrientationButton")
    }

    // MARK: - Pinch to zoom

    private func handlePinch(_ pinch: ViewfinderView.Pinch) {
        // Every camera with more than one stop pinches: the back lenses, and
        // the selfie camera's two framings on the square Center Stage sensor.
        guard let lens = camera.activeLens, camera.zoomStops.count > 1 else { return }
        switch pinch {
        case .began:
            closeFloating()
            zoomHideTask?.cancel()
            pinchBase = lens.zoom
            zoomScrub.present(stops: camera.zoomStops, zoom: lens.zoom, isFront: lens.isFront)
            if !zoomDialVisible {
                withAnimation(Theme.snappy) { zoomDialVisible = true }
            }
            Log.ui.info("ui: pinch begin at \(Double(lens.zoom), privacy: .public)x")
        case .changed(let scale):
            guard let base = pinchBase else { return }
            let zoom = zoomScrub.pinch(to: base * scale)
            camera.setZoom(zoom)
        case .ended:
            pinchBase = nil
            // Same resting rule as the ruler: near a stop lands exactly on it.
            let settled = ZoomScrubModel.settle(zoomScrub.zoom, stops: camera.zoomStops)
            if abs(settled - zoomScrub.zoom) > 0.0001 {
                zoomScrub.present(stops: camera.zoomStops, zoom: settled, isFront: lens.isFront)
                camera.setZoom(settled)
            }
            Log.ui.info("ui: pinch end at \(Double(zoomScrub.zoom), privacy: .public)x (settled \(Double(settled), privacy: .public)x)")
            scheduleRulerHide(after: .milliseconds(1200))
        }
    }

    private func bottomBar(_ m: Metrics) -> some View {
        // Lefty: lens/zoom on the left, thumbnail on the right. The PHOTO /
        // VIDEO switch always sits between the thumbnail and the shutter.
        let lefty = settings.value.lefty
        return HStack(spacing: 0) {
            Group {
                if lefty {
                    lensButton(m)
                        .frame(width: Metrics.sideItem, height: Metrics.sideItem)
                } else {
                    HStack(spacing: 0) {
                        thumbnailSlot
                        modeSwitchSlot(m)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            shutterControl(m)

            Group {
                if lefty {
                    HStack(spacing: 0) {
                        modeSwitchSlot(m)
                        thumbnailSlot
                    }
                } else {
                    lensButton(m)
                        .frame(width: Metrics.sideItem, height: Metrics.sideItem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, m.barInset)
        .animation(Theme.snappy, value: lefty)
    }

    private var thumbnailSlot: some View {
        thumbnailButton
            .frame(width: Metrics.sideItem, height: Metrics.sideItem)
            .opacity(camera.isRecording ? 0.35 : 1)
            .disabled(camera.isRecording)
    }

    /// The PHOTO / VIDEO switch, centred in the space between thumbnail and
    /// shutter (nothing in the lock-screen extension: photos only there).
    @ViewBuilder
    private func modeSwitchSlot(_ m: Metrics) -> some View {
        if hooks.isLockedCapture {
            Spacer(minLength: 0)
        } else {
            let recording = camera.isRecording
            ModeSwitch(mode: settings.value.mode) { (mode: CaptureMode) in
                Log.ui.info("ui: mode -> \(mode.rawValue, privacy: .public)")
                cancelCountdown()
                closeFloating()
                settings.value.mode = mode
            }
            .opacity(recording ? 0 : 1)
            .allowsHitTesting(!recording)
            .animation(Theme.snappy, value: recording)
            .frame(maxWidth: .infinity)
        }
    }

    /// Photo shutter, or the record button in video mode.
    @ViewBuilder
    private func shutterControl(_ m: Metrics) -> some View {
        if isVideo {
            RecordButton(
                isRecording: camera.isRecording,
                isEnabled: camera.status == .running && !camera.isSwitchingMode,
                width: m.shutterWidth,
                height: m.shutterHeight
            ) {
                shutterPressed()
            }
            .transition(.opacity)
        } else {
            ShutterButton(
                isEnabled: camera.status == .running,
                isBusy: shutter.isBusy,
                width: m.shutterWidth,
                height: m.shutterHeight
            ) {
                shutterPressed()
            }
            .overlay(alignment: .top) {
                if shutter.awaitingSecondExposure {
                    Button {
                        shutter.cancelDoubleExposure()
                    } label: {
                        Text("1/2")
                            .monoLabel(10, weight: .semibold, color: Theme.accent)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.pressable)
                    .offset(y: -22)
                    .transition(.opacity)
                    .accessibilityLabel("Cancel double exposure")
                }
            }
            .animation(Theme.snappy, value: shutter.awaitingSecondExposure)
            .transition(.opacity)
        }
    }

    private var thumbnailButton: some View {
        ThumbnailButton(store: store, namespace: heroNamespace) {
            Log.ui.info("ui: viewer open (\(store.items.count, privacy: .public) items)")
            closeFloating()
            withAnimation(Theme.snappy) { showViewer = true }
        }
    }

    private func lensButton(_ m: Metrics) -> some View {
            LensButton(
                // Where a flip is headed, so the button never shows the old camera.
                current: camera.activeLens,
                model: zoomScrub,
                isExpanded: zoomDialVisible,
                frontHasStops: camera.frontHasStops,
                // 16:9: the button floats over the image; keep the ruler above the
                // line where the image meets the black.
                rulerMaxBelow: m.barOverlap > 0
                    ? max(m.vfTop + m.vfHeight - (m.barTop + m.barHeight / 2), 0)
                    : .infinity,
                screenBottom: m.screenBottom,
                onTap: { whileExpanded in
                    if whileExpanded {
                        zoomHideTask?.cancel()
                        withAnimation(Theme.exit) { zoomDialVisible = false }
                    } else if camera.activeLens?.isFront == true, camera.frontHasStops {
                        // Selfie camera with two framings: a tap swaps them.
                        closeFloating()
                        Log.ui.info("ui: lens tap -> toggle selfie framing (from \(camera.activeLens?.id ?? "nil", privacy: .public))")
                        Task { await camera.toggleFrontFraming() }
                    } else {
                        closeFloating()
                        presentZoomRuler()
                    }
                },
                onScrubBegin: { roomBelow in
                    closeFloating()
                    beginZoomScrub(roomBelow: roomBelow)
                },
                onScrubChange: { dy in perform(zoomScrub.update(dy: dy)) },
                onScrubEnd: { endZoomScrub() }
            )
    }

    // MARK: - Actions

    private func hardwareShutter() {
        Log.ui.info("ui: hardware shutter (viewer open=\(showViewer, privacy: .public) video=\(isVideo, privacy: .public) recording=\(camera.isRecording, privacy: .public))")
        if showViewer {
            withAnimation(Theme.snappy) { showViewer = false }
        }
        shutterPressed()
    }

    /// On-screen shutter / record button and the hardware buttons.
    /// Recording stops at once; otherwise the self-timer (if set) counts down
    /// first, and a press during the countdown cancels it.
    private func shutterPressed() {
        closeFloating()
        if countdownTask != nil {
            Log.ui.info("ui: self-timer cancelled")
            cancelCountdown()
            return
        }
        if isVideo, camera.isRecording {
            video.stop()
            return
        }
        let timer = settings.value.timer
        if timer != .off {
            startCountdown(timer.seconds)
            return
        }
        fire()
    }

    private func fire() {
        if isVideo {
            video.start()
        } else {
            shutter.shoot()
        }
    }

    private func startCountdown(_ seconds: Int) {
        Log.ui.info("ui: self-timer \(seconds, privacy: .public)s (video=\(isVideo, privacy: .public))")
        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                withAnimation(reduceMotion ? Theme.fade : .spring(response: 0.3, dampingFraction: 0.8)) {
                    countdown = remaining
                }
                countdownTick += 1
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            withAnimation(Theme.exit) { countdown = nil }
            countdownTask = nil
            timerFireTick += 1
            Log.ui.info("ui: self-timer fired")
            fire()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if countdown != nil {
            withAnimation(Theme.exit) { countdown = nil }
        }
    }

    private func closeFloating() {
        if showSettings { showSettings = false }
        if showLensPicker { showLensPicker = false }
    }

    private func beginZoomScrub(roomBelow: CGFloat) {
        zoomHideTask?.cancel()
        // The camera in use or being switched to: right after a flip the
        // session may still be reconfiguring, and the ruler must already show
        // (and flip from) the new camera's stops.
        let lens = camera.activeLens
        let isFront = lens?.isFront == true
        // A flip needs the other camera, and can't happen mid-recording (the
        // ends are then plain rubber bands: no tension, no SELFIE/BACK hint).
        let otherExists = camera.lenses.contains { $0.isFront != isFront }
        let canFlip = otherExists && !camera.isRecording
        // Only the pull down (back → selfie) can run out of screen.
        let room: CGFloat = isFront ? .infinity : roomBelow
        zoomScrub.begin(stops: camera.zoomStops, zoom: lens?.zoom ?? 1, isFront: isFront,
                        canFlip: canFlip, flipRoom: room)
        Log.ui.info("ui: zoom scrub begin lens=\(lens?.id ?? "nil", privacy: .public) current=\(camera.currentLens?.id ?? "nil", privacy: .public) front=\(isFront, privacy: .public) stops=\(String(describing: camera.zoomStops), privacy: .public) canFlip=\(canFlip, privacy: .public) recording=\(camera.isRecording, privacy: .public) roomBelow=\(Double(roomBelow), privacy: .public) flipThreshold=\(Double(zoomScrub.flipThreshold), privacy: .public)")
        if !zoomDialVisible {
            withAnimation(Theme.snappy) { zoomDialVisible = true }
        }
    }

    /// Tap: show the ruler without zooming, and leave it out a little longer
    /// so it reads as "you can slide this".
    private func presentZoomRuler() {
        let lens = camera.activeLens
        zoomScrub.present(stops: camera.zoomStops, zoom: lens?.zoom ?? 1, isFront: lens?.isFront == true)
        withAnimation(Theme.snappy) { zoomDialVisible = true }
        scheduleRulerHide(after: .milliseconds(3000))
    }

    private func scheduleRulerHide(after delay: Duration) {
        zoomHideTask?.cancel()
        zoomHideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.exit) { zoomDialVisible = false }
        }
    }

    private func endZoomScrub() {
        let action = zoomScrub.end()
        Log.ui.info("ui: zoom scrub end action=\(String(describing: action), privacy: .public)")
        withAnimation(Theme.exit) { perform(action) }
        // Linger so the ruler can be grabbed again, then fold away.
        scheduleRulerHide(after: .milliseconds(1600))
    }

    /// A flip changes cameras: fold the ruler away at once so it never shows
    /// the old camera's zoom while the new one comes up.
    private func foldRulerForFlip() {
        zoomHideTask?.cancel()
        withAnimation(Theme.exit) { zoomDialVisible = false }
    }

    private func perform(_ action: ZoomScrubModel.Action?) {
        switch action {
        case .zoom(let zoom)?:
            camera.setZoom(zoom)
        case .flip?:
            if camera.isRecording {
                // Not offered while recording (canFlip), but recording may
                // have started mid-gesture.
                Log.ui.info("ui: zoom flip ignored while recording")
                foldRulerForFlip()
                return
            }
            performFlip(action)
        case nil:
            break
        }
    }

    private func performFlip(_ action: ZoomScrubModel.Action?) {
        switch action {
        case .flip(.front)?:
            Log.ui.info("ui: zoom flip to front (target \(camera.flipTarget(toFront: true)?.id ?? "nil", privacy: .public))")
            foldRulerForFlip()
            Task { await camera.flip(toFront: true) }
        case .flip(.back)?:
            Log.ui.info("ui: zoom flip to back (target \(camera.flipTarget(toFront: false)?.id ?? "nil", privacy: .public))")
            foldRulerForFlip()
            Task { await camera.flip(toFront: false) }
        default:
            break
        }
    }

    private func stepLook(_ direction: Int) {
        let all = LookLibrary.all
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == settings.value.lookID } ?? 0
        let next = (index + direction + all.count) % all.count
        settings.value.lookID = all[next].id
    }

    private func showLookToast(_ look: Look) {
        guard !showSettings else { return }
        lookToast = look
        lookToastTick += 1
    }

    /// ~90 ms dim-blink of the viewfinder when the shutter fires: drops
    /// almost instantly, recovers with ease-out. Re-triggering mid-blink just
    /// retargets from the current value.
    private func blink() {
        withAnimation(.easeOut(duration: 0.02)) {
            flashOpacity = 0.75
        } completion: {
            withAnimation(.easeOut(duration: 0.07)) {
                flashOpacity = 0
            }
        }
    }

    // MARK: - Lifecycle

    private func activate() async {
        guard !isActivating else {
            Log.ui.debug("ui: activate skipped, already activating")
            return
        }
        isActivating = true
        defer { isActivating = false }
        let clock = ContinuousClock()
        let began = clock.now
        let snapshot = String(describing: settings.value)
        Log.ui.notice("ui: activate status=\(String(describing: camera.status), privacy: .public) locked=\(hooks.isLockedCapture, privacy: .public) settings=\(snapshot, privacy: .public)")

        hooks.setIdleTimerDisabled(true)
        // Location for Photos metadata: the app asks once; the lock screen never prompts.
        LocationProvider.shared.start(prompt: !hooks.isLockedCapture && !Theme.isDemo)
        camera.proEnabled = settings.value.proMode
        camera.flash = settings.value.flash
        if camera.status != .running {
            await camera.start(preferredLensID: settings.value.lensID, rawFlavor: settings.value.rawFlavor)
        }
        await camera.setVideoMode(Self.videoRequest(settings.value, locked: hooks.isLockedCapture))
        camera.proEnabled = settings.value.proMode
        installCaptureControls()
        await store.reload()
        let ms = CameraLogText.ms(clock.now - began)
        Log.ui.notice("ui: activate done status=\(String(describing: camera.status), privacy: .public) lens=\(camera.currentLens?.id ?? "nil", privacy: .public) items=\(store.items.count, privacy: .public) in \(ms, privacy: .public)ms")
    }

    private func deactivate() {
        LocationProvider.shared.stop()
        Log.ui.notice("ui: deactivate recording=\(camera.isRecording, privacy: .public)")
        closeFloating()
        cancelCountdown()
        if camera.isRecording { video.stop() }
        camera.stop()
        hooks.setIdleTimerDisabled(false)
    }

    private func installCaptureControls() {
        let looks = LookLibrary.all
        let selected = looks.firstIndex { $0.id == settings.value.lookID } ?? 0
        camera.installCaptureControls(
            lookCodes: looks.map(\.code),
            selectedIndex: selected,
            onSelect: { index in
                Task { @MainActor in
                    let all = LookLibrary.all
                    guard all.indices.contains(index) else { return }
                    SettingsStore.shared.value.lookID = all[index].id
                }
            },
            ratioTitles: FrameRatio.allCases.map(\.rawValue),
            ratioIndex: FrameRatio.allCases.firstIndex(of: settings.value.ratio) ?? 0,
            onRatio: { index in
                Task { @MainActor in
                    let all = FrameRatio.allCases
                    guard all.indices.contains(index) else { return }
                    SettingsStore.shared.value.ratio = all[index]
                }
            }
        )
    }
}

// MARK: - Long exposure

/// Dims the whole screen while the shutter is open and counts down in accent.
private struct LongExposureOverlay: View {
    let duration: Double
    let start: Date

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
            TimelineView(.animation) { context in
                let elapsed = max(context.date.timeIntervalSince(start), 0)
                let remaining = max(duration - elapsed, 0)
                let progress = duration > 0 ? min(elapsed / duration, 1) : 1
                VStack(spacing: 14) {
                    Text(String(format: "%.1f\"", remaining))
                        .monoLabel(28, weight: .semibold, color: Theme.accent)
                        .monospacedDigit()
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Theme.accent)
                            .frame(width: 160 * progress)
                    }
                    .frame(width: 160, height: 3)
                    Text("HOLD STILL")
                        .monoLabel(9, color: Theme.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // swallow touches while exposing
    }
}

// MARK: - Haptics

/// Every camera-screen haptic in one place (also keeps `CameraScreen.body`
/// small enough for the type checker). Kept very light; only camera flips
/// and errors are firm.
private struct CameraHaptics: ViewModifier {
    let zoomScrub: ZoomScrubModel
    let lookID: String
    let showSettings: Bool
    let awaitingSecondExposure: Bool
    let shutterClosed: Bool
    let focusPoint: CGPoint?
    let isTracking: Bool

    func body(content: Content) -> some View {
        content
            .modifier(ZoomHaptics(zoomScrub: zoomScrub))
            .modifier(ShootingHaptics(
                lookID: lookID,
                showSettings: showSettings,
                awaitingSecondExposure: awaitingSecondExposure,
                shutterClosed: shutterClosed,
                focusPoint: focusPoint,
                isTracking: isTracking
            ))
    }
}

private struct ZoomHaptics: ViewModifier {
    let zoomScrub: ZoomScrubModel

    private static let fine: SensoryFeedback = .impact(flexibility: .soft, intensity: 0.22)
    private static let flip: SensoryFeedback = .impact(weight: .heavy, intensity: 1)

    private static func tension(_ old: Int, _ new: Int) -> SensoryFeedback? {
        guard new > old else { return nil }
        let intensity: Double = 0.25 + 0.15 * Double(new)
        return .impact(flexibility: .soft, intensity: intensity)
    }

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.selection, trigger: zoomScrub.detentTick)
            .sensoryFeedback(Self.fine, trigger: zoomScrub.fineTick)
            .sensoryFeedback(trigger: zoomScrub.tension, Self.tension)
            .sensoryFeedback(Self.flip, trigger: zoomScrub.flipTick)
    }
}

private struct ShootingHaptics: ViewModifier {
    let lookID: String
    let showSettings: Bool
    let awaitingSecondExposure: Bool
    let shutterClosed: Bool
    let focusPoint: CGPoint?
    let isTracking: Bool

    private static let menu: SensoryFeedback = .impact(flexibility: .soft, intensity: 0.4)

    private static func when(_ feedback: SensoryFeedback) -> (Bool, Bool) -> SensoryFeedback? {
        { _, new in new ? feedback : nil }
    }

    private static func focused(_ old: CGPoint?, _ new: CGPoint?) -> SensoryFeedback? {
        new == nil ? nil : .impact(flexibility: .rigid, intensity: 0.35)
    }

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.selection, trigger: lookID)
            .sensoryFeedback(Self.menu, trigger: showSettings)
            .sensoryFeedback(trigger: awaitingSecondExposure, Self.when(.impact(flexibility: .soft, intensity: 0.5)))
            .sensoryFeedback(trigger: shutterClosed, Self.when(.impact(flexibility: .rigid, intensity: 0.45)))
            .sensoryFeedback(trigger: focusPoint, Self.focused)
            .sensoryFeedback(trigger: isTracking, Self.when(.impact(weight: .medium, intensity: 0.6)))
    }
}
