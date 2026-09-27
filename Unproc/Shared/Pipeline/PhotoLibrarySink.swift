#if UNPROC_APP
import Foundation
import ImageIO
import Photos
import Synchronization
import UniformTypeIdentifiers
import os

/// App sink: one Photos asset per shot — the graded JPEG as the photo and,
/// when shooting RAW, the untouched DNG as its alternate (RAW+JPEG pair).
///
/// Photos is picky about resources (PHPhotosErrorDomain 3300 = "invalid
/// resource"), so saving degrades step by step instead of losing the shot:
///   1. JPEG + DNG pair, from files
///   2. JPEG alone, from a file
///   3. JPEG re-encoded with minimal metadata (no MakerApple etc.)
/// Every attempt and failure is logged under `Log.save`.
final class PhotoLibrarySink: CaptureSink {
    init() {}

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        try await Self.ensureAuthorized()

        let stem = Self.baseName(for: photo.capturedAt)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unproc-save-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let jpegURL = folder.appendingPathComponent(stem + ".JPG")
        do {
            try photo.jpeg.write(to: jpegURL, options: .atomic)
        } catch {
            Log.save.error("save: couldn't stage JPEG: \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed(Log.describe(error))
        }
        var dngURL: URL?
        if let dng = photo.dng {
            let url = folder.appendingPathComponent(stem + ".DNG")
            do {
                try dng.write(to: url, options: .atomic)
                dngURL = url
            } catch {
                Log.save.error("save: couldn't stage DNG, saving JPEG only: \(Log.describe(error), privacy: .public)")
            }
        }
        Log.save.info("save: begin \(stem, privacy: .public) jpeg=\(photo.jpeg.count) dng=\(photo.dng?.count ?? 0)")

        var lastError: Error?

        // 1. JPEG + DNG pair.
        if let dngURL {
            do {
                let id = try await Self.create(photo: jpegURL, raw: dngURL, date: photo.capturedAt)
                Log.save.notice("save: ok (JPEG+DNG) \(id, privacy: .public)")
                return id
            } catch {
                lastError = error
                Log.save.error("save: JPEG+DNG rejected, retrying JPEG only: \(Log.describe(error), privacy: .public)")
            }
        }

        // 2. JPEG alone.
        do {
            let id = try await Self.create(photo: jpegURL, raw: nil, date: photo.capturedAt)
            Log.save.notice("save: ok (JPEG) \(id, privacy: .public)")
            return id
        } catch {
            lastError = error
            Log.save.error("save: JPEG rejected, retrying with clean metadata: \(Log.describe(error), privacy: .public)")
        }

        // 3. JPEG with minimal metadata.
        if let clean = Self.cleanJPEG(photo.jpeg) {
            let cleanURL = folder.appendingPathComponent(stem + "_clean.JPG")
            do {
                try clean.write(to: cleanURL, options: .atomic)
                let id = try await Self.create(photo: cleanURL, raw: nil, date: photo.capturedAt)
                Log.save.notice("save: ok (clean JPEG) \(id, privacy: .public)")
                return id
            } catch {
                lastError = error
                Log.save.error("save: clean JPEG rejected: \(Log.describe(error), privacy: .public)")
            }
        } else {
            Log.save.error("save: couldn't re-encode a clean JPEG")
        }

        let message = lastError.map(Log.describe) ?? "unknown error"
        Log.save.fault("save: all attempts failed: \(message, privacy: .public)")
        throw UnprocError.saveFailed(message)
    }

    /// Saves a lone DNG as its own asset. Used for a lock-screen shot whose
    /// JPEG never got written (extension ended mid-save), so the shot isn't lost.
    func saveRAWOnly(_ dng: Data, capturedAt: Date) async throws -> PhotoItem.ID {
        try await Self.ensureAuthorized()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unproc-save-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(Self.baseName(for: capturedAt) + ".DNG")
        do {
            try dng.write(to: url, options: .atomic)
            let id = try await Self.create(photo: url, raw: nil, date: capturedAt, photoType: Self.rawType)
            Log.save.notice("save: ok (DNG only) \(id, privacy: .public)")
            return id
        } catch {
            Log.save.error("save: DNG-only rejected: \(Log.describe(error), privacy: .public)")
            throw UnprocError.saveFailed(Log.describe(error))
        }
    }

    private static let rawType = "com.adobe.raw-image"

    private static func create(photo: URL, raw: URL?, date: Date, photoType: String = UTType.jpeg.identifier) async throws -> String {
        let result = IdentifierBox()
        let rawType = Self.rawType
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date

            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.originalFilename = photo.lastPathComponent.replacingOccurrences(of: "_clean", with: "")
            photoOptions.uniformTypeIdentifier = photoType
            request.addResource(with: .photo, fileURL: photo, options: photoOptions)

            if let raw {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = raw.lastPathComponent
                rawOptions.uniformTypeIdentifier = rawType
                request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
            }
            result.set(request.placeholderForCreatedAsset?.localIdentifier)
        }
        guard let id = result.get() else {
            throw UnprocError.saveFailed("Photos did not return an asset")
        }
        return id
    }

    /// Re-encodes the JPEG keeping only orientation-free basics (no maker
    /// notes, no GPS/EXIF oddities), in case some metadata upsets Photos.
    static func cleanJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let props: [String: Any] = [
            kCGImagePropertyOrientation as String: 1,
            kCGImageDestinationLossyCompressionQuality as String: 0.93,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFSoftware as String: "unproc"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// `.addOnly` is enough to save; full access (for the viewer) also satisfies it.
    static func ensureAuthorized() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        Log.save.info("save: photos add authorization = \(status.rawValue)")
        switch status {
        case .authorized, .limited:
            return
        default:
            throw UnprocError.notAuthorized
        }
    }

    static func baseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "UNPROC_" + f.string(from: date)
    }
}

/// Carries the placeholder id out of the (possibly `@Sendable`) change block.
private final class IdentifierBox: Sendable {
    private let value = Mutex<String?>(nil)
    func set(_ v: String?) { value.withLock { $0 = v } }
    func get() -> String? { value.withLock { $0 } }
}
#endif
