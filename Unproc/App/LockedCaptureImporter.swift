import Foundation
import LockedCameraCapture

/// Moves photos taken from the Lock Screen (written by the capture extension
/// into its session content directories) into the Photos library, then
/// releases those directories.
///
/// Safety rule: a session directory is only invalidated once *every* photo in
/// it has been saved. Anything that fails stays put and is retried on the next
/// launch / activation. Files already saved are remembered, so a failed
/// invalidation never produces duplicates in Photos.
@MainActor
final class LockedCaptureImporter {
    static let shared = LockedCaptureImporter()

    /// Called after at least one photo was imported (e.g. to reload the viewer).
    var onImport: (@MainActor () async -> Void)?

    private let sink = PhotoLibrarySink()
    private var inFlight: Set<URL> = []
    private var observeTask: Task<Void, Never>?

    private static let importedKey = "unproc.lockedImport.done.v1"

    private init() {}

    /// Imports everything currently waiting. Safe to call repeatedly.
    static func importPending() {
        shared.importPending()
    }

    func importPending() {
        let urls = LockedCameraCaptureManager.shared.sessionContentURLs
        for url in urls { importSession(at: url) }
    }

    /// Watches for new session content while the app is running.
    func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { @MainActor [weak self] in
            for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
                guard let self else { return }
                switch update {
                case .initial(let urls):
                    for url in urls { self.importSession(at: url) }
                case .added(let url):
                    self.importSession(at: url)
                case .removed:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - Import

    private func importSession(at url: URL) {
        let key = url.standardizedFileURL
        guard inFlight.insert(key).inserted else { return }
        Task { @MainActor in
            defer { self.inFlight.remove(key) }
            await self.run(session: key)
        }
    }

    private func run(session dir: URL) async {
        let found = await Self.findPhotos(in: dir)
        guard let found else { return }  // unreadable right now: retry later

        var done = loadDone()
        var allSaved = true
        var importedAny = false

        for pair in found.pairs {
            let doneKey = Self.doneKey(session: dir, file: pair.jpeg)
            if done.contains(doneKey) { continue }
            do {
                let photo = try await Self.load(pair)
                _ = try await sink.save(photo)
                done.insert(doneKey)
                saveDone(done)
                importedAny = true
            } catch {
                allSaved = false
            }
        }

        if importedAny { await onImport?() }
        guard allSaved, !found.hasOrphans else { return }

        do {
            try await LockedCameraCaptureManager.shared.invalidateSessionContent(at: dir)
            // Session content is gone: forget its bookkeeping.
            let prefix = Self.sessionPrefix(dir)
            saveDone(loadDone().filter { !$0.hasPrefix(prefix) })
        } catch {
            // Keep the content and the bookkeeping; retried next time.
        }
    }

    // MARK: - Files
    // `nonisolated async` (Swift 5 mode): runs on the global executor, so big
    // DNG reads never block the main actor.

    struct PhotoPair: Sendable {
        let jpeg: URL
        let dng: URL?
    }

    struct SessionPhotos: Sendable {
        var pairs: [PhotoPair]
        /// DNGs without a matching JPEG (e.g. a write that never finished).
        /// We don't know how to import them, so we don't throw them away either.
        var hasOrphans: Bool
    }

    private nonisolated static func findPhotos(in dir: URL) async -> SessionPhotos? {
        scan(dir)
    }

    /// Synchronous on purpose: directory enumerators can't be iterated in an async context.
    private nonisolated static func scan(_ dir: URL) -> SessionPhotos? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var jpegs: [String: URL] = [:]
        var dngs: [String: URL] = [:]
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let base = file.deletingPathExtension().path
            switch file.pathExtension.lowercased() {
            case "jpg", "jpeg": jpegs[base] = file
            case "dng": dngs[base] = file
            default: break
            }
        }

        let pairs = jpegs.keys.sorted().map { base in
            PhotoPair(jpeg: jpegs[base]!, dng: dngs[base])
        }
        let orphans = dngs.keys.contains { jpegs[$0] == nil }
        return SessionPhotos(pairs: pairs, hasOrphans: orphans)
    }

    private nonisolated static func load(_ pair: PhotoPair) async throws -> DevelopedPhoto {
        let jpeg = try Data(contentsOf: pair.jpeg, options: .mappedIfSafe)
        let dng = try pair.dng.map { try Data(contentsOf: $0, options: .mappedIfSafe) }
        let values = try? pair.jpeg.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
        return DevelopedPhoto(jpeg: jpeg, dng: dng, capturedAt: date)
    }

    // MARK: - Bookkeeping

    private nonisolated static func sessionPrefix(_ dir: URL) -> String {
        dir.standardizedFileURL.path + "|"
    }

    private nonisolated static func doneKey(session dir: URL, file: URL) -> String {
        sessionPrefix(dir) + file.lastPathComponent
    }

    private func loadDone() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
    }

    private func saveDone(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: Self.importedKey)
    }
}
