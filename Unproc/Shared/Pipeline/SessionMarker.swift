import Foundation
import os

/// Small JSON sidecars next to a lock-screen shot in the session content
/// directory (`<stem>.jpg` / `<stem>.dng`):
///
/// - `<stem>.saved`: the extension already saved this shot straight to Photos
///   (asset `localIdentifier` inside). The app's importer must not import it
///   again; it only cleans the files up.
/// - `<stem>.deleted`: the shot was saved to Photos and then deleted in the
///   lock-screen viewer. The image files are gone; the marker stays until the
///   app (foreground) has deleted the asset from the library.
///
/// Markers are written atomically (temp file + rename), so a marker on disk is
/// always complete. Pure file-system code, shared by the app and the extension.
enum SessionMarker {
    enum Kind: String, CaseIterable, Sendable {
        case saved
        case deleted
    }

    struct Record: Codable, Equatable, Sendable {
        /// `PHAsset.localIdentifier` of the asset in the library.
        var localIdentifier: String
        /// When the marker was written.
        var date: Date
    }

    /// What `markSaved` ended up writing.
    enum SavedOutcome: Equatable, Sendable {
        /// `.saved` written; the shot is still in the session.
        case saved
        /// The shot was deleted in the viewer while it was being saved to
        /// Photos: a `.deleted` marker was written instead.
        case deleted
    }

    // MARK: - Naming

    /// Marker URL for a shot file (`.jpg` or `.dng`) or for its stem.
    static func url(_ kind: Kind, forShot shot: URL) -> URL {
        let stem = isShotFile(shot) || isMarker(shot) ? shot.deletingPathExtension() : shot
        return stem.appendingPathExtension(kind.rawValue)
    }

    static func kind(of url: URL) -> Kind? {
        Kind(rawValue: url.pathExtension.lowercased())
    }

    static func isMarker(_ url: URL) -> Bool {
        kind(of: url) != nil
    }

    private static func isShotFile(_ url: URL) -> Bool {
        ["jpg", "jpeg", "dng"].contains(url.pathExtension.lowercased())
    }

    // MARK: - Encoding

    static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    /// Nil for anything that isn't a well-formed record with an identifier.
    static func decode(_ data: Data) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data),
              !record.localIdentifier.isEmpty else { return nil }
        return record
    }

    // MARK: - Files

    static func exists(_ kind: Kind, forShot shot: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(kind, forShot: shot).path)
    }

    static func read(_ kind: Kind, forShot shot: URL) -> Record? {
        read(at: url(kind, forShot: shot))
    }

    static func read(at marker: URL) -> Record? {
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return decode(data)
    }

    static func write(_ record: Record, _ kind: Kind, forShot shot: URL) throws {
        let target = url(kind, forShot: shot)
        try encode(record).write(to: target, options: .atomic)
    }

    /// Records that `shot` (its JPEG) is in Photos as `localIdentifier`.
    /// If the JPEG was deleted in the meantime (viewer delete during the
    /// save), writes a `.deleted` marker instead so the app removes the asset.
    @discardableResult
    static func markSaved(localIdentifier: String, forShot shot: URL, now: Date = Date()) throws -> SavedOutcome {
        let record = Record(localIdentifier: localIdentifier, date: now)
        try write(record, .saved, forShot: shot)
        if FileManager.default.fileExists(atPath: shot.path) {
            return .saved
        }
        // Deleted while we were saving: the viewer couldn't see a `.saved`
        // marker yet, so convert it ourselves.
        try convertToDeleted(forShot: shot, record: record)
        return .deleted
    }

    /// After a viewer delete of `shot`: if it was already in Photos, replaces
    /// its `.saved` marker with a `.deleted` one. Returns the identifier, or nil
    /// if the shot was never saved to Photos (nothing more to do).
    @discardableResult
    static func markDeletedIfSaved(forShot shot: URL, now: Date = Date()) throws -> String? {
        let savedURL = url(.saved, forShot: shot)
        guard FileManager.default.fileExists(atPath: savedURL.path) else { return nil }
        guard let saved = read(at: savedURL) else {
            // Unreadable: we can't name the asset, so there's nothing to delete.
            Log.lockscreen.error("marker: unreadable \(savedURL.lastPathComponent, privacy: .public), removing")
            try? FileManager.default.removeItem(at: savedURL)
            return nil
        }
        try convertToDeleted(forShot: shot, record: Record(localIdentifier: saved.localIdentifier, date: now))
        return saved.localIdentifier
    }

    private static func convertToDeleted(forShot shot: URL, record: Record) throws {
        try write(record, .deleted, forShot: shot)
        let savedURL = url(.saved, forShot: shot)
        if FileManager.default.fileExists(atPath: savedURL.path) {
            try? FileManager.default.removeItem(at: savedURL)
        }
    }
}
