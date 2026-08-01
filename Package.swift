// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AliyunTokenBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AliyunTokenBar",
            path: "Sources/AliyunTokenBar"
        ),
        .testTarget(
            name: "AliyunTokenBarTests",
            dependencies: ["AliyunTokenBar"],
            path: "Tests/AliyunTokenBarTests"
        ),
    ]
)
