// swift-tools-version: 5.9
import PackageDescription

// 结构说明(因本机无完整 Xcode,XCTest 不可用,改用纯 Swift 断言验证):
//   AliyunTokenBarCore  — library target,所有逻辑(模型/解析/鉴权/状态)
//   AliyunTokenBar      — executable,@main SwiftUI MenuBarExtra App + UI
//   Verify              — executable,纯 Swift 断言验证 Core 的逻辑层(替代 XCTest)
//
// ⚠️ Sparkle 集成:Vendor/Sparkle/Sparkle.xcframework.zip 就绪后,
// 取消下方 dependencies 与 .product(name:"Sparkle"...) 的注释,并在 App.swift/Menu.swift
// 启用 SparkleUpdater。下载未完成前注释掉以保持可构建。
let package = Package(
    name: "AliyunTokenBar",
    platforms: [.macOS(.v13)],
    // dependencies: [
    //     .package(path: "Vendor/Sparkle"),
    // ],
    targets: [
        .target(
            name: "AliyunTokenBarCore",
            path: "Sources/AliyunTokenBarCore"
        ),
        .executableTarget(
            name: "AliyunTokenBar",
            dependencies: [
                "AliyunTokenBarCore",
                // .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AliyunTokenBar"
        ),
        .executableTarget(
            name: "Verify",
            dependencies: ["AliyunTokenBarCore"],
            path: "Sources/Verify"
        ),
    ]
)
