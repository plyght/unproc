import Foundation
import LockedCameraCapture
import Photos
import UIKit
import os

/// Moves photos taken from the Lock Screen (written by the capture extension
/// into its session content directories) into the Photos library, then
/// releases those directories.
///
/// When it runs: at launch, on every scene activation, when the app is opened
/// from the extension, and for every `sessionContentUpdates` event while the
/// app is alive. All entry points funnel into one per-session serial queue:
/// a request for a session that is already importing is remembered and run
/// again right after, so nothing written mid-import is skipped.
///
/// Safety rules:
/// - A file is only deleted after Photos confirmed the save. Anything that
///   fails stays put and is retried on the next sweep.
/// - Saved files are also remembered by name, so a failed delete never
///   produces duplicates in Photos.
/// - A session directory is only invalidated when nothing un-imported is left,
///   the app is in the foreground, and nothing was written there for a while
///   (see `LockedCaptureScan.release`): invalidating a directory the extension
///   is still writing to would lose every later shot.
/// - Without Photos access nothing is dropped; the import waits for access.
@MainActor
final class LockedCaptureImporter {
    static let shared = LockedCaptureImporter()

    /// Called after at least one photo was imported (e.g. to reload the viewer).
    var onImport: (@MainActor () async -> Void)?

    /// How long a session must have been left alone before it's released.
    static let quietPeriod: TimeInterval = 90
    /// A DNG whose JPEG hasn't appeared after this long is imported on its own.
    static let orphanGrace: TimeInterval = 10 * 60

    private let sink = PhotoLibrarySink()
    /// Session ids currently importing.
    private var inFlight: Set<String> = []
    /// Session ids asked for again while importing: run once more afterwards.
    private var rerun: Set<String> = []
    /// Deferred re-checks (e.g. waiting out the quiet period), by session id.
    private var retries: [String: Task<Void, Never>] = [:]
    private var observeTask: Task<Void, Never>?

    private static let importedKey = "unproc.lockedImport.done.v2"
    private static let legacyImportedKey = "unproc.lockedImport.done.v1"

    private init() {
        migrateBookkeeping()
    }

    /// Imports everything currently waiting. Safe to call repeatedly and concurrently.
    static func importPending(reason: String = "sweep") {
        shared.importPending(reason: reason)
    }

    func importPending(reason: String = "sweep") {
        let urls = LockedCameraCaptureManager.shared.sessionContentURLs
        Log.lockscreen.info("import: sweep (\(reason, privacy: .public)) sessions=\(urls.count, privacy: .public)")
        for url in urls { importSession(at: url, reason: reason) }
    }

    /// Watches for new session content for the app's lifetime.
    func startObserving() {
        guard observeTask == nil else { return }
        Log.lockscreen.info("import: observing session content updates")
        observeTask = Task { @MainActor [weak self] in
            for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
                guard let self else { return }
                switch update {
                case .initial(let urls):
                    Log.lockscreen.info("import: update initial sessions=\(urls.count, privacy: .public)")
                    for url in urls { self.importSession(at: url, reason: "initial") }
                case .added(let url):
                    Log.lockscreen.notice("import: update added \(url.lastPathComponent, privacy: .public)")
                    self.importSession(at: url, reason: "added")
                case .removed:
                    Log.lockscreen.info("import: update removed")
                @unknown default:
                    Log.lockscreen.info("import: unknown session content update")
                }
            }
            Log.lockscreen.notice("import: session content updates ended")
            self?.observeTask = nil
        }
    }

    // MARK: - Scheduling

    private func importSession(at url: URL, reason: String) {
        let dir = url.standardizedFileURL
        let id = LockedCaptureScan.sessionID(dir)
        guard !inFlight.contains(id) else {
            rerun.insert(id)
            Log.lockscreen.debug("import: session \(id, privacy: .public) busy, queued another pass (\(reason, privacy: .public))")
            return
        }
        inFlight.insert(id)
        retries.removeValue(forKey: id)?.cancel()
        Task { @MainActor in
            await self.run(session: dir, reason: reason)
            self.inFlight.remove(id)
            if self.rerun.remove(id) != nil {
                self.importSession(at: dir, reason: "rerun")
            }
        }
    }

    private func retry(_ dir: URL, after seconds: TimeInterval, why: String) {
        let id = LockedCaptureScan.sessionID(dir)
        retries[id]?.cancel()
        Log.lockscreen.info("import: re-check \(id, privacy: .public) in \(Int(seconds.rounded(.up)), privacy: .public)s (\(why, privacy: .public))")
        retries[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.retries.removeValue(forKey: id)
            self.importSession(at: dir, reason: "retry")
        }
    }

    private var appActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    // MARK: - Import

    private func run(session dir: URL, reason: String) async {
        let id = LockedCaptureScan.sessionID(dir)
        guard let first = await Self.scanOffMain(dir) else {
            if FileManager.default.fileExists(atPath: dir.path) {
                Log.lockscreen.error("import: session \(id, privacy: .public) unreadable, retry later \(dir.path, privacy: .public)")
                retry(dir, after: 30, why: "unreadable")
            } else {
                Log.lockscreen.info("import: session \(id, privacy: .public) no longer exists")
            }
            return
        }
        let withDNG = first.pairs.filter { $0.dng != nil }.count
        let active = appActive
        Log.lockscreen.notice("import: session \(id, privacy: .public) (\(reason, privacy: .public)) photos=\(first.pairs.count, privacy: .public) withDNG=\(withDNG, privacy: .public) pendingJPEG=\(first.pendingJPEGs.count, privacy: .public) orphanDNG=\(first.orphanDNGs.count, privacy: .public) active=\(active, privacy: .public)")

        var done = loadDone()
        let now = Date()
        let dueOrphans = first.orphanDNGs.filter { now.timeIntervalSince(Self.modified($0) ?? now) >= Self.orphanGrace }
        let toImport = first.pairs.filter { !done.contains(LockedCaptureScan.doneKey(session: dir, file: $0.jpeg)) }.count
            + dueOrphans.filter { !done.contains(LockedCaptureScan.doneKey(session: dir, file: $0)) }.count

        var importedAny = false
        var authorized = true
        if toImport > 0 {
            authorized = await ensurePhotosAccess(pending: toImport)
        }

        if authorized {
            for pair in first.pairs {
                if await importPair(pair, session: dir, done: &done) { importedAny = true }
                if !authorizedNow() { authorized = false; break }
            }
        }
        if authorized {
            for dng in dueOrphans {
                if await importOrphan(dng, session: dir, done: &done) { importedAny = true }
            }
        }
        if importedAny { await onImport?() }

        // Delete what's safely in Photos (foreground only: the lock-screen
        // extension may still be showing these in its own viewer otherwise).
        if appActive {
            removeImportedFiles(first, session: dir, done: done)
        }

        // Release the session if nothing's left for it.
        guard let after = await Self.scanOffMain(dir) else { return }
        let unimported = after.pairs.filter { !done.contains(LockedCaptureScan.doneKey(session: dir, file: $0.jpeg)) }.count
            + after.orphanDNGs.filter { !done.contains(LockedCaptureScan.doneKey(session: dir, file: $0)) }.count
            + after.pendingJPEGs.count
        let decision = LockedCaptureScan.release(
            unimported: unimported,
            appActive: appActive,
            lastActivity: max(first.lastActivity, after.lastActivity),
            now: Date(),
            quietPeriod: Self.quietPeriod
        )
        switch decision {
        case .keep(let why):
            Log.lockscreen.notice("import: keeping session \(id, privacy: .public): \(why, privacy: .public)")
            if !after.pendingJPEGs.isEmpty {
                retry(dir, after: LockedCaptureScan.suspectJPEGGrace, why: "JPEG still being written")
            } else if !after.orphanDNGs.isEmpty, authorized {
                retry(dir, after: Self.orphanGrace, why: "DNG waiting for its JPEG")
            }
        case .wait(let seconds):
            retry(dir, after: seconds, why: "session used recently")
        case .invalidate:
            await invalidate(dir)
        }
    }

    /// Imports one JPEG (+DNG). Returns true if it was saved now.
    private func importPair(_ pair: LockedCaptureScan.Pair, session dir: URL, done: inout Set<String>) async -> Bool {
        let key = LockedCaptureScan.doneKey(session: dir, file: pair.jpeg)
        let name = pair.jpeg.lastPathComponent
        guard !done.contains(key) else {
            Log.lockscreen.debug("import: \(name, privacy: .public) already imported")
            return false
        }
        do {
            let photo = try await Self.load(pair)
            Log.lockscreen.info("import: saving \(name, privacy: .public) jpeg=\(photo.jpeg.count, privacy: .public)B dng=\(photo.dng?.count ?? 0, privacy: .public)B")
            let assetID = try await sink.save(photo)
            done.insert(key)
            saveDone(done)
            Log.lockscreen.notice("import: saved \(name, privacy: .public) as \(assetID, privacy: .public)")
            return true
        } catch {
            Log.lockscreen.error("import: failed \(name, privacy: .public), kept for next sweep: \(Log.describe(error), privacy: .public)")
            return false
        }
    }

    /// Imports a DNG whose JPEG never arrived, as a RAW-only asset.
    private func importOrphan(_ dng: URL, session dir: URL, done: inout Set<String>) async -> Bool {
        let key = LockedCaptureScan.doneKey(session: dir, file: dng)
        let name = dng.lastPathComponent
        guard !done.contains(key) else { return false }
        do {
            let data = try await Self.read(dng)
            let date = LockedCaptureScan.captureDate(fromName: name) ?? Self.modified(dng) ?? Date()
            Log.lockscreen.notice("import: orphan DNG \(name, privacy: .public) \(data.count, privacy: .public)B, saving RAW only")
            let assetID = try await sink.saveRAWOnly(data, capturedAt: date)
            done.insert(key)
            saveDone(done)
            Log.lockscreen.notice("import: saved orphan \(name, privacy: .public) as \(assetID, privacy: .public)")
            return true
        } catch {
            Log.lockscreen.error("import: orphan \(name, privacy: .public) failed, kept: \(Log.describe(error), privacy: .public)")
            return false
        }
    }

    private func removeImportedFiles(_ contents: LockedCaptureScan.Contents, session dir: URL, done: Set<String>) {
        let fm = FileManager.default
        var files: [URL] = []
        for pair in contents.pairs where done.contains(LockedCaptureScan.doneKey(session: dir, file: pair.jpeg)) {
            // DNG first: a JPEG on disk must never be left without it if we stop halfway.
            if let dng = pair.dng { files.append(dng) }
            files.append(pair.jpeg)
        }
        files += contents.orphanDNGs.filter { done.contains(LockedCaptureScan.doneKey(session: dir, file: $0)) }
        for file in files where fm.fileExists(atPath: file.path) {
            do {
                try fm.removeItem(at: file)
                Log.lockscreen.info("import: removed imported \(file.lastPathComponent, privacy: .public)")
            } catch {
                // Bookkeeping still prevents a second import.
                Log.lockscreen.error("import: couldn't remove \(file.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
        }
    }

    private func invalidate(_ dir: URL) async {
        let id = LockedCaptureScan.sessionID(dir)
        do {
            try await LockedCameraCaptureManager.shared.invalidateSessionContent(at: dir)
            // Session content is gone: forget its bookkeeping.
            let prefix = id + "|"
            saveDone(loadDone().filter { !$0.hasPrefix(prefix) })
            Log.lockscreen.notice("import: session invalidated \(id, privacy: .public)")
        } catch {
            Log.lockscreen.error("import: invalidate failed \(dir.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            // Keep the content and the bookkeeping; retried next time.
        }
    }

    // MARK: - Photos access

    /// Makes sure we can add to Photos. Asks when undetermined, but only in the
    /// foreground (a prompt can't show otherwise); the next activation retries.
    private func ensurePhotosAccess(pending: Int) async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            guard appActive else {
                Log.lockscreen.notice("import: Photos access undetermined, waiting for foreground (\(pending, privacy: .public) pending)")
                return false
            }
            Log.lockscreen.notice("import: requesting Photos add access (\(pending, privacy: .public) pending)")
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        switch status {
        case .authorized, .limited:
            return true
        default:
            Log.lockscreen.error("import: no Photos access (status \(status.rawValue, privacy: .public)); keeping \(pending, privacy: .public) lock-screen photo(s) until access is granted")
            return false
        }
    }

    private func authorizedNow() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    // MARK: - Files (off the main actor)
    // `nonisolated async` (Swift 5 mode): runs on the global executor, so big
    // DNG reads never block the main actor.

    private nonisolated static func scanOffMain(_ dir: URL) async -> LockedCaptureScan.Contents? {
        LockedCaptureScan.scan(dir)
    }

    private nonisolated static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private nonisolated static func load(_ pair: LockedCaptureScan.Pair) async throws -> DevelopedPhoto {
        let jpeg: Data
        var dng: Data?
        do {
            jpeg = try Data(contentsOf: pair.jpeg, options: .mappedIfSafe)
        } catch {
            Log.lockscreen.error("import: read failed \(pair.jpeg.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
            throw error
        }
        if let url = pair.dng {
            do {
                dng = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                // The JPEG is the photo; don't lose it over an unreadable DNG.
                Log.lockscreen.error("import: DNG unreadable, importing JPEG only \(url.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
            }
        }
        let date = LockedCaptureScan.captureDate(fromName: pair.jpeg.lastPathComponent)
            ?? modified(pair.jpeg) ?? Date()
        return DevelopedPhoto(jpeg: jpeg, dng: dng, capturedAt: date)
    }

    private nonisolated static func modified(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    // MARK: - Bookkeeping

    private func loadDone() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    private func saveDone(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: Self.importedKey)
    }

    /// v1 keyed by full session path, which changes when the app container
    /// moves (e.g. after an update) and would re-import leftovers.
    private func migrateBookkeeping() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.stringArray(forKey: Self.legacyImportedKey) else { return }
        let migrated = legacy.compactMap(LockedCaptureScan.migrateLegacyKey)
        saveDone(loadDone().union(migrated))
        defaults.removeObject(forKey: Self.legacyImportedKey)
        Log.lockscreen.info("import: migrated \(migrated.count, privacy: .public) bookkeeping entries")
    }
}
