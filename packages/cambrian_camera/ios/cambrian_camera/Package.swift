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
        // Vendored under the plugin's source tree via git subtree.
        // Path is relative to this Package.swift; Flutter's SPM integration
        // symlinks the plugin into ios/Flutter/ephemeral/Packages/.packages/
        // and evaluates relative paths from there, so the CameraKit subtree
        // MUST live inside the plugin directory (not as a sibling) so the
        // relative reference resolves under both the canonical and ephemeral
        // SPM container locations. Subtree prefix:
        // packages/cambrian_camera/ios/cambrian_camera/CameraKit/
        .package(path: "CameraKit"),
    ],
    targets: [
        .target(
            name: "cambrian_camera",
            dependencies: [
                .product(name: "CameraKit", package: "CameraKit"),
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
