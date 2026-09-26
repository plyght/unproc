import SwiftUI
import AVKit
import GlurBackdrop

/// The whole camera: viewfinder, status badge, settings menu, PRO controls,
/// bottom bar (thumbnail · shutter · lens) and the photo viewer on top.
/// Shared between the app and the lock-screen capture extension.
struct CameraScreen: View {
    let camera: CameraController
    let store: any PhotoStore
    let sink: any CaptureSink
    let hooks: HostHooks

    @State private var shutter: ShutterCoordinator
    @State private var showViewer = false
    @State private var showSettings = false
    @State private var showLensPicker = false
    @State private var zoomScrub = ZoomScrubModel()
    @State private var zoomDialVisible = false
    @State private var zoomHideTask: Task<Void, Never>?
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
        /// Top of the shutter pill, for placing popovers above it.
        var shutterTop: CGFloat { barTop + (barHeight - shutterHeight) / 2 }

        static let gutter: CGFloat = 10
        static let sideItem: CGFloat = 52

        init(size: CGSize, ratio: FrameRatio) {
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
            shutterWidth = compact ? 116 : 132
            shutterHeight = compact ? 56 : 64
            barInset = gutter + 16

            // The actual viewfinder for this ratio.
            let aspect = CGFloat(ratio.portraitAspect)
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
            let m = Metrics(size: geo.size, ratio: settings.value.ratio)
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
                    SettingsMenu(settings: settings, onClose: { closeFloating() })
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
            if event.phase == .ended {
                hardwareShutter()
            }
        }
        // Lifecycle.
        .task {
            LaunchArguments.applyResetIfNeeded()
            await activate()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await activate() }
            case .background: deactivate()
            default: break
            }
        }
        // Settings → camera.
        .modifier(Observers(camera: camera, settings: settings, shutter: shutter))
        .onChange(of: settings.value.proMode) { _, pro in
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
                    Task { await camera.setRawFlavor(flavor) }
                }
                .onChange(of: settings.value.accent) { _, _ in
                    DeviceAccent.refresh()
                }
                .onChange(of: settings.value.doubleExposure) { _, on in
                    if !on { shutter.cancelDoubleExposure() }
                }
                .onChange(of: settings.value.lookID) { _, id in
                    if let index = LookLibrary.all.firstIndex(where: { $0.id == id }) {
                        camera.setCaptureControlsSelection(index)
                    }
                }
                .onChange(of: settings.value.ratio) { _, ratio in
                    camera.setCaptureControlsRatio(FrameRatio.allCases.firstIndex(of: ratio) ?? 0)
                }
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
                look: LookLibrary.look(id: value.lookID),
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
                    stepLook(direction)
                }
            )

            if pro {
                // FocusOverlay works in the 3:4 sensor frame; aspect-fill that
                // frame into the viewfinder so points line up at any ratio.
                Color.clear
                    .aspectRatio(Theme.frameAspect, contentMode: .fill)
                    .overlay {
                        FocusOverlay(
                            point: camera.focus.point,
                            isTracking: camera.focus.isTracking,
                            trackedRect: camera.focus.trackedRect
                        )
                    }
                    .allowsHitTesting(false)
            }

            if value.ratio == .sixteenNine {
                // Tall frame: soften the top and bottom edges so the frame melts into
                // the black and the floating controls sit on calm image. Progressive
                // (Glur backdrop) blur plus a gentle darkening, both on smooth ramps.
                GlurView(radius: 6, mask: .linear(stops: [
                    .init(intensity: 1, location: 0),
                    .init(intensity: 0, location: 0.13),
                    .init(intensity: 0, location: 0.80),
                    .init(intensity: 1, location: 1),
                ], startPoint: .top, endPoint: .bottom))
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
                }
                .animation(Theme.fade, value: look.id)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: .rect(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
                .transition(Theme.blurFade)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.viewfinderCorner, style: .continuous))
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.viewfinderCorner, style: .continuous))
        .overlay(alignment: .topTrailing) {
            StatusBadge(settings: value) {
                showLensPicker = false
                proExpanded = nil
                showSettings = true
            }
            .padding(12)
        }
        .overlay(alignment: .topLeading) {
            if hooks.isLockedCapture, let openFullApp = hooks.openFullApp {
                Button {
                    openFullApp()
                } label: {
                    Text("OPEN UNPROC")
                        .monoLabel(9, weight: .semibold, color: Theme.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.pressable)
                .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let error = shutter.lastError {
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

    private func bottomBar(_ m: Metrics) -> some View {
        HStack(spacing: 0) {
            ThumbnailButton(store: store, namespace: heroNamespace) {
                closeFloating()
                withAnimation(Theme.snappy) { showViewer = true }
            }
            .frame(width: Metrics.sideItem, height: Metrics.sideItem)
            .frame(maxWidth: .infinity, alignment: .leading)

            ShutterButton(
                isEnabled: camera.status == .running,
                isBusy: shutter.isBusy,
                width: m.shutterWidth,
                height: m.shutterHeight
            ) {
                closeFloating()
                shutter.shoot()
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

            LensButton(
                current: camera.currentLens,
                model: zoomScrub,
                isExpanded: zoomDialVisible,
                // 16:9: the button floats over the image; keep the ruler above the
                // line where the image meets the black.
                rulerMaxBelow: m.barOverlap > 0
                    ? max(m.vfTop + m.vfHeight - (m.barTop + m.barHeight / 2), 0)
                    : .infinity,
                onTap: { whileExpanded in
                    if whileExpanded {
                        zoomHideTask?.cancel()
                        withAnimation(Theme.exit) { zoomDialVisible = false }
                    } else {
                        closeFloating()
                        presentZoomRuler()
                    }
                },
                onScrubBegin: {
                    closeFloating()
                    beginZoomScrub()
                },
                onScrubChange: { dy in perform(zoomScrub.update(dy: dy)) },
                onScrubEnd: { endZoomScrub() }
            )
            .frame(width: Metrics.sideItem, height: Metrics.sideItem)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, m.barInset)
    }

    // MARK: - Actions

    private func hardwareShutter() {
        if showViewer {
            withAnimation(Theme.snappy) { showViewer = false }
        }
        closeFloating()
        shutter.shoot()
    }

    private func closeFloating() {
        if showSettings { showSettings = false }
        if showLensPicker { showLensPicker = false }
    }

    private func beginZoomScrub() {
        zoomHideTask?.cancel()
        let lens = camera.currentLens
        zoomScrub.begin(stops: camera.zoomStops, zoom: lens?.zoom ?? 1, isFront: lens?.isFront == true)
        if !zoomDialVisible {
            withAnimation(Theme.snappy) { zoomDialVisible = true }
        }
    }

    /// Tap: show the ruler without zooming, and leave it out a little longer
    /// so it reads as "you can slide this".
    private func presentZoomRuler() {
        let lens = camera.currentLens
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
        withAnimation(Theme.exit) { perform(action) }
        // Linger so the ruler can be grabbed again, then fold away.
        scheduleRulerHide(after: .milliseconds(1600))
    }

    private func perform(_ action: ZoomScrubModel.Action?) {
        switch action {
        case .zoom(let zoom)?:
            camera.setZoom(zoom)
        case .flip(.front)?:
            if let front = camera.lenses.first(where: \.isFront) { select(front) }
        case .flip(.back)?:
            let back = camera.lenses.first { $0.id == "back.wide" } ?? camera.lenses.first { !$0.isFront }
            if let back { select(back) }
        case nil:
            break
        }
    }

    private func select(_ lens: Lens) {
        guard lens.id != camera.currentLens?.id else { return }
        Task { await camera.select(lens) }
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
        guard !isActivating else { return }
        isActivating = true
        defer { isActivating = false }

        hooks.setIdleTimerDisabled(true)
        camera.proEnabled = settings.value.proMode
        if camera.status != .running {
            await camera.start(preferredLensID: settings.value.lensID, rawFlavor: settings.value.rawFlavor)
        }
        camera.proEnabled = settings.value.proMode
        installCaptureControls()
        await store.reload()
    }

    private func deactivate() {
        closeFloating()
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
