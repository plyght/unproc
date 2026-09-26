import AVFoundation
import CoreGraphics

/// One entry in the lens selector. A physical camera, optionally with a
/// centre crop ("2×" on the wide, "2× tele" on the telephoto).
struct Lens: Identifiable, Hashable, Sendable {
    /// Stable id, e.g. "back.wide", "back.wide.crop2", "back.tele", "back.tele.crop2", "front.wide".
    let id: String
    /// `AVCaptureDevice.uniqueID` of the physical camera.
    let deviceID: String
    let position: AVCaptureDevice.Position
    let kind: Kind
    /// Centre crop applied on top of the physical lens (1 = none, 2 = 2× crop).
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
