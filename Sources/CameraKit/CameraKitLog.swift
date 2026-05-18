import OSLog

/// Centralised logging for CameraKit.
///
/// Off by default. Set `CameraKitLog.isEnabled = true` early in your app
/// (e.g. `App.init`) to enable output in Console.app and the on-device log file.
public enum CameraKitLog {
    // Master switch — write once at app init before any CameraKit actor runs.
    // nonisolated(unsafe): safe because startup write precedes all concurrent reads.
    public nonisolated(unsafe) static var isEnabled: Bool = false

    public enum Category: String {
        case engine, consumers, scenePhase, interop, metal, test
    }

    private enum Loggers {
        static let engine = Logger(subsystem: "com.cambrian.camerakit", category: "engine")
        static let consumers = Logger(subsystem: "com.cambrian.camerakit", category: "consumers")
        static let scenePhase = Logger(subsystem: "com.cambrian.camerakit", category: "scenePhase")
        static let interop = Logger(subsystem: "com.cambrian.camerakit", category: "interop")
        static let metal = Logger(subsystem: "com.cambrian.camerakit", category: "metal")
        static let test = Logger(subsystem: "com.cambrian.camerakit", category: "test")
    }

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .engine: return Loggers.engine
        case .consumers: return Loggers.consumers
        case .scenePhase: return Loggers.scenePhase
        case .interop: return Loggers.interop
        case .metal: return Loggers.metal
        case .test: return Loggers.test
        }
    }

    public static func notice(_ category: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: category).notice("\(s, privacy: .public)")
        write("[\(category.rawValue)] \(s)")
    }

    public static func info(_ category: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: category).info("\(s, privacy: .public)")
        write("[\(category.rawValue)] \(s)")
    }

    public static func warning(_ category: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: category).warning("\(s, privacy: .public)")
        write("[\(category.rawValue)] \(s)")
    }

    public static func error(_ category: Category, _ msg: @autoclosure () -> String) {
        guard isEnabled else { return }
        let s = msg()
        logger(for: category).error("\(s, privacy: .public)")
        write("[\(category.rawValue)] \(s)")
    }

    // MARK: - File sink (Wi-Fi device, no USB console available)

    // nonisolated(unsafe): written once on init(), read from multiple queues — all after init.
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    /// Opens `<Documents>/camerakit.log` for append and starts mirroring all log
    /// calls to it.
    ///
    /// Call once from `App.init()` alongside setting `isEnabled = true`.
    public static func enableFileLogging() {
        guard
            let docs = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else { return }
        let url = docs.appendingPathComponent("camerakit.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        write("=== CameraKit session started \(Date()) ===")
    }

    private static func write(_ message: String) {
        guard isEnabled, let fh = fileHandle else { return }
        let line = "\(timestamp()) \(message)\n"
        fh.write(Data(line.utf8))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
