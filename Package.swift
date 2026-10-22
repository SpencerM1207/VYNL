// swift-tools-version: 5.9
// Swift 5 language mode on purpose: Swift 6 strict concurrency adds errors that can't be
// tested without a Mac toolchain. Revisit once the app is stable.
import PackageDescription

let package = Package(
    name: "VYNL",
    // Core Audio process taps (the EQ) need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        // The real-time EQ math lives in C so the audio thread never touches the Swift runtime:
        // no allocations, no locks, no reference counting.
        .target(
            name: "DevDockDSP",
            path: "Sources/DevDockDSP"
        ),
        // The app. Its folder keeps the old name (DevDock); the product is VYNL.
        .executableTarget(
            name: "VYNL",
            dependencies: ["DevDockDSP"],
            path: "Sources/DevDock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("WebKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
    ]
)
