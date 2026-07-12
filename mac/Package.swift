// swift-tools-version: 5.9
import PackageDescription

// XVCCore — the audio pipeline (capture, resample, jitter buffer, playout, WS client),
// shared by the headless CLI (test harness) and the menu-bar app. Zero dependencies:
// AVFoundation + URLSession cover everything.
let package = Package(
    name: "XVCLiveMic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "XVCCore", path: "Sources/XVCCore"),
        .executableTarget(name: "xvc-cli", dependencies: ["XVCCore"], path: "Sources/xvc-cli"),
        .executableTarget(name: "XVCLiveMic", dependencies: ["XVCCore"], path: "Sources/XVCLiveMic"),
    ]
)
