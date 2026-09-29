import Foundation
import os

/// Lock-screen sink: writes into the capture extension's session content
/// directory (what the lock-screen viewer shows) and, when the extension has
/// Photos add access (inherited from the app), also saves the shot straight to
/// the library, even while the device is locked.
///
/// Files: `<yyyyMMdd-HHmmss-SSS>-<uuid8>.dng` (if any) first, then `.jpg`,
/// both written atomically (temp file + rename), so a `.jpg` on disk always
/// means a complete shot and its DNG (if any) is already there. After Photos
/// confirmed the save, a `<stem>.saved` marker (see `SessionMarker`) tells the
/// app's importer the shot is already in the library. Without the marker (no
/// access, save failed, extension killed mid-save) the app imports the files
/// after unlock as before. Returns the JPEG's path as the item id.
final class SessionContentSink: CaptureSink {
    let root: URL
    /// Direct-to-Photos saver; nil to only write session files.
    let library: (any CaptureSink)?

    init(root: URL, library: (any CaptureSink)? = nil) {
        self.root = root
        self.library = library
    }

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        // A nonisolated async method on a non-actor class runs on the global
        // concurrent executor in Swift 5 mode, so this file I/O is already off
        // the main actor. No extra task is needed.
        //
        // Session files first (fast; the viewer and the app's fallback import
        // rely on them), then Photos right away. The caller holds an expiring
        // activity across this whole call, so locking the phone right after
        // the shot still lets both finish.
        let id = try Self.write(photo, into: root)
        if let library {
            await Self.saveToLibrary(photo, jpeg: URL(fileURLWithPath: id), library: library)
        }
        return id
    }

    /// Never throws: the shot is already safe in the session directory, and a
    /// missing `.saved` marker makes the app import it after unlock.
    private static func saveToLibrary(_ photo: DevelopedPhoto, jpeg: URL, library: any CaptureSink) async {
        let name = jpeg.lastPathComponent
        let began = Date()
        Log.lockscreen.info("direct save: begin \(name, privacy: .public)")
        let assetID: String
        do {
            assetID = try await library.save(photo)
        } catch {
            let ms = Int((Date().timeIntervalSince(began) * 1000).rounded())
            Log.lockscreen.error("direct save: failed after \(ms, privacy: .public)ms, app will import \(name, privacy: .public) after unlock: \(Log.describe(error), privacy: .public)")
            return
        }
        let ms = Int((Date().timeIntervalSince(began) * 1000).rounded())
        Log.lockscreen.notice("direct save: \(name, privacy: .public) in Photos as \(assetID, privacy: .public) after \(ms, privacy: .public)ms")
        do {
            switch try SessionMarker.markSaved(localIdentifier: assetID, forShot: jpeg) {
            case .saved:
                Log.lockscreen.info("direct save: marked \(name, privacy: .public) saved")
            case .deleted:
                Log.lockscreen.notice("direct save: \(name, privacy: .public) was deleted during the save, marked for deletion from Photos")
            }
        } catch {
            // Worst case the app imports it again (a duplicate), never a loss.
            Log.lockscreen.error("direct save: couldn't write marker for \(name, privacy: .public): \(Log.describe(error), privacy: .public)")
        }
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
                || fm.fileExists(atPath: root.appendingPathComponent(name + ".dng").path)
                || SessionMarker.Kind.allCases.contains(where: { fm.fileExists(atPath: root.appendingPathComponent(name + "." + $0.rawValue).path) }) {
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
