import Foundation
import Testing
import UniformTypeIdentifiers

@testable import CameraKit

// MARK: - ImageFileFormat (extension → format mapping)

@Suite("ImageFileFormat", .progressLogged)
struct ImageFileFormatTests {

    @Test("parse maps supported extensions case-insensitively")
    func parseSupportedExtensions() {
        #expect(ImageFileFormat.parse(extension: "png") == .png)
        #expect(ImageFileFormat.parse(extension: "PNG") == .png)
        #expect(ImageFileFormat.parse(extension: "jpg") == .jpeg)
        #expect(ImageFileFormat.parse(extension: "JPG") == .jpeg)
        #expect(ImageFileFormat.parse(extension: "jpeg") == .jpeg)
        #expect(ImageFileFormat.parse(extension: "JPEG") == .jpeg)
        #expect(ImageFileFormat.parse(extension: "tif") == .tiff)
        #expect(ImageFileFormat.parse(extension: "tiff") == .tiff)
        #expect(ImageFileFormat.parse(extension: "TIFF") == .tiff)
    }

    @Test("parse returns nil for unsupported extensions")
    func parseUnsupportedExtensions() {
        #expect(ImageFileFormat.parse(extension: "gif") == nil)
        #expect(ImageFileFormat.parse(extension: "heic") == nil)
        #expect(ImageFileFormat.parse(extension: "bmp") == nil)
        #expect(ImageFileFormat.parse(extension: "") == nil)
    }

    @Test("utType matches the format")
    func utTypeMapping() {
        #expect(ImageFileFormat.png.utType == .png)
        #expect(ImageFileFormat.jpeg.utType == .jpeg)
        #expect(ImageFileFormat.tiff.utType == .tiff)
    }

    @Test("only JPEG carries a lossy quality, fixed to the high-quality default")
    func lossyQuality() {
        #expect(ImageFileFormat.jpeg.lossyQuality == Constants.jpegCaptureQuality)
        #expect(ImageFileFormat.png.lossyQuality == nil)
        #expect(ImageFileFormat.tiff.lossyQuality == nil)
    }

    @Test("the no-name default is PNG")
    func defaultIsPng() {
        #expect(ImageFileFormat.defaultFormat == .png)
        #expect(ImageFileFormat.defaultExtension == "png")
    }
}

// MARK: - OutputPathResolver.image

@Suite("OutputPathResolver.image", .progressLogged)
struct OutputPathResolverImageTests {

    @Test("nil outputURL → <Documents>/<timestamp>.png, PNG, no colons in filename")
    func nilDefaultsToPng() throws {
        let (url, format) = try OutputPathResolver.image(nil)
        #expect(format == .png)
        #expect(url.pathExtension == "png")
        #expect(url.path.hasPrefix(URL.documentsDirectory.path))
        // Bug-history note: ISO-8601 colons cannot land in filenames — Files.app
        // and AirDrop trip on them.
        #expect(!url.lastPathComponent.contains(":"))
        #expect(url.path.hasPrefix(NSHomeDirectory()))
    }

    @Test("extension selects the format (case-insensitive)")
    func extensionSelectsFormat() throws {
        #expect(try OutputPathResolver.image(URL(string: "a.png")).format == .png)
        #expect(try OutputPathResolver.image(URL(string: "a.PNG")).format == .png)
        #expect(try OutputPathResolver.image(URL(string: "a.jpg")).format == .jpeg)
        #expect(try OutputPathResolver.image(URL(string: "a.jpeg")).format == .jpeg)
        #expect(try OutputPathResolver.image(URL(string: "a.JPEG")).format == .jpeg)
        #expect(try OutputPathResolver.image(URL(string: "a.tif")).format == .tiff)
        #expect(try OutputPathResolver.image(URL(string: "a.tiff")).format == .tiff)
    }

    @Test("filename-only URL drops into Documents; caller extension wins")
    func filenameOnlyLandsInDocuments() throws {
        let (url, format) = try OutputPathResolver.image(URL(string: "photo.jpg"))
        #expect(url.path == URL.documentsDirectory.appendingPathComponent("photo.jpg").path)
        #expect(format == .jpeg)
    }

    @Test("absolute URL inside sandbox is used as-is")
    func absoluteSandboxURLUsedAsIs() throws {
        let input = URL.documentsDirectory.appendingPathComponent("custom-name.tiff")
        let (url, format) = try OutputPathResolver.image(input)
        #expect(url.path == input.path)
        #expect(format == .tiff)
    }

    @Test("FileManager.temporaryDirectory URL (/private/var/... symlink form) is accepted")
    func sandboxTmpSymlinkAccepted() throws {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        let (url, format) = try OutputPathResolver.image(input)
        #expect(url.path == input.path)
        #expect(format == .tiff)
        #expect(input.path.hasPrefix("/private/var/"))
    }

    @Test("name with no extension throws StillCaptureError.missingFileExtension")
    func missingExtensionThrows() {
        do {
            _ = try OutputPathResolver.image(URL(string: "photo"))
            Issue.record("Expected missingFileExtension, got success")
        } catch StillCaptureError.missingFileExtension(let name) {
            #expect(name == "photo")
        } catch {
            Issue.record("Expected StillCaptureError.missingFileExtension, got \(error)")
        }
    }

    @Test("unsupported extension throws StillCaptureError.unsupportedImageFormat")
    func unsupportedExtensionThrows() {
        do {
            _ = try OutputPathResolver.image(URL(string: "photo.gif"))
            Issue.record("Expected unsupportedImageFormat, got success")
        } catch StillCaptureError.unsupportedImageFormat(let ext) {
            #expect(ext == "gif")
        } catch {
            Issue.record("Expected StillCaptureError.unsupportedImageFormat, got \(error)")
        }
    }

    @Test("absolute URL outside the sandbox throws EngineError.invalidOutputPath")
    func sandboxEscapeThrows() {
        let input = URL(fileURLWithPath: "/tmp/eva-test.png")
        do {
            _ = try OutputPathResolver.image(input)
            Issue.record("Expected invalidOutputPath, got success")
        } catch EngineError.invalidOutputPath(let bad) {
            #expect(bad.path == input.path)
        } catch {
            Issue.record("Expected EngineError.invalidOutputPath, got \(error)")
        }
    }
}

// MARK: - OutputPathResolver.video

@Suite("OutputPathResolver.video", .progressLogged)
struct OutputPathResolverVideoTests {

    @Test("nil outputURL → <Documents>/<timestamp>.mp4, no colons in filename")
    func nilDefaultsToMp4() throws {
        let url = try OutputPathResolver.video(nil)
        #expect(url.pathExtension == "mp4")
        #expect(url.path.hasPrefix(URL.documentsDirectory.path))
        #expect(!url.lastPathComponent.contains(":"))
        #expect(url.path.hasPrefix(NSHomeDirectory()))
    }

    @Test("filename-only .mp4 drops into Documents")
    func filenameOnlyLandsInDocuments() throws {
        let url = try OutputPathResolver.video(URL(string: "clip.mp4"))
        #expect(url.path == URL.documentsDirectory.appendingPathComponent("clip.mp4").path)
    }

    @Test(".MP4 is accepted (case-insensitive)")
    func mp4CaseInsensitive() throws {
        let url = try OutputPathResolver.video(URL(string: "clip.MP4"))
        #expect(url.lastPathComponent == "clip.MP4")
    }

    @Test("subdirectory auto-creates intermediate directories")
    func subdirectoryAutoCreated() throws {
        let unique = "OPRTest-\(UUID().uuidString)"
        let input = URL.documentsDirectory
            .appendingPathComponent(unique)
            .appendingPathComponent("video-01.mp4")
        let url = try OutputPathResolver.video(input)
        #expect(url.path == input.path)
        let parentExists = FileManager.default.fileExists(
            atPath: input.deletingLastPathComponent().path
        )
        #expect(parentExists, "expected auto-create of \(input.deletingLastPathComponent().path)")
        try? FileManager.default.removeItem(
            at: URL.documentsDirectory.appendingPathComponent(unique)
        )
    }

    @Test("name with no extension throws RecordingError.missingFileExtension")
    func missingExtensionThrows() {
        do {
            _ = try OutputPathResolver.video(URL(string: "clip"))
            Issue.record("Expected missingFileExtension, got success")
        } catch RecordingError.missingFileExtension(let name) {
            #expect(name == "clip")
        } catch {
            Issue.record("Expected RecordingError.missingFileExtension, got \(error)")
        }
    }

    @Test("non-mp4 extension throws RecordingError.unsupportedVideoFormat")
    func unsupportedExtensionThrows() {
        do {
            _ = try OutputPathResolver.video(URL(string: "clip.mov"))
            Issue.record("Expected unsupportedVideoFormat, got success")
        } catch RecordingError.unsupportedVideoFormat(let ext) {
            #expect(ext == "mov")
        } catch {
            Issue.record("Expected RecordingError.unsupportedVideoFormat, got \(error)")
        }
    }

    @Test("absolute URL outside the sandbox throws EngineError.invalidOutputPath")
    func sandboxEscapeThrows() {
        let input = URL(fileURLWithPath: "/tmp/eva-test.mp4")
        do {
            _ = try OutputPathResolver.video(input)
            Issue.record("Expected invalidOutputPath, got success")
        } catch EngineError.invalidOutputPath(let bad) {
            #expect(bad.path == input.path)
        } catch {
            Issue.record("Expected EngineError.invalidOutputPath, got \(error)")
        }
    }
}
