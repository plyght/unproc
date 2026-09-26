import AVFoundation
import Foundation
import os

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
        let id = photo.resolvedSettings.uniqueID
        if let error {
            Log.capture.error("delegate: id=\(id, privacy: .public) photo raw=\(photo.isRawPhoto, privacy: .public) error: \(Log.describe(error), privacy: .public)")
            if firstError == nil { firstError = error }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            Log.capture.error("delegate: id=\(id, privacy: .public) photo raw=\(photo.isRawPhoto, privacy: .public) has no fileDataRepresentation")
            if firstError == nil { firstError = UnprocError.captureFailed("No image data") }
            return
        }
        let dims = photo.resolvedSettings.photoDimensions
        let rawDims = photo.resolvedSettings.rawPhotoDimensions
        let pixelFormat = photo.pixelBuffer.map { CameraLogText.fourCC(CVPixelBufferGetPixelFormatType($0)) } ?? "n/a"
        Log.capture.info("delegate: id=\(id, privacy: .public) photo raw=\(photo.isRawPhoto, privacy: .public) bytes=\(data.count, privacy: .public) dims=\(CameraLogText.dims(photo.isRawPhoto ? rawDims : dims), privacy: .public) pixelFormat=\(pixelFormat, privacy: .public) metaKeys=\(photo.metadata.count, privacy: .public)")
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
        let id = resolvedSettings.uniqueID
        guard !finished else {
            lock.unlock()
            Log.capture.fault("delegate: id=\(id, privacy: .public) didFinishCapture called twice")
            return
        }
        finished = true
        if let error {
            Log.capture.error("delegate: id=\(id, privacy: .public) finish error: \(Log.describe(error), privacy: .public)")
        }
        let result: Result<Output, Error>
        if let error = error ?? firstError, collected.raw == nil, collected.processed == nil {
            result = .failure(UnprocError.captureFailed(error.localizedDescription))
        } else if collected.raw == nil, collected.processed == nil {
            result = .failure(UnprocError.captureFailed("Capture produced no photo"))
        } else {
            result = .success(collected)
        }
        if case .failure(let failure) = result {
            Log.capture.error("delegate: id=\(id, privacy: .public) capture failed: \(Log.describe(failure), privacy: .public)")
        } else if error != nil || firstError != nil {
            Log.capture.notice("delegate: id=\(id, privacy: .public) partial success despite error raw=\(self.collected.raw != nil, privacy: .public) processed=\(self.collected.processed != nil, privacy: .public)")
        }
        lock.unlock()
        completion(result)
    }
}
