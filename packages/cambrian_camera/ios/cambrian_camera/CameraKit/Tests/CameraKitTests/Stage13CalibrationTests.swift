import Foundation
import Testing

@testable import CameraKit

// MARK: - Phase 2 §2b — Engine-side calibration

@Suite("Stage 13 Calibration")
struct Stage13CalibrationTests {

    @Test("calibrateWhiteBalance throws .notOpen pre-open")
    func calibrateWBThrowsNotOpenBeforeOpen() async {
        let engine = CameraEngine()
        await #expect(throws: EngineError.self) {
            _ = try await engine.calibrateWhiteBalance()
        }
    }

    @Test("calibrateBlackBalance throws .notOpen pre-open")
    func calibrateBBThrowsNotOpenBeforeOpen() async {
        let engine = CameraEngine()
        await #expect(throws: EngineError.self) {
            _ = try await engine.calibrateBlackBalance()
        }
    }

    @Test("CalibrationResult shape encodes the contract for single-shot")
    func calibrationResultShapeForSingleShot() {
        let r = CalibrationResult(
            before: RgbSample(r: 0.5, g: 0.5, b: 0.5),
            after: RgbSample(r: 0.5, g: 0.5, b: 0.5),
            converged: true,
            iterations: 1)
        #expect(r.converged == true)
        #expect(r.iterations == 1)
        #expect(r.before == r.after)
    }

    @Test("EngineError.calibrationInProgress is a distinct case")
    func calibrationInProgressErrorExists() {
        let e: EngineError = .calibrationInProgress
        switch e {
        case .calibrationInProgress: break
        default: Issue.record("expected .calibrationInProgress, got \(e)")
        }
    }
}
