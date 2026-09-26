import CoreImage

/// A subtle colour grade ("Look"). Implemented as a procedurally generated
/// 3D LUT so the exact same transform runs on the viewfinder and on the
/// full-resolution photo. See `LookLibrary`.
struct Look: Identifiable, Hashable, Sendable {
    /// Stable id persisted in settings, e.g. "zero", "s1-01".
    let id: String
    /// Short code shown in the menu, e.g. "ZERO", "S1 01".
    let code: String
    /// Human name, e.g. "Neutral", "Warm 400".
    let name: String

    static let zero = Look(id: "zero", code: "ZERO", name: "Neutral")
}
