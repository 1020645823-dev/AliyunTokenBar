// swift-tools-version: 5.9
import PackageDescription

// 本地 Sparkle 封装包:把预编译 Sparkle.xcframework 暴露为 SPM binaryTarget,
// 使主项目能 `import Sparkle` 而无需联网拉 GitHub(本机 github 网络受限)。
//
// 用法(在主项目 Package.swift 里加依赖):
//   .package(path: "Vendor/Sparkle")
//   .executableTarget(name: "AliyunTokenBar", dependencies: [
//       "AliyunTokenBarCore",
//       .product(name: "Sparkle", package: "Sparkle"),
//   ], ...)
//
// 前置:把 Sparkle.xcframework 放到本目录(从 Sparkle-x.x.x.tar.xz 解压,
// 或 Sparkle-for-Swift-Package-Manager.zip)。SPM binaryTarget 要求 xcframework
// 是一个 .zip 文件,因此打包前需先 `zip -r Sparkle.xcframework.zip Sparkle.xcframework`。
let package = Package(
    name: "Sparkle",
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"]),
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework.zip"
        ),
    ]
)
