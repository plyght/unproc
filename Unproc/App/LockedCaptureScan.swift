import Foundation

/// Pure, file-system-only logic behind `LockedCaptureImporter`: what is in a
/// lock-screen session content directory, what is safe to import, and when the
/// directory may be released. No Photos, no LockedCameraCapture, so it's unit
/// testable.
enum LockedCaptureScan {
    /// A finished shot: the JPEG and, when shooting RAW, its DNG sibling.
    struct Pair: Sendable, Equatable {
        let jpeg: URL
        let dng: URL?
    }

    /// A shot the extension already saved to Photos (`.saved` marker): never
    /// imported, only cleaned up.
    struct SavedShot: Sendable, Equatable {
        let marker: URL
        /// Nil if the marker couldn't be parsed (still counts as saved:
        /// importing it again would duplicate it).
        let localIdentifier: String?
        /// Its remaining image files, DNG before JPEG (delete in this order).
        let files: [URL]
    }

    /// A shot deleted in the lock-screen viewer after it was saved to Photos
    /// (`.deleted` marker): the app deletes the asset, then the marker.
    struct Deletion: Sendable, Equatable {
        let marker: URL
        /// Nil if unreadable (nothing can be deleted; the marker is dropped).
        let localIdentifier: String?
        /// Everything else left for that stem (stray `.saved` marker or image
        /// files a failed delete left behind): removed with the marker, never imported.
        let leftovers: [URL]
    }

    struct Contents: Sendable {
        /// JPEGs that look complete (+ DNG sibling if present), oldest first,
        /// not saved to Photos yet: to be imported.
        var pairs: [Pair] = []
        /// Complete JPEGs without a `.saved` marker younger than
        /// `directSaveGrace`: the extension may still be saving them to Photos
        /// itself, so importing now could duplicate them. Retried later.
        var awaitingDirectSave: [Pair] = []
        /// Already in Photos: skip, just clean up.
        var saved: [SavedShot] = []
        /// Asset deletions requested from the lock-screen viewer.
        var deletions: [Deletion] = []
        /// JPEGs that look truncated or empty and are younger than the grace
        /// period: probably still being written, retried later.
        var pendingJPEGs: [URL] = []
        /// DNGs without a JPEG. Normally a shot whose JPEG is being written
        /// right now; if old, a shot whose JPEG never arrived.
        var orphanDNGs: [URL] = []
        /// Newest sign of life in the directory: newest file modification
        /// (including hidden temp files of in-progress atomic writes), or the
        /// directory's creation date when it's empty.
        var lastActivity: Date = .distantPast

        var isEmpty: Bool {
            pairs.isEmpty && pendingJPEGs.isEmpty && orphanDNGs.isEmpty
                && awaitingDirectSave.isEmpty && saved.isEmpty && deletions.isEmpty
        }
    }

    /// A JPEG that doesn't look complete is only imported once it's been left
    /// alone this long (atomic writes make this unlikely; this is a backstop).
    static let suspectJPEGGrace: TimeInterval = 60

    /// The extension writes the session files first and then saves to Photos
    /// (usually well under a few seconds). A marker-less JPEG younger than this
    /// is left alone so a shot taken right before unlocking isn't imported twice.
    static let directSaveGrace: TimeInterval = 45

    // MARK: - Scanning

    /// Synchronous on purpose: directory enumerators can't be iterated in an
    /// async context. Returns nil if the directory can't be read.
    static func scan(_ dir: URL, now: Date = Date(), directSaveGrace: TimeInterval = LockedCaptureScan.directSaveGrace) -> Contents? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [])
        else { return nil }

        var contents = Contents()
        let dirValues = try? dir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        contents.lastActivity = dirValues?.creationDate ?? dirValues?.contentModificationDate ?? .distantPast

        var jpegs: [String: URL] = [:]
        var dngs: [String: URL] = [:]
        var savedMarkers: [String: URL] = [:]
        var deletedMarkers: [String: URL] = [:]
        var modified: [URL: Date] = [:]
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let mtime = values?.contentModificationDate ?? values?.creationDate
            if let mtime { contents.lastActivity = max(contents.lastActivity, mtime) }
            if file.lastPathComponent.hasPrefix(".") {
                // Temp file of an atomic write in progress (or other hidden
                // bookkeeping): counts as activity, never imported.
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            modified[file] = mtime
            let base = file.deletingPathExtension().path
            switch file.pathExtension.lowercased() {
            case "jpg", "jpeg": jpegs[base] = file
            case "dng": dngs[base] = file
            default:
                switch SessionMarker.kind(of: file) {
                case .some(.saved): savedMarkers[base] = file
                case .some(.deleted): deletedMarkers[base] = file
                case .none: break
                }
            }
        }

        // Deleted in the lock-screen viewer: never imported, whatever is left.
        for base in deletedMarkers.keys.sorted() {
            let marker = deletedMarkers[base]!
            let leftovers = [dngs[base], jpegs[base], savedMarkers[base]].compactMap { $0 }
            contents.deletions.append(Deletion(marker: marker,
                                               localIdentifier: SessionMarker.read(at: marker)?.localIdentifier,
                                               leftovers: leftovers))
            jpegs[base] = nil
            dngs[base] = nil
            savedMarkers[base] = nil
        }

        // Already in Photos: never imported.
        for base in savedMarkers.keys.sorted() {
            let marker = savedMarkers[base]!
            let files = [dngs[base], jpegs[base]].compactMap { $0 }
            contents.saved.append(SavedShot(marker: marker,
                                            localIdentifier: SessionMarker.read(at: marker)?.localIdentifier,
                                            files: files))
            jpegs[base] = nil
            dngs[base] = nil
        }

        for base in jpegs.keys.sorted() {
            let jpeg = jpegs[base]!
            let age = now.timeIntervalSince(modified[jpeg] ?? .distantPast)
            if isCompleteJPEG(at: jpeg) {
                let pair = Pair(jpeg: jpeg, dng: dngs[base])
                if age < directSaveGrace {
                    contents.awaitingDirectSave.append(pair)
                } else {
                    contents.pairs.append(pair)
                }
            } else if age >= suspectJPEGGrace {
                contents.pairs.append(Pair(jpeg: jpeg, dng: dngs[base]))
            } else {
                contents.pendingJPEGs.append(jpeg)
            }
        }
        contents.orphanDNGs = dngs.keys.sorted().filter { jpegs[$0] == nil }.map { dngs[$0]! }
        return contents
    }

    // MARK: - JPEG completeness

    /// Starts with SOI (FF D8) and has an EOI (FF D9) near the end.
    static func isCompleteJPEG(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(2))
        guard bytes == [0xFF, 0xD8] else { return false }
        return hasEOI(in: [UInt8](data.suffix(64)))
    }

    static func isCompleteJPEG(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 4 else { return false }
        do {
            try handle.seek(toOffset: 0)
            guard let head = try handle.read(upToCount: 2), [UInt8](head) == [0xFF, 0xD8] else { return false }
            let tailLength = min(size, 64)
            try handle.seek(toOffset: size - tailLength)
            guard let tail = try handle.read(upToCount: Int(tailLength)) else { return false }
            return hasEOI(in: [UInt8](tail))
        } catch {
            return false
        }
    }

    /// Some encoders pad after the EOI marker, so look for it in the tail
    /// rather than only in the very last two bytes.
    private static func hasEOI(in tail: [UInt8]) -> Bool {
        guard tail.count >= 2 else { return false }
        for i in stride(from: tail.count - 2, through: 0, by: -1) where tail[i] == 0xFF && tail[i + 1] == 0xD9 {
            return true
        }
        return false
    }

    // MARK: - Naming / bookkeeping

    /// Stable id of a session directory. The full path isn't stable: the app
    /// container path can change across app updates.
    static func sessionID(_ dir: URL) -> String {
        dir.standardizedFileURL.lastPathComponent
    }

    static func doneKey(session dir: URL, file: URL) -> String {
        sessionID(dir) + "|" + file.lastPathComponent
    }

    /// Converts a v1 key ("<full session path>|<file>") to the v2 form.
    static func migrateLegacyKey(_ key: String) -> String? {
        guard let bar = key.lastIndex(of: "|") else { return nil }
        let path = String(key[..<bar])
        let file = String(key[key.index(after: bar)...])
        guard !path.isEmpty, !file.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent + "|" + file
    }

    /// Capture date from a `SessionContentSink` file name
    /// (`yyyyMMdd-HHmmss-SSS[-suffix].ext`), if it has that form.
    static func captureDate(fromName name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.count >= 19 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.date(from: String(stem.prefix(19)))
    }

    // MARK: - Releasing the session

    enum Release: Equatable {
        /// Safe to invalidate the session content now.
        case invalidate
        /// Everything is imported, but the session was active recently; check
        /// again after this many seconds.
        case wait(TimeInterval)
        /// Don't invalidate (reason for the log).
        case keep(String)
    }

    /// Invalidating a session deletes its directory. If the lock-screen
    /// extension is still using it, every later shot written there is lost
    /// for good (the system no longer reports that directory). So we only
    /// release a session when nothing un-imported is left, the app is in the
    /// foreground (device unlocked, so no lock-screen capture can be running)
    /// and nothing has been written there for a while.
    static func release(unimported: Int, appActive: Bool, lastActivity: Date, now: Date, quietPeriod: TimeInterval) -> Release {
        if unimported > 0 { return .keep("\(unimported) item(s) not imported yet") }
        if !appActive { return .keep("app not in foreground") }
        let idle = now.timeIntervalSince(lastActivity)
        if idle < quietPeriod { return .wait(max(1, quietPeriod - idle)) }
        return .invalidate
    }
}
