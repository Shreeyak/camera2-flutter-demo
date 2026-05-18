import Flutter
import Foundation

/// Stub HostApi impl — Plan 1 deliverable. Every method returns
/// `PigeonError(code: "not_implemented", ...)`. Plan 2 replaces each body
/// with a real CameraEngine call via the handle registry.
final class CameraHostApiImpl: CameraHostApi {

    // All HostApi methods follow the same shape — each returns a Pigeon
    // not_implemented error. The exact list is regenerated at the end of
    // Cluster B (every §5 amendment that adds a method updates this file).

    func open(cameraId: String?, settings: CamSettings?,
              completion: @escaping (Result<Int64, Error>) -> Void) {
        completion(.failure(notImplemented("open")))
    }

    func getCapabilities(handle: Int64,
                         completion: @escaping (Result<CamCapabilities, Error>) -> Void) {
        completion(.failure(notImplemented("getCapabilities")))
    }

    func updateSettings(handle: Int64, settings: CamSettings) throws {
        throw notImplemented("updateSettings")
    }

    func setResolution(handle: Int64, width: Int64, height: Int64,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("setResolution")))
    }

    func setProcessingParams(handle: Int64, params: CamProcessingParams) throws {
        throw notImplemented("setProcessingParams")
    }

    func captureNaturalPicture(handle: Int64, outputDirectory: String?, fileName: String?,
                               destination: CamPhotosDestination?,
                               completion: @escaping (Result<CamCaptureResult, Error>) -> Void) {
        completion(.failure(notImplemented("captureNaturalPicture")))
    }

    func captureImage(handle: Int64, outputDirectory: String?, fileName: String?,
                      destination: CamPhotosDestination?,
                      completion: @escaping (Result<CamCaptureResult, Error>) -> Void) {
        completion(.failure(notImplemented("captureImage")))
    }

    func getNativePipelineHandle(handle: Int64,
                                 completion: @escaping (Result<Int64?, Error>) -> Void) {
        completion(.failure(notImplemented("getNativePipelineHandle")))
    }

    func startRecording(handle: Int64, outputDirectory: String?, fileName: String?,
                        bitrate: Int64?, fps: Int64?,
                        completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("startRecording")))
    }

    func stopRecording(handle: Int64,
                       completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(notImplemented("stopRecording")))
    }

    func close(handle: Int64,
               completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("close")))
    }

    func pause(handle: Int64,
               completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("pause")))
    }

    func resume(handle: Int64,
                completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(notImplemented("resume")))
    }

    func getPersistedProcessingParams(handle: Int64) throws -> CamProcessingParams? {
        throw notImplemented("getPersistedProcessingParams")
    }

    func sampleCenterPatch(handle: Int64,
                           completion: @escaping (Result<CamRgbSample, Error>) -> Void) {
        completion(.failure(notImplemented("sampleCenterPatch")))
    }

    private func notImplemented(_ name: String) -> PigeonError {
        PigeonError(code: "not_implemented",
                    message: "\(name) is not yet implemented in Phase 3 Plan 1.",
                    details: nil)
    }
}
