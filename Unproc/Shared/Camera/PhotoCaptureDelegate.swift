import AVFoundation
import Foundation

/// Collects the output of one `capturePhoto(with:delegate:)` call and reports it
/// once, when AVFoundation says the whole capture is finished.
///
/// The engine keeps each instance alive in a dictionary keyed by
/// `AVCapturePhotoSettings.uniqueID` until `completion` has run.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    struct Output: @unchecked Sendable {
        var raw: Data?
        var processed: Data?
        var metadata: [String: Any] = [:]
    }

    private let lock = NSLock()
    private var collected = Output()
    private var firstError: Error?
    private var finished = false
    private let completion: (Result<Output, Error>) -> Void

    init(completion: @escaping (Result<Output, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            if firstError == nil { firstError = error }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            if firstError == nil { firstError = UnprocError.captureFailed("No image data") }
            return
        }
        if photo.isRawPhoto {
            collected.raw = data
            // The RAW's metadata describes the sensor exposure: prefer it.
            collected.metadata = photo.metadata
        } else {
            collected.processed = data
            if collected.metadata.isEmpty { collected.metadata = photo.metadata }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result: Result<Output, Error>
        if let error = error ?? firstError, collected.raw == nil, collected.processed == nil {
            result = .failure(UnprocError.captureFailed(error.localizedDescription))
        } else if collected.raw == nil, collected.processed == nil {
            result = .failure(UnprocError.captureFailed("Capture produced no photo"))
        } else {
            result = .success(collected)
        }
        lock.unlock()
        completion(result)
    }
}
