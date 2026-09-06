// swift-tools-version: 5.9
import PackageDescription

// 结构说明(因本机无完整 Xcode,XCTest 不可用,改用纯 Swift 断言验证):
//   AliyunTokenBarCore  — library target,所有逻辑(模型/解析/鉴权/状态)
//   AliyunTokenBar      — executable,@main SwiftUI MenuBarExtra App + UI
//   Verify              — executable,纯 Swift 断言验证 Core 的逻辑层(替代 XCTest)
//
// 注:已移除 Sparkle 自动更新(不检测/不下载/不弹更新)。App 不再依赖任何外部 framework。
let package = Package(
    name: "AliyunTokenBar",
    platforms: [.macOS(.v13)],
    // 显式 library product:外部工具/临时探针包可按路径依赖复用 Core(不影响现有 target 构建)
    products: [
        .library(name: "AliyunTokenBarCore", targets: ["AliyunTokenBarCore"])
    ],
    targets: [
        .target(
            name: "AliyunTokenBarCore",
            path: "Sources/AliyunTokenBarCore"
        ),
        .executableTarget(
            name: "AliyunTokenBar",
            dependencies: ["AliyunTokenBarCore"],
            path: "Sources/AliyunTokenBar"
        ),
        .executableTarget(
            name: "Verify",
            dependencies: ["AliyunTokenBarCore"],
            path: "Sources/Verify"
        ),
        // P2-A2:CI 双轨。开发机无完整 Xcode 时 XCTest 不可用,本地仍用 swift run Verify;
        // CI(macos-14/15 完整 Xcode)运行 swift test 获得覆盖率与失败聚合。
        .testTarget(
            name: "AliyunTokenBarCoreTests",
            dependencies: ["AliyunTokenBarCore"],
            path: "Tests/AliyunTokenBarCoreTests"
        ),
    ]
)
