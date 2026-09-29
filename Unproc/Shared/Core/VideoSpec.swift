import CoreGraphics
import Foundation

/// Pure helpers for video mode (unit tested): bitrates, labels, frame-rate
/// offers, output size, track rotation and the recording timecode.
enum VideoSpec {
    /// Average bitrate in bits/s. "Higher end of the middle ground": ~50 Mb/s
    /// at 4K30, ~80 at 4K60, proportionally less at 24 fps and for 1080p
    /// (1080p is a quarter of the pixels but gets ~40 % of the bits, since
    /// smaller frames need more bits per pixel for the same quality). HDR
    /// (10-bit HLG) gets 20 % more.
    static func bitrate(resolution: VideoResolution, fps: Int, hdr: Bool = false) -> Int {
        let base4K: Double
        switch fps {
        case ..<26: base4K = 42_000_000
        case ..<45: base4K = 50_000_000
        default: base4K = 80_000_000
        }
        let scale: Double = resolution == .uhd4K ? 1 : 0.4
        let hdrScale: Double = hdr ? 1.2 : 1
        return Int((base4K * scale * hdrScale).rounded())
    }

    /// Status badge label, e.g. "4K30", "1080·60".
    static func badge(resolution: VideoResolution, fps: Int) -> String {
        switch resolution {
        case .uhd4K: "4K\(fps)"
        case .hd1080: "1080·\(fps)"
        }
    }

    /// The rates in `VideoFrameRate` a format whose best frame rate is `maxRate` can record.
    static func offeredRates(maxRate: Double) -> [VideoFrameRate] {
        VideoFrameRate.allCases.filter { Double($0.rawValue) <= maxRate + 0.5 }
    }

    /// `wanted` if offered, else the fastest offered rate below it, else the slowest offered.
    static func resolve(_ wanted: VideoFrameRate, offered: [VideoFrameRate]) -> VideoFrameRate {
        if offered.contains(wanted) { return wanted }
        let sorted = offered.sorted { $0.rawValue < $1.rawValue }
        return sorted.last { $0.rawValue < wanted.rawValue } ?? sorted.first ?? wanted
    }

    /// Output size for recorded frames of `frame` size: the frame's own
    /// orientation, cropped to 16:9 (9:16 when portrait), no larger than
    /// `longSide`, with even dimensions.
    static func outputSize(frame: CGSize, longSide: Int) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let portrait = frame.height >= frame.width
        let long = portrait ? frame.height : frame.width
        let short = portrait ? frame.width : frame.height
        // Largest 16:9 rectangle inside the frame.
        var outLong = long
        var outShort = long * 9 / 16
        if outShort > short {
            outShort = short
            outLong = short * 16 / 9
        }
        let cap = CGFloat(longSide)
        if outLong > cap {
            outShort = outShort * cap / outLong
            outLong = cap
        }
        let evenLong = CGFloat(max(Int(outLong.rounded(.down)) / 2 * 2, 2))
        let evenShort = CGFloat(max(Int(outShort.rounded(.down)) / 2 * 2, 2))
        return portrait ? CGSize(width: evenShort, height: evenLong) : CGSize(width: evenLong, height: evenShort)
    }

    /// Clockwise degrees (0, 90, 180, 270) the player must rotate recorded
    /// frames by: frames are recorded at `recordedAngle` (the portrait preview
    /// rotation) but the phone was held at `captureAngle` (the rotation
    /// coordinator's horizon-level angle).
    static func trackRotation(captureAngle: Double, recordedAngle: Double) -> Int {
        var delta = (captureAngle - recordedAngle).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        let quarter = Int((delta / 90).rounded()) % 4
        return quarter * 90
    }

    /// Track transform rotating a `width`×`height` frame clockwise by
    /// `degrees` (multiple of 90) and translating it back into the positive quadrant.
    static func trackTransform(degrees: Int, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: return .identity
        }
    }
}

/// Recording timecode: "mm:ss" (minutes keep counting past 59).
enum Timecode {
    static func string(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// Short duration for thumbnails: "0:05", "1:23", "1:02:03".
    static func short(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded()), 0) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
