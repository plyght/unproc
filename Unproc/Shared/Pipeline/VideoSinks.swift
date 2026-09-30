import Foundation
import os
#if UNPROC_APP
import Photos
import Synchronization
import UniformTypeIdentifiers
#endif

// Saving finished recordings. Video mode exists only in the app (the
// lock-screen extension is photos only), but the local folder sink is also
// what the Simulator / CI demo uses.

extension SessionContentSink {
    /// Moves the movie into the folder as `<yyyyMMdd-HHmmss-SSS>-<uuid8>.mov`.
    func saveVideo(at url: URL, capturedAt: Date) async throws -> PhotoItem.ID {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.save.error("session sink: create folder for video failed \(self.root.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed("Could not create folder: \(error.localizedDescription)")
        }
        let target = root.appendingPathComponent(Self.fileStem(for: capturedAt) + ".mov")
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            Log.save.error("session sink: video move failed \(url.lastPathComponent, privacy: .public) -> \(target.path, privacy: .public): \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed("Video: \(error.localizedDescription)")
        }
        let bytes = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.intValue ?? -1
        Log.save.notice("session sink: wrote video \(target.path, privacy: .public) \(bytes, privacy: .public)B")
        return target.path
    }
}

#if UNPROC_APP
extension PhotoLibrarySink {
    /// Adds the movie to Photos as a video asset (add-only access is enough),
    /// then deletes the temporary file.
    func saveVideo(at url: URL, capturedAt: Date) async throws -> PhotoItem.ID {
        try await Self.ensureAuthorized(prompt: promptForAccess)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
        let name = Self.baseName(for: capturedAt) + ".MOV"
        Log.save.info("save: video begin \(name, privacy: .public) \(bytes, privacy: .public)B from \(url.lastPathComponent, privacy: .public)")
        let result = VideoIdentifierBox()
        let location = LocationProvider.shared.recentLocation
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = capturedAt
                request.location = location
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = name
                options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                request.addResource(with: .video, fileURL: url, options: options)
                result.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            Log.save.error("save: video rejected: \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed(Log.describe(error))
        }
        guard let id = result.get() else {
            Log.save.error("save: video saved but Photos returned no asset id")
            throw UnprocError.saveFailed("Photos did not return an asset")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.save.error("save: couldn't delete temporary video \(url.lastPathComponent, privacy: .public): \(Log.describe(error), privacy: .public)")
        }
        Log.save.notice("save: ok (video) \(id, privacy: .public)")
        return id
    }
}

/// Carries the placeholder id out of the change block.
private final class VideoIdentifierBox: Sendable {
    private let value = Mutex<String?>(nil)
    func set(_ v: String?) { value.withLock { $0 = v } }
    func get() -> String? { value.withLock { $0 } }
}
#endif
