import CoreGraphics

/// Coordinate conversions between the portrait viewfinder and the capture device.
///
/// **Viewfinder space** (what the UI and `CameraController` API use):
/// normalized, (0,0) = top-left, (1,1) = bottom-right of the upright 3:4 portrait
/// frame exactly as shown on screen (i.e. already mirrored for the front camera).
///
/// **Device point-of-interest space** (`focusPointOfInterest`,
/// `exposurePointOfInterest`): normalized in the sensor's native landscape
/// orientation — (0,0) = top-left, (1,1) = bottom-right with the phone held in
/// landscape with the (virtual) home button on the right — regardless of how
/// the connection rotates or mirrors the video.
///
/// Back camera (connection rotation 90°): turning the upright phone into that
/// landscape pose rotates it 90° counter-clockwise, so the viewfinder's top
/// edge becomes the sensor's left edge and the viewfinder's left edge becomes
/// the sensor's bottom edge:
///
///     device.x = view.y          device.y = 1 − view.x
///
/// Front camera (rotation 90° + horizontal mirror): the mirror flips the
/// viewfinder's x before the same rotation, which cancels the `1 −`:
///
///     device.x = view.y          device.y = view.x
///
/// **Vision space** (`VNDetectedObjectObservation.boundingBox` on the portrait
/// preview frames, orientation `.up`): normalized with the origin at the
/// *bottom*-left, so only y flips relative to viewfinder space.
enum ViewfinderGeometry {
    static let centre = CGPoint(x: 0.5, y: 0.5)

    /// Clamps a point into the unit square.
    static func clampUnit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    /// Viewfinder point → device point of interest.
    static func devicePoint(fromViewfinder p: CGPoint, isFront: Bool) -> CGPoint {
        let v = clampUnit(p)
        return isFront ? CGPoint(x: v.y, y: v.x) : CGPoint(x: v.y, y: 1 - v.x)
    }

    /// Device point of interest → viewfinder point (inverse of `devicePoint`).
    static func viewfinderPoint(fromDevice p: CGPoint, isFront: Bool) -> CGPoint {
        let d = clampUnit(p)
        return isFront ? CGPoint(x: d.y, y: d.x) : CGPoint(x: 1 - d.y, y: d.x)
    }

    /// Viewfinder rect (top-left origin) → Vision rect (bottom-left origin).
    static func visionRect(fromViewfinder r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Vision rect (bottom-left origin) → viewfinder rect (top-left origin), clipped to the unit square.
    static func viewfinderRect(fromVision r: CGRect) -> CGRect {
        let flipped = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        let clipped = flipped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull ? flipped : clipped
    }

    /// A square (in pixels) seed box around `p` whose side is `fraction` of the
    /// frame width, kept inside the frame. The portrait frame is 3:4 (w:h), so
    /// the normalized height is `fraction * 3/4`.
    static func trackingSeed(around p: CGPoint, fraction: CGFloat = 0.18) -> CGRect {
        let c = clampUnit(p)
        let w = fraction
        let h = fraction * 3.0 / 4.0
        let x = min(max(c.x - w / 2, 0), 1 - w)
        let y = min(max(c.y - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
