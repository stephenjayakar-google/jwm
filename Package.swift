// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "jwm",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "jwm", path: "Sources/jwm"),
    ]
)
