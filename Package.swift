// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMgr",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalMgr", targets: ["LocalMgr"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "LocalMgr",
            dependencies: [],
            path: "Sources/LocalMgr",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
