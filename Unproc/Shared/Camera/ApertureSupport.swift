import AVFoundation

// Variable-aperture support (iPhone 18 Pro main camera: f/1.48, 1.8, 2.8, 4).
//
// The SDK API that exposes/sets the aperture isn't known yet, so every
// aperture-*control* device call lives in this file. The rest of the camera
// module only calls through these two functions. (Reading the live f-number
// uses the long-standing `AVCaptureDevice.lensAperture`.)

/// The f-numbers the device can be set to, ascending. Empty = fixed aperture.
func availableApertures(for device: AVCaptureDevice) -> [Float] {
    // TODO(iOS 27 aperture API): return the device's selectable apertures
    // (e.g. [1.48, 1.8, 2.8, 4] on the iPhone 18 Pro main camera).
    _ = device
    return []
}

/// Sets the aperture (`nil` = automatic). Called on the session queue with the
/// device already locked for configuration; must be a no-op when the device has
/// a fixed aperture.
func applyAperture(_ fNumber: Float?, to device: AVCaptureDevice) {
    // TODO(iOS 27 aperture API): drive the device's aperture control here
    // (manual f-number, or back to automatic when `fNumber` is nil).
    _ = fNumber
    _ = device
}
