import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Synchronization

/// The catalogue of Looks and the code that applies them.
///
/// Each Look is a procedurally generated 33³ 3D LUT (see `LookRecipes`),
/// indexed in display-encoded Display P3. The cube is built lazily once per
/// Look and cached; `apply` only wraps the cached `Data` in a fresh
/// `CIColorCubeWithColorSpace`, which is cheap enough to do per preview frame.
enum LookLibrary {
    static let all: [Look] = [
        .zero,
        Look(id: "s1-01", code: "S1 01", name: "Warm 400"),
        Look(id: "s1-02", code: "S1 02", name: "Gold"),
        Look(id: "s1-03", code: "S1 03", name: "Chrome"),
        Look(id: "s1-04", code: "S1 04", name: "Cine"),
        Look(id: "s1-05", code: "S1 05", name: "Fade"),
        Look(id: "s1-06", code: "S1 06", name: "Mono"),
        Look(id: "s1-07", code: "S1 07", name: "Mono HC"),
    ]

    /// Falls back to `.zero` for unknown ids.
    static func look(id: String) -> Look {
        all.first { $0.id == id } ?? .zero
    }

    /// Cube edge length.
    static let dimension = 33

    /// The space the cube is indexed in: gamma-encoded Display P3. Core Image
    /// converts from the context's working space into this before the lookup
    /// and back afterwards.
    static let cubeColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    static func apply(_ look: Look, to image: CIImage) -> CIImage {
        guard look.id != Look.zero.id, let data = cache.data(for: look.id) else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = data
        filter.colorSpace = cubeColorSpace
        return filter.outputImage ?? image
    }

    /// Builds every cube up front (call from a background queue at launch so
    /// the first swipe through Looks never stalls a frame).
    static func prewarm() {
        for look in all where look.id != Look.zero.id {
            _ = cache.data(for: look.id)
        }
    }

    /// Raw cube bytes (RGBA float32) for a look, e.g. for tests or export.
    static func cubeData(for look: Look) -> Data? {
        cache.data(for: look.id)
    }

    private static let cache = LUTCache()
}

/// Thread-safe, build-once store of cube data.
private final class LUTCache: Sendable {
    private struct State {
        var cubes: [String: Data] = [:]
        var missing: Set<String> = []
    }

    private let state = Mutex(State())

    func data(for id: String) -> Data? {
        state.withLock { cache -> Data? in
            if let d = cache.cubes[id] { return d }
            if cache.missing.contains(id) { return nil }
            guard let transform = LookRecipes.transform(for: id) else {
                cache.missing.insert(id)
                return nil
            }
            // Building takes a few ms. Holding the lock means concurrent callers
            // wait for the single build instead of duplicating it.
            let d = LUTBuilder.cube(dimension: LookLibrary.dimension, transform)
            cache.cubes[id] = d
            return d
        }
    }
}
