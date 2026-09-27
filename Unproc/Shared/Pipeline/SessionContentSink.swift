import Foundation
import os

/// Lock-screen sink: writes into the capture extension's session content
/// directory, which the app imports into Photos after unlock.
///
/// Files: `<yyyyMMdd-HHmmss-SSS>-<uuid8>.dng` (if any) first, then `.jpg`,
/// both written atomically (temp file + rename), so a `.jpg` on disk always
/// means a complete shot and its DNG (if any) is already there. Returns the
/// JPEG's path as the item id.
final class SessionContentSink: CaptureSink {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        // A nonisolated async method on a non-actor class runs on the global
        // concurrent executor in Swift 5 mode, so this file I/O is already off
        // the main actor. No extra task is needed.
        try Self.write(photo, into: root)
    }

    private static func write(_ photo: DevelopedPhoto, into root: URL) throws -> PhotoItem.ID {
        let fm = FileManager.default
        Log.save.info("session sink: write jpeg=\(photo.jpeg.count, privacy: .public)B dng=\(photo.dng?.count ?? 0, privacy: .public)B into \(root.path, privacy: .public)")
        if !fm.fileExists(atPath: root.path) {
            // The session directory is created by the system. If it's gone,
            // the app may have released (invalidated) it; a shot written into
            // a re-created folder is never reported to the app, so say so loudly.
            Log.save.notice("session sink: content folder missing, re-creating \(root.path, privacy: .public)")
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.save.error("session sink: create folder failed \(root.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed("Could not create folder: \(error.localizedDescription)")
        }

        // Unique per shot: two shots in the same millisecond (or two presses
        // saving concurrently) must never overwrite each other.
        var name = fileStem(for: photo.capturedAt)
        while fm.fileExists(atPath: root.appendingPathComponent(name + ".jpg").path)
                || fm.fileExists(atPath: root.appendingPathComponent(name + ".dng").path) {
            Log.save.notice("session sink: name collision on \(name, privacy: .public)")
            name = fileStem(for: photo.capturedAt)
        }

        let jpgURL = root.appendingPathComponent(name + ".jpg")
        if let dng = photo.dng {
            let dngURL = root.appendingPathComponent(name + ".dng")
            do {
                try dng.write(to: dngURL, options: .atomic)
                Log.save.info("session sink: wrote \(dngURL.lastPathComponent, privacy: .public) \(dng.count, privacy: .public)B")
            } catch {
                // Keep going: the JPEG is the photo; losing it over the RAW would be worse.
                Log.save.error("session sink: DNG write failed, saving JPEG only \(dngURL.path, privacy: .public): \(Log.describe(error), privacy: .public)")
                try? fm.removeItem(at: dngURL)
            }
        }
        do {
            try photo.jpeg.write(to: jpgURL, options: .atomic)
        } catch {
            Log.save.error("session sink: JPEG write failed, retrying \(jpgURL.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            // One retry: transient I/O hiccups shouldn't cost a shot.
            do {
                try photo.jpeg.write(to: jpgURL, options: .atomic)
            } catch {
                Log.save.error("session sink: JPEG retry failed \(jpgURL.path, privacy: .public): \(Log.describe(error), privacy: .public)")
                throw UnprocError.saveFailed("JPEG: \(error.localizedDescription)")
            }
        }
        Log.save.notice("session sink: wrote \(jpgURL.path, privacy: .public) \(photo.jpeg.count, privacy: .public)B")
        return jpgURL.path
    }

    /// `<yyyyMMdd-HHmmss-SSS>-<8 hex>`: sorts by time, parses back to the
    /// capture date (first 19 characters), and is unique per shot.
    static func fileStem(for date: Date) -> String {
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return baseName(for: date) + "-" + tag
    }

    static func baseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}
