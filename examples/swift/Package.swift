// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "inzm-swift",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "InzmCore", targets: ["InzmCore"]),
        .executable(name: "inzm", targets: ["inzm"]),
    ],
    targets: [
        .target(
            name: "InzmCore"
        ),
        .executableTarget(
            name: "inzm",
            dependencies: ["InzmCore"]
        ),
        .testTarget(
            name: "InzmCoreTests",
            dependencies: ["InzmCore"]
        ),
    ]
)
