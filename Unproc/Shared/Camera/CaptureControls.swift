import AVFoundation
import Foundation
import os

/// What the Camera Control (iPhone 16+ capture button) offers, and where its
/// changes go. None of the controls is bound to a device, so they survive
/// lens switches (a zoom slide can cross physical cameras without the
/// controls being rebuilt under the user's thumb).
struct CaptureControlsConfig: Sendable {
    /// Lens stops (zoom relative to the main wide), ascending, e.g. [0.5, 1, 2, 4, 8].
    var zoomStops: [Float]
    var zoom: Float
    var onZoom: @Sendable (Float) -> Void

    var biasRange: ClosedRange<Float>
    var bias: Float
    var onBias: @Sendable (Float) -> Void

    var lookCodes: [String]
    var selectedIndex: Int
    var onSelect: @Sendable (Int) -> Void

    var ratioTitles: [String]
    var ratioIndex: Int
    var onRatio: @Sendable (Int) -> Void
}

/// Camera Control requires a controls delegate before any control is active.
/// We don't need the callbacks, so they're no-ops.
final class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        Log.controls.debug("controls: did become active")
    }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        Log.controls.debug("controls: will enter fullscreen")
    }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        Log.controls.debug("controls: will exit fullscreen")
    }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        Log.controls.debug("controls: did become inactive")
    }
}

/// The installed controls, kept so their values can follow on-screen changes.
struct InstalledCaptureControls {
    var zoom: AVCaptureSlider?
    var zoomValues: [Float] = []
    var bias: AVCaptureSlider?
    var biasBounds: ClosedRange<Float>?
    var look: AVCaptureIndexPicker?
    var ratio: AVCaptureIndexPicker?
}

enum CaptureControlsInstaller {
    /// Replaces the session's controls with Zoom, Exposure, Look and Ratio.
    /// Call on the session queue.
    ///
    /// Actions are delivered on `delegateQueue` (the session queue), and that is
    /// the only queue a control's value may be changed on — setting `value` /
    /// `selectedIndex` from any other queue raises. All later syncing
    /// (`CameraEngine.updateControl…`) therefore runs on the session queue, and
    /// every callback hops to the main actor itself.
    static func install(on session: AVCaptureSession,
                        config: CaptureControlsConfig,
                        delegate: CaptureControlsDelegate,
                        delegateQueue: DispatchQueue) -> InstalledCaptureControls {
        var installed = InstalledCaptureControls()
        guard session.supportsControls else {
            Log.controls.info("controls: session does not support controls (no Camera Control)")
            return installed
        }
        session.setControlsDelegate(delegate, queue: delegateQueue)

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            Log.controls.notice("controls: installed zoom=\(installed.zoom != nil, privacy: .public) (\(installed.zoomValues.count, privacy: .public) values) exposure=\(installed.bias != nil, privacy: .public) look=\(installed.look != nil, privacy: .public) ratio=\(installed.ratio != nil, privacy: .public) total=\(session.controls.count, privacy: .public) max=\(session.maxControlsCount, privacy: .public)")
        }

        Log.controls.debug("controls: removing \(session.controls.count, privacy: .public) existing")
        for control in session.controls {
            session.removeControl(control)
        }

        // Zoom: discrete log-spaced values so every stop gets equal travel and
        // lands exactly on the lens stops.
        let zoomValues = Self.zoomValues(stops: config.zoomStops)
        if zoomValues.count > 1 {
            let zoom = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", values: zoomValues)
            zoom.localizedValueFormat = "%@×"
            zoom.prominentValues = config.zoomStops
            zoom.value = nearest(config.zoom, in: zoomValues)
            let onZoom = config.onZoom
            zoom.setActionQueue(delegateQueue) { value in onZoom(value) }
            if session.canAddControl(zoom) {
                session.addControl(zoom)
                installed.zoom = zoom
                installed.zoomValues = zoomValues
                Log.controls.info("controls: zoom added values=\(zoomValues.count, privacy: .public) range=\(zoomValues.first ?? 0, privacy: .public)...\(zoomValues.last ?? 0, privacy: .public) value=\(zoom.value, privacy: .public)")
            } else {
                Log.controls.error("controls: cannot add zoom slider")
            }
        } else {
            Log.controls.info("controls: zoom skipped, only \(zoomValues.count, privacy: .public) values")
        }

        // Exposure compensation in third stops.
        let lower = (config.biasRange.lowerBound * 3).rounded(.up) / 3
        let upper = (config.biasRange.upperBound * 3).rounded(.down) / 3
        if upper > lower {
            let bias = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: lower...upper, step: 1.0 / 3.0)
            bias.localizedValueFormat = "%@ EV"
            bias.prominentValues = [0]
            // Must be on the slider's 1/3-stop grid and in range, or AVFoundation raises.
            bias.value = min(max((config.bias * 3).rounded() / 3, lower), upper)
            let onBias = config.onBias
            bias.setActionQueue(delegateQueue) { value in onBias(value) }
            if session.canAddControl(bias) {
                session.addControl(bias)
                installed.bias = bias
                installed.biasBounds = lower...upper
                Log.controls.info("controls: exposure added range=\(lower, privacy: .public)...\(upper, privacy: .public) value=\(bias.value, privacy: .public)")
            } else {
                Log.controls.error("controls: cannot add exposure slider")
            }
        } else {
            Log.controls.info("controls: exposure skipped, empty range \(lower, privacy: .public)...\(upper, privacy: .public)")
        }

        if !config.lookCodes.isEmpty {
            let look = AVCaptureIndexPicker("Look", symbolName: "camera.filters",
                                            localizedIndexTitles: config.lookCodes)
            look.selectedIndex = CameraMath.clamp(config.selectedIndex, 0, config.lookCodes.count - 1)
            let onSelect = config.onSelect
            look.setActionQueue(delegateQueue) { index in
                Log.controls.debug("controls: look action \(index, privacy: .public)")
                onSelect(index)
            }
            if session.canAddControl(look) {
                session.addControl(look)
                installed.look = look
                Log.controls.info("controls: look added count=\(config.lookCodes.count, privacy: .public) sel=\(look.selectedIndex, privacy: .public)")
            } else {
                Log.controls.error("controls: cannot add look picker")
            }
        }

        if !config.ratioTitles.isEmpty {
            let ratio = AVCaptureIndexPicker("Ratio", symbolName: "aspectratio",
                                             localizedIndexTitles: config.ratioTitles)
            ratio.selectedIndex = CameraMath.clamp(config.ratioIndex, 0, config.ratioTitles.count - 1)
            let onRatio = config.onRatio
            ratio.setActionQueue(delegateQueue) { index in
                Log.controls.debug("controls: ratio action \(index, privacy: .public)")
                onRatio(index)
            }
            if session.canAddControl(ratio) {
                session.addControl(ratio)
                installed.ratio = ratio
                Log.controls.info("controls: ratio added count=\(config.ratioTitles.count, privacy: .public) sel=\(ratio.selectedIndex, privacy: .public)")
            } else {
                Log.controls.error("controls: cannot add ratio picker")
            }
        }
        return installed
    }

    /// 6 steps per stop gap, evenly spaced in log zoom, rounded to 0.1×
    /// (0.05× below 1×) and de-duplicated; stops are always exact.
    static func zoomValues(stops: [Float]) -> [Float] {
        // Positive, finite, unique — duplicates would make AVCaptureSlider(values:) raise.
        let stops = Array(Set(stops.filter { $0.isFinite && $0 > 0 })).sorted()
        guard stops.count > 1 else { return stops }
        var values: [Float] = []
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            values.append(a)
            for step in 1..<6 {
                let z = a * pow(b / a, Float(step) / 6)
                let rounded = z < 1 ? (z * 20).rounded() / 20 : (z * 10).rounded() / 10
                if rounded > a, rounded < b, rounded != values.last { values.append(rounded) }
            }
        }
        values.append(stops[stops.count - 1])
        return values
    }

    static func nearest(_ value: Float, in values: [Float]) -> Float {
        values.min { abs(log(max($0, 0.01) / max(value, 0.01))) < abs(log(max($1, 0.01) / max(value, 0.01))) } ?? value
    }
}
