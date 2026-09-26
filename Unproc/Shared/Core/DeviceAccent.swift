import SwiftUI
import UIKit
import CoreImage
import Synchronization
import os

/// The app's single accent colour: unproc's signal orange, or the finish of
/// the user's phone that they picked (iOS doesn't expose which finish a phone
/// is, so `DeviceModel` lists the model's finishes and the user chooses). The
/// finish colour is nudged so it stays legible as text on black and as a fill
/// behind the shutter's black word.
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
        let id = SettingsStore.shared.value.accent
        // The phone's own finishes first (ids like "gold" repeat across models
        // with different shades), then any known finish.
        let finish = DeviceModel.finishes.first { $0.id == id } ?? DeviceModel.finish(id: id)
        let value = finish.flatMap { parseHex($0.hex) }.map(legible) ?? signalOrange
        storage.withLock { $0 = value }
        Log.settings.notice("accent: id=\(id, privacy: .public) finish=\(finish?.name ?? "orange", privacy: .public) model=\(DeviceModel.identifier, privacy: .public) (\(DeviceModel.name ?? "unknown", privacy: .public)) hex=\(hexString(value), privacy: .public)")
        return value
    }

    /// The legible accent a finish would give (for colouring menu labels).
    static func preview(of finish: DeviceModel.Finish) -> Color {
        let c = parseHex(finish.hex).map(legible) ?? signalOrange
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static var orangeColor: Color {
        Color(.sRGB, red: Double(signalOrange.x), green: Double(signalOrange.y), blue: Double(signalOrange.z))
    }

    private static func hexString(_ c: SIMD4<Float>) -> String {
        func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
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
