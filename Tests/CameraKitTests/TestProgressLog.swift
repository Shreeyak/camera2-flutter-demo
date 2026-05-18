import Foundation
import Testing

@testable import CameraKit

/// Swift Testing trait that logs each test's start and finish to the
/// CameraKit file log.
///
/// A hung or crashed test is pinpointed by the last `[test] ▶ <name>` with
/// no matching `[test] ✓` / `[test] ✗`. `FileHandle.write` is synchronous,
/// so the `▶` line survives even a hard process crash. Applied to every
/// `@Suite` in CameraKitTests via `.progressLogged`; tail it live with
/// `scripts/device-log-live.sh grep '\[test\]'`.
struct TestProgressLog: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // A recursive suite trait also scopes the suite node itself; only
        // leaf test functions get the ▶/✓ treatment.
        guard !test.isSuite else {
            try await function()
            return
        }
        let name = test.name
        CameraKitLog.notice(.test, "▶ \(name)")
        let start = Date()
        do {
            try await function()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            CameraKitLog.notice(.test, "✓ \(name) (\(ms)ms)")
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            CameraKitLog.notice(.test, "✗ \(name) (\(ms)ms) — \(error)")
            throw error
        }
    }
}

extension Trait where Self == TestProgressLog {
    /// Logs `[test] ▶/✓/✗ <name>` for every test in the annotated suite.
    static var progressLogged: Self { TestProgressLog() }
}
