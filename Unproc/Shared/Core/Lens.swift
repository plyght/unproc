import AVFoundation
import CoreGraphics

/// One entry in the lens selector: a zoom stop on a camera device. On phones
/// with a back virtual camera every back stop is that one device at a
/// different `videoZoomFactor`; otherwise a physical camera, optionally with a
/// centre crop ("2×" on the wide, "2× tele" on the telephoto).
struct Lens: Identifiable, Hashable, Sendable {
    /// Stable id, e.g. "back.wide", "back.wide.crop2", "back.tele", "back.tele.crop2", "front.wide".
    let id: String
    /// `AVCaptureDevice.uniqueID` of the camera (the back virtual camera, or a physical one).
    let deviceID: String
    let position: AVCaptureDevice.Position
    let kind: Kind
    /// The device's `videoZoomFactor` for this stop (physical: the centre crop,
    /// 1 = none, 2 = 2×; virtual: display zoom / the widest constituent's zoom).
    /// On a captured frame it's the crop still owed to the RAW (for a virtual
    /// camera, relative to the constituent that took the shot).
    let crop: CGFloat
    /// Zoom relative to the main wide lens, as printed on the button (0.5, 1, 2, 5, 10…).
    let zoom: CGFloat

    enum Kind: String, Sendable { case ultraWide, wide, tele, front }

    /// "0.5", "1", "2", "5", "FRONT".
    var label: String {
        if kind == .front { return "FRONT" }
        let z = zoom
        if z.rounded() == z { return "\(Int(z))" }
        return String(format: "%.1f", z).replacingOccurrences(of: ".0", with: "")
    }

    var isFront: Bool { position == .front }
}
