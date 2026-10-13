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
    ],
    targets: [
        .target(name: "CheckJuiceCore"),
        .testTarget(
            name: "CheckJuiceCoreTests",
            dependencies: ["CheckJuiceCore"],
            resources: [.process("Resources")]
        ),
    ]
)
