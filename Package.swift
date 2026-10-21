// swift-tools-version:6.0
import PackageDescription

// The pure TOTP/HOTP/Base32/URI logic lives in `AuthenticatorCore`, which has
// no Apple-only dependencies and builds + tests on Linux too.
// The SwiftUI app target is only added when building on macOS.

var products: [Product] = [
    .library(name: "AuthenticatorCore", targets: ["AuthenticatorCore"]),
]

var targets: [Target] = [
    .target(
        name: "AuthenticatorCore",
        path: "Sources/AuthenticatorCore"
    ),
    .testTarget(
        name: "AuthenticatorCoreTests",
        dependencies: ["AuthenticatorCore"],
        path: "Tests/AuthenticatorCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "Authenticator", targets: ["Authenticator"]))
targets.append(
    .executableTarget(
        name: "Authenticator",
        dependencies: ["AuthenticatorCore"],
        path: "Sources/Authenticator",
        swiftSettings: [
            // UI code uses Swift 5 language mode to avoid strict-concurrency
            // churn with AppKit/Vision/ScreenCaptureKit types; the core
            // library is compiled in Swift 6 mode.
            .swiftLanguageMode(.v5),
        ],
        linkerSettings: [
            .linkedFramework("Security"),
            .linkedFramework("Vision"),
            .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("LocalAuthentication"),
            // Embed Info.plist so `swift run` gets a bundle id, display name, etc.
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Support/Info.plist",
            ]),
        ]
    )
)
#endif

let package = Package(
    name: "Authenticator",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
