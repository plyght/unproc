import AVFoundation
import Foundation

/// Arguments of the last `installCaptureControls` call, kept so the controls can
/// be rebuilt when the lens (and therefore the device) changes.
struct CaptureControlsConfig: Sendable {
    var lookCodes: [String]
    var selectedIndex: Int
    var onSelect: @Sendable (Int) -> Void
}

/// Camera Control (iPhone 16+) requires a controls delegate before any control
/// is active. We don't need the callbacks, so they're no-ops.
final class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

enum CaptureControlsInstaller {
    /// Replaces the session's controls with an exposure-bias slider bound to
    /// `device` and a Look picker. Call on the session queue.
    /// Returns the picker (so its selection can be updated later), if added.
    @discardableResult
    static func install(on session: AVCaptureSession,
                        device: AVCaptureDevice,
                        config: CaptureControlsConfig,
                        delegate: CaptureControlsDelegate,
                        delegateQueue: DispatchQueue) -> AVCaptureIndexPicker? {
        guard session.supportsControls else { return nil }
        session.setControlsDelegate(delegate, queue: delegateQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for control in session.controls {
            session.removeControl(control)
        }

        let slider = AVCaptureSystemExposureBiasSlider(device: device)
        if session.canAddControl(slider) {
            session.addControl(slider)
        }

        guard !config.lookCodes.isEmpty else { return nil }
        let picker = AVCaptureIndexPicker("Look",
                                          symbolName: "camera.filters",
                                          localizedIndexTitles: config.lookCodes)
        picker.selectedIndex = CameraMath.clamp(config.selectedIndex, 0, config.lookCodes.count - 1)
        let onSelect = config.onSelect
        picker.setActionQueue(.main) { index in
            onSelect(index)
        }
        guard session.canAddControl(picker) else { return nil }
        session.addControl(picker)
        return picker
    }
}
