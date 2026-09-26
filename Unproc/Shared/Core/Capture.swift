import AVFoundation
import CoreImage
import ImageIO

/// Raw result of one exposure from `CameraController`, before any development.
struct CapturedFrame: @unchecked Sendable {
    /// DNG bytes when a RAW was captured (Bayer or ProRAW).
    var rawDNG: Data?
    var rawFlavor: RawFlavor?
    /// Fallback processed image (HEIC/JPEG) when the lens can't do RAW (e.g. front camera).
    var processed: Data?
    /// Capture metadata (EXIF/TIFF/etc.) from `AVCapturePhoto.metadata`.
    var metadata: [String: Any]
    let lens: Lens
    /// Exposure the frame was actually taken at, for display/logging.
    var exposureDuration: Double?
    var iso: Float?
    let capturedAt: Date
}

/// A finished photo, ready to be written somewhere.
struct DevelopedPhoto: @unchecked Sendable {
    /// Final graded JPEG (orientation baked in, metadata attached).
    let jpeg: Data
    /// Original DNG to store alongside, if the user shoots RAW.
    let dng: Data?
    let capturedAt: Date
}

/// Where developed photos go. The app writes into Photos; the lock-screen
/// extension writes into its session content directory.
protocol CaptureSink: Sendable {
    /// Returns an identifier the viewer can use to locate the new item.
    func save(_ photo: DevelopedPhoto) async throws -> PhotoItem.ID
}

enum UnprocError: LocalizedError {
    case cameraUnavailable
    case notAuthorized
    case captureFailed(String)
    case developFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "Camera unavailable"
        case .notAuthorized: "Access not granted"
        case .captureFailed(let s): "Capture failed: \(s)"
        case .developFailed(let s): "Develop failed: \(s)"
        case .saveFailed(let s): "Save failed: \(s)"
        }
    }
}
