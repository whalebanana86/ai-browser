// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feather",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Feather", path: "Sources/Feather"),
        .testTarget(name: "FeatherTests", dependencies: ["Feather"], path: "Tests/FeatherTests"),
    ]
)
