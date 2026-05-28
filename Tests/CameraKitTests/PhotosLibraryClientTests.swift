import Foundation
import Photos
import Testing

@testable import CameraKit

// NOTE: Output-path/format resolution tests moved to
// `OutputPathResolutionTests.swift` when `PhotosLibraryClient.resolve` was
// extracted into `OutputPathResolver`. This file now covers Photos `describe`
// and the Recording ↔ PhotosDestination integration only.

// MARK: - PhotosLibraryClient.describe

@Suite("PhotosLibraryClient.describe", .progressLogged)
struct PhotosLibraryClientDescribeTests {

    private func phError(_ code: PHPhotosError.Code) -> NSError {
        NSError(domain: PHPhotosError.errorDomain, code: code.rawValue)
    }

    @Test("accessUserDenied → typed name + Settings hint")
    func accessUserDeniedHinted() {
        let result = PhotosLibraryClient.describe(phError(.accessUserDenied))
        #expect(result.contains("PHPhotosError.accessUserDenied"))
        #expect(result.contains("Settings"))
    }

    @Test("accessRestricted → typed name + Screen-Time/MDM hint")
    func accessRestrictedHinted() {
        let result = PhotosLibraryClient.describe(phError(.accessRestricted))
        #expect(result.contains("PHPhotosError.accessRestricted"))
        #expect(result.lowercased().contains("screen time") || result.contains("MDM"))
    }

    @Test("invalidResource → typed name")
    func invalidResourceNamed() {
        let result = PhotosLibraryClient.describe(phError(.invalidResource))
        #expect(result.contains("PHPhotosError.invalidResource"))
    }

    @Test("networkAccessRequired → typed name + iCloud mention")
    func networkAccessRequiredHinted() {
        let result = PhotosLibraryClient.describe(phError(.networkAccessRequired))
        #expect(result.contains("PHPhotosError.networkAccessRequired"))
        #expect(result.lowercased().contains("icloud"))
    }

    @Test("unknown PHPhotos code falls through with raw code")
    func unknownPHPhotosCodeFallsThrough() {
        let unknown = NSError(domain: PHPhotosError.errorDomain, code: 999_999)
        let result = PhotosLibraryClient.describe(unknown)
        #expect(result.contains("PHPhotosError.code=999999"))
    }

    @Test("non-Photos NSError falls back to bare domain + code + description")
    func nonPhotosErrorFallsBack() {
        let foreign = NSError(
            domain: "com.example.Test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "foreign-error"]
        )
        let result = PhotosLibraryClient.describe(foreign)
        #expect(result.contains("com.example.Test"))
        #expect(result.contains("42"))
        #expect(result.contains("foreign-error"))
        #expect(!result.contains("PHPhotosError"))
    }
}

// MARK: - Recording + PhotosDestination integration

@Suite("Recording + PhotosDestination", .progressLogged)
struct RecordingPhotosDestinationTests {

    @Test("Recording.start stores options.photosDestination for engine readback")
    func recordingCapturesPhotosDestination() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let hooks = Recording.Hooks(
            publishState: { _ in },
            emitError: { _ in Issue.record("unexpected error") }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(photosDestination: .copy),
            captureSize: Size(width: 1920, height: 1080)
        )
        #expect(await rec.photosDestination == .copy)
        _ = await rec.stop()
    }

    @Test("Recording.start defaults photosDestination to .none")
    func recordingDefaultsPhotosDestinationToNone() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let hooks = Recording.Hooks(
            publishState: { _ in },
            emitError: { _ in Issue.record("unexpected error") }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 1920, height: 1080)
        )
        #expect(await rec.photosDestination == .none)
        _ = await rec.stop()
    }

    @Test("Recording.start with sandbox-escape outputURL throws EngineError.invalidOutputPath")
    func recordingStartRejectsSandboxEscape() async {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let hooks = Recording.Hooks(
            publishState: { _ in },
            emitError: { _ in }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        do {
            _ = try await rec.start(
                options: RecordingOptions(outputURL: URL(fileURLWithPath: "/tmp/eva-test.mp4")),
                captureSize: Size(width: 1920, height: 1080)
            )
            Issue.record("Expected invalidOutputPath, got success")
        } catch EngineError.invalidOutputPath(let bad) {
            #expect(bad.path == "/tmp/eva-test.mp4")
        } catch {
            Issue.record("Expected EngineError.invalidOutputPath, got \(error)")
        }
    }

    @Test("Recording.start uses lastPathComponent of resolved URL as displayName")
    func recordingDisplayNameMatchesResolvedFilename() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let hooks = Recording.Hooks(
            publishState: { _ in },
            emitError: { _ in Issue.record("unexpected error") }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        let custom = URL.documentsDirectory.appendingPathComponent("custom-recording.mp4")
        let start = try await rec.start(
            options: RecordingOptions(outputURL: custom),
            captureSize: Size(width: 1920, height: 1080)
        )
        #expect(start.displayName == "custom-recording.mp4")
        #expect(start.uri == custom.path)
        _ = await rec.stop()
    }
}
