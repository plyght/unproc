import Foundation

/// The seven "S1" grades. Each is a pure function on display-encoded
/// Display P3 values that gets baked into a 33³ cube once.
///
/// Design rules: nothing here should read as a filter. Moves are small
/// (a few percent), neutrals stay close to neutral apart from the intended
/// warmth, skin is protected, and every curve is monotone so no banding or
/// tone reversals can appear.
enum LookRecipes {
    typealias Transform = (GradeRGB) -> GradeRGB
    private typealias K = GradeKit
    private typealias Band = GradeKit.HueBand

    static func transform(for id: String) -> Transform? {
        switch id {
        case "s1-01": return warm400
        case "s1-02": return gold
        case "s1-03": return chrome
        case "s1-04": return cine
        case "s1-05": return fade
        case "s1-06": return mono
        case "s1-07": return monoHC
        default: return nil
        }
    }

    // MARK: S1 01 — Warm 400
    // Portrait-negative feel: a touch of warmth, slightly lifted (warm) blacks,
    // soft highlight shoulder, calmer olive-leaning greens, gentle skin.
    static let warm400: Transform = { input in
        var c = K.liftGammaGain(input,
                                lift: GradeRGB(0.020, 0.017, 0.013),
                                gain: GradeRGB(1.015, 1.0, 0.975))
        c = K.perChannel(c) { K.filmic($0, contrast: 0.10, pivot: 0.45) }
        c = K.perChannel(c) { K.shoulder($0, knee: 0.72, strength: 0.25) }
        c = K.hueBands(c, [
            Band(center: 115, width: 38, saturation: 0.82, hueShift: -6, luminance: -0.01), // greens → calmer, olive
            Band(center: 60, width: 18, saturation: 0.95),                               // yellows
            Band(center: 28, width: 20, saturation: 1.03, hueShift: 1),                  // skin
            Band(center: 215, width: 35, saturation: 0.90, hueShift: -4),                // blues slightly cyan, softer
        ])
        c = K.saturation(c, 0.96)
        c = K.splitTone(c, shadowHue: 200, shadowAmount: 0.006,
                        highlightHue: 38, highlightAmount: 0.018)
        return c
    }

    // MARK: S1 02 — Gold
    // Golden-hour: yellow-gold mids, warm skin, softened blues.
    static let gold: Transform = { input in
        var c = K.liftGammaGain(input,
                                lift: GradeRGB(0.012, 0.010, 0.004),
                                gain: GradeRGB(1.03, 1.008, 0.955))
        c = K.perChannel(c) { K.filmic($0, contrast: 0.12, pivot: 0.47) }
        c = K.perChannel(c) { K.shoulder($0, knee: 0.78, strength: 0.30) }
        c = K.splitTone(c, shadowHue: 25, shadowAmount: 0.006,
                        highlightHue: 45, highlightAmount: 0.015,
                        midHue: 48, midAmount: 0.028)
        c = K.hueBands(c, [
            Band(center: 25, width: 20, saturation: 1.05, hueShift: 2),   // skin, warm
            Band(center: 45, width: 20, saturation: 1.08),                // oranges / golds
            Band(center: 110, width: 35, saturation: 0.88, hueShift: -8), // greens toward yellow
            Band(center: 220, width: 40, saturation: 0.86),               // blues quieter
        ])
        return c
    }

    // MARK: S1 03 — Chrome
    // Slide-film: firmer contrast with a denser black, deeper blues, richer reds.
    static let chrome: Transform = { input in
        var c = K.perChannel(input) { K.toe($0, end: 0.12, amount: 0.35) }
        c = K.perChannel(c) { K.filmic($0, contrast: 0.26, pivot: 0.46) }
        c = K.perChannel(c) { K.shoulder($0, knee: 0.85, strength: 0.35) }
        c = K.hueBands(c, [
            Band(center: 0, width: 22, saturation: 1.10, luminance: -0.01),              // reds richer
            Band(center: 28, width: 16, saturation: 1.00),                               // keep skin honest
            Band(center: 120, width: 35, saturation: 1.02, hueShift: 4),                 // greens slightly cool
            Band(center: 222, width: 35, saturation: 1.12, hueShift: 4, luminance: -0.035), // deep blues
            Band(center: 190, width: 20, saturation: 1.04, hueShift: 6),                 // cyans lean blue
        ])
        c = K.saturation(c, 1.05)
        c = K.splitTone(c, shadowHue: 225, shadowAmount: 0.010,
                        highlightHue: 50, highlightAmount: 0.006)
        return c
    }

    // MARK: S1 04 — Cine
    // Subtle teal shadows / warm highlights on a filmic S-curve, skin kept natural.
    static let cine: Transform = { input in
        var c = K.perChannel(input) { K.lift($0, black: 0.012) }
        c = K.perChannel(c) { K.filmic($0, contrast: 0.20, pivot: 0.45) }
        c = K.perChannel(c) { K.shoulder($0, knee: 0.76, strength: 0.35) }
        c = K.splitTone(c, shadowHue: 188, shadowAmount: 0.035,
                        highlightHue: 34, highlightAmount: 0.028)
        c = K.hueBands(c, [
            Band(center: 26, width: 20, saturation: 1.02),                 // skin protected
            Band(center: 115, width: 35, saturation: 0.85, hueShift: 10),  // greens toward teal, calmer
            Band(center: 300, width: 40, saturation: 0.85),                // tame magentas
        ])
        c = K.saturation(c, 0.94)
        return c
    }

    // MARK: S1 05 — Fade
    // Matte, low contrast, pastel.
    static let fade: Transform = { input in
        var c = K.perChannel(input) { K.filmic($0, contrast: -0.10, pivot: 0.5) }
        c = K.perChannel(c) { K.shoulder($0, knee: 0.70, strength: 0.45) }
        c = K.liftGammaGain(c,
                            lift: GradeRGB(0.065, 0.062, 0.070),
                            gamma: GradeRGB(1.02, 1.02, 1.0),
                            gain: GradeRGB(0.975, 0.975, 0.965))
        c = K.saturation(c, 0.80)
        c = K.hueBands(c, [
            Band(center: 26, width: 20, saturation: 1.06),                 // skin keeps a little life
            Band(center: 120, width: 40, saturation: 0.90, hueShift: -4),
        ])
        c = K.splitTone(c, shadowHue: 250, shadowAmount: 0.014,
                        highlightHue: 40, highlightAmount: 0.012)
        return c
    }

    // MARK: S1 06 — Mono
    // B&W through a mild red-orange filter (darker skies, clean skin), gentle curve.
    static let mono: Transform = { input in
        var y = K.mono(input, weights: GradeRGB(0.42, 0.46, 0.12))
        y = K.lift(y, black: 0.012)
        y = K.filmic(y, contrast: 0.12, pivot: 0.47)
        y = K.shoulder(y, knee: 0.82, strength: 0.35)
        return GradeRGB(repeating: y)
    }

    // MARK: S1 07 — Mono HC
    // Contrasty B&W: stronger red filter, deep blacks, bright but not clipped whites.
    static let monoHC: Transform = { input in
        var y = K.mono(input, weights: GradeRGB(0.52, 0.40, 0.08))
        y = K.toe(y, end: 0.15, amount: 0.45)
        y = K.filmic(y, contrast: 0.42, pivot: 0.45)
        y = K.shoulder(y, knee: 0.90, strength: 0.40)
        return GradeRGB(repeating: y)
    }
}
