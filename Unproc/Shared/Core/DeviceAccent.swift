import SwiftUI
import UIKit
import CoreImage
import Synchronization

/// The app's single accent colour: the phone's own enclosure colour when it
/// can be read (AUTO), otherwise unproc's signal orange.
///
/// There is no public API for the device colour. AUTO asks `UIDevice` for the
/// private "DeviceEnclosureColor" key — fine for a sideloaded build, and it
/// fails soft: if the selector is gone or iOS withholds the value, we keep the
/// orange. The raw colour is then nudged so it stays legible as text on black
/// and as a fill behind the shutter's black word.
enum DeviceAccent {
    /// #FF5A1F — unproc's own accent.
    static let signalOrange = SIMD4<Float>(1.0, 90.0 / 255.0, 31.0 / 255.0, 1)

    private static let storage = Mutex<SIMD4<Float>?>(nil)

    /// Current accent as RGBA (safe from any thread; resolves on first use).
    static var rgba: SIMD4<Float> {
        if let value = storage.withLock({ $0 }) { return value }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { refresh() }
        }
        return signalOrange
    }

    static var color: Color {
        let c = rgba
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static var ciColor: CIColor {
        let c = rgba
        return CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z))
    }

    /// Re-resolves from the current setting. Call after the ACCENT setting changes.
    @MainActor
    @discardableResult
    static func refresh() -> SIMD4<Float> {
        let value: SIMD4<Float>
        switch SettingsStore.shared.value.accent {
        case .orange:
            value = signalOrange
        case .auto:
            value = enclosureColor().map(legible) ?? signalOrange
        }
        storage.withLock { $0 = value }
        return value
    }

    // MARK: - Device colour (private API, fails soft)

    @MainActor
    private static func enclosureColor() -> SIMD4<Float>? {
        let device = UIDevice.current
        for name in ["deviceInfoForKey:", "_deviceInfoForKey:"] {
            let selector = NSSelectorFromString(name)
            guard device.responds(to: selector),
                  let raw = device.perform(selector, with: "DeviceEnclosureColor")?.takeUnretainedValue()
            else { continue }
            if let string = raw as? String, let rgb = parseHex(string) { return rgb }
        }
        return nil
    }

    /// "#e1e4e3" / "e1e4e3" → RGBA. Numeric (index) values aren't mappable, so they fall back.
    private static func parseHex(_ string: String) -> SIMD4<Float>? {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return SIMD4<Float>(
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float(value & 0xFF) / 255,
            1
        )
    }

    /// Keeps the hue; lifts brightness so it reads on black and behind black
    /// text; gives colourful finishes enough saturation to read as an accent,
    /// while near-neutral finishes (silver, white, black) become a clean light
    /// neutral.
    private static func legible(_ rgb: SIMD4<Float>) -> SIMD4<Float> {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 {
            // Neutral finish: a slightly cool light silver.
            s = 0.04
            b = 0.86
        } else {
            s = min(max(s, 0.5), 0.9)
            b = max(b, 0.8)
        }
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        UIColor(hue: h, saturation: s, brightness: b, alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(bl), 1)
    }
}
