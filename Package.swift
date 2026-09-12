// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CableScope",
    platforms: [.macOS(.v13)],
    targets: [
        // 系统 IO 适配层（IOKit / CoreFoundation / CoreGraphics 封装）
        .target(
            name: "CableKit",
            path: "Sources/CableKit"
        ),
        .testTarget(
            name: "CableKitTests",
            dependencies: ["CableKit"],
            path: "Tests/CableKitTests"
        ),
    ]
)
