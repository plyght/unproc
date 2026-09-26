import Foundation

/// Lock-screen sink: writes into the capture extension's session content
/// directory, which the app imports into Photos after unlock.
///
/// Files: `<yyyyMMdd-HHmmss-SSS>.dng` (if any) first, then `.jpg`, both
/// written atomically, so a `.jpg` on disk always means a complete shot and
/// its DNG (if any) is already there. Returns the JPEG's path as the item id.
final class SessionContentSink: CaptureSink {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        let root = self.root
        return try await Task.detached(priority: .userInitiated) {
            try Self.write(photo, into: root)
        }.value
    }

    private static func write(_ photo: DevelopedPhoto, into root: URL) throws -> PhotoItem.ID {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw UnprocError.saveFailed("Could not create folder: \(error.localizedDescription)")
        }

        // Never overwrite an earlier shot: suffix on (very unlikely) collision.
        let stem = baseName(for: photo.capturedAt)
        var name = stem
        var n = 1
        while fm.fileExists(atPath: root.appendingPathComponent(name + ".jpg").path)
                || fm.fileExists(atPath: root.appendingPathComponent(name + ".dng").path) {
            name = "\(stem)-\(n)"
            n += 1
        }

        let jpgURL = root.appendingPathComponent(name + ".jpg")
        if let dng = photo.dng {
            let dngURL = root.appendingPathComponent(name + ".dng")
            do {
                try dng.write(to: dngURL, options: .atomic)
            } catch {
                throw UnprocError.saveFailed("DNG: \(error.localizedDescription)")
            }
        }
        do {
            try photo.jpeg.write(to: jpgURL, options: .atomic)
        } catch {
            // One retry: transient I/O hiccups shouldn't cost a shot.
            do {
                try photo.jpeg.write(to: jpgURL, options: .atomic)
            } catch {
                throw UnprocError.saveFailed("JPEG: \(error.localizedDescription)")
            }
        }
        return jpgURL.path
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
