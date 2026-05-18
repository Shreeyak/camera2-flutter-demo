import Foundation
import Photos
import Testing

@testable import CameraKit

// MARK: - PhotosLibraryClient.resolve

@Suite("PhotosLibraryClient.resolve", .progressLogged)
struct PhotosLibraryClientResolveTests {

    @Test("nil outputURL returns <Documents>/<timestamp>.<ext> with no colons in filename")
    func nilOutputURLAutoNames() throws {
        let url = try PhotosLibraryClient.resolve(outputURL: nil, defaultExt: "mp4")
        #expect(url.path.hasPrefix(URL.documentsDirectory.path))
        #expect(url.pathExtension == "mp4")
        // Bug-history note: ISO-8601 colons cannot land in filenames — Files.app
        // and AirDrop trip on them.
        #expect(!url.lastPathComponent.contains(":"))
        // Sandbox guarantee.
        #expect(url.path.hasPrefix(NSHomeDirectory()))
    }

    @Test("nil outputURL with .tif ext lands inside Documents")
    func nilOutputURLRespectsDefaultExt() throws {
        let url = try PhotosLibraryClient.resolve(outputURL: nil, defaultExt: "tif")
        #expect(url.pathExtension == "tif")
    }

    @Test("filename-only URL drops into Documents; defaultExt is ignored")
    func filenameOnlyURLLandsInDocuments() throws {
        let input = URL(string: "video.mp4")
        let url = try PhotosLibraryClient.resolve(outputURL: input, defaultExt: "tif")
        #expect(url.path == URL.documentsDirectory.appendingPathComponent("video.mp4").path)
        // Caller's extension wins.
        #expect(url.pathExtension == "mp4")
    }

    @Test("absolute URL inside sandbox is used as-is")
    func absoluteSandboxURLIsUsedAsIs() throws {
        let input = URL.documentsDirectory.appendingPathComponent("custom-name.mp4")
        let url = try PhotosLibraryClient.resolve(outputURL: input, defaultExt: "mp4")
        #expect(url.path == input.path)
    }

    @Test("URL with subdirectory auto-creates intermediate directories")
    func subdirectoryAutoCreated() throws {
        let unique = "PLCTest-\(UUID().uuidString)"
        let input = URL.documentsDirectory
            .appendingPathComponent(unique)
            .appendingPathComponent("video-01.mp4")
        let url = try PhotosLibraryClient.resolve(outputURL: input, defaultExt: "mp4")
        #expect(url.path == input.path)
        let parentExists = FileManager.default.fileExists(
            atPath: input.deletingLastPathComponent().path
        )
        #expect(parentExists, "expected resolve to auto-create \(input.deletingLastPathComponent().path)")
        // Cleanup
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent(unique)
        )
    }

    @Test("FileManager.temporaryDirectory URL (/private/var/... symlink form) is accepted")
    func sandboxTmpDirectorySymlinkAccepted() throws {
        // NSHomeDirectory() returns /var/mobile/Containers/Data/Application/<UUID>,
        // but FileManager.temporaryDirectory canonicalizes through the /private
        // root symlink and returns /private/var/mobile/... — both point at the
        // same physical directory inside the sandbox. The hasPrefix(home) check
        // must accept either form (regression test for the Stage07
        // still-capture-in-flight-guard / Stage 12 sweep finding).
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        let url = try PhotosLibraryClient.resolve(outputURL: input, defaultExt: "tif")
        #expect(url.path == input.path)
        // Sanity — the URL really does carry the /private/var/... shape we're
        // asserting works, otherwise this test isn't covering the regression.
        #expect(input.path.hasPrefix("/private/var/"))
    }

    @Test("absolute URL outside the app sandbox throws EngineError.invalidOutputPath")
    func sandboxEscapeThrows() {
        let input = URL(fileURLWithPath: "/tmp/eva-test.mp4")
        do {
            _ = try PhotosLibraryClient.resolve(outputURL: input, defaultExt: "mp4")
            Issue.record("Expected invalidOutputPath, got success")
        } catch EngineError.invalidOutputPath(let bad) {
            #expect(bad.path == input.path)
        } catch {
            Issue.record("Expected EngineError.invalidOutputPath, got \(error)")
        }
    }
}

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
        _ = await rec.stop(reason: .user)
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
        _ = await rec.stop(reason: .user)
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
        #expect(start.uri == custom.absoluteString)
        _ = await rec.stop(reason: .user)
    }
}
