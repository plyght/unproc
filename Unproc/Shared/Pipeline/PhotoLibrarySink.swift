#if UNPROC_APP
import Foundation
import Photos
import Synchronization
import UniformTypeIdentifiers

/// App sink: one Photos asset per shot — the graded JPEG as the photo and,
/// when shooting RAW, the untouched DNG as its alternate (RAW+JPEG pair).
final class PhotoLibrarySink: CaptureSink {
    init() {}

    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID {
        try await Self.ensureAuthorized()

        let stem = Self.baseName(for: photo.capturedAt)
        let result = IdentifierBox()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = photo.capturedAt

                let jpegOptions = PHAssetResourceCreationOptions()
                jpegOptions.originalFilename = stem + ".JPG"
                jpegOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                request.addResource(with: .photo, data: photo.jpeg, options: jpegOptions)

                if let dng = photo.dng {
                    let dngOptions = PHAssetResourceCreationOptions()
                    dngOptions.originalFilename = stem + ".DNG"
                    dngOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                    request.addResource(with: .alternatePhoto, data: dng, options: dngOptions)
                }
                result.set(request.placeholderForCreatedAsset?.localIdentifier)
            }
        } catch {
            throw UnprocError.saveFailed(error.localizedDescription)
        }
        guard let id = result.get() else {
            throw UnprocError.saveFailed("Photos did not return an asset")
        }
        return id
    }

    /// `.addOnly` is enough to save; full access (for the viewer) also satisfies it.
    static func ensureAuthorized() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
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
