// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoView",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "VideoView", path: "Sources/VideoView")
    ]
)
