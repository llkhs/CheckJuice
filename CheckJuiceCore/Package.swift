// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheckJuiceCore",
    // 核心逻辑不依赖 SwiftUI / UIKit / SwiftData，纯 Foundation。
    // 唯一目的：让 App、Widget、以及将来的 watchOS / 快捷指令复用同一套算法。
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CheckJuiceCore", targets: ["CheckJuiceCore"]),
        .library(name: "CheckJuiceStore", targets: ["CheckJuiceStore"]),
    ],
    targets: [
        // 纯算法。不认识任何 Apple 平台 API，可在任意 Swift 环境复用。
        .target(name: "CheckJuiceCore"),
        // 持久化 + App Group 共享。依赖 Core，但只碰 FileManager / JSON。
        // 单独成 target：让「算法」与「存哪儿」两件事互不污染。
        .target(name: "CheckJuiceStore", dependencies: ["CheckJuiceCore"]),
        .testTarget(
            name: "CheckJuiceCoreTests",
            dependencies: ["CheckJuiceCore", "CheckJuiceStore"],
            resources: [.process("Resources")]
        ),
    ]
)
