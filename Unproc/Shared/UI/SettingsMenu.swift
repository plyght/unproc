import SwiftUI

/// Liquid Glass panel that drops down over the top of the viewfinder.
///
///     CAPTURE ────────────────────────────   (VIDEO in video mode:
///     [JPEG|RAW] [BAYER|PRORAW]    [⚡̸|⚡A|⚡]    [4K|1080]   [24|30|60]
///     [▯ 4:3 | ▯ 3:2 | ▯ 16:9 | □ 1:1]          [SDR|HDR]  TIMER [OFF|3S|10S])
///                       TIMER [OFF|3S|10S]
///     LOOK ──────────────────── NEUTRAL
///     [ZERO|S1 01|…] →
///     ASSISTS ────────────────────────────
///     [2×EXP] [PRO] [ZEBRAS] [PEAKING]
///     APPEARANCE ────────────── ORANGE
///     ● ● ● ● →              HAND [L|R]
///
/// The panel is the only glass surface; the controls inside use plain fills
/// (see `SettingsControls.swift`) so nothing stacks glass on glass.
struct SettingsMenu: View {
    let settings: SettingsStore
    /// Video mode: the VIDEO section replaces CAPTURE.
    var isVideo: Bool = false
    /// Frame rates the current video format can record.
    var offeredRates: [VideoFrameRate] = VideoFrameRate.allCases
    /// What video mode actually records (e.g. "4K30"), shown in the header.
    var activeVideoLabel: String? = nil
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Theme.viewfinderCorner,
            bottomLeadingRadius: 24,
            bottomTrailingRadius: 24,
            topTrailingRadius: Theme.viewfinderCorner,
            style: .continuous
        )
    }

    var body: some View {
        let value = settings.value
        VStack(alignment: .leading, spacing: 14) {
            if isVideo {
                videoSection
            } else {
                captureSection
            }
            lookSection
            assistsSection
            appearanceSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.bottom, 9)
        }
        .glassEffect(.regular.tint(Color.black.opacity(0.45)), in: shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        // Glass doesn't hit-test: without this, taps in the gaps between
        // controls would fall through to the tap-outside catcher and close.
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { (drag: DragGesture.Value) in
                if drag.translation.height < -30 { onClose() }
            }
        )
        .animation(Theme.snappy, value: value.output)
        .sensoryFeedback(.selection, trigger: value)
    }

    // MARK: Sections

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuSectionHeader(title: "CAPTURE")
            formatRow
            PillSegmented(
                segments: Self.ratioSegments,
                selectedID: settings.value.ratio.rawValue,
                horizontalPadding: 6,
                fillsWidth: true
            ) { (id: String) in
                settings.value.ratio = FrameRatio(rawValue: id) ?? .fourThree
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                timerControl
            }
        }
    }

    /// Resolution and frame rate, SDR / HDR, and the self-timer.
    private var videoSection: some View {
        let value = settings.value
        let rates = offeredRates.isEmpty ? VideoFrameRate.allCases : offeredRates
        let shownRate = VideoSpec.resolve(value.videoFPS, offered: rates)
        return VStack(alignment: .leading, spacing: 8) {
            MenuSectionHeader(title: "VIDEO", detail: activeVideoLabel)
            HStack(spacing: 8) {
                PillSegmented(segments: Self.resolutionSegments,
                              selectedID: value.videoResolution.rawValue) { (id: String) in
                    settings.value.videoResolution = VideoResolution(rawValue: id) ?? .uhd4K
                }
                Spacer(minLength: 0)
                PillSegmented(segments: Self.fpsSegments(rates),
                              selectedID: String(shownRate.rawValue),
                              horizontalPadding: 9) { (id: String) in
                    if let fps = Int(id), let rate = VideoFrameRate(rawValue: fps) {
                        settings.value.videoFPS = rate
                    }
                }
            }
            HStack(spacing: 8) {
                PillSegmented(segments: Self.rangeSegments,
                              selectedID: value.videoHDR ? "hdr" : "sdr",
                              horizontalPadding: 9) { (id: String) in
                    settings.value.videoHDR = id == "hdr"
                }
                Spacer(minLength: 0)
                timerControl
            }
        }
    }

    /// OFF | 3S | 10S.
    private var timerControl: some View {
        HStack(spacing: 6) {
            Text("TIMER")
                .monoLabel(9, weight: .semibold, color: Color.white.opacity(0.42))
            PillSegmented(
                segments: Self.timerSegments,
                selectedID: String(settings.value.timer.rawValue),
                horizontalPadding: 9
            ) { (id: String) in
                settings.value.timer = SelfTimer(rawValue: Int(id) ?? 0) ?? .off
            }
        }
        .fixedSize()
    }

    /// JPEG | RAW, the RAW flavour (only while RAW), and flash on the right.
    private var formatRow: some View {
        let value = settings.value
        let flavorTransition = Theme.transition(
            .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)),
            reduceMotion: reduceMotion
        )
        return HStack(spacing: 8) {
            PillSegmented(segments: Self.formatSegments, selectedID: value.output.rawValue) { (id: String) in
                settings.value.output = OutputFormat(rawValue: id) ?? .jpeg
            }
            if value.output == .raw {
                PillSegmented(
                    segments: Self.flavorSegments,
                    selectedID: value.rawFlavor == .bayer ? "bayer" : "proraw",
                    fontSize: 9,
                    height: 26,
                    horizontalPadding: 8
                ) { (id: String) in
                    settings.value.rawFlavor = id == "bayer" ? .bayer : .proRAW
                }
                .transition(flavorTransition)
            }
            Spacer(minLength: 0)
            PillSegmented(
                segments: Self.flashSegments,
                selectedID: value.flash.rawValue,
                horizontalPadding: 8
            ) { (id: String) in
                settings.value.flash = FlashSetting(rawValue: id) ?? .off
            }
        }
    }

    private var lookSection: some View {
        let selectedID = settings.value.lookID
        return VStack(alignment: .leading, spacing: 8) {
            MenuSectionHeader(title: "LOOK", detail: LookLibrary.look(id: selectedID).name)
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView(.horizontal, showsIndicators: false) {
                    PillSegmented(segments: Self.lookSegments, selectedID: selectedID) { (id: String) in
                        settings.value.lookID = id
                    }
                    .padding(.trailing, 28)
                }
                .scrollClipDisabled()
                .mask { TrailingFadeMask() }
                .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }

    private var assistsSection: some View {
        let value = settings.value
        return VStack(alignment: .leading, spacing: 8) {
            MenuSectionHeader(title: "ASSISTS")
            HStack(spacing: 6) {
                ToggleTile(title: "2×EXP", symbol: "square.on.square", id: "double",
                           isOn: value.doubleExposure) { (on: Bool) in
                    settings.value.doubleExposure = on
                }
                ToggleTile(title: "PRO", symbol: "slider.horizontal.3", id: "pro",
                           isOn: value.proMode) { (on: Bool) in
                    settings.value.proMode = on
                }
                ToggleTile(title: "ZEBRAS", symbol: "sun.max", id: "zebras",
                           isOn: value.zebras) { (on: Bool) in
                    settings.value.zebras = on
                }
                ToggleTile(title: "PEAKING", symbol: "scope", id: "peaking",
                           isOn: value.peaking) { (on: Bool) in
                    settings.value.peaking = on
                }
            }
        }
    }

    private var appearanceSection: some View {
        let swatches = Self.accentSwatches
        let stored = settings.value.accent
        // Anything unknown resolves to orange (always first).
        let selected: AccentSwatch = swatches.first(where: { (swatch: AccentSwatch) -> Bool in
            swatch.id == stored
        }) ?? swatches[0]
        return VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader(title: "APPEARANCE", detail: selected.name)
            HStack(spacing: 10) {
                ScrollViewReader { (proxy: ScrollViewProxy) in
                    ScrollView(.horizontal, showsIndicators: false) {
                        AccentSwatches(swatches: swatches, selectedID: selected.id) { (id: String) in
                            settings.value.accent = id
                        }
                        .padding(.trailing, 20)
                    }
                    .scrollClipDisabled()
                    .mask { TrailingFadeMask(width: 20) }
                    .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                }
                handControl
            }
        }
    }

    private var handControl: some View {
        HStack(spacing: 6) {
            Text("HAND")
                .monoLabel(9, weight: .semibold, color: Color.white.opacity(0.42))
            PillSegmented(
                segments: Self.handSegments,
                selectedID: settings.value.lefty ? "left" : "right",
                horizontalPadding: 11
            ) { (id: String) in
                settings.value.lefty = id == "left"
            }
        }
        .fixedSize()
    }

    // MARK: Options
    // Accessibility ids are "menu.<row>.<value>" (UI tests rely on them).

    private static var formatSegments: [MenuSegment] {
        [
            MenuSegment(id: "jpeg", label: "JPEG", accessibilityID: "menu.format.jpeg"),
            MenuSegment(id: "raw", label: "RAW", accessibilityID: "menu.format.raw"),
        ]
    }

    private static var resolutionSegments: [MenuSegment] {
        [
            MenuSegment(id: VideoResolution.uhd4K.rawValue, label: "4K", accessibilityID: "menu.video.4k"),
            MenuSegment(id: VideoResolution.hd1080.rawValue, label: "1080", accessibilityID: "menu.video.1080"),
        ]
    }

    private static func fpsSegments(_ rates: [VideoFrameRate]) -> [MenuSegment] {
        rates.map { (rate: VideoFrameRate) -> MenuSegment in
            MenuSegment(id: String(rate.rawValue), label: "\(rate.rawValue)",
                        accessibilityID: "menu.video.fps.\(rate.rawValue)",
                        accessibilityLabel: "\(rate.rawValue) frames per second")
        }
    }

    private static var rangeSegments: [MenuSegment] {
        [
            MenuSegment(id: "sdr", label: "SDR", accessibilityID: "menu.video.sdr"),
            MenuSegment(id: "hdr", label: "HDR", accessibilityID: "menu.video.hdr",
                        accessibilityLabel: "HDR (HLG)"),
        ]
    }

    private static var timerSegments: [MenuSegment] {
        [
            MenuSegment(id: "0", label: "OFF", accessibilityID: "menu.timer.off",
                        accessibilityLabel: "Timer off"),
            MenuSegment(id: "3", label: "3S", accessibilityID: "menu.timer.3",
                        accessibilityLabel: "Timer 3 seconds"),
            MenuSegment(id: "10", label: "10S", accessibilityID: "menu.timer.10",
                        accessibilityLabel: "Timer 10 seconds"),
        ]
    }

    private static var flavorSegments: [MenuSegment] {
        [
            MenuSegment(id: "bayer", label: "BAYER", accessibilityID: "menu.raw.bayer"),
            MenuSegment(id: "proraw", label: "PRORAW", accessibilityID: "menu.raw.proraw"),
        ]
    }

    private static var flashSegments: [MenuSegment] {
        [
            MenuSegment(id: "off", symbol: "bolt.slash.fill", accessibilityID: "menu.flash.off",
                        accessibilityLabel: "Flash off"),
            MenuSegment(id: "auto", symbol: "bolt.badge.automatic.fill", accessibilityID: "menu.flash.auto",
                        accessibilityLabel: "Flash auto"),
            MenuSegment(id: "on", symbol: "bolt.fill", accessibilityID: "menu.flash.on",
                        accessibilityLabel: "Flash on"),
        ]
    }

    private static var ratioSegments: [MenuSegment] {
        FrameRatio.allCases.map { (ratio: FrameRatio) -> MenuSegment in
            MenuSegment(id: ratio.rawValue, label: ratio.rawValue, ratio: CGFloat(ratio.portraitAspect),
                        accessibilityID: "menu.ratio.\(ratio.rawValue)")
        }
    }

    private static var lookSegments: [MenuSegment] {
        LookLibrary.all.map { (look: Look) -> MenuSegment in
            MenuSegment(id: look.id, label: look.code, accessibilityID: "menu.look.\(look.id)",
                        accessibilityLabel: look.name)
        }
    }

    private static var handSegments: [MenuSegment] {
        [
            MenuSegment(id: "left", label: "L", accessibilityID: "menu.hand.left",
                        accessibilityLabel: "Left-handed"),
            MenuSegment(id: "right", label: "R", accessibilityID: "menu.hand.right",
                        accessibilityLabel: "Right-handed"),
        ]
    }

    /// ORANGE plus the finishes of this phone model.
    private static var accentSwatches: [AccentSwatch] {
        let orange = AccentSwatch(id: AccentID.orange, name: "ORANGE", color: DeviceAccent.orangeColor)
        let finishes = DeviceModel.finishes.map { (finish: DeviceModel.Finish) -> AccentSwatch in
            AccentSwatch(id: finish.id, name: finish.name, color: DeviceAccent.preview(of: finish))
        }
        return [orange] + finishes
    }
}
