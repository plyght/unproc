import Foundation

/// The phone's model (public: the `utsname` machine id, e.g. "iPhone18,1")
/// and the finishes it shipped in, so the accent can match the user's phone.
/// iOS doesn't say which finish a particular phone is, so the user picks.
enum DeviceModel {
    struct Finish: Identifiable, Hashable, Sendable {
        /// Stable id stored in settings, e.g. "cosmic-orange".
        let id: String
        /// Menu label, e.g. "COSMIC ORANGE".
        let name: String
        /// Approximate finish colour, "#RRGGBB".
        let hex: String
    }

    /// e.g. "iPhone18,1". In the Simulator, the simulated model's id.
    static let identifier: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Marketing name, e.g. "iPhone 17 Pro" (nil if unknown).
    static var name: String? { entry(for: identifier)?.name }

    /// Finishes for this phone; a broad palette of recent finishes if the
    /// model isn't in the table (newer than this build, iPad, …).
    static var finishes: [Finish] { entry(for: identifier)?.finishes ?? fallbackFinishes }

    /// Every finish we know, for resolving a stored id.
    static var allFinishes: [Finish] {
        var seen = Set<String>()
        return (table.values.flatMap(\.finishes) + fallbackFinishes).filter { seen.insert($0.id).inserted }
    }

    static func finish(id: String) -> Finish? {
        allFinishes.first { $0.id == id }
    }

    // MARK: - Table

    private struct Entry {
        let name: String
        let finishes: [Finish]
    }

    private static func entry(for identifier: String) -> Entry? {
        if let exact = table[identifier] { return exact }
        // Unlisted variants of the newest generation (e.g. "iPhone19,7").
        if identifier.hasPrefix("iPhone19,") { return table["iPhone19,2"] }
        return nil
    }

    private static func f(_ name: String, _ hex: String) -> Finish {
        Finish(id: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name.uppercased(), hex: hex)
    }

    // Shared finishes.
    private static let black = f("Black", "#2E2E30")
    private static let white = f("White", "#F2F2EF")
    private static let red = f("Product Red", "#BA0C2E")
    private static let midnight = f("Midnight", "#232A31")
    private static let starlight = f("Starlight", "#F4EEE6")
    private static let silver = f("Silver", "#E3E4E5")
    private static let graphite = f("Graphite", "#54524F")
    private static let spaceBlack = f("Space Black", "#3B3B3D")

    private static let iPhone11 = [black, white, f("Green", "#AEE1CD"), f("Yellow", "#FFE681"), f("Purple", "#D1CDDA"), red]
    private static let iPhone11Pro = [f("Midnight Green", "#4E5851"), f("Space Gray", "#535150"), silver, f("Gold", "#F9D8BE")]
    private static let iPhone12 = [black, white, red, f("Green", "#D8EFD5"), f("Blue", "#023B63"), f("Purple", "#B7AFE6")]
    private static let iPhone12Pro = [f("Pacific Blue", "#2E4755"), f("Gold", "#FCEBD3"), graphite, silver]
    private static let iPhone13 = [f("Pink", "#FAE0D8"), f("Blue", "#276787"), midnight, starlight, red, f("Green", "#394C38")]
    private static let iPhone13Pro = [f("Sierra Blue", "#9BB5CE"), graphite, f("Gold", "#F9E5C9"), silver, f("Alpine Green", "#576856")]
    private static let iPhoneSE = [midnight, starlight, red]
    private static let iPhone14 = [f("Blue", "#A0B4C7"), f("Purple", "#E6DDEB"), f("Yellow", "#F9E479"), midnight, starlight, red]
    private static let iPhone14Pro = [f("Deep Purple", "#594F63"), f("Gold", "#F4E8CE"), silver, spaceBlack]
    private static let iPhone15 = [f("Blue", "#D4E4ED"), f("Pink", "#E3C8CA"), f("Yellow", "#E6E0C1"), f("Green", "#CAD4C5"), black]
    private static let iPhone15Pro = [f("Natural Titanium", "#BAB4A9"), f("Blue Titanium", "#394C5E"), f("White Titanium", "#F2F1EB"), f("Black Titanium", "#3C3C3D")]
    private static let iPhone16 = [f("Ultramarine", "#9AADF6"), f("Teal", "#B0D4D2"), f("Pink", "#F2ADDA"), white, black]
    private static let iPhone16Pro = [f("Desert Titanium", "#BFA48F"), f("Natural Titanium", "#C2BCB2"), f("White Titanium", "#F2F1ED"), f("Black Titanium", "#3C3C3D")]
    private static let iPhone16e = [white, black]
    private static let iPhone17 = [f("Lavender", "#DFCEEA"), f("Sage", "#A9B689"), f("Mist Blue", "#96AED1"), white, black]
    private static let iPhone17Pro = [f("Cosmic Orange", "#F77E2D"), f("Deep Blue", "#32374A"), silver]
    private static let iPhoneAir = [f("Sky Blue", "#C8DCEE"), f("Light Gold", "#EDDCC0"), f("Cloud White", "#F4F4F2"), spaceBlack]
    private static let iPhone17e = [white, black, f("Soft Pink", "#F1D6D6")]
    private static let iPhone18Pro = [f("Burgundy", "#6D2432"), f("Glacier", "#C9DDEA"), silver, black]

    private static let fallbackFinishes = [
        f("Cosmic Orange", "#F77E2D"), f("Deep Blue", "#32374A"), f("Burgundy", "#6D2432"), f("Glacier", "#C9DDEA"),
        f("Ultramarine", "#9AADF6"), f("Sage", "#A9B689"), f("Pink", "#F2ADDA"), silver,
    ]

    private static let table: [String: Entry] = [
        "iPhone12,1": Entry(name: "iPhone 11", finishes: iPhone11),
        "iPhone12,3": Entry(name: "iPhone 11 Pro", finishes: iPhone11Pro),
        "iPhone12,5": Entry(name: "iPhone 11 Pro Max", finishes: iPhone11Pro),
        "iPhone12,8": Entry(name: "iPhone SE", finishes: [black, white, red]),
        "iPhone13,1": Entry(name: "iPhone 12 mini", finishes: iPhone12),
        "iPhone13,2": Entry(name: "iPhone 12", finishes: iPhone12),
        "iPhone13,3": Entry(name: "iPhone 12 Pro", finishes: iPhone12Pro),
        "iPhone13,4": Entry(name: "iPhone 12 Pro Max", finishes: iPhone12Pro),
        "iPhone14,4": Entry(name: "iPhone 13 mini", finishes: iPhone13),
        "iPhone14,5": Entry(name: "iPhone 13", finishes: iPhone13),
        "iPhone14,2": Entry(name: "iPhone 13 Pro", finishes: iPhone13Pro),
        "iPhone14,3": Entry(name: "iPhone 13 Pro Max", finishes: iPhone13Pro),
        "iPhone14,6": Entry(name: "iPhone SE", finishes: iPhoneSE),
        "iPhone14,7": Entry(name: "iPhone 14", finishes: iPhone14),
        "iPhone14,8": Entry(name: "iPhone 14 Plus", finishes: iPhone14),
        "iPhone15,2": Entry(name: "iPhone 14 Pro", finishes: iPhone14Pro),
        "iPhone15,3": Entry(name: "iPhone 14 Pro Max", finishes: iPhone14Pro),
        "iPhone15,4": Entry(name: "iPhone 15", finishes: iPhone15),
        "iPhone15,5": Entry(name: "iPhone 15 Plus", finishes: iPhone15),
        "iPhone16,1": Entry(name: "iPhone 15 Pro", finishes: iPhone15Pro),
        "iPhone16,2": Entry(name: "iPhone 15 Pro Max", finishes: iPhone15Pro),
        "iPhone17,3": Entry(name: "iPhone 16", finishes: iPhone16),
        "iPhone17,4": Entry(name: "iPhone 16 Plus", finishes: iPhone16),
        "iPhone17,1": Entry(name: "iPhone 16 Pro", finishes: iPhone16Pro),
        "iPhone17,2": Entry(name: "iPhone 16 Pro Max", finishes: iPhone16Pro),
        "iPhone17,5": Entry(name: "iPhone 16e", finishes: iPhone16e),
        "iPhone18,3": Entry(name: "iPhone 17", finishes: iPhone17),
        "iPhone18,1": Entry(name: "iPhone 17 Pro", finishes: iPhone17Pro),
        "iPhone18,2": Entry(name: "iPhone 17 Pro Max", finishes: iPhone17Pro),
        "iPhone18,4": Entry(name: "iPhone Air", finishes: iPhoneAir),
        "iPhone18,5": Entry(name: "iPhone 17e", finishes: iPhone17e),
        "iPhone19,2": Entry(name: "iPhone 18 Pro", finishes: iPhone18Pro),
        "iPhone19,3": Entry(name: "iPhone 18 Pro Max", finishes: iPhone18Pro),
    ]
}
