import SwiftUI
import AVKit

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
        /// Top of the shutter pill, for placing popovers above it.
        var shutterTop: CGFloat { barTop + (barHeight - shutterHeight) / 2 }

        static let gutter: CGFloat = 10
        static let sideItem: CGFloat = 52

        init(size: CGSize) {
            let gutter = Self.gutter
            let minBar: CGFloat = 104
            vfTop = 4
            let byWidth = max(size.width - gutter * 2, 0)
            let byHeight = max(size.height - vfTop - minBar, 0) * Theme.frameAspect
            vfWidth = min(byWidth, byHeight)
            vfHeight = vfWidth / Theme.frameAspect
            let remaining = max(size.height - vfTop - vfHeight, 0)
            barHeight = min(max(remaining * 0.6, 84), 120)
            barTop = vfTop + vfHeight + max((remaining - barHeight) / 2, 0)
            let compact = size.width < 380 || remaining < 150
            shutterWidth = compact ? 116 : 132
            shutterHeight = compact ? 56 : 64
            barInset = gutter + 16
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: m.vfTop)
                    viewfinder(m)
                        .frame(width: m.vfWidth, height: m.vfHeight)
                    Color.clear.frame(height: max(m.barTop - m.vfTop - m.vfHeight, 0))
                    bottomBar(m)
                        .frame(height: m.barHeight)
                    Spacer(minLength: 0)
                }
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

                if showLensPicker {
                    LensPicker(lenses: camera.lenses, current: camera.currentLens) { lens in
                        select(lens)
                        // Let the glass selection slide over before the picker folds away.
                        Task {
                            try? await Task.sleep(for: .milliseconds(280))
                            closeFloating()
                        }
                    }
                    .frame(height: LensPicker.height)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, max(m.shutterTop - 16 - LensPicker.height, 0))
                    .transition(Theme.popover(anchor: .bottom, offsetY: 8, reduceMotion: reduceMotion))
                    .zIndex(2)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
        .animation(Theme.snappy, value: settings.value.proMode)
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
        .onChange(of: camera.currentLens?.id) { _, id in
            if let id, settings.value.lensID != id { settings.value.lensID = id }
        }
        .onChange(of: settings.value.rawFlavor) { _, flavor in
            Task { await camera.setRawFlavor(flavor) }
        }
        .onChange(of: settings.value.proMode) { _, pro in
            camera.proEnabled = pro
            if !pro { proExpanded = nil }
        }
        .onChange(of: settings.value.doubleExposure) { _, on in
            if !on { shutter.cancelDoubleExposure() }
        }
        .onChange(of: settings.value.lookID) { _, id in
            showLookToast(LookLibrary.look(id: id))
        }
        .onChange(of: shutter.flash) { _, _ in blink() }
        .onChange(of: camera.openShutterDuration) { _, duration in
            longExposureStart = duration == nil ? nil : Date()
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
                FocusOverlay(
                    point: camera.focus.point,
                    isTracking: camera.focus.isTracking,
                    trackedRect: camera.focus.trackedRect
                )
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
            .padding(.bottom, 14)
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
                onTap: { cycleLens() },
                onLongPress: {
                    guard camera.lenses.count > 1 else { return }
                    showSettings = false
                    showLensPicker = true
                }
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

    private func cycleLens() {
        let lenses = camera.lenses
        guard lenses.count > 1 else { return }
        let index = lenses.firstIndex { $0.id == camera.currentLens?.id } ?? -1
        select(lenses[(index + 1) % lenses.count])
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
