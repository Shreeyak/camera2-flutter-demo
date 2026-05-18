// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "CameraKit", targets: ["CameraKit"]),
        // TEMPORARY (Phase 1A): exported so the relocated DisplayViewModel
        // can `import CameraKitInterop` for CppCannyStub. Phase 1B removes
        // the OpenCV/Canny consumer from the package and unexports this.
        .library(name: "CameraKitInterop", targets: ["CameraKitInterop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        // C++ PixelSink pool + atomics. No OpenCV — Phase 1B (2026-05-15) moved
        // the Canny consumer + the opencv2 xcframework into the eva-swift-stitch
        // app target. The package now contains the consumer-join seam only
        // (PixelSinkPool fan-out, CaptureAtomic capture guard); external code
        // joins via engine.getNativePipelineHandle() + pixel_sink_pool_register.
        .target(
            name: "CameraKitCxx",
            dependencies: [],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("CPP_POOL_THREAD_COUNT", to: "4"),
                .headerSearchPath("include"),
            ]
        ),
        // Thin Swift C++ interop boundary — .interoperabilityMode(.Cxx) confined here (ADR-13).
        .target(
            name: "CameraKitInterop",
            dependencies: ["CameraKitCxx"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "CameraKit",
            dependencies: [
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Required to import CameraKitInterop (built with C++ interop).
                // No C++ types appear in CameraKit's public API — containment per ADR-13 is met.
                .interoperabilityMode(.Cxx),
            ]
        ),
        .testTarget(
            name: "CameraKitTests",
            dependencies: [
                "CameraKit",
                "CameraKitInterop",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
