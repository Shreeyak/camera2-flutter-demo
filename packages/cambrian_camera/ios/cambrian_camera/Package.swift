// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cambrian_camera",
    platforms: [.iOS("26.0")],
    products: [
        // Kebab-case product name — Flutter's auto-generated
        // FlutterGeneratedPluginSwiftPackage umbrella references it as
        // .product(name: "cambrian-camera", ...). Mismatch breaks discovery.
        .library(name: "cambrian-camera", targets: ["cambrian_camera"]),
    ],
    dependencies: [
        // CameraKit is consumed as a remote SwiftPM package pinned to the
        // upstream release tag. This replaces the former git-subtree vendoring;
        // URL dependencies resolve by package *identity* (the repo name), not by
        // a relative path, so the old "subtree must live inside the plugin dir"
        // fragility no longer applies. Pinned exact for reproducibility — bump
        // the version here to adopt a new CameraKit release.
        .package(url: "https://github.com/Shreeyak/cambrian-ios-camera.git", exact: "1.2.0"),
    ],
    targets: [
        .target(
            name: "cambrian_camera",
            dependencies: [
                // package: is the SwiftPM identity derived from the repo name
                // (lowercased, ".git" stripped) — NOT the package's declared
                // name ("CameraKit"). The product is still "CameraKit".
                .product(name: "CameraKit", package: "cambrian-ios-camera"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                // Plugin layer stays at Swift 5 to dodge the
                // FlutterMethodNotImplemented Sendable warning under strict Swift 6.
                // CameraKit's three internal targets stay Swift 6.
                .swiftLanguageMode(.v5),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
