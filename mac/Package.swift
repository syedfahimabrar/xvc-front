// swift-tools-version: 5.9
import PackageDescription

// Phase 1: a headless CLI, no UI, no virtual mic. Deliberately zero dependencies —
// AVFoundation and URLSession cover capture, resampling, playout and WebSocket.
let package = Package(
    name: "xvc-cli",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "xvc-cli", path: "Sources/xvc-cli")
    ]
)
