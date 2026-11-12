// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "spike",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "spike", path: "Sources/spike")
    ]
)
