// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CableScope",
    platforms: [.macOS(.v14)],
    products: [
        // 供 Xcode 工程（xcodegen 生成）与未来外部引用使用
        .library(name: "CableKit", targets: ["CableKit"]),
    ],
    targets: [
        // 系统 IO 适配层（IOKit / CoreFoundation / CoreGraphics 封装）
        .target(
            name: "CableKit",
            path: "Sources/CableKit",
            resources: [
                .process("Resources")
            ]
        ),
        // CLI：开发期验证数据边界 + 用户可用的命令行工具
        .executableTarget(
            name: "CableScopeCLI",
            dependencies: ["CableKit"],
            path: "Sources/CableScopeCLI"
        ),
        // macOS 菜单栏 App（SwiftUI）
        .executableTarget(
            name: "CableScopeApp",
            dependencies: ["CableKit"],
            path: "Sources/CableScopeApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CableKitTests",
            dependencies: ["CableKit"],
            path: "Tests/CableKitTests"
        ),
        .testTarget(
            name: "CableScopeCLITests",
            dependencies: ["CableScopeCLI"],
            path: "Tests/CableScopeCLITests"
        ),
    ]
)
