// swift-tools-version: 5.9
import PackageDescription

// 结构说明(因本机无完整 Xcode,XCTest 不可用,改用纯 Swift 断言验证):
//   AliyunTokenBarCore  — library target,所有逻辑(模型/解析/鉴权/状态)
//   AliyunTokenBar      — executable,@main SwiftUI MenuBarExtra App + UI
//   Verify              — executable,纯 Swift 断言验证 Core 的逻辑层(替代 XCTest)
//
// ⚠️ Sparkle 集成方式:本机无完整 Xcode,无法用 xcodebuild 生成合规 xcframework,
// SPM 的 binaryTarget 拒绝手工包装的 zip。改用 unsafeFlags 直接链接预编译 Sparkle.framework:
//   -F <framework 路径>    指定 framework 搜索路径
//   -framework Sparkle     链接 Sparkle
// framework 在 Vendor/Sparkle/Sparkle.framework(打包脚本会把它嵌入 .app/Contents/Frameworks)。
let package = Package(
    name: "AliyunTokenBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AliyunTokenBarCore",
            path: "Sources/AliyunTokenBarCore"
        ),
        .executableTarget(
            name: "AliyunTokenBar",
            dependencies: ["AliyunTokenBarCore"],
            path: "Sources/AliyunTokenBar",
            // Swift 编译需 -F 找到 Sparkle.framework 的 modulemap;链接需 -framework Sparkle
            swiftSettings: [
                .unsafeFlags(["-F", "Vendor/Sparkle"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "Vendor/Sparkle",
                    "-framework", "Sparkle",
                    // 运行时 Sparkle.framework 在 .app/Contents/Frameworks,需 rpath 指向
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "Verify",
            dependencies: ["AliyunTokenBarCore"],
            path: "Sources/Verify"
        ),
    ]
)
